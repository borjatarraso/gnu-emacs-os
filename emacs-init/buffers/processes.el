;;; processes.el --- *processes* buffer, the live UI for top / htop -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; what does it show: the current set of running processes, walked
;; directly out of /proc. one row per pid with pid, user, state, rss
;; in kb, a cpu% sample, the comm name, and the tail of the cmdline.
;; sorted by pid ascending. no kthreads filtering, they are real and
;; the user gets to see them.
;;
;; how does it refresh: a 2-second repeating timer that the buffer
;; owns. timer is started on first display and cancelled when the
;; buffer is killed. `g' forces an immediate refresh. cpu% is computed
;; as the delta of (utime+stime) jiffies between successive ticks
;; against the wall delta, so the first frame after open shows 0.0
;; for every row. that is fine, it converges in two seconds.
;;
;; what can the user do here: `g' refresh, `RET' on a row pops a
;; *process-details* buffer with the full /proc/PID/status dump,
;; `k' prompts for a signal (default TERM) and sends it via
;; `signal-process', `q' buries (we never kill our concept buffers).
;;
;; what breaks if the source disappears: /proc is kernel-provided and
;; effectively always present on Linux. if a pid disappears mid-walk
;; (very common, processes exit constantly) we silently skip the row
;; and keep going. if /proc itself is unreadable the buffer prints
;; "no data" and routes the underlying error through `panic-handle'.
;; it does NOT die.

;; same load-order hazard as network.el: panic may not be loaded yet
;; under early byte-compile or repl eval. tolerate it.
(condition-case err
    (require 'panic)
  (error
   (message "processes-buffer: require panic failed: %S" err)))

;; cl-position lives in cl-lib.  emacs ships it preloaded most days,
;; but byte-compile and -Q without site-load do not, so be explicit.
(require 'cl-lib)

(defvar processes-buffer-name "*processes*"
  "Name of the canonical processes state buffer.
Per project rules this buffer is conceptually unkillable. the
timer cleanup hook exists for symmetry, not because we expect
the buffer to die.")

(defvar processes-buffer-details-name "*process-details*"
  "Name of the popup buffer that shows /proc/PID/status for one pid.")

(defvar processes-buffer-refresh-interval 2
  "Seconds between automatic refreshes of *processes*.
Two seconds keeps cpu% smoothing readable and parsing 1000 pids
stays well under our 100ms budget on /proc.")

(defvar-local processes-buffer--timer nil
  "Per-buffer timer driving auto-refresh. Cancelled in the kill hook.")

(defvar-local processes-buffer--last-jiffies (make-hash-table :test 'eql)
  "Map pid -> last (utime+stime) jiffies sample, for cpu% delta.")

(defvar-local processes-buffer--last-sample-time nil
  "`float-time' at which the last jiffies sample was taken.")

(defvar processes-buffer--clk-tck 100
  "Assumed CLK_TCK. /proc reports jiffies in units of this.
Linux defaults to 100 on x86_64 and we do not have sysconf in
elisp without a module. if a kernel ships with CONFIG_HZ != 100
the cpu% will be off by a constant factor. acceptable.")

(defvar processes-buffer--uid-cache (make-hash-table :test 'eql)
  "Map uid -> resolved username string. /etc/passwd is read once.")

(defvar processes-buffer--uid-cache-loaded nil
  "Non-nil after we have walked /etc/passwd into the uid cache.")

(defun processes-buffer--load-passwd ()
  "Populate `processes-buffer--uid-cache' from /etc/passwd.
We do not invalidate. user creation is rare and the cost of a
restart is zero. errors are swallowed: an unreadable /etc/passwd
just means every user shows as their numeric uid."
  (unless processes-buffer--uid-cache-loaded
    (setq processes-buffer--uid-cache-loaded t)
    (condition-case _err
        (with-temp-buffer
          (insert-file-contents "/etc/passwd")
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((line (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))
                   (fields (split-string line ":")))
              (when (>= (length fields) 3)
                (let ((name (nth 0 fields))
                      (uid (string-to-number (nth 2 fields))))
                  (puthash uid name processes-buffer--uid-cache))))
            (forward-line 1)))
      (error nil))))

