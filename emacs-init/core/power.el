;;; -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;; power.el, M-x geos-poweroff and M-x geos-reboot.
;;
;; the eshell route ("sudo poweroff") does NOT work in GEOS:
;;   - no sudo binary in the system profile, by design.
;;   - no /sbin/poweroff binary either; coreutils is in the profile
;;     but shutdown/halt/poweroff live in shadow or sysvinit, neither
;;     of which we ship.
;;   - even if we shipped a binary, /sbin/poweroff is conventionally a
;;     symlink that asks the init system over a socket. our init system
;;     IS emacs; there is no socket protocol to ask, the answer lives
;;     in this file.
;;
;; the right path is to call the reboot(2) syscall directly. the pid1
;; dynamic module exposes pid1-poweroff and pid1-reboot which sync()
;; and then issue the syscall. this file just adds a confirmation
;; prompt and a condition-case around them so we get a sane *panic*
;; trail if the syscall fails (typically EPERM if CAP_SYS_BOOT was
;; lost, or ENOSYS on a kernel built without reboot support).
;;
;; NOTE on panic-handle: it is a LOGGER, not an executor. the
;; command-error-function in panic.el catches errors raised by
;; interactive commands and routes them to panic-handle automatically.
;; we just need to NOT suppress errors here.

(require 'panic)

(defun geos-poweroff ()
  "Power off the machine.
Asks for y-or-n confirmation, then invokes the reboot(2) syscall via
the pid1 dynamic module.  The syscall does not return on success; the
kernel terminates every process including this one and ACPI signals
qemu to exit (or, on bare metal, the firmware cuts power)."
  (interactive)
  (when (yes-or-no-p "Power off the machine? ")
    (cond
     ((not (fboundp 'pid1-poweroff))
      ;; route through panic-handle directly rather than raising a
      ;; bare error: this file lives under core/ and the project rule
      ;; is no bare `error' here.  caller sees the message and *panic*
      ;; gets the audit trail.
      (panic-handle (list 'pid1-module-missing 'poweroff) 'geos-poweroff)
      (message "geos-poweroff: pid1-module not loaded; cannot poweroff"))
     (t
      (message "geos-poweroff: syncing and powering off...")
      (redisplay t)
      ;; bind `panic-allow-kill-emacs' as defense in depth.  pid1-poweroff
      ;; calls reboot(2) directly and shouldn't reach kill-emacs, but if
      ;; a future kernel returns EBUSY and the C wrapper falls through
      ;; to `kill-emacs', we want it through the gate cleanly.
      (let ((panic-allow-kill-emacs t))
        ;; pid1-poweroff does not return on success.  if it returns at
        ;; all, the syscall failed; pid1-error has already been
        ;; signalled inside the C wrapper and the
        ;; command-error-function in panic.el will route it.  we add an
        ;; explicit fallback message in case the signal got swallowed
        ;; somewhere unexpected.
        (pid1-poweroff)
        (message "geos-poweroff: reboot(2) returned, see *panic*"))))))

(defun geos-reboot ()
  "Reboot the machine.
Asks for y-or-n confirmation, then invokes reboot(RB_AUTOBOOT) via the
pid1 dynamic module.  Under qemu this drops the guest; on bare metal
it triggers a normal restart."
  (interactive)
  (when (yes-or-no-p "Reboot the machine? ")
    (cond
     ((not (fboundp 'pid1-reboot))
      (panic-handle (list 'pid1-module-missing 'reboot) 'geos-reboot)
      (message "geos-reboot: pid1-module not loaded; cannot reboot"))
     (t
      (message "geos-reboot: syncing and rebooting...")
      (redisplay t)
      (let ((panic-allow-kill-emacs t))
        (pid1-reboot)
        (message "geos-reboot: reboot(2) returned, see *panic*"))))))

;; both commands are M-x discoverable. no global keybinding by default
;; because C-x C-c (save-buffers-kill-emacs) and the exwm prefix space
;; should not be hijacked silently. a user who wants a hotkey can
;; (global-set-key (kbd "C-c q") #'geos-poweroff) in their own config.

(provide 'power)
;;; power.el ends here
