;;; services.el --- *services* buffer, the live UI for systemctl / herd -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; what does it show: every supervised service in the elisp userland.
;; one row per service with name, status (running/dead/disabled), pid
;; (or "-" for timers and sentinels), kind (process/timer/sentinel),
;; restart count, and uptime in seconds. sorted by name. when
;; core/supervise.el is loaded the rows come from its registry. when
;; it is not loaded (early phases, repl boot) the rows come from a
;; synthesized walk of `process-list' so the buffer is still useful.
;;
;; how does it refresh: a 2-second repeating timer that the buffer
;; owns. timer is started on first display and cancelled when the
;; buffer is killed. `g' forces an immediate refresh.
;;
;; what can the user do here: `g' refresh, `RET' shows full details
;; (the entire registry plist when available, just process info
;; otherwise), `s' starts a service, `S' stops one, `r' restarts one,
;; `q' buries (we never kill our concept buffers, same rule as
;; *network* and *processes*). start/stop/restart no-op with a
;; message when supervise.el has not been loaded yet.
;;
;; what breaks if the source disappears: nothing fatal. the registry
;; lookup goes through `fboundp', the fallback walks `process-list'
;; which is always available, and any error during render is routed
;; through `panic-handle' and the buffer prints "render failed, see
;; *panic*" instead of dying. cross-process visibility into pid1's
;; child table (xorg, the supervised emacs itself) is partial until
;; pid1-module exposes a child-list primitive; today we can only see
;; what is reachable from `process-list' inside this emacs.

