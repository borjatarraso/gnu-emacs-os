;;; boot-marker.el --- write boot sentinels to /dev/console -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; smoke-test gate.  /iso-build/smoke-test.sh boots the qcow2 with the
;; serial console wired to a tmpfile and greps it for sentinel
;; strings.  pid1 emits its own markers (X server up, etc) which prove
;; the supervisor reached its main loop.  what those markers do NOT
;; prove is that emacs got past the -l chain and into the userland.
;; an init.el that errors on file load, or a panic.el that swallows
;; the error and leaves the rest of the chain unevaluated, would
;; still pass a pid1-only smoke test.
;;
;; this file closes that gap.  loaded LAST in the boot gexp's -l
;; chain (see system.scm).  if it ran, every previous -l ran too,
;; modulo errors that panic.el reported but did not abort.  it writes
;; "geos: emacs userland up" to /dev/console synchronously, then
;; arms a hook on exwm-init-hook that emits "geos: exwm up" once the
;; window manager grabs root (UI mode only; in console mode that hook
;; never fires and that is fine).
;;
;; failure mode: when /dev/console is not writable (interactive emacs
;; on a dev host, no module loaded, etc) the writes are silently
;; skipped.  the markers exist for the smoke test, not for users.

(defconst boot-marker--console "/dev/console"
  "Where the smoke-test serial console lives during boot.")

(defun boot-marker--write (msg)
  "Append MSG and a newline to `boot-marker--console'.
Returns t on success, nil on any error.  errors are swallowed on
purpose: this code runs during boot and must never derail it."
  (condition-case _
      (when (file-writable-p boot-marker--console)
        (let ((coding-system-for-write 'utf-8)
              (write-region-inhibit-fsync t))
          (write-region (concat msg "\n") nil boot-marker--console
                        t 'silent))
        t)
    (error nil)))

(defun boot-marker-emit-userland ()
  "Emit the userland-up sentinel.  safe to call interactively."
  (interactive)
  (boot-marker--write "geos: emacs userland up"))

(defun boot-marker-emit-exwm ()
  "Emit the exwm-up sentinel.  safe to call interactively."
  (interactive)
  (boot-marker--write "geos: exwm up"))

;; load-time emit.  by the time this file is being loaded every
;; previous -l in the boot gexp has run; if any of them errored,
;; panic.el either rerouted to *panic* and continued or escalated.
(boot-marker-emit-userland)

;; arm the exwm marker.  with-eval-after-load does not fire if the
;; package is loaded BEFORE this hook is added; in our boot order
;; exwm-config.el (which requires exwm) runs earlier in the -l chain,
;; so we cannot rely on it.  add-hook directly: exwm-init-hook is
;; defvar'd inside exwm-core.el, which exwm-config.el has already
;; loaded by the time we get here.  guard fboundp anyway so a future
;; reorganization that loads boot-marker before exwm degrades to a
;; message instead of a void-variable error.
(if (boundp 'exwm-init-hook)
    (add-hook 'exwm-init-hook #'boot-marker-emit-exwm)
  (message "boot-marker: exwm-init-hook unbound, skipping exwm sentinel"))

(provide 'boot-marker)
;;; boot-marker.el ends here
