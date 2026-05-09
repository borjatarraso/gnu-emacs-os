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
;; prompt and a panic-handle wrapper around them so we get a sane
;; *panic* trail if the syscall fails (typically EPERM if the kernel
;; was compiled without CONFIG_KEXEC and we asked for a kexec; not
;; our situation, but cheap insurance).

(require 'panic)

(defun geos-poweroff ()
  "Power off the machine.
Asks for y-or-n confirmation, then invokes the reboot(2) syscall via
the pid1 dynamic module.  The syscall does not return on success; the
kernel terminates every process including this one and ACPI signals
qemu to exit (or, on bare metal, the firmware cuts power)."
  (interactive)
  (when (yes-or-no-p "Power off the machine? ")
    (panic-handle
     (lambda ()
       (message "geos-poweroff: syncing and powering off...")
       (redisplay t)
       (if (fboundp 'pid1-poweroff)
           (pid1-poweroff)
         (error "pid1-module not loaded; cannot poweroff from elisp"))))))

(defun geos-reboot ()
  "Reboot the machine.
Asks for y-or-n confirmation, then invokes reboot(RB_AUTOBOOT) via the
pid1 dynamic module.  Under qemu this drops the guest; on bare metal
it triggers a normal restart."
  (interactive)
  (when (yes-or-no-p "Reboot the machine? ")
    (panic-handle
     (lambda ()
       (message "geos-reboot: syncing and rebooting...")
       (redisplay t)
       (if (fboundp 'pid1-reboot)
           (pid1-reboot)
         (error "pid1-module not loaded; cannot reboot from elisp"))))))

;; both commands are M-x discoverable. no global keybinding by default
;; because C-x C-c (save-buffers-kill-emacs) and the exwm prefix space
;; should not be hijacked silently. a user who wants a hotkey can
;; (global-set-key (kbd "C-c q") #'geos-poweroff) in their own config.

(provide 'power)
;;; power.el ends here
