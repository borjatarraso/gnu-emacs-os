;;; files.el --- dired wiring for the file manager role -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;; the project rule says "every user-facing system concept is a buffer".
;; the file manager is dired. nothing more, nothing less. there is no
;; nautilus alternative on this image and there will not be one.
;;
;; dired ships in-tree with emacs, no Guix package needed. we still
;; pass it through use-package because the project rule wants every
;; package to carry a one-line :comment justifying its presence. that
;; rule is enforced visually by /ricer-check.

(require 'panic)

(condition-case err
    (use-package dired
      :comment "the file manager. ls(1) you can edit, no nautilus needed."
      ;; not :defer t. dired-jump is the first reflex when i open a
      ;; file in another buffer and want to see siblings. loading it at
      ;; boot keeps that snappy.
      :bind (("C-c e d" . dired-jump))
      :config
      ;; -h human sizes, -a show dotfiles, -l long format, --group-directories-first
      ;; so dirs sort to the top. coreutils ls supports the long flag,
      ;; busybox does not, but we have no busybox.
      (setq dired-listing-switches "-alh --group-directories-first")
      ;; copy/move target defaults to the other dired window when split.
      ;; saves a tab of typing for the common case.
      (setq dired-dwim-target t)
      ;; auto-revert when the directory changes on disk. otherwise i
      ;; keep wondering why a new file is not showing up.
      (setq dired-auto-revert-buffer t))
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'userland-files-load)
     (message "userland/files: load failed before panic-handle: %S" err))))

(provide 'userland-files)
;;; files.el ends here