;; same load-order hazard as network.el and processes.el: panic may
;; not be loaded yet under early byte-compile or repl eval. tolerate
;; it.
(condition-case err
    (require 'panic)
  (error
   (message "services-buffer: require panic failed: %S" err)))

(defvar services-buffer-name "*services*"
  "Name of the canonical services state buffer.
Per project rules this buffer is conceptually unkillable. the
timer cleanup hook exists for symmetry, not because we expect
the buffer to die.")

(defvar services-buffer-details-name "*service-details*"
  "Name of the popup buffer that shows the full plist for one service.")

(defvar services-buffer-refresh-interval 2
  "Seconds between automatic refreshes of *services*.
Two seconds is fine. the registry is small (tens, not thousands)
and a process-list walk on a phase-4 emacs is bounded by however
many subprocesses this single emacs has spawned. well under our
100ms budget either way.")

(defvar-local services-buffer--timer nil
  "Per-buffer timer driving auto-refresh. Cancelled in the kill hook.")

(defun services-buffer--registry-available-p ()
  "Return non-nil if core/supervise.el has been loaded.
The registry function is the contract surface. if it is not
bound, the buffer falls back to `process-list' and the
start/stop/restart commands degrade to a message."
  ;; TODO(6): drop this guard once core/supervise.el is a hard
  ;; dependency of init.el. until then we tolerate its absence.
  (fboundp 'supervise-registry))

(defun services-buffer--from-process-list ()
  "Synthesize a registry-shaped list from `process-list'.
Used when core/supervise.el is not loaded. each emacs subprocess
becomes a plist with the same keys the real registry uses, so
the renderer does not have to care which source it got. uptime
is unknown here (process objects do not carry start time we can
trust across emacs restarts) so it reports as 0. restarts is
also 0, since this fallback has no memory."
  (mapcar
   (lambda (p)
     (let ((status (process-status p)))
       ;; (MAJOR, audit round-5 2026-05-10) `make-symbol' returns an
       ;; UNINTERNED symbol so an attacker who can name a subprocess
       ;; cannot inject obarray entries that persist for the life of
       ;; this emacs.  the rest of the renderer compares :name with
       ;; symbol-name, which works the same for interned and uninterned
       ;; symbols, so the swap is observation-equivalent.
       (list :name (make-symbol (process-name p))
             :kind 'process
             :status (cond ((memq status '(run open listen connect)) 'running)
                           ((memq status '(exit signal closed failed)) 'dead)
                           (t 'disabled))
             :pid (process-id p)
             :restarts 0
             :started-at nil
             :process p)))
   (process-list)))

(defun services-buffer--collect ()
  "Return the list of service plists from whichever source is live.
Prefers `supervise-registry' when bound, falls back to a walk of
`process-list' shaped into the same plist contract."
  (if (services-buffer--registry-available-p)
      (condition-case err
          (supervise-registry)
        (error
         (when (fboundp 'panic-handle)
           (panic-handle err 'services-buffer-registry))
         nil))
    (services-buffer--from-process-list)))

(defun services-buffer--uptime (plist)
  "Compute uptime in whole seconds for service PLIST.
Returns 0 when :started-at is nil (the fallback path) or when
the service is not running."
  (let ((started (plist-get plist :started-at))
        (status  (plist-get plist :status)))
    (if (and started (eq status 'running))
        (max 0 (truncate (- (float-time) started)))
      0)))

(defun services-buffer--format-uptime (secs)
  "Render SECS as a short human-ish string. zero shows as '-'."
  (cond ((<= secs 0) "-")
        ((< secs 60) (format "%ds" secs))
        ((< secs 3600) (format "%dm%ds" (/ secs 60) (mod secs 60)))
        ((< secs 86400) (format "%dh%dm" (/ secs 3600) (/ (mod secs 3600) 60)))
        (t (format "%dd%dh" (/ secs 86400) (/ (mod secs 86400) 3600)))))

(defun services-buffer--format-pid (plist)
  "Render the pid column for PLIST. timers and sentinels print '-'."
  (let ((pid (plist-get plist :pid)))
    (if (and pid (integerp pid) (> pid 0))
        (format "%d" pid)
      "-")))

(defun services-buffer--render-rows (rows)
  "Insert one line per service in ROWS (list of plists)."
  (insert (format "  %-22s %-9s %-7s %-9s %-8s %-10s\n"
                  "name" "status" "pid" "kind" "restarts" "uptime"))
  (if (null rows)
      (insert "  (no services)\n")
    (dolist (s (sort (copy-sequence rows)
                     (lambda (a b)
                       (string< (format "%s" (plist-get a :name))
                                (format "%s" (plist-get b :name))))))
      (let* ((restarts-raw (plist-get s :restarts))
             ;; %d crashes if the registry plist ever stores a non-
             ;; integer (some legacy supervise.el rows used a string
             ;; "0" or nil).  numberp-guard so the row degrades to "?"
             ;; rather than taking the whole render down via condition-
             ;; case at the caller.
             (restarts (if (numberp restarts-raw) restarts-raw 0))
             (line (format "  %-22s %-9s %-7s %-9s %-8d %-10s"
                           (plist-get s :name)
                           (or (plist-get s :status) 'unknown)
                           (services-buffer--format-pid s)
                           (or (plist-get s :kind) 'unknown)
                           restarts
                           (services-buffer--format-uptime
                            (services-buffer--uptime s)))))
        ;; stash the plist on the line so RET / s / S / r can pick it
        ;; up without re-collecting from the registry.
        (insert (propertize line 'services-service s) "\n")))))

(defun services-buffer--render ()
  "Repaint the current buffer from the registry (or the fallback).
Wrapped in `condition-case' so a parse glitch does not stop the
timer or kill the buffer."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col (current-column)))
    (erase-buffer)
    (setq header-line-format
          (format "*services*  %s  refreshed %s"
                  (if (services-buffer--registry-available-p)
                      "registry"
                    "process-list fallback")
                  (format-time-string "%Y-%m-%d %H:%M:%S")))
    (condition-case err
        (services-buffer--render-rows (services-buffer--collect))
      (error
       (if (fboundp 'panic-handle)
           (panic-handle err 'services-buffer-render)
         (message "services-buffer render failed: %S" err))
       (insert "render failed, see *panic*\n")))
    ;; restore point roughly where the user had it. matters when the
    ;; timer fires while the user is hovering a row to hit RET.
    (goto-char (point-min))
    (forward-line (1- start-line))
    (move-to-column start-col)))

(defun services-buffer-refresh ()
  "Force a refresh of *services*. Bound to `g'."
  (interactive)
  (let ((buf (get-buffer services-buffer-name)))
    (when buf
      (with-current-buffer buf
        (services-buffer--render)))))

(defun services-buffer--timer-tick (buf)
  "Timer callback. Refresh BUF if it still exists, else self-cancel.
The kill-hook normally cancels our timer, but if the buffer dies
without our hook running (or is recreated under the same name
with a fresh buffer-local timer slot) the previously-armed timer
survives and fires here against a dead buffer. detect that and
cancel ourselves out of `timer-list' so we do not leak a wakeup
forever. same defensive pattern as network.el."
  (if (buffer-live-p buf)
      (with-current-buffer buf
        (condition-case err
            (services-buffer--render)
          (error
           (if (fboundp 'panic-handle)
               (panic-handle err 'services-buffer-timer)
             (message "services-buffer timer failed: %S" err)))))
    (dolist (tm (append timer-list timer-idle-list))
      (when (and (timerp tm)
                 (eq (timer--function tm) #'services-buffer--timer-tick)
                 (equal (timer--args tm) (list buf)))
        (cancel-timer tm)))))

(defun services-buffer--start-timer ()
  "Install the 2-second refresh timer on the current buffer."
  (when (timerp services-buffer--timer)
    (cancel-timer services-buffer--timer))
  (setq services-buffer--timer
        (run-at-time services-buffer-refresh-interval
                     services-buffer-refresh-interval
                     #'services-buffer--timer-tick
                     (current-buffer))))

(defun services-buffer--kill-hook ()
  "Cancel the per-buffer refresh timer when *services* is killed.
Project rule: this buffer is never killed. the hook is here for
symmetry with the rest of buffers/."
  (when (timerp services-buffer--timer)
    (cancel-timer services-buffer--timer)
    (setq services-buffer--timer nil)))

(defun services-buffer-service-at-point ()
  "Return the service plist stored on the current line, or nil."
  (get-text-property (line-beginning-position) 'services-service))

(defun services-buffer-show-details ()
  "Open a popup with the full plist for the service on the current line.
Bound to `RET'. silently no-ops on header / blank lines. when
the row came from the registry the popup shows every key in the
plist; when it came from the fallback it shows just the synthesized
fields plus the underlying process object."
  (interactive)
  (let ((plist (services-buffer-service-at-point)))
    (when plist
      (let ((buf (get-buffer-create services-buffer-details-name)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (special-mode)
            (insert (format "service: %s\n\n" (plist-get plist :name)))
            ;; walk the plist as pairs. works for both the registry
            ;; shape and the fallback shape because both are plists.
            (let ((p plist))
              (while p
                (insert (format "%-14s %S\n" (car p) (cadr p)))
                (setq p (cddr p))))
            (goto-char (point-min))))
        (display-buffer buf)))))

(defun services-buffer--registry-call (sym name action)
  "Invoke (SYM NAME) for ACTION, message-degrading when SYM is unbound.
Wraps the supervise.el ABI in a single guard so the start/stop/restart
commands do not each need to repeat the fboundp dance."
  ;; TODO(6): collapse this into direct calls once core/supervise.el
  ;; is guaranteed loaded by init.el.
  (cond
   ((not (fboundp sym))
    (message "services: %s requires core/supervise.el (not loaded)" action))
   (t
    (condition-case err
        (progn
          (funcall sym name)
          (message "services: %s %s" action name)
          (services-buffer-refresh))
      (error
       (if (fboundp 'panic-handle)
           (panic-handle err (intern (format "services-buffer-%s" action)))
         (message "services-buffer %s failed: %S" action err)))))))

(defun services-buffer-start ()
  "Start the service on the current line via `supervise-start'.
Bound to `s'. no-op with a message when the registry is missing."
  (interactive)
  (let ((plist (services-buffer-service-at-point)))
    (when plist
      (services-buffer--registry-call
       'supervise-start (plist-get plist :name) "start"))))

(defun services-buffer-stop ()
  "Stop the service on the current line via `supervise-stop'.
Bound to `S'. no-op with a message when the registry is missing."
  (interactive)
  (let ((plist (services-buffer-service-at-point)))
    (when plist
      (services-buffer--registry-call
       'supervise-stop (plist-get plist :name) "stop"))))

(defun services-buffer-restart ()
  "Restart the service on the current line via `supervise-restart'.
Bound to `r'. no-op with a message when the registry is missing."
  (interactive)
  (let ((plist (services-buffer-service-at-point)))
    (when plist
      (services-buffer--registry-call
       'supervise-restart (plist-get plist :name) "restart"))))

(defun services-buffer-quit ()
  "Bury *services*. Per project rules we do not kill it."
  (interactive)
  (bury-buffer))

(defvar services-buffer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g")   #'services-buffer-refresh)
    (define-key m (kbd "RET") #'services-buffer-show-details)
    (define-key m (kbd "s")   #'services-buffer-start)
    (define-key m (kbd "S")   #'services-buffer-stop)
    (define-key m (kbd "r")   #'services-buffer-restart)
    (define-key m (kbd "q")   #'services-buffer-quit)
    m)
  "Keymap for `services-buffer-mode'.")

(define-derived-mode services-buffer-mode special-mode "Services"
  "Major mode for the *services* buffer.
Read-only view of the supervise.el registry (or `process-list'
when supervise.el is not loaded), refreshed every two seconds.
see the file commentary for the four-question contract."
  (setq truncate-lines t)
  (add-hook 'kill-buffer-hook #'services-buffer--kill-hook nil t))

;;;###autoload
(defun services ()
  "Display the *services* buffer, creating it on first call.
Interactive entry point: `M-x services'. starts the refresh
timer if it is not already running."
  (interactive)
  (let ((buf (get-buffer-create services-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'services-buffer-mode)
        (services-buffer-mode))
      (services-buffer--render)
      (unless (timerp services-buffer--timer)
        (services-buffer--start-timer)))
    (display-buffer buf)
    buf))

;; TODO(6): when core/supervise.el lands, register the *services*
;; refresh timer with it so the buffer's own liveness is supervised
;; the same way it supervises everything else:
;;   (supervise-register
;;    :name 'services-buffer-timer
;;    :kind 'timer
;;    :start (lambda ()
;;             (with-current-buffer (get-buffer-create services-buffer-name)
;;               (unless (derived-mode-p 'services-buffer-mode)
;;                 (services-buffer-mode))
;;               (services-buffer--start-timer)))
;;    :stop  (lambda ()
;;             (let ((buf (get-buffer services-buffer-name)))
;;               (when buf
;;                 (with-current-buffer buf
;;                   (services-buffer--kill-hook))))))
;; cross-process visibility into pid1's child table (xorg, the
;; supervised emacs itself) is also a phase-6 item: pid1-module needs
;; to expose a `pid1-process-list' primitive before this buffer can
;; show what pid1 is babysitting. today we only see what
;; (process-list) inside this emacs returns.

(provide 'services-buffer)
;;; services.el ends here
