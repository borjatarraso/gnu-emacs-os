;;; panic.el --- the buffer that catches errors so the OS keeps running -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;; HARD RULE: `panic-handle' is the ONLY safe way to surface errors
;; from supervisory code. a bare `error' anywhere under core/ is a
;; violation. we are PID 1. an uncaught signal here means the box is
;; dead. route everything through here.
;;
;; this does not eliminate the single-thread problem. a wedged regex
;; still wedges the world. it just means a normal raised error logs
;; and life continues.

(defvar panic-buffer-name "*panic*"
  "Name of the buffer that collects every routed error.
Never killed. See `panic--unkillable'.")

(defvar panic--frame-depth 12
  "How many backtrace frames to snapshot per panic entry.
Enough to see who called who, not so many that the buffer becomes
a wall of noise during a tight error loop.")

(defvar panic--reentry nil
  "Non-nil while `panic-handle' is running.
Guards against panic-in-panic. if logging itself raises, we eat
it silently rather than recursing forever.")

(defun panic--get-buffer ()
  "Return the *panic* buffer, creating it if needed.
Buffer is read-only via `special-mode' but we bind
`inhibit-read-only' when appending."
  (let ((buf (get-buffer panic-buffer-name)))
    (unless buf
      (setq buf (get-buffer-create panic-buffer-name))
      (with-current-buffer buf
        (special-mode)
        (setq-local truncate-lines nil)))
    buf))

(defun panic--unkillable (&optional _buf)
  "Refuse to kill the panic buffer.
Hooked into `kill-buffer-query-functions'. returns nil iff the
buffer being killed is the panic buffer."
  (not (string= (buffer-name) panic-buffer-name)))

(add-hook 'kill-buffer-query-functions #'panic--unkillable)

;; refuse (kill-emacs) and friends.  PID 1's emacs going down is a
;; full userland reboot from the supervisor's point of view; nothing
;; in elisp should be able to trigger that by accident.  the right way
;; to power down is M-x geos-poweroff (which calls reboot(2) directly,
;; bypassing this gate).  we hook three paths and they layer like this:
;;
;;   - advice-add :around on `kill-emacs' itself.  this is the strong
;;     gate: programmatic (kill-emacs) bypasses query-functions, so we
;;     pin around-advice at depth -100 to make sure no later advice can
;;     slip in front and let the kill through.  refuses by returning nil
;;     without calling the original.
;;
;;   - kill-emacs-query-functions: consulted by save-buffers-kill-* and
;;     the windowing shutdown paths.  returning nil aborts the kill.
;;     redundant given the around-advice but cheap and clearer in
;;     post-mortems (the user sees the refusal message).
;;
;;   - kill-emacs-hook: only fires when a kill ACTUALLY proceeds (the
;;     gates above let it through, e.g. geos-poweroff bound
;;     `panic-allow-kill-emacs').  we leave a breadcrumb so a
;;     post-mortem can tell deliberate exit from anything that managed
;;     to slip past.
;;
;; opt-out: bind `panic-allow-kill-emacs' to non-nil (e.g. inside
;; geos-poweroff after the user confirmed) to skip both gates.

(defvar panic-allow-kill-emacs nil
  "Bind non-nil to allow `kill-emacs' through the panic gate.
Set by the deliberate shutdown paths (geos-poweroff, geos-reboot)
just before they hand off to the kernel.  Anywhere else, leaving
this nil refuses the kill and logs a breadcrumb.")

(defvar panic--running-as-pid1
  (and (boundp 'pid1-as-emacs-p) pid1-as-emacs-p)
  "Non-nil when this Emacs is the PID 1 supervisor.
Initialized from `pid1-as-emacs-p' which early-init.el sets before
panic.el is loaded; on a dev host where early-init.el wasn't read
the symbol is unbound and we default to nil.  The kill-emacs gates
check this rather than sniffing for individual module symbols, so
dev-host emacs sessions that happen to byte-compile this file are
not held hostage by the gate.")

(defun panic--refuse-kill-emacs ()
  "Refuse (kill-emacs) unless `panic-allow-kill-emacs' is set.
Returning nil from `kill-emacs-query-functions' aborts the kill.
On a non-PID1 emacs (`panic--running-as-pid1' nil) we wave the
kill through so dev-host sessions aren't held hostage by this
hook.  Batch emacs (`noninteractive') is also waved through: it
has no user to read the refusal message and would just hang."
  (cond
   (panic-allow-kill-emacs t)
   (noninteractive t)
   ((not panic--running-as-pid1) t)
   (t
    (panic-handle (list 'kill-emacs-refused 'interactive)
                  'panic--refuse-kill-emacs)
    (message "panic: kill-emacs refused; use M-x geos-poweroff to shut down")
    nil)))

(add-hook 'kill-emacs-query-functions #'panic--refuse-kill-emacs)

(defun panic--note-kill-emacs ()
  "Leave a breadcrumb in *panic* when (kill-emacs) actually proceeds.
The kill has already been authorized by the time this runs; we
cannot stop it.  We log so a post-mortem can tell whether the
exit was deliberate (geos-poweroff / geos-reboot bound
`panic-allow-kill-emacs') or accidental."
  (panic-handle (list 'kill-emacs-proceeding
                      (cons 'allowed panic-allow-kill-emacs))
                'panic--note-kill-emacs))

(add-hook 'kill-emacs-hook #'panic--note-kill-emacs)

;; programmatic (kill-emacs) does NOT consult kill-emacs-query-functions
;; (that is only run by save-buffers-kill-terminal and the windowing
;; shutdown paths).  the freeze test calls (kill-emacs) directly to
;; verify PID 1 cannot be tricked into exiting from elisp.  wrap
;; kill-emacs itself so the refusal is symmetric.  on a non-PID1 emacs
;; we still let it through, otherwise dev-host sessions would be held
;; hostage by this advice the moment panic.el got loaded.
;;
;; depth -100 pins this advice OUTERMOST so we get the first chance to
;; refuse.  any later `:around' at the default depth 0 sits beneath
;; ours and will only run if WE call orig (i.e. we authorized the
;; kill).  layering caveat: if we authorize and the inner advice then
;; refuses, we lose the kill-emacs we expected to happen.  not a real
;; concern today (no one else advises kill-emacs in this tree) but
;; flagged here so a future `advice-add' on kill-emacs at depth 0
;; doesn't surprise the next reader.
(defun panic--refuse-kill-emacs-around (orig &rest args)
  "Around-advice for `kill-emacs' that mirrors `panic--refuse-kill-emacs'.
Bypasses the gate when `panic-allow-kill-emacs' is non-nil, when
this is batch emacs (`noninteractive'), or when this Emacs is not
the PID 1 supervisor (`panic--running-as-pid1' nil)."
  (cond
   (panic-allow-kill-emacs
    (apply orig args))
   (noninteractive
    (apply orig args))
   ((not panic--running-as-pid1)
    (apply orig args))
   (t
    (panic-handle (list 'kill-emacs-refused 'programmatic)
                  'panic--refuse-kill-emacs-around)
    (message "panic: kill-emacs refused; use M-x geos-poweroff to shut down")
    nil)))

(advice-add 'kill-emacs :around #'panic--refuse-kill-emacs-around
            '((depth . -100)))

(defun panic--format-frames ()
  "Return a short string describing the current backtrace.
Trimmed to `panic--frame-depth' frames. wrapped in
`condition-case' because `backtrace-frames' itself can fail in
weird states."
  (condition-case _
      (let ((frames (backtrace-frames))
            (out '())
            (n 0))
        (while (and frames (< n panic--frame-depth))
          (let ((f (car frames)))
            (push (format "  %S" (nth 1 f)) out))
          (setq frames (cdr frames))
          (setq n (1+ n)))
        (mapconcat #'identity (nreverse out) "\n"))
    (error "  <backtrace unavailable>")))

(defun panic-handle (err &optional context)
  "Log ERR to the panic buffer with optional CONTEXT tag.
ERR is the error object as received by `condition-case' (a cons
of symbol and data). CONTEXT is any printable tag describing
where we were when it blew up.

Must never itself raise. If logging fails, swallow the secondary
error and return."
  (unless panic--reentry
    (let ((panic--reentry t))
      (condition-case _
          (let* ((buf (panic--get-buffer))
                 (ts  (format-time-string "%Y-%m-%dT%H:%M:%S.%3N"))
                 (sym (car-safe err))
                 (msg (condition-case _
                          (error-message-string err)
                        (error (format "%S" err))))
                 (frames (panic--format-frames)))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (goto-char (point-max))
                (insert (format "[%s] ctx=%s sym=%S msg=%s\n%s\n\n"
                                ts (or context "-") sym msg frames)))))
        (error nil))))
  nil)

(defun panic--command-error (err _context _caller)
  "Bridge `command-error-function' to `panic-handle'.
ERR is the error data. The other two args are the command name
and caller, which we ignore here; the caller name is already in
the backtrace."
  (panic-handle err 'command-loop))

(setq command-error-function #'panic--command-error)

;; `command-error-function' only fires for uncaught errors from
;; interactive commands. M-: (eval-expression) goes through its own
;; path, so wrap that too. anything you eval at the prompt gets the
;; panic safety net.  re-signal after logging: M-: callers expect to
;; see the error in the echo area, not have it disappear into
;; *panic*.  the log + re-raise pattern means we get both: an audit
;; trail in *panic* and the usual interactive feedback.
(defun panic--eval-expression-advice (orig &rest args)
  "Around-advice for `eval-expression' routing errors to panic.
Logs the error to *panic* then re-signals it so the user still
sees the normal echo-area failure message."
  (condition-case err
      (apply orig args)
    (error
     (panic-handle err 'eval-expression)
     (signal (car err) (cdr err)))))

(advice-add 'eval-expression :around #'panic--eval-expression-advice)

(defun panic-test ()
  "Trigger a fake error and confirm *panic* logged it.
Interactive smoke test. Returns t on success, nil otherwise."
  (interactive)
  (let ((before (with-current-buffer (panic--get-buffer)
                  (buffer-size))))
    (condition-case err
        (error "panic test")
      (error (panic-handle err 'panic-test)))
    (let* ((buf (panic--get-buffer))
           (after (with-current-buffer buf (buffer-size)))
           (ok (> after before)))
      (message "panic-test: %s (delta=%d bytes)"
               (if ok "ok" "FAIL") (- after before))
      ok)))

(provide 'panic)
;;; panic.el ends here
