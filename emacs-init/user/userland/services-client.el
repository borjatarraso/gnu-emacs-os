;;; services-client.el --- user-side *services* via supervisor RPC -*- lexical-binding: t -*-
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

;; v0.7 item 4.2.  the supervisor still owns the supervised-service
;; registry (everything in core/supervise.el).  v0.6 item 3 shipped
;; the AF_UNIX RPC channel; v0.7 item 4.1 added the `services-list'
;; verb that returns the registry sanitised for the wire.  this file
;; is the user-side view: a read-only buffer that polls the verb on
;; a 3s timer and renders the rows.
;;
;; why a polling timer and not a push:
;;   the supervisor is single-threaded.  pushing on registry change
;;   would require a publish primitive on top of the existing
;;   request/reply socket, which is more wire and more state for
;;   the same effective freshness as a 3s poll.  if a user wants
;;   the snapshot right now they hit `g'.
;;
;; why 3s and not 2s like the supervisor's *services* buffer:
;;   the supervisor's buffer reads its registry in-process; a 2s
;;   render is essentially free.  the user-side renderer pays a
;;   socket round-trip per refresh; 3s halves the RPC churn for
;;   the same screen freshness from the user's perspective.
;;
;; what breaks if the supervisor is down:
;;   `geos-rpc' raises an error (socket missing / connection
;;   refused).  we catch and surface "supervisor RPC down" in the
;;   buffer body, no panic; the timer keeps polling and the buffer
;;   reconnects on its own once the supervisor is back.

(require 'cl-lib)
(require 'panic)
(require 'rpc-client)

(defvar services-client-buffer-name "*services*"
  "Canonical buffer name for the user-side services view.
matches the supervisor's *services* buffer name, on purpose: a
user typing M-x services in the user-emacs should see the same
header even though the data took a different path to get there.")

(defvar services-client-refresh-interval 3
  "Seconds between RPC polls.
slightly slower than the supervisor's in-process 2s render so we
do not double the RPC traffic for no perceptible benefit.")

(defvar-local services-client--timer nil
  "Per-buffer auto-refresh timer.")

(defvar-local services-client--last-rows nil
  "Last successfully-fetched rows, kept so a transient RPC error
does not blank the buffer between successful polls.")

(defun services-client--fetch ()
  "Call the `services-list' RPC verb, return the row list or signal.
returns whatever the supervisor returned, which today is a list of
plists with :name :kind :status :pid :restarts :started-at.  any
RPC failure (socket missing, parse error, timeout) propagates so
the renderer can show it in the buffer body rather than wedging."
  (geos-rpc "services-list"))

(defun services-client--format-pid (plist)
  "Render the pid column.  matches the supervisor renderer's shape:
a positive integer prints as decimal, anything else is `-' so the
column stays the same width."
  (let ((pid (plist-get plist :pid)))
    (if (and pid (integerp pid) (> pid 0))
        (format "%d" pid)
      "-")))

(defun services-client--format-uptime (started)
  "Render STARTED (unix-epoch seconds or nil) as a short string.
nil or non-positive prints `-'."
  (cond
   ((not (numberp started)) "-")
   (t
    (let ((secs (max 0 (truncate (- (float-time) started)))))
      (cond ((<= secs 0) "-")
            ((< secs 60) (format "%ds" secs))
            ((< secs 3600) (format "%dm%ds" (/ secs 60) (mod secs 60)))
            ((< secs 86400) (format "%dh%dm" (/ secs 3600)
                                    (/ (mod secs 3600) 60)))
            (t (format "%dd%dh" (/ secs 86400)
                       (/ (mod secs 86400) 3600))))))))