(defun processes-buffer--user-for-uid (uid)
  "Return the username string for UID, or the numeric uid as a fallback."
  (processes-buffer--load-passwd)
  (or (gethash uid processes-buffer--uid-cache)
      (number-to-string uid)))

(defun processes-buffer--read-file (path)
  "Slurp PATH into a string. Return nil on any error.
We use this for the small /proc files. inhibiting message and
file-name-handler keeps tramp and friends out of the hot path."
  (condition-case _err
      (let ((inhibit-message t)
            (file-name-handler-alist nil))
        (with-temp-buffer
          (insert-file-contents path)
          (buffer-substring-no-properties (point-min) (point-max))))
    (error nil)))

(defun processes-buffer--parse-stat (raw)
  "Parse /proc/PID/stat RAW. Return a plist or nil on failure.
The comm field (field 2) is wrapped in parens and may itself
contain whitespace and parens. you cannot just `split-string' on
spaces, you have to find the LAST `)' and split before/after.
this is the one bit of /proc parsing that bites everybody once."
  (when raw
    (let* ((open (string-match "(" raw))
           (close (and open (cl-position ?\) raw :from-end t))))
      (when (and open close (> close open))
        (let* ((pid-part (substring raw 0 open))
               (comm (substring raw (1+ open) close))
               (rest-part (substring raw (1+ close)))
               (pid (string-to-number (string-trim pid-part)))
               ;; rest fields, 1-indexed in the man page starting at 3.
               ;; we re-zero-index here. so rest-fields[0] == proc(5) field 3.
               (rest-fields (split-string (string-trim rest-part)
                                          " " t)))
          (when (>= (length rest-fields) 22)
            (list :pid pid
                  :comm comm
                  :state (nth 0 rest-fields)
                  :ppid (string-to-number (nth 1 rest-fields))
                  :utime (string-to-number (nth 11 rest-fields))
                  :stime (string-to-number (nth 12 rest-fields))
                  :starttime (string-to-number (nth 19 rest-fields)))))))))

