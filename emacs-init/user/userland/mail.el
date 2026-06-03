;;; mail.el --- notmuch, mail as a tag query -*- lexical-binding: t -*-
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
