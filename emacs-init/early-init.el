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
;; (B1, audit round-5 2026-05-10) define `pid1-error' BEFORE module-load
;; runs.  the C side can raise pid1-error during module init (e.g. from
;; emacs_module_init's setup helpers), and condition-case can only catch
;; it as `error' if the symbol is registered as an error-condition first.
;; without this define, a module-init signal lands as a "peculiar error"
;; and the surrounding condition-case below catches it as a generic
;; `error', losing the type and triggering the wrong fallback path.
;; declaring outside the `when' is fine: define-error is idempotent on a
;; dev host where pid1-as-emacs-p is nil, and pid1-error existing in a
;; non-OS emacs is harmless (no code raises it there).
(define-error 'pid1-error "PID1 supervision error")

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
              (module-load mod))
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

;; (B1, audit 2026-05-10) start the emacs server NOW so /bin/sh ->
;; shstub -> emacsclient -> eshell-command works for every legacy
;; invocation later in boot. without this line every `sh -c ...`
;; in the system silently exits with "can't find socket". server
;; default `server-socket-dir' is `(temporary-file-directory)/emacsN'
;; for uid N; we are uid 0 so the socket lands at /tmp/emacs0/server,
;; which matches shstub/sh.c's wait_for_emacs_server probe.
;;
;; only start the server when we are the OS userland.  on a dev-host
;; emacs we leave the user's existing server (if any) alone.
;;
;; server-start is wrapped in condition-case so a transient failure
;; (perm error on /tmp, stale socket from a previous boot) does not
;; abort early-init and brick supervision; we degrade by leaving the
;; bridge offline and let panic-handle log the failure once it loads.
(when pid1-as-emacs-p
  (condition-case err
      (progn
        (require 'server)
        ;; server-start signals if a stale server-process exists; pass
        ;; INHIBIT-PROMPT t so the boot does not block on a y-or-n
        ;; nag, and pass nil for `leave-dead' so a stale socket is
        ;; replaced rather than refused.
        (server-start nil t))
    (error
     ;; (B2, audit round-5 2026-05-10) panic.el is not loaded yet at
     ;; this point in early-init (it loads from init.el), so panic-handle
     ;; is unbound.  also `*Messages*' alone is invisible at boot if the
     ;; framebuffer never lights up.  write directly to /dev/console so
     ;; the failure is captured on the serial log.  ignore write errors:
     ;; if /dev/console itself is gone, we are already in a worse spot
     ;; than a missing shstub bridge.
     (message "early-init: server-start failed: %S, /bin/sh bridge offline" err)
     (condition-case _
         (let ((write-region-inhibit-fsync t))
           (write-region
            (format "early-init: server-start failed: %S, shstub bridge offline\n"
                    err)
            nil "/dev/console" 'append 'nomsg))
       (error nil)))))

(provide 'early-init)
;;; early-init.el ends here
