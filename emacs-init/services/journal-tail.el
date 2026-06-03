;;; journal-tail.el --- supervised /dev/kmsg follower service -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;; first real defservice.  pulls the kmsg-follower dd subprocess out
;; of buffers/journal.el's lazy `journal' entry point and hands it to
;; supervise.el so it gets restarted on death (kernel.dmesg_restrict
;; flip, OOM kill, somebody SIGKILLs the dd process by hand, ...).
;;
;; what changes for the user: nothing visible.  M-x journal still
;; renders kmsg records, only now the *journal* buffer is fed by the
;; supervised dd from boot, not by an in-buffer dd that the user
;; happened to spawn the first time they visited the buffer.  records
;; that arrive before the user ever runs `journal' get appended into
;; the buffer regardless, so the post-boot first visit shows the full
;; backlog instead of starting from "now".
;;
;; design: the supervised dd writes its stdout into a hidden work
;; buffer (` *supervise:journal-kmsg*'), and a per-byte process filter
;; reuses `journal-buffer--kmsg-filter' from journal.el to do the
;; record parsing.  the filter looks at the work buffer's
;; `journal-buffer--target' buffer-local to find the *journal* buffer
;; it should append to; we set that target lazily on the first chunk,
;; which removes the boot ordering gotcha (the work buffer exists at
;; supervise.el spawn time, but *journal* may not be created until the
;; user types M-x journal).

