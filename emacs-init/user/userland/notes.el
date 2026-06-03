;;; notes.el --- org, the notes and agenda system -*- lexical-binding: t -*-
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

;; org is in-tree on emacs 29+ and recent enough for our needs. we keep
;; the config minimal: agenda key, capture key, and ~/org as the agenda
;; root. no roam, no super-agenda, no contrib, no dotfile cruft. /ricer-check
;; would flag it.

(require 'panic)

(condition-case err
    (use-package org
      :comment "notes and agenda. in-tree, the only outliner i need."
      :defer t
      :bind (("C-c e o" . org-agenda))
      :config
      ;; ~/org is the canonical notes dir. on a fresh image it does
      ;; not exist; org-agenda will print "No agenda files" which is
      ;; the right behavior, not a panic.
      (setq org-directory "~/org")
      (setq org-agenda-files (list "~/org"))
      ;; capture is the daily driver. one template, INBOX entry under
      ;; ~/org/inbox.org. anything more elaborate belongs in user dotfiles,
      ;; not here.
      (setq org-capture-templates
            '(("i" "inbox" entry
               (file+headline "~/org/inbox.org" "Inbox")
               "* %?\n  %U\n"))))
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'userland-notes-load)
     (message "userland/notes: load failed before panic-handle: %S" err))))

(provide 'userland-notes)
;;; notes.el ends here
