;;; mail.el --- notmuch, mail as a tag query -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; notmuch is two pieces: a C indexer (system package `notmuch') and
;; an Emacs UI (system package `emacs-notmuch'). the indexer talks to
;; xapian, the UI talks to the indexer via the `notmuch' binary using
;; process-file. no shell-out from our code.
;;
;; we do NOT configure a backend (offlineimap, mbsync, isync) here.
;; that is per-host setup, lives in ~/.notmuch-config, and is not
;; the OS image's business.

(require 'panic)

(condition-case err
    (use-package notmuch
      :comment "mail client. tags, not folders. no IMAP daemon in emacs."
      :defer t
      :bind (("C-c e m" . notmuch))
      :config
      ;; default search shows the last 30 days of unread mail. the
      ;; built-in default is "tag:inbox" which on a fresh install is
      ;; empty and confusing.
      (setq notmuch-saved-searches
            '((:name "inbox"   :query "tag:inbox"   :key "i")
              (:name "unread"  :query "tag:unread"  :key "u")
              (:name "recent"  :query "date:30d.."  :key "r"))))
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'userland-mail-load)
     (message "userland/mail: load failed before panic-handle: %S" err))))

(provide 'userland-mail)
;;; mail.el ends here
