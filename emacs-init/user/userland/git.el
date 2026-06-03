;;; git.el --- magit, because git on the command line is a war crime -*- lexical-binding: t -*-
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

;; magit is the version-control UI. it forks git via process-file with
;; an argv vector, never through a posix-shell wrapper, so it satisfies
;; the project's no-shell rule out of the box.
;;
;; depends on emacs-magit (system package, added in guix-system/system.scm).

(require 'panic)

(condition-case err
    (use-package magit
      :comment "git porcelain. zero shell-out, talks to git via process-file."
      ;; defer until the user actually asks for it. magit pulls in
      ;; transient, with-editor, dash, and a pile of macros at load
      ;; time; no point doing that during boot.
      :defer t
      :bind (("C-c e g" . magit-status))
      :config
      ;; show the full diff when committing. magit's default is "show
      ;; the diff in a window", which on a small screen means hunting
      ;; for it. tall is fine.
      (setq magit-diff-refine-hunk 'all))
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'userland-git-load)
     (message "userland/git: load failed before panic-handle: %S" err))))

(provide 'userland-git)
;;; git.el ends here
