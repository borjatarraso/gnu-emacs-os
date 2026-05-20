;;; journal-tail.el --- supervised /dev/kmsg follower service -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

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

(provide 'journal-tail)
;;; journal-tail.el ends here
