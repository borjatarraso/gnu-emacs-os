;;; journal-client.el --- user-side *journal* via supervisor RPC -*- lexical-binding: t -*-
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

;; v0.7 item 4.3.  the supervisor's *Messages* buffer is the audit
;; trail: every supervised-service event, every RPC reboot/poweroff
;; line, every panic-handle landing.  v0.6 item 3 shipped the
;; `journal-tail' RPC verb that returns the last N lines as strings;
;; this file is the user-side viewer that polls it and renders.
;;
;; what shows here vs. the supervisor's *journal*:
;;   the supervisor's buffers/journal.el reads /dev/kmsg directly,
;;   that is the kernel ring buffer, not the supervisor's elisp
;;   message log.  this file shows the supervisor's elisp side,
;;   which is the more useful audit surface from a user's view (it
;;   logs RPC events, service restarts, etc.).  the kmsg surface
;;   stays supervisor-only; a future item exposes it via a separate
;;   `kmsg-tail' verb.  for now this gives the user enough.
;;
;; why a fixed N=200 default:
;;   the supervisor clamps N to [1, 500].  200 fits a typical
;;   terminal of useful height (~50 lines visible, headroom for
;;   scroll).  bump via prefix-arg to M-x journal: `C-u 500 M-x
;;   journal' fetches the supervisor cap.
;;
;; refresh cadence: 3s, same logic as services-client.el (one
;; RPC round-trip per tick; halving the rate vs. the supervisor's
;; 2s in-process render is a fair trade for the wire cost).

(require 'cl-lib)
(require 'panic)
(require 'rpc-client)

(defvar journal-client-buffer-name "*journal*"
  "Canonical buffer name for the user-side journal view.
matches the supervisor's *journal* buffer name on purpose; the
user typing M-x journal sees the same name regardless of which
side rendered it.")

(defvar journal-client-default-n 200
  "Default number of trailing lines to ask for.
the supervisor caps at 500; this is a useful per-screen value
that scrolls back a few minutes on a busy boot.")

(defvar journal-client-refresh-interval 3
  "Seconds between RPC polls.  matches services-client.")

(defvar-local journal-client--timer nil)
(defvar-local journal-client--n journal-client-default-n
  "Last requested line count for this buffer.")
(defvar-local journal-client--last-lines nil
  "Last successfully-fetched lines.  preserved across transient
RPC errors so the buffer keeps showing data while the supervisor
is briefly unreachable.")

(defun journal-client--fetch (n)
  "Call the `journal-tail' RPC verb for N lines, return string list.
the verb returns a list of strings (no trailing newlines); the
supervisor clamps N to [1, 500]."
  (geos-rpc "journal-tail" n))

(defun journal-client--render-lines (lines)
  "Insert LINES with one entry per row.  nil-safe."
  (cond
   ((null lines)
    (insert "  (journal is empty)\n"))
   (t
    (dolist (line lines)
      (insert (if (stringp line) line (format "%S" line)))
      (insert "\n")))))

(defun journal-client--render ()
  "Repaint the current buffer from a fresh RPC fetch.
on error: keep the last good lines visible (if any) plus the
error line and a flipped header.  same survival shape as
services-client.el."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col  (current-column)))
    (erase-buffer)
    (condition-case err
        (let ((lines (journal-client--fetch journal-client--n)))
          (setq journal-client--last-lines lines)
          (setq header-line-format
                (format "*journal* (over RPC, n=%d)  refreshed %s"
                        journal-client--n
                        (format-time-string "%H:%M:%S")))
          (journal-client--render-lines lines))
      (error
       (setq header-line-format
             (format "*journal* (over RPC)  RPC down at %s, last good %s"
                     (format-time-string "%H:%M:%S")
                     (if journal-client--last-lines "below" "(none)")))
       (insert (format "  supervisor RPC error: %s\n"
                       (error-message-string err)))
       (when journal-client--last-lines
         (insert "  showing last good snapshot:\n")
         (journal-client--render-lines journal-client--last-lines))
       (when (fboundp 'panic-handle)
         (panic-handle err 'journal-client--render))))
    (insert "\nkeys: g refresh   + more lines   - fewer lines   q bury\n")
    (goto-char (point-min))
    (forward-line (1- start-line))
    (move-to-column start-col)))

(defun journal-client-refresh ()
  "Force one RPC fetch + repaint."
  (interactive)
  (let ((buf (get-buffer journal-client-buffer-name)))
    (when buf
      (with-current-buffer buf
        (journal-client--render)))))

(defun journal-client-more ()
  "Ask for more lines (cap at the supervisor's 500).  bound to `+'."
  (interactive)
  (setq journal-client--n
        (min 500 (+ journal-client--n 100)))
  (journal-client--render))

(defun journal-client-less ()
  "Ask for fewer lines (floor 10).  bound to `-'."
  (interactive)
  (setq journal-client--n
        (max 10 (- journal-client--n 100)))
  (journal-client--render))

(defun journal-client--timer-tick (buf)
  "Timer callback.  refresh BUF or self-cancel if it died."
  (cond
   ((not (buffer-live-p buf))
    (when (timerp journal-client--timer)
      (cancel-timer journal-client--timer)))
   (t
    (with-current-buffer buf
      (journal-client--render)))))

(defun journal-client-quit ()
  "Bury the buffer.  same rule as services-client / supervisor *journal*."
  (interactive)
  (bury-buffer))

(defvar journal-client-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g") #'journal-client-refresh)
    (define-key m (kbd "+") #'journal-client-more)
    (define-key m (kbd "=") #'journal-client-more)
    (define-key m (kbd "-") #'journal-client-less)
    (define-key m (kbd "q") #'journal-client-quit)
    m)
  "Keymap for `journal-client-mode'.")

(define-derived-mode journal-client-mode special-mode "Journal"
  "Major mode for the user-side *journal* view."
  (setq truncate-lines nil)
  (unless (timerp journal-client--timer)
    (let ((buf (current-buffer)))
      (setq journal-client--timer
            (run-at-time journal-client-refresh-interval
                         journal-client-refresh-interval
                         #'journal-client--timer-tick
                         buf)))))

;;;###autoload
(defun journal (&optional n)
  "Open *journal*, the user-side view of the supervisor's audit log.
prefix arg sets the line count (clamped supervisor-side to 500).
bound to C-c e j to match the C-c e * convention."
  (interactive "P")
  (let ((buf (get-buffer-create journal-client-buffer-name))
        (req (cond ((numberp n) n)
                   ((consp n) journal-client-default-n)
                   (t journal-client-default-n))))
    (with-current-buffer buf
      (unless (derived-mode-p 'journal-client-mode)
        (journal-client-mode))
      (setq journal-client--n
            (max 10 (min 500 req)))
      (journal-client--render))
    (display-buffer buf)
    buf))

(global-set-key (kbd "C-c e j") #'journal)

(provide 'journal-client)
;;; journal-client.el ends here
