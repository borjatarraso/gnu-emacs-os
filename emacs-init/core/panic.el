;;; panic.el --- the buffer that catches errors so the OS keeps running -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

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
;; panic safety net.
(defun panic--eval-expression-advice (orig &rest args)
  "Around-advice for `eval-expression' routing errors to panic."
  (condition-case err
      (apply orig args)
    (error (panic-handle err 'eval-expression))))

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