(require 'supervise)
(require 'panic)
(require 'port)
(require 'journal-buffer)

(defconst journal-tail--work-buffer-name " *supervise:journal-kmsg*"
  "Hidden work buffer the supervised dd writes its stdout into.
Leading space hides it from buffer lists; the filter consumes the
text and routes parsed records into *journal*, so this buffer's
own contents are uninteresting.")

(defconst journal-tail--syslog-work-buffer-name " *supervise:journal-syslog*"
  "Hidden work buffer for the Hurd /var/log/syslog tail.
Separate from the kern.log work buffer because supervise.el wants
one buffer per service and the per-buffer residue state must not
collide with the kern.log filter's residue.")

(defun journal-tail--ensure-journal-buffer ()
  "Get-or-create the *journal* buffer in journal-buffer-mode.
Without this, kmsg records arriving before the user ever runs M-x
journal would have nowhere to land.  the buffer is initialised in
the major mode so its buffer-local variables (proc-residue, panic
mark, line counter) are all bound and the filter can mutate them
without tripping void-variable.

Returns the buffer, never nil.  errors during mode init are caught
and routed through panic-handle; on failure we return the bare
buffer with no mode set, which means the filter's state slots are
unbound and the next chunk will raise.  that is acceptable: the
mode init is the simplest piece of code in the chain, and a
breakage there means something deeper is broken."
  (let ((buf (get-buffer-create journal-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'journal-buffer-mode)
        (condition-case err (journal-buffer-mode)
          (error (panic-handle err 'journal-tail--ensure-journal-buffer)))))
    buf))

(defun journal-tail--filter (proc chunk)
  "Process filter for the supervised dd /dev/kmsg follower.
PROC is the dd process; CHUNK is the bytes it produced.  We adopt
the work buffer's `journal-buffer--target' to point at *journal*
on the first call (lazy init: see commentary), then delegate
parsing to `journal-buffer--kmsg-filter' which already knows how
to walk the work buffer's residue and emit records.

If something goes wrong we route through panic-handle and drop the
chunk; the next chunk will retry.  the supervisor will restart dd
if it actually dies; a filter error does NOT kill dd (process
filters have no influence over their producer), it just loses one
window of records."
  (condition-case err
      (let ((work (process-buffer proc))
            (journal (journal-tail--ensure-journal-buffer)))
        (when (buffer-live-p work)
          (with-current-buffer work
            ;; tag the work buffer with the journal target so the
            ;; existing filter can find it.  setq-local so a re-spawn
            ;; (which gets a fresh work buffer? no: we get the same
            ;; one because supervise.el re-uses the named buffer)
            ;; does not re-create the binding redundantly.
            (unless (and (local-variable-p 'journal-buffer--target)
                         (eq (buffer-local-value 'journal-buffer--target
                                                 (current-buffer))
                             journal))
              (setq-local journal-buffer--target journal))))
        (journal-buffer--kmsg-filter proc chunk))
    (error (panic-handle err 'journal-tail--filter))))

;; hurd arm.  we tail /var/log/kern.log (populated by Debian Hurd's
;; inetutils-syslogd from /dev/klog) and parse the BSD/syslog one-line
;; format.  /dev/klog itself is a streamio kmsg translator that blocks
;; until kernel writes and has no history replay; the kern.log file is
;; the only surface that gives us both a backlog and a live tail.  no
;; procfs /proc/kmsg, no Mach RPC for kernel messages, so this is
;; pure elisp wiring against coreutils `tail'.
;;
;; residue + chunk discipline mirrors the kmsg filter.  unlike kmsg,
;; syslog lines never use a leading-space continuation convention, so
;; we drop that guard for the syslog path.
(defun journal-tail--filter-syslog (proc chunk)
  "Process filter for the supervised tail /var/log/kern.log follower.
PROC is the tail process; CHUNK is the bytes it produced.  Same
work-buffer + target-lookup discipline as `journal-tail--filter',
but dispatches per-line to `journal-buffer--parse-syslog-record'.

Errors route through panic-handle and drop the chunk; the next
chunk retries."
  (condition-case err
      (let* ((work (process-buffer proc))
             (journal (journal-tail--ensure-journal-buffer)))
        (when (buffer-live-p work)
          (with-current-buffer work
            (unless (and (local-variable-p 'journal-buffer--target)
                         (eq (buffer-local-value 'journal-buffer--target
                                                 (current-buffer))
                             journal))
              (setq-local journal-buffer--target journal))
            (let* ((data (concat (or (and (local-variable-p
                                           'journal-buffer--proc-residue)
                                          journal-buffer--proc-residue)
                                     "")
                                 chunk))
                   (parts (split-string data "\n"))
                   (last (car (last parts)))
                   (complete (butlast parts))
                   (recs '()))
              (setq-local journal-buffer--proc-residue (or last ""))
              (dolist (raw complete)
                (unless (string-empty-p raw)
                  (let ((rec (journal-buffer--parse-syslog-record raw)))
                    (when rec
                      (push rec recs)))))
              (when recs
                (with-current-buffer journal
                  (journal-buffer--append-records (nreverse recs))))))))
    (error (panic-handle err 'journal-tail--filter-syslog))))

;; v0.9.17: second hurd arm.  /var/log/syslog catches what kern.log
;; cannot: user processes that called `logger -p kern.info ...' get
;; demoted by syslogd to LOG_USER at source-classification time (per
;; RFC 3164: user processes are not allowed to emit kern.*) and the
;; demoted line lands in /var/log/syslog with the user's tag.  v0.9.15
;; slice A tried to fix this with a kern.* override + SIGHUP; v0.9.16
;; cold-boot verify proved that path is unfixable via config edits
;; (wrong conf file on Debian Hurd 0.9, AND the demotion happens
;; before routing anyway).  this is the alternate fix: tail both
;; files, accept that lines authored by user processes show up tagged
;; as `syslog-user' in the *journal* source column.
;;
;; line shape is identical to /var/log/kern.log (BSD syslog one-line
;; format) so we reuse `journal-buffer--parse-syslog-record' and just
;; re-tag the :source slot so the renderer's source column visibly
;; distinguishes kernel-origin from user-origin entries.
;;
;; de-dup wart: kernel-origin lines that genuinely fan out to BOTH
;; files (some syslog.conf setups mirror kern.* into syslog as well)
;; will appear twice in *journal* with different source tags.  on a
;; canonical Debian Hurd 0.9 install /etc/syslog.conf routes kern.*
;; only to /var/log/kern.log so the overlap is zero in practice; if
;; an operator hand-edits syslog.conf to add a *.info catch-all that
;; covers kern.*, they get duplicates.  we don't try to dedupe (would
;; need cross-stream timestamp+message matching and the two tails are
;; independently buffered; honest duplicates beat dropped originals).
(defun journal-tail--filter-syslog-user (proc chunk)
  "Process filter for the supervised tail /var/log/syslog follower.
Same shape as `journal-tail--filter-syslog' but re-tags every
emitted record's :source to `syslog-user' so the renderer's source
column reflects that the record came in via the user-facing syslog
file, not via /var/log/kern.log.  No structural change to the
parsed plist; downstream code only reads :source for the column."
  (condition-case err
      (let* ((work (process-buffer proc))
             (journal (journal-tail--ensure-journal-buffer)))
        (when (buffer-live-p work)
          (with-current-buffer work
            (unless (and (local-variable-p 'journal-buffer--target)
                         (eq (buffer-local-value 'journal-buffer--target
                                                 (current-buffer))
                             journal))
              (setq-local journal-buffer--target journal))
            (let* ((data (concat (or (and (local-variable-p
                                           'journal-buffer--proc-residue)
                                          journal-buffer--proc-residue)
                                     "")
                                 chunk))
                   (parts (split-string data "\n"))
                   (last (car (last parts)))
                   (complete (butlast parts))
                   (recs '()))
              (setq-local journal-buffer--proc-residue (or last ""))
              (dolist (raw complete)
                (unless (string-empty-p raw)
                  (let ((rec (journal-buffer--parse-syslog-record raw)))
                    (when rec
                      ;; retag source so the renderer's source column
                      ;; shows `syslog-user' instead of `syslog'.
                      ;; plist-put on a freshly-cons'd plist is fine;
                      ;; the parser builds a new list per call so we
                      ;; are not mutating shared state.
                      (push (plist-put rec :source 'syslog-user)
                            recs)))))
              (when recs
                (with-current-buffer journal
                  (journal-buffer--append-records (nreverse recs))))))))
    (error (panic-handle err 'journal-tail--filter-syslog-user))))

;; v0.9.6 follow-on: prime *journal* from /var/log/dmesg on Hurd.
;; the syslog tail pipeline is wired correctly but /var/log/kern.log
;; ships at 0 bytes on a fresh Debian Hurd 0.9 boot because gnumach
;; doesn't push boot printfs through /dev/klog there.  /etc/init.d/
;; bootlogs slurps the printbuf into /var/log/dmesg once at boot and
;; that's where the actual boot transcript ends up.  without this
;; prime, M-x journal on a fresh boot shows an empty buffer until a
;; runtime kernel event happens (which can be never).
;;
;; pure elisp: `insert-file-contents-literally' into a temp buffer,
;; split, parse each line through `journal-buffer--parse-dmesg-record',
;; hand the lot to `journal-buffer--append-records'.  best-effort: if
;; the file is missing (host has no bootlogs, or it hasn't run yet)
;; or unreadable, we return cleanly and the supervised tail still
;; comes up.  errors route through panic-handle.
(defun journal-tail--prime-from-dmesg ()
  "Prime *journal* with /var/log/dmesg contents on Hurd.
No-op on Linux (kmsg already carries the boot ring buffer) and on
Hurd hosts where /var/log/dmesg doesn't exist yet.  Errors are
caught and routed through panic-handle; the supervised tail must
still come up regardless."
  (when (and (not (geos-kernel-linux-p))
             (file-readable-p "/var/log/dmesg"))
    (condition-case err
        (let* ((journal (journal-tail--ensure-journal-buffer))
               (text (with-temp-buffer
                       (insert-file-contents-literally "/var/log/dmesg")
                       (buffer-string)))
               (lines (split-string text "\n"))
               (recs '()))
          (dolist (raw lines)
            (let ((rec (journal-buffer--parse-dmesg-record raw)))
              (when rec
                (push rec recs))))
          (when recs
            (with-current-buffer journal
              (journal-buffer--append-records (nreverse recs)))))
      (error (panic-handle err 'journal-tail--prime-from-dmesg)))))

;; prime BEFORE we register the live tail, so the boot transcript
;; lands in *journal* first and runtime records stream in on top.
;; on linux this is a no-op; the call cost is one branch on the
;; kernel predicate.
(journal-tail--prime-from-dmesg)

;; v0.9.14 follow-on #2 from
;; docs/runlogs/2026-05-22-v0914-live-kmsg-probe.md: gnumach boot
;; printfs land in /var/log/dmesg (read direct from the gnumach
;; printbuf by dmesg(8)), NOT through /dev/klog -> syslogd ->
;; kern.log.  the prime above catches the day-zero boot transcript,
;; but any runtime kernel event that lands in the printbuf AFTER
;; load-time never reaches *journal*.  this re-sync covers that gap
;; with an idle timer that diffs the file by byte offset and appends
;; the delta.
;;
;; offset-based, not SHA1-based.  hurd doesn't rotate /var/log/dmesg
;; today; the cheap path wins until that changes.  on truncation
;; (size shrank below the last-seen offset) we reset to zero and
;; re-read from the top, which is the same shape as a log rotation
;; recovering itself.  on a missing file we no-op and leave the timer
;; armed; a future boot that produces the file will be picked up on
;; the next tick.  every fs error routes through panic-handle so a
;; mid-life unlink does not crash the supervisor.

(defcustom journal-tail-dmesg-resync-interval 30
  "Seconds between /var/log/dmesg re-sync passes on Hurd.
The re-sync runs as an idle timer so it never preempts an
interactive command.  Linux is a strict no-op regardless of this
value; the kmsg path already streams the ring buffer live.

Set before `journal-tail' loads to take effect at boot; changes at
runtime require a manual re-arm via
`journal-tail--arm-dmesg-resync'."
  :type 'integer
  :group 'journal)

(defvar journal-tail--dmesg-last-size 0
  "Last observed byte size of /var/log/dmesg.
Set by `journal-tail--dmesg-resync-tick' after each successful
read.  On rotation (file shrank) the tick resets this to zero and
re-reads the file from the top.  Starts at zero so the very first
tick has to compare against the size left by
`journal-tail--prime-from-dmesg' if any; in practice the prime
runs `insert-file-contents-literally' without remembering the
size, so the first tick will re-emit the entire file as delta on a
Hurd boot.  That double-emit is benign: the prime fired before
*journal* could even be a buffer the user looks at, and
`journal-buffer--append-records' is idempotent in shape; the only
cost is a one-shot duplication of the boot transcript on the
first tick after load.  Future slice can prime this from the post-
prime file size if the duplication ever matters.")

(defvar journal-tail--dmesg-resync-timer nil
  "Idle timer object driving the /var/log/dmesg re-sync, or nil.
Held in a defvar so repeated loads do not stack timers: the arm
function cancels any prior timer before scheduling a new one.")

(defun journal-tail--dmesg-resync-tick ()
  "Read the delta of /var/log/dmesg since the last tick and append it.
Stat the file; if the size grew, read only the appended bytes via
`insert-file-contents-literally' with explicit BEG/END byte
offsets; if the size shrank (rotation, truncation), reset the
last-seen offset to zero and re-read from the top; if the file is
absent or the same size, no-op.  Every fs error routes through
panic-handle so a transient unlink does not crash the timer.

The supervised `tail -F' on /var/log/kern.log is the canonical
source for runtime kernel events on Hurd; this is the safety net
for events that gnumach pushes only into its printbuf and never
through /dev/klog -> syslogd."
  (when (and (not (geos-kernel-linux-p))
             (file-readable-p "/var/log/dmesg"))
    (condition-case err
        (let* ((attrs (file-attributes "/var/log/dmesg"))
               (size (and attrs (file-attribute-size attrs))))
          (cond
           ;; stat failed or returned something we cannot reason about.
           ;; no-op, leave the offset alone; the next tick retries.
           ((not (integerp size)) nil)
           ;; empty file: record the zero size so a future append from
           ;; a fresh write is detected against the right baseline.
           ((zerop size)
            (setq journal-tail--dmesg-last-size 0))
           ;; rotation / truncation: reset and re-read from the top so
           ;; we don't miss the post-rotation prefix.
           ((< size journal-tail--dmesg-last-size)
            (setq journal-tail--dmesg-last-size 0)
            (journal-tail--dmesg-resync-append 0 size)
            (setq journal-tail--dmesg-last-size size))
           ;; grew: read only the new bytes.
           ((> size journal-tail--dmesg-last-size)
            (journal-tail--dmesg-resync-append
             journal-tail--dmesg-last-size size)
            (setq journal-tail--dmesg-last-size size))
           ;; size equal: no new bytes, nothing to do.
           (t nil)))
      (error (panic-handle err 'journal-tail--dmesg-resync-tick)))))

(defun journal-tail--dmesg-resync-append (beg end)
  "Read bytes [BEG, END) of /var/log/dmesg and append parsed records.
Helper for `journal-tail--dmesg-resync-tick'; splits the read text
on newlines, runs each non-empty line through
`journal-buffer--parse-dmesg-record', and hands the batch to
`journal-buffer--append-records'.  Errors route through
panic-handle and the tick continues."
  (condition-case err
      (let* ((journal (journal-tail--ensure-journal-buffer))
             (text (with-temp-buffer
                     (insert-file-contents-literally
                      "/var/log/dmesg" nil beg end)
                     (buffer-string)))
             (lines (split-string text "\n"))
             (recs '()))
        (dolist (raw lines)
          (let ((rec (journal-buffer--parse-dmesg-record raw)))
            (when rec
              (push rec recs))))
        (when recs
          (with-current-buffer journal
            (journal-buffer--append-records (nreverse recs)))))
    (error (panic-handle err 'journal-tail--dmesg-resync-append))))

(defun journal-tail--arm-dmesg-resync ()
  "Schedule (or re-schedule) the /var/log/dmesg re-sync idle timer.
Hurd-only.  Idempotent: a prior timer in
`journal-tail--dmesg-resync-timer' is cancelled before the new one
goes in, so re-loading this file does not stack timers.  Lifetime
is the rest of the Emacs life; there is no `journal-tail-stop'
counterpart today, so an explicit teardown means
`(cancel-timer journal-tail--dmesg-resync-timer)' from a repl."
  (when (timerp journal-tail--dmesg-resync-timer)
    (cancel-timer journal-tail--dmesg-resync-timer)
    (setq journal-tail--dmesg-resync-timer nil))
  (when (not (geos-kernel-linux-p))
    (setq journal-tail--dmesg-resync-timer
          (run-with-idle-timer journal-tail-dmesg-resync-interval
                               t
                               #'journal-tail--dmesg-resync-tick))))

(journal-tail--arm-dmesg-resync)

;; v0.9.13 follow-on: pre-create /var/log/kern.log on Hurd so the
;; supervised `tail -F --lines=+1` does not race syslogd's first
;; write.  the race window matters: hurd-syslogd is a sibling
;; service in hurd-essentials.el, the supervisor brings both up in
;; one autostart pass, and tail spawning before syslogd's first
;; kern.log write was burning the on-crash respawn cap during VM
;; verify.  GNU coreutils `tail -F` is supposed to retry-on-missing
;; via --retry, but combined with `--lines=+1` (which wants to read
;; from byte 1) the early-window behaviour is fragile; creating a
;; zero-byte file makes the contract trivial.
;;
;; v0.9.17 added a sibling touch for /var/log/syslog and the two
;; copies were byte-for-byte identical modulo the path.  the touch
;; logic now lives in core/port.el as `geos-hurd-ensure-path' (linux
;; short-circuits to nil, hurd does mkdir-parent + write-region "" +
;; panic-handle on error), and the two call sites below collapse to
;; one funcall each.  see port.el for the design contract; the user
;; explicitly waived the no-premature-abstraction rule for this one
;; helper on 2026-05-30.
(defun journal-tail--ensure-kern-log-hurd ()
  "Touch /var/log/kern.log on Hurd if it does not exist.
Thin wrapper around `geos-hurd-ensure-path' kept for the autostart
call below and any external code still naming this entry point."
  (geos-hurd-ensure-path "/var/log/kern.log"))

(defun journal-tail--ensure-syslog-hurd ()
  "Touch /var/log/syslog on Hurd if it does not exist.
Thin wrapper around `geos-hurd-ensure-path' for symmetry with
`journal-tail--ensure-kern-log-hurd'."
  (geos-hurd-ensure-path "/var/log/syslog"))

(journal-tail--ensure-kern-log-hurd)
(journal-tail--ensure-syslog-hurd)

;; the `dd' we spawn on linux here is the same coreutils binary the
;; lazy in-buffer follower used.  bs=8192 is generous for kmsg
;; (records are typically << 1 KiB), status=none silences the
;; byte-count line that dd writes to stderr on exit.  no shell, no
;; eshell, no -c wrapper: this satisfies /no-shell-check.
;;
;; kernel branch.  /dev/kmsg is a linux-only device.  on hurd we tail
;; /var/log/kern.log instead (inetutils-syslogd ships and runs by
;; default on Debian Hurd 0.9 and drains /dev/klog there); tail -F
;; with --lines=+1 replays the file from the first line so the boot
;; backlog is present in *journal*, then follows it live.  the
;; per-record parser differs (BSD/syslog format, not kmsg key=value)
;; so we route through a different filter.  go through
;; supervise-register here so the :command / :filter keywords can be
;; computed at runtime; defservice takes its plist as literal data
;; and would not see geos-kernel-linux-p.
(let* ((command
        (if (geos-kernel-linux-p)
            '("dd" "if=/dev/kmsg" "bs=8192" "status=none")
          '("tail" "-F" "--lines=+1" "/var/log/kern.log")))
       (filter
        (if (geos-kernel-linux-p)
            #'journal-tail--filter
          #'journal-tail--filter-syslog)))
  (supervise-register
   :name 'journal-kmsg
   :command command
   :restart 'on-crash
   :buffer journal-tail--work-buffer-name
   :filter filter))

;; v0.9.17: second supervised tail on Hurd, parallel to the kern.log
;; one above.  gated explicitly on the hurd predicate (Linux has no
;; need: kmsg streams every facility live).  same supervise contract:
;; on-crash respawn, dedicated work buffer, dedicated filter that
;; re-tags :source to `syslog-user' so renderer's source column shows
;; the origin.  re-registering the same name is idempotent in
;; supervise-register (it overwrites static intent and preserves
;; counters), so a re-load of this file does not duplicate the entry.
(when (geos-kernel-hurd-p)
  (supervise-register
   :name 'journal-syslog
   :command '("tail" "-F" "--lines=+1" "/var/log/syslog")
   :restart 'on-crash
   :buffer journal-tail--syslog-work-buffer-name
   :filter #'journal-tail--filter-syslog-user))

(provide 'journal-tail)
;;; journal-tail.el ends here
