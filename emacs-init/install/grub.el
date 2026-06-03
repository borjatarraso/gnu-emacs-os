;;; grub.el --- install GRUB on the target disk for the *install* wizard -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
;;;
;;; This file is part of GEOS.
;;;
;;; GEOS is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; GEOS is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GEOS.  If not, see <https://www.gnu.org/licenses/>.

;; v0.4 MVP install wizard, the last technical step before reboot.
;; assumes the target is mounted at TARGET-MOUNT and the system
;; closure has been copied (so /gnu/store is present under the
;; mount).  we run two binaries from the host's grub package:
;;
;;   grub-install --target=i386-pc --boot-directory=TARGET/boot DEVICE
;;       writes the MBR stub on the whole-disk DEVICE and lays down
;;       the core image + modules under TARGET/boot/grub/.  i386-pc
;;       is BIOS; UEFI is a v0.4.1 nicety (target=x86_64-efi plus a
;;       mounted ESP and --efi-directory).
;;
;;   grub-mkconfig -o TARGET/boot/grub/grub.cfg
;;       runs the os-prober and 10_linux scripts to generate the
;;       config from what is on TARGET/.  since we copied
;;       /run/current-system as a symlink and the bootloader entries
;;       in system.scm reference (operating-system-kernel-file
;;       base-os) etc., grub-mkconfig finds the kernel/initrd via
;;       the symlink and writes a working grub.cfg.
;;
;; the two are chained: install first, then mkconfig.  if install
;; fails we do not run mkconfig (no config without a stub).  if
;; mkconfig fails we leave the MBR stub in place but log loudly so
;; the operator can re-run from a recovery shell.

(require 'panic)

(defcustom install-grub-install-program "grub-install"
  "Absolute path or PATH-resolvable name of grub-install.
Default is the bare name, resolved through process-environment at
spawn time.  on Guix this comes from the grub package."
  :type 'string
  :group 'install)

(defcustom install-grub-mkconfig-program "grub-mkconfig"
  "Absolute path or PATH-resolvable name of grub-mkconfig.
Same provenance as `install-grub-install-program'."
  :type 'string
  :group 'install)

(defcustom install-grub-target "i386-pc"
  "GRUB target architecture.
i386-pc is BIOS (the default that works under QEMU's seabios).
x86_64-efi is UEFI; switching to it also requires a mounted ESP
and a --efi-directory flag, which v0.4.1 adds when the wizard
learns to partition."
  :type 'string
  :group 'install)

(defconst install-grub--work-buffer " *install:grub*"
  "Hidden work buffer for grub-install / grub-mkconfig stdout/stderr.
One buffer for both steps; the step is named in the prefix line
we insert before each spawn so the operator can read the log.")

(defun install-grub--log (line)
  "Append LINE to `install-grub--work-buffer'.
Internal helper.  the buffer is read-only by the time the wizard
exposes it so we use inhibit-read-only."
  (let ((buf (get-buffer-create install-grub--work-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert line)))))

(defun install-grub--spawn (program args step callback)
  "Run PROGRAM with ARGS, sentinel calls CALLBACK with (ok reason).
STEP is a short string for the log header.  internal helper for the
two entry points below.  errors route through panic-handle and
CALLBACK is invoked with (nil err)."
  (condition-case err
      (let ((buf (get-buffer-create install-grub--work-buffer)))
        (install-grub--log
         (format "\n--- %s: %s %s ---\n"
                 step program (mapconcat #'identity args " ")))
        (make-process
         :name (concat "install-grub:" step)
         :buffer buf
         :noquery t
         :connection-type 'pipe
         :command (cons program args)
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal failed))
             (let* ((sig  (process-status proc))
                    (code (process-exit-status proc))
                    (ok (and (eq sig 'exit) (zerop code))))
               (install-grub--log
                (format "--- %s exit: status=%s code=%s ---\n"
                        step sig code))
               (cond
                (ok (funcall callback t nil))
                (t (funcall callback nil
                            (list :step step
                                  :status sig
                                  :exit code)))))))))
    (error
     (panic-handle err (cons 'install-grub--spawn step))
     (funcall callback nil err))))

(defun install-grub-install (device target-mount callback)
  "Run grub-install on DEVICE with --boot-directory=TARGET-MOUNT/boot.
CALLBACK is (lambda (ok reason)).  DEVICE is a whole-disk path
\(\"/dev/sda\", \"/dev/nvme0n1\") not a partition.  TARGET-MOUNT is
where the new root is mounted on the live host.

This writes both the stage-1 MBR stub on DEVICE and the stage-2
core image under TARGET-MOUNT/boot/grub/.  the operator must have
already mounted the target's root partition at TARGET-MOUNT; the
caller (the *install* state machine) checks this."
  (let ((boot-dir (expand-file-name "boot" target-mount)))
    (install-grub--spawn
     install-grub-install-program
     (list (concat "--target=" install-grub-target)
           (concat "--boot-directory=" boot-dir)
           device)
     "grub-install"
     callback)))

(defun install-grub-mkconfig (target-mount callback)
  "Run grub-mkconfig -o TARGET-MOUNT/boot/grub/grub.cfg.
CALLBACK is (lambda (ok reason)).  TARGET-MOUNT is the new root's
mount point on the live host.  must be called AFTER a successful
`install-grub-install'; running mkconfig alone leaves the MBR
stub-less and the target unbootable."
  (let ((cfg (expand-file-name "boot/grub/grub.cfg" target-mount)))
    (install-grub--spawn
     install-grub-mkconfig-program
     (list "-o" cfg)
     "grub-mkconfig"
     callback)))

(defun install-grub-finalize (device target-mount callback)
  "Install GRUB on DEVICE and generate grub.cfg for TARGET-MOUNT.
CALLBACK is (lambda (ok reason)).  chains the two steps: install
first, mkconfig second, mkconfig is skipped on install failure.
this is the single entry point the wizard's state machine calls."
  (install-grub-install
   device target-mount
   (lambda (ok reason)
     (cond
      ((not ok) (funcall callback nil reason))
      (t (install-grub-mkconfig target-mount callback))))))

(provide 'install-grub)
;;; grub.el ends here
