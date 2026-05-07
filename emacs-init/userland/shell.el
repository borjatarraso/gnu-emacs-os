;;; shell.el --- eshell, the only shell on this OS -*- lexical-binding: t -*-

;; project hard rule #1: there is no shell other than eshell. /bin/sh
;; is a stub that forwards to emacsclient (see shstub/sh.c). this file
;; configures eshell so the prompt feels like a real shell and not a
;; "well, it's emacs" toy.
;;
;; eshell is in-tree, no extra Guix package. wrapped in use-package
;; so the :comment lives next to the config, per project rule.

(require 'panic)

(condition-case err
    (use-package eshell
      :comment "the one shell on this OS. /bin/sh forwards here via shstub."
      ;; not :defer t. shstub bridges into eshell on every /bin/sh exec,
      ;; which means eshell can be called before the user ever types
      ;; M-x eshell. having it loaded at boot avoids a require-on-first
      ;; -execve stall on a cold image.
      :bind (("C-c e s" . eshell))
      :config
      ;; keep shell history on disk so a respawn does not amnesia.
      (setq eshell-history-size 4096)
      ;; trim duplicated commands from history. nothing kills a session
      ;; faster than ls ls ls ls cluttering up M-r.
      (setq eshell-hist-ignoredups t)
      ;; scroll behavior: stay at the bottom on output, like every
      ;; other terminal in existence.
      (setq eshell-scroll-to-bottom-on-input 'this)
      (setq eshell-scroll-to-bottom-on-output 'this)
      ;; visual commands need a real terminal. eshell hands these off
      ;; to term-mode automatically. this list covers the cases that
      ;; matter: i pull up htop, less, and $EDITOR a lot.
      (with-eval-after-load 'em-term
        (setq eshell-visual-commands
              (append '("htop" "less" "more" "vi" "vim" "ssh")
                      (and (boundp 'eshell-visual-commands)
                           eshell-visual-commands)))))
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'userland-shell-load)
     (message "userland/shell: load failed before panic-handle: %S" err))))

(provide 'userland-shell)
;;; shell.el ends here
