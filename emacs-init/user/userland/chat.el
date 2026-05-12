;;; chat.el --- erc, the irc client -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; erc is in-tree. for now i wire it up with sane defaults and a
;; keybinding. server config is a per-user concern, lives in init.el
;; or via M-x erc, not in the OS image.

(require 'panic)

(condition-case err
    (use-package erc
      :comment "irc client. in-tree, defers cleanly, no daemon."
      :defer t
      :bind (("C-c e c" . erc))
      :config
      ;; nicks i actually want to highlight on. empty by default; a
      ;; user customizes via M-x customize-variable. listed here only
      ;; so the var is set to a list (not nil) and erc-match doesn't
      ;; complain.
      (setq erc-keywords '())
      ;; hide the join/part/quit spam. on a busy channel this is the
      ;; difference between erc being usable and being a wall of noise.
      (setq erc-hide-list '("JOIN" "PART" "QUIT" "NICK"))
      ;; tab completes nicks at the prompt. on by default in newer erc
      ;; but i set it explicitly because the default flipped twice in
      ;; the last decade and i no longer trust it.
      (setq erc-pcomplete-nick-postfix ": "))
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'userland-chat-load)
     (message "userland/chat: load failed before panic-handle: %S" err))))

(provide 'userland-chat)
;;; chat.el ends here