(defun processes-buffer--parse-status-uid (raw)
  "Pull the real uid out of a /proc/PID/status RAW string.
Uid: line is `Uid:\\truid\\teuid\\tsuid\\tfsuid'. we want ruid."
  (when raw
    (when (string-match "^Uid:[ \t]+\\([0-9]+\\)" raw)
      (string-to-number (match-string 1 raw)))))

(defun processes-buffer--parse-status-rss (raw)
  "Pull VmRSS in kB out of a /proc/PID/status RAW string.
Kernel threads have no VmRSS line, return 0 for them."
  (when raw
    (if (string-match "^VmRSS:[ \t]+\\([0-9]+\\)" raw)
        (string-to-number (match-string 1 raw))
      0)))

(defun processes-buffer--parse-cmdline (raw)
  "Render /proc/PID/cmdline RAW into a single space-separated string.
The file uses NUL bytes as argv separators and ends with a NUL.
empty file means kernel thread, return empty string."
  (if (or (null raw) (string-empty-p raw))
      ""
    (let* ((trimmed (if (and (> (length raw) 0)
                             (eq (aref raw (1- (length raw))) 0))
                        (substring raw 0 (1- (length raw)))
                      raw))
           (parts (split-string trimmed "\0" t)))
      (mapconcat #'identity parts " "))))

(defun processes-buffer--list-pids ()
  "Return a sorted list of integer pids currently in /proc.
We filter for all-digit directory names. we tolerate
disappearing entries between this listing and the per-pid reads
later, that is the nature of /proc."
  (let (pids)
    (condition-case _err
        (dolist (name (directory-files "/proc" nil "\\`[0-9]+\\'" t))
          (push (string-to-number name) pids))
      (error nil))
    (sort pids #'<)))

(defconst processes-buffer-pid-cap 2000
  "Hard cap on rows shown in *processes*.
Walking /proc with no bound costs O(N) syscalls, O(N) parses, and O(N)
inserts per refresh.  On a container host with 10K+ pids the buffer
becomes hundreds of MB and the 2-second refresh tick falls behind
itself.  When we hit the cap we render the first N pids in ascending
order and append a single \"[... M more ...]\" footer line in
`processes-buffer--render'.  2000 is enough to cover a desktop and
most servers without paging the operator out of context.
(BLOCKER, audit round-5 2026-05-10)")

(defvar processes-buffer--truncated 0
  "How many pids were dropped on the most recent collect, for the footer.")

(defun processes-buffer--collect ()
  "Walk /proc and return a list of process plists.
Each plist carries :pid :user :state :rss :cpu :comm :cmdline.
cpu% is filled in against `processes-buffer--last-jiffies' from
the previous tick. on the first tick everything reads 0.0.
Cap of `processes-buffer-pid-cap' applied; surplus pids tracked in
`processes-buffer--truncated'."
  (let* ((now (float-time))
         (dt (if processes-buffer--last-sample-time
                 (max 0.001 (- now processes-buffer--last-sample-time))
               nil))
         (new-jiffies (make-hash-table :test 'eql))
         (rows nil)
         (all-pids (processes-buffer--list-pids))
         (n-all (length all-pids))
         (capped (if (> n-all processes-buffer-pid-cap)
                     (seq-take all-pids processes-buffer-pid-cap)
                   all-pids)))
    (setq processes-buffer--truncated (max 0 (- n-all (length capped))))
    (dolist (pid capped)
      (let* ((stat-raw (processes-buffer--read-file
                        (format "/proc/%d/stat" pid)))
             (stat (processes-buffer--parse-stat stat-raw)))
        (when stat
          (let* ((status-raw (processes-buffer--read-file
                              (format "/proc/%d/status" pid)))
                 (cmdline-raw (processes-buffer--read-file
                               (format "/proc/%d/cmdline" pid)))
                 (uid (or (processes-buffer--parse-status-uid status-raw) 0))
                 (rss (or (processes-buffer--parse-status-rss status-raw) 0))
                 (cmdline (processes-buffer--parse-cmdline cmdline-raw))
                 (jiffies (+ (plist-get stat :utime)
                             (plist-get stat :stime)))
                 (prev (gethash pid processes-buffer--last-jiffies))
                 (cpu (if (and prev dt)
                          (let ((djiff (max 0 (- jiffies prev))))
                            (* 100.0
                               (/ (/ (float djiff)
                                     processes-buffer--clk-tck)
                                  dt)))
                        0.0)))
            (puthash pid jiffies new-jiffies)
            (push (list :pid pid
                        :user (processes-buffer--user-for-uid uid)
                        :state (plist-get stat :state)
                        :rss rss
                        :cpu cpu
                        :comm (plist-get stat :comm)
                        :cmdline cmdline)
                  rows)))))
    (setq processes-buffer--last-jiffies new-jiffies
          processes-buffer--last-sample-time now)
    ;; pids were collected in ascending order and we pushed, so reverse
    ;; restores ascending. avoids a sort pass.
    (nreverse rows)))

(defun processes-buffer--render-row (row)
  "Format ROW (a process plist) as a single line, propertized."
  (let* ((pid (plist-get row :pid))
         (cmdline (plist-get row :cmdline))
         ;; tail: keep last 60 chars, that is usually the meaningful part
         ;; (long java/python invocations bury the script name at the end).
         (cmd-tail (if (> (length cmdline) 60)
                       (concat "..." (substring cmdline (- (length cmdline) 57)))
                     cmdline))
         (line (format "%6d %-10s %-2s %10d %5.1f %-16s %s"
                       pid
                       (truncate-string-to-width
                        (plist-get row :user) 10 nil ?\s)
                       (plist-get row :state)
                       (plist-get row :rss)
                       (plist-get row :cpu)
                       (truncate-string-to-width
                        (plist-get row :comm) 16 nil ?\s)
                       cmd-tail)))
    (propertize line 'processes-row row)))

(defun processes-buffer--render ()
  "Repaint the current buffer from /proc.
Wrapped in `condition-case' so a parse glitch does not stop the
timer or kill the buffer."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col (current-column)))
    (erase-buffer)
    (setq header-line-format
          (format "*processes*  refreshed %s"
                  (format-time-string "%Y-%m-%d %H:%M:%S")))
    (insert (format "%6s %-10s %-2s %10s %5s %-16s %s\n"
                    "pid" "user" "st" "rss-kb" "cpu%" "comm" "cmdline"))
    (condition-case err
        (let ((rows (processes-buffer--collect)))
          (if (null rows)
              (insert "(no data)\n")
            (dolist (r rows)
              (insert (processes-buffer--render-row r) "\n"))
            (when (> processes-buffer--truncated 0)
              (insert (format "[... %d more pid(s) hidden, cap=%d ...]\n"
                              processes-buffer--truncated
                              processes-buffer-pid-cap)))))
      (error
       (if (fboundp 'panic-handle)
           (panic-handle err 'processes-buffer-render)
         (message "processes-buffer render failed: %S" err))
       (insert "render failed, see *panic*\n")))
    (goto-char (point-min))
    (forward-line (1- start-line))
    (move-to-column start-col)))

(defun processes-buffer-refresh ()
  "Force a refresh of *processes*. Bound to `g'."
  (interactive)
  (let ((buf (get-buffer processes-buffer-name)))
    (when buf
      (with-current-buffer buf
        (processes-buffer--render)))))

(defun processes-buffer--timer-tick (buf)
  "Timer callback. Refresh BUF if it still exists, else self-cancel.
Same orphan-timer dance as network.el: if our buffer was killed
without our kill-hook running (or recreated under the same name
with a fresh buffer-local timer slot) the previously-armed timer
survives and would keep firing forever. detect and cancel by
walking timer-list and matching on callback identity + args."
  (if (buffer-live-p buf)
      (with-current-buffer buf
        (condition-case err
            (processes-buffer--render)
          (error
           (if (fboundp 'panic-handle)
               (panic-handle err 'processes-buffer-timer)
             (message "processes-buffer timer failed: %S" err)))))
    (dolist (tm (append timer-list timer-idle-list))
      (when (and (timerp tm)
                 (eq (timer--function tm) #'processes-buffer--timer-tick)
                 (equal (timer--args tm) (list buf)))
        (cancel-timer tm)))))

(defun processes-buffer--start-timer ()
  "Install the 2-second refresh timer on the current buffer."
  (when (timerp processes-buffer--timer)
    (cancel-timer processes-buffer--timer))
  (setq processes-buffer--timer
        (run-at-time processes-buffer-refresh-interval
                     processes-buffer-refresh-interval
                     #'processes-buffer--timer-tick
                     (current-buffer))))

(defun processes-buffer--kill-hook ()
  "Cancel the per-buffer refresh timer when *processes* is killed.
Project rule: this buffer is never killed. the hook is here for
symmetry with the rest of buffers/."
  (when (timerp processes-buffer--timer)
    (cancel-timer processes-buffer--timer)
    (setq processes-buffer--timer nil)))

(defun processes-buffer-row-at-point ()
  "Return the process plist stored on the current line, or nil."
  (get-text-property (line-beginning-position) 'processes-row))

(defun processes-buffer-show-details ()
  "Open a popup with the full /proc/PID/status for the row at point.
Bound to `RET'. silently no-ops on lines without a row."
  (interactive)
  (let ((row (processes-buffer-row-at-point)))
    (when row
      (let* ((pid (plist-get row :pid))
             (status (processes-buffer--read-file
                      (format "/proc/%d/status" pid)))
             (buf (get-buffer-create processes-buffer-details-name)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (special-mode)
            (insert (format "pid:     %d\n" pid))
            (insert (format "comm:    %s\n" (plist-get row :comm)))
            (insert (format "cmdline: %s\n\n" (plist-get row :cmdline)))
            (insert "--- /proc/PID/status ---\n")
            (insert (or status "(unreadable, pid likely exited)\n"))
            (goto-char (point-min))))
        (display-buffer buf)))))

(defconst processes-buffer--known-signals
  '("HUP" "INT" "QUIT" "ILL" "TRAP" "ABRT" "BUS" "FPE"
    "KILL" "USR1" "SEGV" "USR2" "PIPE" "ALRM" "TERM"
    "STKFLT" "CHLD" "CONT" "STOP" "TSTP" "TTIN" "TTOU"
    "URG" "XCPU" "XFSZ" "VTALRM" "PROF" "WINCH" "IO"
    "PWR" "SYS")
  "Whitelist of POSIX signal names accepted by `processes-buffer-signal'.
The threat model: an unfiltered (intern (upcase ...)) lets a typo
intern an arbitrary symbol into obarray.  worse, a sufficiently
clever input could synthesize the name of an existing callable
that `signal-process' might happen to dispatch through, depending
on emacs internals.  this list mirrors the names exported by
`signal-process' itself on linux-glibc; anything off the list gets
rejected with a message instead of being passed through.  add to
this list only after checking the name appears in signal(7).")

(defun processes-buffer-signal ()
  "Send a signal to the process on the current row.
Bound to `k'. prompts for a signal name, defaulting to TERM.
uses `signal-process', never shells out to kill(1). errors route
through panic-handle so a permission denied does not kill the
buffer.

Refuses to signal pid 1.  on GEOS pid 1 IS our emacs (and on any
linux box pid 1 is init, signaling which is rarely what a user
in a process viewer actually wants).  if a future operator really
needs to kick pid 1, M-: (signal-process 1 'TERM) is still there,
but a single keypress in *processes* should not be able to brick
the OS."
  (interactive)
  (let ((row (processes-buffer-row-at-point)))
    (cond
     ((null row)
      (message "no process on this line"))
     ((= (plist-get row :pid) 1)
      (message "refusing to signal pid 1 (would take down init)"))
     (t
      (let* ((pid (plist-get row :pid))
             (raw (read-string
                   (format "signal to send to %d (%s) [TERM]: "
                           pid (plist-get row :comm))
                   nil nil "TERM"))
             (name (upcase (string-trim raw))))
        (cond
         ((not (member name processes-buffer--known-signals))
          (message "unknown signal %S, refusing (allowed: %s)"
                   name
                   (mapconcat #'identity
                              processes-buffer--known-signals
                              " ")))
         (t
          ;; safe to intern: name passed the whitelist.
          (let ((sig-sym (intern name)))
            (condition-case err
                (let ((rc (signal-process pid sig-sym)))
                  (if (eq rc 0)
                      (message "sent SIG%s to %d" name pid)
                    (message "signal-process returned %S for pid %d"
                             rc pid)))
              (error
               (if (fboundp 'panic-handle)
                   (panic-handle err 'processes-buffer-signal)
                 (message "signal failed: %S" err))))))))))))

(defun processes-buffer-quit ()
  "Bury *processes*. Per project rules we do not kill it."
  (interactive)
  (bury-buffer))

(defvar processes-buffer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g")   #'processes-buffer-refresh)
    (define-key m (kbd "RET") #'processes-buffer-show-details)
    (define-key m (kbd "k")   #'processes-buffer-signal)
    (define-key m (kbd "q")   #'processes-buffer-quit)
    m)
  "Keymap for `processes-buffer-mode'.")

(define-derived-mode processes-buffer-mode special-mode "Processes"
  "Major mode for the *processes* buffer.
Read-only view of /proc, refreshed every two seconds. see the
file commentary for the four-question contract."
  (setq truncate-lines t)
  (add-hook 'kill-buffer-hook #'processes-buffer--kill-hook nil t))

;;;###autoload
(defun processes ()
  "Display the *processes* buffer, creating it on first call.
Interactive entry point: `M-x processes'. starts the refresh
timer if it is not already running."
  (interactive)
  (let ((buf (get-buffer-create processes-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'processes-buffer-mode)
        (processes-buffer-mode))
      (processes-buffer--render)
      (unless (timerp processes-buffer--timer)
        (processes-buffer--start-timer)))
    (display-buffer buf)
    buf))

;; gnu-emacs-os-<concept> alias per the buffer template.
;;;###autoload
(defalias 'gnu-emacs-os-processes #'processes
  "Canonical concept entry point. See `processes'.")

;; TODO(6): when core/supervise.el lands, register here:
;;   (supervise-register
;;    :name 'processes-buffer-timer
;;    :kind 'timer
;;    :start (lambda ()
;;             (with-current-buffer (get-buffer-create processes-buffer-name)
;;               (unless (derived-mode-p 'processes-buffer-mode)
;;                 (processes-buffer-mode))
;;               (processes-buffer--start-timer)))
;;    :stop  (lambda ()
;;             (let ((buf (get-buffer processes-buffer-name)))
;;               (when buf
;;                 (with-current-buffer buf
;;                   (processes-buffer--kill-hook))))))
;; until then the timer is started lazily by `processes' and there is
;; no restart-on-death. acceptable for phase 4, not for v1.

(provide 'processes-buffer)
;;; processes.el ends here
