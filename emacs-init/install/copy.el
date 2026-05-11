;;; copy.el --- copy /gnu/store + system closure into install target -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; v0.4 MVP install wizard, the bulk-data step.  once the target
;; partition is mkfs'd and mounted at TARGET-MOUNT, this file copies
;; everything the booted target needs to come up on its own:
;;
;;   /gnu/store           the entire content-addressed store.  this
;;                        is the substantive bytes (multiple GB).
;;   /var/guix            the daemon's bookkeeping (profiles,
;;                        gc-roots, db).  without it the booted
;;                        target cannot guix-reconfigure.
;;   /run/current-system  the booted system derivation.  the
;;                        bootloader-config generator below points
;;                        at this for kernel + initrd paths.
;;
;; we shell out to cp from coreutils via make-process: -a preserves
;; everything cp can preserve (mode, ownership, timestamps, symlinks)
;; which is what /gnu/store needs to remain content-addressed.  no
;; /bin/sh, no shell expansion of paths; cp gets argv directly.
;;
;; on size: a fresh GEOS closure is ~6-8 GB.  on a modern SATA disk
;; that copies in a couple minutes.  on a USB 2 stick it can take
;; half an hour.  the wizard does not parallelise: cp is single-
;; threaded by design and the elisp side stays out of its way.

(require 'panic)

(defcustom install-copy-program "cp"
  "Absolute path or PATH-resolvable name of cp.
From coreutils.  -a is the only flag we use, which is portable
across every coreutils version we will encounter."
  :type 'string
  :group 'install)

(defconst install-copy--sources
  '("/gnu/store" "/var/guix" "/run/current-system")
  "Top-level paths copied wholesale into the install target.
Order matters less than completeness; cp -a is content-preserving.
/run/current-system is a symlink, but cp -a preserves it as a
symlink, and the target it points to is under /gnu/store which we
also copy, so the target system finds its current-system intact.")

(defconst install-copy--work-buffer " *install:copy*"
  "Hidden work buffer for cp stdout/stderr.")

(defun install-copy--ensure-target-skeleton (target-mount)
  "Create /gnu, /var, /run inside TARGET-MOUNT if not already there.
cp -a will create the final-segment dir if its parent exists, so
we just need the parents.  errors route through panic-handle and
the caller's callback fires with (nil ...)."
  (dolist (sub '("gnu" "var" "run"))
    (let ((p (expand-file-name sub target-mount)))
      (unless (file-directory-p p)
        (condition-case err
            (make-directory p t)
          (error
           (panic-handle err
                         (cons 'install-copy--ensure-target-skeleton p))))))))

(defun install-copy-system (target-mount callback)
  "Copy /gnu/store, /var/guix, /run/current-system into TARGET-MOUNT.
CALLBACK is (lambda (ok reason)).  spawned via make-process so the
supervisor stays responsive during what can be a multi-minute copy.

Sequenced rather than parallel: each source is copied with a
separate cp invocation, chained through the sentinel.  if any cp
fails, the chain stops and CALLBACK fires with (nil reason).
that is the right shape for a wizard step: partial copies leave
an unbootable target either way, so the operator wants to know on
the first failure, not after three.

Progress feedback is intentionally minimal in v0.4: the work
buffer captures cp's stderr (which is empty on success), the
wizard polls the work buffer size for a coarse ticker.  cp does
not print per-file by default and we are not adding -v: that
would produce GB of log on a 6 GB copy."
  (condition-case err
      (let ((buf (get-buffer-create install-copy--work-buffer)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (format "\n--- install-copy-system %s ---\n"
                            target-mount))))
        (install-copy--ensure-target-skeleton target-mount)
        (install-copy--next install-copy--sources target-mount callback))
    (error
     (panic-handle err 'install-copy-system)
     (funcall callback nil err))))

(defun install-copy--next (remaining target-mount callback)
  "Copy the next source in REMAINING; chain via sentinel.
Internal worker for `install-copy-system'.  recurses through
`install-copy--sources' in order, terminating on first failure or
on empty list."
  (cond
   ((null remaining)
    (funcall callback t nil))
   (t
    (let* ((src (car remaining))
           (rest (cdr remaining))
           (dest (expand-file-name (file-name-nondirectory src) target-mount))
           (buf (get-buffer-create install-copy--work-buffer)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format "cp -a %s %s\n" src dest))))
      (condition-case err
          (make-process
           :name (concat "install-copy:" (file-name-nondirectory src))
           :buffer buf
           :noquery t
           :connection-type 'pipe
           :command (list install-copy-program "-a" src dest)
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal failed))
               (let* ((sig  (process-status proc))
                      (code (process-exit-status proc))
                      (ok (and (eq sig 'exit) (zerop code))))
                 (cond
                  (ok (install-copy--next rest target-mount callback))
                  (t (funcall callback nil
                              (list :failed-at src
                                    :status sig
                                    :exit code))))))))
        (error
         (panic-handle err (cons 'install-copy--next src))
         (funcall callback nil err)))))))

(provide 'install-copy)
;;; copy.el ends here
