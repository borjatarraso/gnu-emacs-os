;;; early-init.el --- first thing emacs reads when booting as PID 1 -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;;; Project: GNU/Emacs Operating System (GEOS)

;; this file runs before package.el, before the GUI, before anything.
;; if i mess it up, the system never reaches a usable state. keep it
;; small. keep it boring.

;; we manage packages ourselves later in init.el / core/. don't let
;; package.el wake up and start touching ELPA on boot.
(setq package-enable-at-startup nil)

;; the C emacs-init forks emacs as a child, so emacs's pid is not 1
;; even when we are the supervised userland. the right signal that we
;; are the OS emacs (not a stray `emacs -Q` on a dev host) is whether
;; emacs-init populated PID1_MODULE_PATH in our env. once stage B
;; lands and emacs itself is PID 1, this predicate flips back to
;; (= (emacs-pid) 1) and pid1-module.so loads as a dlopen from a
;; statically-linked emacs. for now, env presence is the truth.
(defconst pid1-as-emacs-p (and (getenv "PID1_MODULE_PATH") t)
  "Non-nil when this Emacs is the supervised OS userland.
True when emacs-init exported PID1_MODULE_PATH into our env. Used
downstream to gate module loads, /var ownership, and supervision
wiring. Plain `emacs -Q` invocations on a dev host see nil here.")

(message "early-init: emacs pid=%d pid1-as-emacs-p=%s module-env=%s"
         (emacs-pid) pid1-as-emacs-p (getenv "PID1_MODULE_PATH"))

;; the module exposes pid1-reap, pid1-mount, pid1-set-hostname,
;; pid1-bring-up-lo. emacs-init passes the absolute store path of the
;; .so via PID1_MODULE_PATH; during dev or under plain `emacs -Q` the
;; env var is unset and we silently skip.
(when pid1-as-emacs-p
  (let ((mod (getenv "PID1_MODULE_PATH")))
    (if (and mod (file-exists-p mod))
        ;; condition-case is non-negotiable here. a bare module-load
        ;; that signals (ABI mismatch, missing dep, wrong libc) at
        ;; PID 1 with panic.el not yet loaded means uncaught error,
        ;; which means kernel panic. a console without supervision is
        ;; still better than a panic, so we degrade and message.
        (condition-case err
            (progn
              (message "early-init: loading pid1 module from %s" mod)
              (module-load mod)
              ;; the C side raises `pid1-error' via non_local_exit_signal
              ;; but the symbol has no error-conditions property until
              ;; we declare it here. without this, condition-case with
              ;; `(error ...)` will not catch pid1-error and emacs
              ;; prints "peculiar error" to *Messages*. register both
              ;; the parent (`error`) and a usable docstring so M-x
              ;; condition-case-and-friends can talk about it.
              (define-error 'pid1-error "PID1 supervision error"))
          (error
           (message "early-init: module-load failed: %S, continuing without supervision primitives"
                    err)))
      (message "early-init: PID1_MODULE_PATH unset or file missing (%s), skipping module"
               mod))))

;; we live in a terminal. the splash screen and scratch chatter are
;; just noise on console boot.
(setq inhibit-startup-screen t)
(setq initial-scratch-message nil)

;; libgpm prints "zero screen dimension, assuming 80x25" the first
;; time emacs's tty layer wakes it up on a kernel framebuffer console.
;; the warning is harmless but it dirties the boot log. emacs's
;; term/linux.el adds gpm-mouse-mode-startup to tty-setup-hook by
;; default; pull it out before the hook fires. once exwm is up we
;; route mouse events through X anyway, so gpm has nothing to do.
(dolist (sym '(gpm-mouse-startup
               gpm-mouse-mode-startup))
  (when (boundp 'tty-setup-hook)
    (remove-hook 'tty-setup-hook sym)))
(when (and (fboundp 'gpm-mouse-mode)
           (bound-and-true-p gpm-mouse-mode))
  (gpm-mouse-mode -1))

;; phase 1 boot warned about ~/.emacs.d/. we own /var, point there.
;; non-pid1 invocations keep the default so my normal emacs config
;; isn't disturbed.
(when pid1-as-emacs-p
  (setq user-emacs-directory "/var/emacs/"))

(provide 'early-init)
;;; early-init.el ends here
