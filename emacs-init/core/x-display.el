;;; x-display.el --- supervisor side of the EXWM display-release dance -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; v0.7 item 1 spike artifact.
;;
;; The supervisor emacs owns Xorg :0 today via `(exwm-enable)' in
;; user/exwm-config.el.  v0.7 item 1 hands the WM role to the
;; per-user emacs across the boundary of a successful login.
;;
;; This file is the supervisor side of that dance:
;;
;;   x-display-release   tear down the supervisor's EXWM state, flush
;;                       and disconnect the XCB connection, drop the
;;                       supervisor's X frame.  call after
;;                       pid1-spawn-as-uid has returned the child pid;
;;                       the user-emacs is the next process to call
;;                       (exwm-wm-mode 1) against :0.
;;
;;   x-display-reclaim   open :0 again for *login*.  call from
;;                       session-end (and the poller's auto-teardown
;;                       path) once the registry is empty.
;;
;; Both are panic-handled and idempotent: a double release returns
;; t without doing further work; a reclaim when the display is
;; already up does likewise.
;;
;; Spike finding (2026-05-12): EXWM 0.34 does have a documented
;; teardown verb.  `exwm-wm-mode' is a global minor mode; calling
;; `(exwm-wm-mode -1)' runs `exwm-exit-hook', exits the input /
;; manage / workspace / floating / layout submodules, flushes and
;; disconnects the XCB connection, and nils `exwm--connection'.
;; `(exwm-enable)' is the deprecated-since-0.33 entry point that
;; routes to `(exwm-wm-mode 1)' anyway.  the plan's "EXWM does not
;; document a release path" risk is mitigated: the toggle IS
;; documented.  the open question is whether dropping the
;; supervisor's X frame after the toggle leaves :0 clean enough
;; for a fresh client to call (exwm-wm-mode 1) without an EXWM
;; patch.  the answer is empirical and lives in the QEMU smoke-
;; test for item 1.1.
;;
;; This file does NOT wire itself into session.el.  it is the
;; prototype.  the actual wiring lands in item 1.2 alongside the
;; user-init.el WM chain growth and the supervisor-side stop-
;; calling-exwm-enable change.

(require 'panic nil t)

(defvar x-display--released nil
  "Non-nil if the supervisor currently has no X connection.
Set by `x-display-release', cleared by `x-display-reclaim'.
Idempotency guard for both verbs.")

(defun x-display--has-connection-p ()
  "Return non-nil if EXWM thinks it owns an XCB connection.
Checks the EXWM internal `exwm--connection' bound after a successful
`(exwm-wm-mode 1)'.  Returns nil if EXWM never loaded."
  (and (boundp 'exwm--connection)
       (symbol-value 'exwm--connection)))

(defun x-display--frames-on-display ()
  "Return the list of live frames whose terminal is :0.
Empty list if we are running on the kernel framebuffer console
or if all X frames have already been closed."
  (let (acc)
    (dolist (f (frame-list))
      (let ((kind (and (frame-live-p f)
                       (framep f)
                       (frame-parameter f 'display))))
        (when (and (stringp kind) (string-prefix-p ":" kind))
          (push f acc))))
    acc))

(defun x-display-release ()
  "Tear down the supervisor's EXWM state and close :0.
Steps:
  1. if `x-display--released' is non-nil, return t (idempotent).
  2. toggle `exwm-wm-mode' off; this runs exwm-exit-hook,
     exits the submodules, flushes XCB, and disconnects.
  3. delete every X frame still bound to a display starting `:'.
     (the terminal will close when its last frame goes.)
  4. call `x-close-connection' for each remaining display name
     to be sure.  errors swallowed: the display may already be
     gone.
  5. set `x-display--released' t and return t.

Errors at any step route through `panic-handle' and return nil.
Caller (session-spawn) treats nil as 'release failed, supervisor
keeps its frame, the user-emacs will not be able to grab :0
this login'.  the login still proceeds; the user just gets a
non-WM frame until the next attempt."
  (cond
   (x-display--released t)
   (t
    (condition-case err
        (progn
          (when (and (fboundp 'exwm-wm-mode)
                     (x-display--has-connection-p))
            (exwm-wm-mode -1))
          (dolist (f (x-display--frames-on-display))
            (when (and (frame-live-p f)
                       (> (length (frame-list)) 1))
              (delete-frame f t)))
          (when (fboundp 'x-close-connection)
            (dolist (d (and (fboundp 'x-display-list)
                            (x-display-list)))
              (condition-case _
                  (x-close-connection d)
                (error nil))))
          (setq x-display--released t)
          t)
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err 'x-display-release))
       nil)))))

(defun x-display-reclaim ()
  "Re-open :0 for the supervisor so *login* can draw.
Steps:
  1. if `x-display--released' is nil, return t (idempotent;
     either we never released or we already reclaimed).
  2. open a new X frame on :0 via `make-frame-on-display'.
     this brings up a terminal at :0 with the kernel-console
     font (supervisor no longer loads fonts.el under v0.7
     item 1 once it moves to user-side).
  3. clear `x-display--released' and return t.

The supervisor does NOT re-call (exwm-wm-mode 1) here.  *login*
is a single buffer rendered into a plain X frame; no WM bookkeeping
is needed between sessions.  the next user-emacs to log in claims
WM duties.

Errors route through `panic-handle' and return nil.  caller
(session-end) treats nil as 'reclaim failed; the operator sees
the supervisor TTY but no X frame.  a manual M-x x-display-reclaim
retry is the recovery path."
  (cond
   ((not x-display--released) t)
   (t
    (condition-case err
        (let ((display (or (getenv "DISPLAY") ":0")))
          (when (fboundp 'make-frame-on-display)
            (make-frame-on-display
             display
             '((name . "geos-login")
               (fullscreen . fullboth))))
          (setq x-display--released nil)
          t)
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err 'x-display-reclaim))
       nil)))))

(provide 'x-display)

;;; x-display.el ends here
