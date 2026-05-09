;;; notes.el --- org, the notes and agenda system -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

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
