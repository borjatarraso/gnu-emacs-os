;;; journal.el --- *journal* buffer, the live system log stream -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; what does it show: a single chronological feed of system log
;; records from every source we have. today that means /dev/kmsg
;; (kernel ring buffer), the contents of the *panic* buffer (elisp
;; errors routed through panic-handle), and, if it exists,
;; /var/log/messages (userspace). each line carries a wall- or
;; mono-clock timestamp, a source tag, a severity, and the message.
;;
;; how does it refresh: kmsg is followed by a long-running `dd
;; if=/dev/kmsg' subprocess whose stdout filter parses one record at
;; a time and appends it. the *panic* buffer is sampled by a 1-second
;; per-buffer timer that diffs against the last byte we copied.
;; /var/log/messages, when present, is polled by the same timer with
;; a stat+seek strategy. `g' force-rereads everything from scratch.
;;
;; what can the user do here: `g' force refresh, `c' clear the
;; visible buffer without stopping the source, `q' bury, `RET' on a
;; kmsg line opens a popup with the raw record, `n' / `p' jump to
;; the next/previous event of the same severity. read-only.
;;
;; what breaks if the source disappears: if /dev/kmsg is unreadable
;; (no CAP_SYSLOG, kernel.dmesg_restrict, namespace) the dd process
;; exits and we mark the kmsg source as down in the header line. the
;; panic and messages tails keep working. if dd itself is missing
;; (we are coreutils-less for some reason) we degrade to "kmsg: no
;; reader" and continue. a render error on a single record is caught
;; and routed through panic-handle; the stream keeps flowing.