(defun services-client--render-rows (rows)
  "Insert one line per row in ROWS (list of plists from the verb)."
  (insert (format "  %-22s %-9s %-7s %-9s %-8s %-10s\n"
                  "name" "status" "pid" "kind" "restarts" "uptime"))
  (cond
   ((null rows)
    (insert "  (no services)\n"))
   (t
    (dolist (s rows)
      (let* ((restarts-raw (plist-get s :restarts))
             (restarts (if (numberp restarts-raw) restarts-raw 0))
             (line (format "  %-22s %-9s %-7s %-9s %-8d %-10s"
                           (or (plist-get s :name) "?")
                           (or (plist-get s :status) 'unknown)
                           (services-client--format-pid s)
                           (or (plist-get s :kind) 'unknown)
                           restarts
                           (services-client--format-uptime
                            (plist-get s :started-at)))))
        (insert (propertize line 'services-service s) "\n"))))))

(defun services-client--render ()
  "Repaint the current buffer from a fresh RPC fetch.
errors from `geos-rpc' are caught and shown in the body so a
transient supervisor outage does not kill the buffer or stop the
timer.  the last good rows are kept in `services-client--last-rows'
and re-rendered with an `outdated' marker so the user knows what
they are looking at."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col  (current-column)))
    (erase-buffer)
    (condition-case err
        (let ((rows (services-client--fetch)))
          (setq services-client--last-rows rows)
          (setq header-line-format
                (format "*services* (over RPC)  refreshed %s"
                        (format-time-string "%H:%M:%S")))
          (services-client--render-rows rows))
      (error
       (setq header-line-format
             (format "*services* (over RPC)  RPC down at %s, last good %s"
                     (format-time-string "%H:%M:%S")
                     (if services-client--last-rows "below" "(none)")))
       (insert (format "  supervisor RPC error: %s\n"
                       (error-message-string err)))
       (when services-client--last-rows
         (insert "  showing last good snapshot:\n")
         (services-client--render-rows services-client--last-rows))
       (when (fboundp 'panic-handle)
         (panic-handle err 'services-client--render))))
    (insert "\nkeys: g refresh   q bury\n")
    (goto-char (point-min))
    (forward-line (1- start-line))
    (move-to-column start-col)))

(defun services-client-refresh ()
  "Force one RPC fetch + repaint."
  (interactive)
  (let ((buf (get-buffer services-client-buffer-name)))
    (when buf
      (with-current-buffer buf
        (services-client--render)))))

(defun services-client--timer-tick (buf)
  "Timer callback.  refresh BUF or self-cancel if it died."
  (cond
   ((not (buffer-live-p buf))
    (when (timerp services-client--timer)
      (cancel-timer services-client--timer)))
   (t
    (with-current-buffer buf
      (services-client--render)))))

(defun services-client-quit ()
  "Bury the buffer (we do not kill it; the rule is the same as the
supervisor's *services* buffer)."
  (interactive)
  (bury-buffer))

(defvar services-client-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g") #'services-client-refresh)
    (define-key m (kbd "q") #'services-client-quit)
    m)
  "Keymap for `services-client-mode'.")

(define-derived-mode services-client-mode special-mode "Services"
  "Major mode for the user-side *services* buffer."
  (setq truncate-lines t)
  ;; install the auto-refresh timer on first display.  the buffer is
  ;; long-lived (it lives in the user-emacs's buffer list) so this
  ;; only fires once.
  (unless (timerp services-client--timer)
    (let ((buf (current-buffer)))
      (setq services-client--timer
            (run-at-time services-client-refresh-interval
                         services-client-refresh-interval
                         #'services-client--timer-tick
                         buf)))))

;;;###autoload
(defun services ()
  "Open *services*, the user-side view of the supervisor's service
registry.  fetches over the v0.6 item 3 RPC channel; refreshes every
3 seconds.  bound to C-c e s to match the C-c e * convention."
  (interactive)
  (let ((buf (get-buffer-create services-client-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'services-client-mode)
        (services-client-mode))
      (services-client--render))
    (display-buffer buf)
    buf))

(global-set-key (kbd "C-c e s") #'services)

(provide 'services-client)
;;; services-client.el ends here
