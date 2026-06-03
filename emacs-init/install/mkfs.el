;;; mkfs.el --- format partitions for the *install* wizard -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;; v0.4 MVP install wizard: format an already-partitioned target.
;; from-scratch partitioning (the parted dance, BLKRRPART re-read,
;; ESP+root layout) is v0.4.1.  for v0.4 the operator pre-partitions
;; from a Guix live ISO and the wizard takes over from mkfs onward.
;;
;; both formatters here are make-process calls into mkfs.ext4 and
;; mkfs.fat from %geos-installer-packages (added to system.scm
;; alongside the wizard).  no shell-out, no /bin/sh, no eshell
;; bridge: make-process gets argv directly.  sentinel-driven so the
;; supervisor never blocks on the mkfs run (mkfs.ext4 on a 240 GB
;; disk takes seconds, but mkfs over a slow USB stick can take a
;; minute and we are PID 1).

(require 'panic)

(define-error 'install-mkfs-error
  "mkfs invocation failure"
  'error)

(defcustom install-mkfs-ext4-program "mkfs.ext4"
  "Absolute path or PATH-resolvable name of mkfs.ext4.
Default is the bare name, resolved through process-environment at
spawn time.  pin to a /gnu/store path under a paranoid policy."
  :type 'string
  :group 'install)

(defcustom install-mkfs-fat-program "mkfs.fat"
  "Absolute path or PATH-resolvable name of mkfs.fat.
Used for the ESP.  on Guix this comes from dosfstools."
  :type 'string
  :group 'install)

(defconst install-mkfs--work-buffer-prefix " *install:mkfs:"
  "Prefix for the hidden work buffer that captures mkfs output.
One buffer per device so concurrent (rare but possible: ESP +
root in parallel is a v0.4.1 nicety) mkfs runs do not braid their
logs.")

(defun install-mkfs--work-buffer (device)
  "Hidden work buffer for mkfs against DEVICE."
  (get-buffer-create
   (concat install-mkfs--work-buffer-prefix device "*")))

(defun install-mkfs--spawn (program args device callback)
  "Run PROGRAM with ARGS, sentinel calls CALLBACK with (t/nil REASON).
DEVICE is used to label the work buffer.  internal helper shared by
the ext4 and fat32 entry points.  errors from make-process route
through panic-handle and CALLBACK is invoked with (nil error)."
  (condition-case err
      (let* ((buf (install-mkfs--work-buffer device))
             (proc (make-process
                    :name (concat "mkfs:" device)
                    :buffer buf
                    :noquery t
                    :connection-type 'pipe
                    :command (cons program args)
                    :sentinel
                    (lambda (proc _event)
                      (when (memq (process-status proc)
                                  '(exit signal failed))
                        (let* ((sig  (process-status proc))
                               (code (process-exit-status proc))
                               (ok (and (eq sig 'exit) (zerop code))))
                          (cond
                           (ok (funcall callback t nil))
                           (t (funcall callback nil
                                       (list :status sig :exit code))))))))))
        (with-current-buffer (install-mkfs--work-buffer device)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (format "\n--- %s %s ---\n"
                            program (mapconcat #'identity args " ")))))
        proc)
    (error
     (panic-handle err (cons 'install-mkfs--spawn device))
     (funcall callback nil err)
     nil)))

(defun install-mkfs-ext4 (device label callback)
  "Format DEVICE as ext4 with LABEL.  CALLBACK is (lambda (ok reason)).
DEVICE is a full /dev/... path.  LABEL goes into the filesystem
header (the wizard sets it to \"geos-root\" by convention so a
later boot can find the root by label as a fallback to UUID).

We pass -F (force) because mkfs.ext4 will otherwise prompt on
stdin if the device already has a filesystem signature, and we
have no stdin.  the wizard's confirm-format state is the human
gate; once we are here the user has already said yes.

This is destructive.  the caller is responsible for having
verified via `install-disk-mounted-p' that the disk is safe."
  (install-mkfs--spawn install-mkfs-ext4-program
                       (list "-F" "-L" label device)
                       device
                       callback))

(defun install-mkfs-fat32 (device label callback)
  "Format DEVICE as FAT32 with LABEL.  CALLBACK is (lambda (ok reason)).
Used for the EFI System Partition.  LABEL is upper-cased to fit
the 11-byte FAT volume-label field; we let mkfs.fat enforce that
rather than truncating here.

-F 32 forces a FAT32 type (mkfs.fat defaults to FAT16 on small
partitions, which the EFI spec rejects)."
  (install-mkfs--spawn install-mkfs-fat-program
                       (list "-F" "32" "-n" label device)
                       device
                       callback))

(provide 'install-mkfs)
;;; mkfs.el ends here