(require 'panic)
(require 'port)

(defvar journal-buffer-name "*journal*"
  "Name of the canonical system log stream buffer.
Conceptually unkillable, same convention as the other buffers/.")

(defvar journal-buffer-raw-popup-name "*journal-record*"
  "Name of the popup that shows one raw kmsg record on RET.")

(defvar journal-buffer-messages-path "/var/log/messages"
  "Optional userspace log path. Folded in if and only if the file exists.")

(defvar journal-buffer-poll-interval 1
  "Seconds between *panic* and /var/log/messages polls.
Kmsg is event-driven via the dd process filter and does not use this.")

(defvar journal-buffer-max-lines 5000
  "Hard cap on rendered lines.
On overflow we trim the oldest 25%. Keeps the 100ms refresh budget
honest even if the kernel is screaming.")

(defvar-local journal-buffer--proc nil
  "The `dd if=/dev/kmsg' process feeding this buffer, or nil.")

(defvar-local journal-buffer--timer nil
  "Per-buffer timer that polls *panic* and /var/log/messages.")

(defvar-local journal-buffer--proc-residue ""
  "Bytes left over from the previous filter call that did not end in \\n.
Kmsg records are newline-terminated; partial reads happen.")

(defvar-local journal-buffer--target nil
  "Set on the dd work buffer to point at the *journal* buffer it feeds.
Filter and sentinel use this rather than `process-buffer' so the work
buffer can stay hidden and a filter error cannot leak raw kmsg bytes
into *journal*.  (round-5)")

(defvar-local journal-buffer--panic-mark 0
  "Number of characters already copied out of the *panic* buffer.")

(defvar-local journal-buffer--messages-pos 0
  "Byte offset already copied out of /var/log/messages.")

(defvar-local journal-buffer--kmsg-down nil
  "Non-nil if the kmsg follower has died. shown in the header line.")

;; severity faces. kmsg priorities are 0..7 per syslog. we collapse
;; emerg/alert/crit/err into "error", warning into "warn", notice/info
;; into "info", debug into "debug". keeps the palette short.
(defface journal-buffer-error-face
  '((t :inherit error))
  "Face for journal lines at err or worse.")

(defface journal-buffer-warn-face
  '((t :inherit warning))
  "Face for journal lines at warn.")

(defface journal-buffer-info-face
  '((t :inherit default))
  "Face for journal lines at info or notice.")

(defface journal-buffer-debug-face
  '((t :inherit shadow))
  "Face for journal lines at debug.")

(defun journal-buffer--severity-name (prio)
  "Map a numeric kmsg PRIO (0..7) to a short string."
  (pcase prio
    (0 "emerg") (1 "alert") (2 "crit") (3 "error")
    (4 "warn")  (5 "notice") (6 "info") (7 "debug")
    (_ "info")))

(defun journal-buffer--severity-bucket (sev)
  "Collapse a severity string SEV into one of error/warn/info/debug."
  (pcase sev
    ((or "emerg" "alert" "crit" "error") "error")
    ("warn" "warn")
    ("debug" "debug")
    (_ "info")))

(defun journal-buffer--face-for (sev)
  "Pick the face for severity string SEV."
  (pcase (journal-buffer--severity-bucket sev)
    ("error" 'journal-buffer-error-face)
    ("warn"  'journal-buffer-warn-face)
    ("debug" 'journal-buffer-debug-face)
    (_       'journal-buffer-info-face)))

;; kmsg record format, per Documentation/ABI/testing/dev-kmsg:
;;   PRIO,SEQ,TIMESTAMP_USEC,FLAGS[,...];MESSAGE\n
;;   <space>continuation key=value\n
;; we ignore continuation lines for now. the prefix before ';' is
;; comma-separated; the message is everything after the first ';'
;; up to (but not including) the terminating newline.
(defun journal-buffer--parse-kmsg-record (raw)
  "Parse one /dev/kmsg record RAW (no trailing newline).
Return a plist (:source kmsg :prio N :seq N :ts-usec N :sev S :msg S)
or nil if RAW does not look like a record."
  (let ((semi (string-match ";" raw)))
    (when semi
      (let* ((header (substring raw 0 semi))
             (msg    (substring raw (1+ semi)))
             (fields (split-string header ",")))
        (when (>= (length fields) 3)
          (let* ((prio (string-to-number (nth 0 fields)))
                 (seq  (string-to-number (nth 1 fields)))
                 (ts   (string-to-number (nth 2 fields))))
            (list :source 'kmsg
                  :prio prio
                  :seq seq
                  :ts-usec ts
                  :sev (journal-buffer--severity-name prio)
                  :msg msg
                  :raw raw)))))))

;; syslog (BSD/inetutils) line shape, as written by Debian Hurd's
;; inetutils-syslogd into /var/log/kern.log:
;;
;;   MMM DD HH:MM:SS HOST TAG[: ]REST...
;;
;; example:
;;   May 21 00:34:12 geos-hurd vmunix: cd0: dos partition I/O error
;;
;; the file is implicitly kern.* (syslog.conf routes kern.* there), so
;; no per-record priority is on the wire.  we default :sev to "info"
;; and leave :prio + :seq nil; the renderer copes (it reads :sev and
;; :msg; missing :prio/:seq just hides those rows in the RET popup).
;;
;; the timestamp lacks a year; syslog convention is "current year".
;; we use the host's current year + parse-time-string which returns a
;; decoded-time we hand to encode-time.  if parsing fails we return
;; nil so the filter drops the line rather than rendering an unparsed
;; smear.  malformed lines (missing HOST or TAG) likewise yield nil.
(defun journal-buffer--parse-syslog-record (raw)
  "Parse one syslog/kern.log line RAW (no trailing newline).
Return a plist (:source syslog :time TIME :sev \"info\" :msg S :raw R)
or nil if RAW does not look like a syslog line."
  (when (and (stringp raw)
             (string-match
              ;; MMM DD HH:MM:SS HOST TAG REST
              ;; HOST: \S+ (no whitespace, no colon).
              ;; TAG: everything up to the first ": " separator; we
              ;; do not split off the tag into its own field because
              ;; the renderer does not use it and the message is the
              ;; whole suffix including the optional tag prefix.
              (concat "^"
                      "\\([A-Z][a-z][a-z]\\)[ ]+"     ; 1 month
                      "\\([0-9]+\\)[ ]+"               ; 2 day
                      "\\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\)[ ]+"  ; 3 hh:mm:ss
                      "\\([^ :]+\\)[ ]+"               ; 4 host
                      "\\(.+\\)$")                     ; 5 rest (tag + msg)
              raw))
    (condition-case nil
        (let* ((mon-str (match-string 1 raw))
               (day     (string-to-number (match-string 2 raw)))
               (hms     (match-string 3 raw))
               (rest    (match-string 5 raw))
               (year    (nth 5 (decode-time (current-time))))
               (decoded (parse-time-string
                         (format "%s %d %s %d" mon-str day hms year)))
               (time    (and decoded (encode-time decoded))))
          (and time
               (list :source 'syslog
                     :time time
                     :sev "info"
                     :msg rest
                     :raw raw)))
      (error nil))))

(defun journal-buffer--format-ts (rec)
  "Return a fixed-width timestamp string for record REC.
Kmsg records carry a monotonic microsecond timestamp; we render
that as [seconds.fff]. panic and messages records carry a wall
clock and we render as HH:MM:SS."
  (pcase (plist-get rec :source)
    ('kmsg
     (let* ((us (or (plist-get rec :ts-usec) 0))
            (s  (/ us 1000000))
            (ms (/ (mod us 1000000) 1000)))
       (format "[%5d.%03d]" s ms)))
    (_
     (format-time-string "%H:%M:%S" (or (plist-get rec :time) (current-time))))))

(defun journal-buffer--render-record (rec)
  "Insert one record REC at point in the current buffer.
Caller must have `inhibit-read-only' bound and must be at the
position where the record should land (typically point-max)."
  (let* ((sev (or (plist-get rec :sev) "info"))
         (face (journal-buffer--face-for sev))
         (src  (symbol-name (or (plist-get rec :source) 'unknown)))
         (ts   (journal-buffer--format-ts rec))
         (msg  (or (plist-get rec :msg) ""))
         (line (format "%s %-5s %-5s %s" ts src sev msg)))
    (insert (propertize line
                        'face face
                        'journal-record rec
                        'journal-severity sev))
    (insert "\n")))

(defun journal-buffer--at-tail-p ()
  "Return non-nil if point is at point-max (so we should auto-scroll)."
  (= (point) (point-max)))

(defvar-local journal-buffer--line-count 0
  "Local approximate line count, maintained incrementally.
Cheaper than count-lines per tick (which is O(buffer-size)).
(MAJOR, audit round-5 2026-05-10)")

(defun journal-buffer--append-records (recs)
  "Append RECS (list of plists) to the current buffer.
Auto-scrolls only if point was at point-max before the append.
Trims oldest lines if we cross `journal-buffer-max-lines'.
(MAJOR, round-5) maintains an incremental line counter so we never
re-walk the whole buffer per tick."
  (when recs
    (let ((stick (journal-buffer--at-tail-p))
          (inhibit-read-only t)
          (added 0))
      (save-excursion
        (goto-char (point-max))
        (dolist (r recs)
          (condition-case err
              (progn
                (journal-buffer--render-record r)
                (setq added (1+ added)))
            (error
             (condition-case _
                 (when (fboundp 'panic-handle)
                   (panic-handle err 'journal-buffer-render))
               (error nil))))))
      (cl-incf journal-buffer--line-count added)
      ;; trim only when the local counter says we should.  the trim
      ;; itself updates the counter from the actual delete-region
      ;; instead of a re-count; keeps the loop O(records-added) rather
      ;; than O(buffer-size).
      (when (> journal-buffer--line-count journal-buffer-max-lines)
        (let* ((cut (/ journal-buffer-max-lines 4))
               (start (point-min)))
          (save-excursion
            (goto-char start)
            (forward-line cut)
            (delete-region start (point))
            (setq journal-buffer--line-count
                  (max 0 (- journal-buffer--line-count cut))))))
      (when stick
        (goto-char (point-max))
        ;; (MAJOR, round-5) walk EVERY window showing this buffer, not
        ;; just one.  multi-frame setups otherwise scroll only one
        ;; frame and the others freeze with stale point.
        (dolist (win (get-buffer-window-list (current-buffer) nil t))
          (set-window-point win (point-max)))))))

;; ---------------- kmsg follower (dd subprocess) ----------------

(defun journal-buffer--kmsg-filter (proc chunk)
  "Process filter for the dd /dev/kmsg follower.
PROC is the dd process; CHUNK is the raw bytes it just produced.
We accumulate any leftover from a partial record and flush every
complete \\n-terminated record into the journal buffer.
(round-5) the target *journal* buffer is found via the work-buffer's
buffer-local `journal-buffer--target'; process-buffer points at the
work buffer, not at *journal*."
  (let* ((work (process-buffer proc))
         (buf (and (buffer-live-p work)
                   (buffer-local-value 'journal-buffer--target work))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (condition-case err
            (let* ((data (concat journal-buffer--proc-residue chunk))
                   (parts (split-string data "\n"))
                   (last (car (last parts)))
                   (complete (butlast parts))
                   (recs '()))
              ;; the trailing element after a final \n is "". if the
              ;; chunk did not end in \n, last is a partial record we
              ;; must hold for next time.
              (setq journal-buffer--proc-residue (or last ""))
              (dolist (raw complete)
                (unless (string-empty-p raw)
                  ;; continuation lines start with a space; skip them
                  ;; for now, we only render the head line.
                  (unless (and (> (length raw) 0)
                               (eq (aref raw 0) ?\s))
                    (let ((rec (journal-buffer--parse-kmsg-record raw)))
                      (when rec
                        (push rec recs))))))
              (when recs
                (journal-buffer--append-records (nreverse recs))))
          (error
           (when (fboundp 'panic-handle)
             (panic-handle err 'journal-buffer-kmsg-filter))))))))

(defun journal-buffer--kmsg-sentinel (proc event)
  "Sentinel for the dd process. Marks kmsg as down on exit.
(round-5) finds the target *journal* buffer via the work-buffer's
buffer-local `journal-buffer--target'."
  (let* ((work (process-buffer proc))
         (buf (and (buffer-live-p work)
                   (buffer-local-value 'journal-buffer--target work))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq journal-buffer--kmsg-down t)
        (journal-buffer--update-header)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert (propertize
                     (format "-- kmsg follower exited: %s"
                             (string-trim event))
                     'face 'journal-buffer-warn-face))
            (insert "\n")))))
    ;; clean up the work buffer so we do not leak hidden buffers each
    ;; time the supervisor reaps and respawns the journal viewer.
    (when (buffer-live-p work) (kill-buffer work))))

(defun journal-buffer--start-kmsg (buf)
  "Spawn `dd if=/dev/kmsg' attached to BUF.
We use dd because it is a coreutils binary, not a shell, which
satisfies /no-shell-check. cat would also work but cat under
emacs-init's no-shell stub feels too close to the shell line; dd
is unambiguously a binary tool. iflag=nonblock would be nicer but
not all coreutils builds have it; we accept blocking reads since
dd is in its own process.

On hurd /dev/kmsg does not exist.  spawning dd here would error in
make-process (ENOENT on the device) and the kmsg-down flag would
flip on its own, but the panic-handle entry the C-side ENOENT
produces is ugly and confusing (looks like dd is missing rather
than the device).  branch up front: route a clean port-unimplemented
event for `journal-kmsg' and return nil.  the in-buffer renderer
already copes with a never-started follower (panic + messages tails
keep working), and `journal-buffer--update-header' shows kmsg:down."
  (cond
   ((not (geos-kernel-linux-p))
    (with-current-buffer buf
      (setq journal-buffer--kmsg-down t)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert (propertize
                   "-- no /dev/kmsg on this kernel; kmsg follower not started"
                   'face 'journal-buffer-warn-face))
          (insert "\n"))))
    (geos-port-unimplemented 'journal-kmsg)
    nil)
   (t
  (condition-case err
      (progn
        ;; (MAJOR, round-5) initialise the residue + down flag BEFORE
        ;; make-process so the filter sees a consistent state if the
        ;; very first chunk arrives between fork+exec and the setq
        ;; below.  the prior order set these AFTER make-process and
        ;; relied on mode-setup having run first; the invariant was
        ;; implicit and would silently regress if a future caller
        ;; spawns kmsg before mode setup.  also use a hidden work
        ;; buffer instead of `:buffer buf' so a filter error cannot
        ;; leak raw kmsg bytes into *journal* via process-mark
        ;; default insertion.
        (with-current-buffer buf
          (setq journal-buffer--proc-residue ""
                journal-buffer--kmsg-down nil))
        (let* ((work (generate-new-buffer
                      (format " *journal-kmsg-stdout-%s*" (buffer-name buf))))
               (proc (make-process
                      :name "journal-kmsg"
                      :buffer work
                      :command '("dd" "if=/dev/kmsg" "bs=8192" "status=none")
                      :connection-type 'pipe
                      :noquery t
                      :filter   #'journal-buffer--kmsg-filter
                      :sentinel #'journal-buffer--kmsg-sentinel)))
          ;; tag the work buffer with the journal buffer it feeds, so
          ;; the filter/sentinel can find their target without using
          ;; process-buffer (which is the work buffer, not *journal*).
          (with-current-buffer work
            (setq-local journal-buffer--target buf))
          (with-current-buffer buf
            (setq journal-buffer--proc proc))))
    (error
     (with-current-buffer buf
       (setq journal-buffer--kmsg-down t))
     (when (fboundp 'panic-handle)
       (panic-handle err 'journal-buffer-start-kmsg)))))))

;; ---------------- panic buffer tail ----------------

(defun journal-buffer--drain-panic (buf)
  "Copy any new bytes from *panic* into journal BUF.
We track how many characters of *panic* we have already absorbed
in `journal-buffer--panic-mark' and only fold in the suffix.

Mark semantics: we store the last point-max we copied through.
buffer-substring is half-open at the end and 1-based at the start,
so the next slice is [mark, end).  initial value 0 collapses to
point-min on the first drain.  the previous code used (1+ mark)
which dropped one byte per drain cycle, so the first byte after
each tick was lost."
  (let ((src (get-buffer panic-buffer-name)))
    (when src
      (with-current-buffer buf
        (let* ((mark journal-buffer--panic-mark)
               (end  (with-current-buffer src (point-max)))
               (start (if (zerop mark)
                          (with-current-buffer src (point-min))
                        mark)))
          (when (< start end)
            (let* ((chunk (with-current-buffer src
                            (buffer-substring-no-properties start end)))
                   (lines (split-string chunk "\n" t))
                   (now (current-time))
                   (recs (mapcar
                          (lambda (l)
                            (list :source 'panic
                                  :sev "error"
                                  :msg l
                                  :time now
                                  :raw l))
                          lines)))
              (setq journal-buffer--panic-mark end)
              (journal-buffer--append-records recs))))))))

;; ---------------- /var/log/messages tail ----------------

(defun journal-buffer--drain-messages (buf)
  "Copy any new bytes from /var/log/messages into journal BUF.
No-op if the file does not exist. Tracks position by byte offset
in `journal-buffer--messages-pos'. If the file shrinks (rotated)
we restart from zero."
  (when (file-readable-p journal-buffer-messages-path)
    (condition-case err
        (let* ((attrs (file-attributes journal-buffer-messages-path))
               ;; attrs can be nil if the file vanished between
               ;; file-readable-p and file-attributes (rotation race).
               ;; file-attribute-size on nil returns nil, and the
               ;; numeric comparisons below would then signal
               ;; wrong-type-argument and abort the whole timer tick.
               (size  (and attrs (file-attribute-size attrs))))
          (when (numberp size)
            (with-current-buffer buf
              (when (< size journal-buffer--messages-pos)
                (setq journal-buffer--messages-pos 0))
              (when (> size journal-buffer--messages-pos)
                (let ((from journal-buffer--messages-pos)
                      (to   size))
                  (with-temp-buffer
                    (insert-file-contents journal-buffer-messages-path
                                          nil from to)
                    (let* ((text (buffer-string))
                           (lines (split-string text "\n" t))
                           (now (current-time))
                           (recs (mapcar
                                  (lambda (l)
                                    ;; very loose: treat the whole line
                                    ;; as the message, severity unknown.
                                    (list :source 'messages
                                          :sev "info"
                                          :msg l
                                          :time now
                                          :raw l))
                                  lines)))
                      (with-current-buffer buf
                        (setq journal-buffer--messages-pos to)
                        (journal-buffer--append-records recs)))))))))
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err 'journal-buffer-drain-messages))))))

;; ---------------- timer plumbing ----------------

(defun journal-buffer--timer-tick (buf)
  "Poll panic and /var/log/messages into BUF.
Self-cancels if BUF has been killed without the kill-hook running
(symmetry with network-buffer's defensive cancel)."
  (if (buffer-live-p buf)
      (condition-case err
          (progn
            (journal-buffer--drain-panic buf)
            (journal-buffer--drain-messages buf))
        (error
         (when (fboundp 'panic-handle)
           (panic-handle err 'journal-buffer-timer))))
    (dolist (tm (append timer-list timer-idle-list))
      (when (and (timerp tm)
                 (eq (timer--function tm) #'journal-buffer--timer-tick)
                 (equal (timer--args tm) (list buf)))
        (cancel-timer tm)))))

(defun journal-buffer--start-timer (buf)
  "Install the per-buffer poll timer on BUF."
  (with-current-buffer buf
    (when (timerp journal-buffer--timer)
      (cancel-timer journal-buffer--timer))
    (setq journal-buffer--timer
          (run-at-time journal-buffer-poll-interval
                       journal-buffer-poll-interval
                       #'journal-buffer--timer-tick
                       buf))))

(defun journal-buffer--update-header ()
  "Refresh the header line to reflect source health."
  (setq header-line-format
        (format "*journal*  kmsg:%s  panic:on  messages:%s"
                (if journal-buffer--kmsg-down "down" "on")
                (if (file-readable-p journal-buffer-messages-path)
                    "on" "absent"))))

;; ---------------- interactive commands ----------------

(defun journal-buffer-refresh ()
  "Force a re-read of every source. Bound to `g'.
Idempotent: kmsg's existing tail keeps running, we just resync
the panic mark and the messages position so anything we missed
gets pulled in."
  (interactive)
  (let ((buf (get-buffer journal-buffer-name)))
    (when buf
      (with-current-buffer buf
        (condition-case err
            (progn
              (journal-buffer--drain-panic buf)
              (journal-buffer--drain-messages buf)
              (journal-buffer--update-header))
          (error
           (when (fboundp 'panic-handle)
             (panic-handle err 'journal-buffer-refresh))))))))

(defun journal-buffer-clear ()
  "Erase the visible buffer without stopping the source.
Bound to `c'. Sources keep flowing; the next event will land in
an empty buffer. Useful when you want to watch for a specific
event after clearing the noise."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (journal-buffer--update-header)))

(defun journal-buffer-quit ()
  "Bury *journal*. Per project rules we do not kill it."
  (interactive)
  (bury-buffer))

(defun journal-buffer-record-at-point ()
  "Return the record plist stored on the current line, or nil."
  (get-text-property (line-beginning-position) 'journal-record))

(defun journal-buffer-show-raw ()
  "Pop a buffer with the raw record at point. Bound to `RET'.
Silently no-ops on lines without a record (e.g. clear markers)."
  (interactive)
  (let ((rec (journal-buffer-record-at-point)))
    (when rec
      (let ((buf (get-buffer-create journal-buffer-raw-popup-name)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (special-mode)
            (insert (format "source:   %s\n" (plist-get rec :source)))
            (insert (format "severity: %s\n" (plist-get rec :sev)))
            (when (plist-get rec :prio)
              (insert (format "priority: %d\n" (plist-get rec :prio))))
            (when (plist-get rec :seq)
              (insert (format "sequence: %d\n" (plist-get rec :seq))))
            (when (plist-get rec :ts-usec)
              (insert (format "ts-usec:  %d\n" (plist-get rec :ts-usec))))
            (insert "raw:\n")
            (insert (or (plist-get rec :raw) (plist-get rec :msg) ""))
            (goto-char (point-min))))
        (display-buffer buf)))))

(defun journal-buffer--jump (direction)
  "Move to the next (DIRECTION = 1) or prev (-1) line of same severity.
Severity comes from the line at point. If point is on a line
without a recorded severity we fall back to plain forward-line."
  (let ((sev (get-text-property (line-beginning-position) 'journal-severity)))
    (if (null sev)
        (forward-line direction)
      (let ((found nil)
            (start (point)))
        (forward-line direction)
        (while (and (not found)
                    (not (if (> direction 0) (eobp) (bobp))))
          (let ((here (get-text-property (line-beginning-position)
                                         'journal-severity)))
            (if (equal here sev)
                (setq found t)
              (forward-line direction))))
        (unless found
          (goto-char start)
          (message "no further %s events" sev))))))

(defun journal-buffer-next-of-severity ()
  "Jump to the next event of the same severity as the current line."
  (interactive)
  (journal-buffer--jump 1))

(defun journal-buffer-prev-of-severity ()
  "Jump to the previous event of the same severity as the current line."
  (interactive)
  (journal-buffer--jump -1))

;; ---------------- mode + entry point ----------------

(defun journal-buffer--kill-hook ()
  "Stop the kmsg follower and the poll timer when *journal* dies.
Project rule: this buffer is conceptually unkillable. The hook is
present for symmetry, and to make sure we do not leak a dd
subprocess if someone forces the buffer dead from M-x."
  (when (timerp journal-buffer--timer)
    (cancel-timer journal-buffer--timer)
    (setq journal-buffer--timer nil))
  (when (process-live-p journal-buffer--proc)
    (condition-case err
        (delete-process journal-buffer--proc)
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err 'journal-buffer-kill-hook)))))
  (setq journal-buffer--proc nil))

(defvar journal-buffer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g")   #'journal-buffer-refresh)
    (define-key m (kbd "c")   #'journal-buffer-clear)
    (define-key m (kbd "q")   #'journal-buffer-quit)
    (define-key m (kbd "RET") #'journal-buffer-show-raw)
    (define-key m (kbd "n")   #'journal-buffer-next-of-severity)
    (define-key m (kbd "p")   #'journal-buffer-prev-of-severity)
    m)
  "Keymap for `journal-buffer-mode'.")

(define-derived-mode journal-buffer-mode special-mode "Journal"
  "Major mode for the *journal* buffer.
Live system log stream from /dev/kmsg, the *panic* buffer, and
/var/log/messages when present. See the file commentary for the
four-question contract."
  (setq truncate-lines t)
  (setq-local journal-buffer--proc-residue "")
  (setq-local journal-buffer--panic-mark 0)
  (setq-local journal-buffer--messages-pos 0)
  (journal-buffer--update-header)
  (add-hook 'kill-buffer-hook #'journal-buffer--kill-hook nil t))

(defun journal-buffer--supervised-kmsg-p ()
  "Return non-nil if core/supervise.el owns the kmsg follower for us.
When services/journal-tail.el has registered `journal-kmsg' with the
supervisor, the supervised dd writes into a hidden work buffer and a
filter routes records into *journal*.  spawning a second dd from this
file would double-feed every record.  the gate is conservative: if
`supervise-status' is unbound (no supervisor on this host) or returns
nil (registry knows nothing about our service), we fall back to the
in-buffer lazy spawn so the dev-host path still works."
  (and (fboundp 'supervise-status)
       (supervise-status 'journal-kmsg)))

;;;###autoload
(defun journal ()
  "Display the *journal* buffer, creating it on first call.
Interactive entry point: `M-x journal'. Starts the panic/messages
poll timer if it is not already running.  the kmsg follower itself
is owned by services/journal-tail.el under the supervisor; on a
dev host where the supervisor is absent, falls back to spawning
an in-buffer dd."
  (interactive)
  (let ((buf (get-buffer-create journal-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'journal-buffer-mode)
        (journal-buffer-mode))
      (unless (or (process-live-p journal-buffer--proc)
                  (journal-buffer--supervised-kmsg-p))
        (journal-buffer--start-kmsg buf))
      (unless (timerp journal-buffer--timer)
        (journal-buffer--start-timer buf))
      ;; first paint: pull whatever panic and messages already have.
      (journal-buffer--drain-panic buf)
      (journal-buffer--drain-messages buf)
      (journal-buffer--update-header))
    (display-buffer buf)
    buf))

(provide 'journal-buffer)
;;; journal.el ends here
