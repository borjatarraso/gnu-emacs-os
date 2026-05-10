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

;; the `dd' we spawn here is the same coreutils binary the lazy
;; in-buffer follower used.  bs=8192 is generous for kmsg (records
;; are typically << 1 KiB), status=none silences the byte-count line
;; that dd writes to stderr on exit.  no shell, no eshell, no -c
;; wrapper: this satisfies /no-shell-check.
(defservice journal-kmsg
  :command ("dd" "if=/dev/kmsg" "bs=8192" "status=none")
  :restart on-crash
  :buffer journal-tail--work-buffer-name
  :filter journal-tail--filter)

(provide 'journal-tail)
;;; journal-tail.el ends here
