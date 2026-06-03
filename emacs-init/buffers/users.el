;;; users.el --- *users* buffer, the live UI for /etc/passwd -*- lexical-binding: t -*-
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

;; what does it show: every account in /etc/passwd plus a hint as to
;; whether a hashed password lives in /etc/shadow.  same columnar
;; pattern as *services* and *processes*.
;;
;; how does it refresh: re-reads on `g'.  no timer because /etc/passwd
;; does not change behind our back (we are the only writer).
;;
;; what can the user do here:
;;   `a' add, `d' delete (refuses uid 0), `p' set password,
;;   `g' refresh, `q' bury.
;;
;; what breaks if /etc/passwd disappears: we render "(no data)" and
;; the rest of the OS keeps running.  passwd-read-passwd is already
;; soft-fail; we just paint the empty list.

(require 'panic)
(require 'cl-lib)

(condition-case err
    (require 'passwd)
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'users-buffer-require)
     (message "users-buffer: passwd require failed: %S" err))))

;; session.el is optional in case the *users* buffer is invoked on a
;; v0.4 image where the login flow has not been wired yet.  the
;; rendering helper below soft-fails when `session-count-for-uid' is
;; unbound and prints "-" in the login column.
(condition-case err
    (require 'session)
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'users-buffer-require-session)
     (message "users-buffer: session require failed: %S" err))))

(defvar users-buffer-name "*users*"
  "Canonical name of the user-list buffer.")

(defun users-buffer--source-available-p ()
  "Return non-nil if the passwd reader is bound."
  (fboundp 'passwd-read-passwd))

(defun users-buffer--session-cell (uid)
  "Return the per-row login-count string for UID.
\"N sessions\" when session.el is loaded, \"-\" otherwise.  one
buffer per system concept means we annotate here rather than spin
up a *sessions* buffer."
  (cond
   ((not (fboundp 'session-count-for-uid)) "-")
   (t
    (let ((n (condition-case err
                 (session-count-for-uid uid)
               (error
                (panic-handle err `(users-buffer--session-cell . ,uid))
                0))))
      (format "%d sessions" n)))))

(defun users-buffer--locked-p (user shadow-rows)
  "Return non-nil if USER's shadow row indicates a locked account.
shadow conventionally locks an account by storing `!' or `*' as
the hash.  also returns non-nil if no shadow row is found at all,
since an account with no shadow entry effectively cannot log in."
  (let ((row (cl-find-if (lambda (e) (string= (plist-get e :user) user))
                         shadow-rows)))
    (or (null row)
        (let ((h (plist-get row :hash)))
          (or (null h)
              (string-empty-p h)
              (string-prefix-p "!" h)
              (string-prefix-p "*" h))))))

(defun users-buffer--render ()
  "Repaint the *users* buffer from /etc/passwd + /etc/shadow."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col (current-column)))
    (erase-buffer)
    (setq header-line-format
          (format "*users*  state=%s  refreshed %s"
                  (if (fboundp 'state-mode-string)
                      (state-mode-string)
                    "?")
                  (format-time-string "%Y-%m-%d %H:%M:%S")))
    (cond
     ((not (users-buffer--source-available-p))
      (insert "core/passwd.el not loaded\n"))
     (t
      (condition-case err
          (let ((users (passwd-read-passwd))
                (shadow (passwd-read-shadow)))
            (insert (format "  %-16s %5s %5s %-22s %-16s %-6s %s\n"
                            "user" "uid" "gid" "home" "shell" "pw"
                            "login"))
            (cond
             ((null users)
              (insert "  (no data)\n"))
             (t
              (dolist (u users)
                (let* ((name (plist-get u :user))
                       (uid (plist-get u :uid))
                       (locked (users-buffer--locked-p name shadow))
                       (login-cell (users-buffer--session-cell uid))
                       (line (format "  %-16s %5d %5d %-22s %-16s %-6s %s"
                                     name
                                     uid
                                     (plist-get u :gid)
                                     (plist-get u :home)
                                     (plist-get u :shell)
                                     (if locked "locked" "set")
                                     login-cell)))
                  (insert (propertize line 'users-row u) "\n")))))
            (insert
             "\nkeys: a=add  d=delete  p=password  u=unlock  g=refresh  q=bury\n"))
        (error
         (panic-handle err 'users-buffer-render)
         (insert "render failed, see *panic*\n")))))
    (goto-char (point-min))
    (forward-line (1- start-line))
    (move-to-column start-col)))

(defun users-buffer-refresh ()
  "Force a refresh of *users*.  bound to `g'."
  (interactive)
  (let ((buf (get-buffer users-buffer-name)))
    (when buf
      (with-current-buffer buf
        (users-buffer--render)))))

(defun users-buffer-row-at-point ()
  "Return the user plist for the current line, or nil."
  (get-text-property (line-beginning-position) 'users-row))

(defun users-buffer--read-int (prompt default)
  "Read an integer from the minibuffer with DEFAULT as fallback.
empty input returns DEFAULT.  non-integer input loops.  used by the
add flow so the operator can hit RET through every defaulted slot."
  (let ((raw (read-string (format "%s (default %d): " prompt default))))
    (cond
     ((or (null raw) (string-empty-p raw)) default)
     ((string-match-p "\\`-?[0-9]+\\'" raw) (string-to-number raw))
     (t
      (message "users-buffer: %s must be an integer" prompt)
      (sit-for 1)
      (users-buffer--read-int prompt default)))))

(defun users-buffer--read-string (prompt default)
  "Read a string, returning DEFAULT on empty input."
  (let ((raw (read-string (format "%s (default %s): " prompt default))))
    (cond ((or (null raw) (string-empty-p raw)) default)
          (t raw))))

(defun users-buffer-add ()
  "Add a user end to end: passwd row, home dir, password.  bound to `a'.
prompts for username, uid (default next free), gid (default = uid),
home (default /home/NAME), shell (default /bin/sh), and password
(read-passwd twice).  on success the account is logged-in-ready;
v0.5.1 needed an M-: dance to chain these steps, v0.6 owns it.

empty password is rejected: the operator can still use a locked
account by hitting C-g during the prompt and running `a' again
without the password, but that's an unusual ask and we trade the
edge case for one less surprising path."
  (interactive)
  (cond
   ((not (fboundp 'passwd-create-user-and-home))
    (message "users-buffer: passwd-create-user-and-home unbound"))
   (t
    (let* ((name (read-string "New username: ")))
      (cond
       ((or (null name) (string-empty-p name))
        (message "users-buffer: empty username, aborting"))
       (t
        (let* ((default-uid (passwd--next-uid))
               (uid (users-buffer--read-int "uid" default-uid))
               (gid (users-buffer--read-int "gid" uid))
               (home (users-buffer--read-string
                      "home" (concat passwd-default-home-prefix name)))
               (shell (users-buffer--read-string
                       "shell" passwd-default-shell))
               (pw1 (read-passwd
                     (format "Password for %s (empty to skip): " name)))
               (pw2 (and pw1 (not (string-empty-p pw1))
                         (read-passwd "Confirm password: "))))
          (cond
           ((and pw1 (not (string-empty-p pw1))
                 (not (string= pw1 pw2)))
            (message "users-buffer: passwords do not match, aborting"))
           (t
            (passwd-create-user-and-home
             name
             :uid uid :gid gid :home home :shell shell
             :password (and pw1 (not (string-empty-p pw1)) pw1))
            (users-buffer-refresh))))))))))

(defun users-buffer-delete ()
  "Delete the user on the current line.  bound to `d'.
prompts for confirmation.  refuses uid 0 (handled in `passwd-delete-user').
after the passwd row is gone, offers to remove the home directory
too; default n because losing a home dir to a typo is hard to
undo, while keeping a stale dir on disk is cheap."
  (interactive)
  (let ((row (users-buffer-row-at-point)))
    (cond
     ((null row)
      (message "users-buffer: no user on this line"))
     ((not (fboundp 'passwd-delete-user))
      (message "users-buffer: passwd-delete-user unbound"))
     ((not (yes-or-no-p (format "Delete user %s? " (plist-get row :user)))))
     (t
      (let ((name (plist-get row :user))
            (home (plist-get row :home)))
        (when (passwd-delete-user name)
          (when (and home (file-directory-p home)
                     (y-or-n-p (format "Also remove home dir %s? " home)))
            (condition-case err
                (delete-directory home t)
              (error
               (panic-handle err `(users-buffer-delete-home . ,home))))))
        (users-buffer-refresh))))))

(defun users-buffer-set-password ()
  "Set the password for the user on the current line.  bound to `p'.
falls back to a free-form prompt if point is not on a user row."
  (interactive)
  (let* ((row (users-buffer-row-at-point))
         (name (or (and row (plist-get row :user))
                   (read-string "User: ")))
         (pw (read-passwd (format "New password for %s: " name) t)))
    (cond
     ((not (fboundp 'passwd-set-password))
      (message "users-buffer: passwd-set-password unbound"))
     ((or (null pw) (string-empty-p pw))
      (message "users-buffer: empty password rejected"))
     (t
      (passwd-set-password name pw)
      (users-buffer-refresh)))))

(defun users-buffer-unlock ()
  "Clear the lockout on the user at point.  bound to `u'.
v0.6 item 5.3 ships the lockout: 10 bad credential attempts inside
5 minutes flips a username to a `:locked-until' record under
/var/emacs/lockouts/NAME.  this command deletes that file.  the
file is supervisor-owned, so only the *users* buffer (which only
opens in the supervisor emacs) can reach it; the per-user emacs
gets ENOENT on the open and would silently no-op.

falls back to a free-form prompt if point is not on a user row,
mirroring `users-buffer-set-password' so an operator can unlock a
user whose row is off-screen without scrolling first."
  (interactive)
  (let* ((row (users-buffer-row-at-point))
         (name (or (and row (plist-get row :user))
                   (read-string "Unlock user: "))))
    (cond
     ((or (null name) (string-empty-p name))
      (message "users-buffer: empty username, aborting"))
     ((not (fboundp 'login--lockout-clear))
      (message "users-buffer: login--lockout-clear unbound"))
     (t
      (login--lockout-clear name)
      (message "users-buffer: lockout cleared for %s" name)
      (users-buffer-refresh)))))

(defun users-buffer-quit ()
  "Bury *users*.  per project rules we do not kill it."
  (interactive)
  (bury-buffer))

(defvar users-buffer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g") #'users-buffer-refresh)
    (define-key m (kbd "a") #'users-buffer-add)
    (define-key m (kbd "d") #'users-buffer-delete)
    (define-key m (kbd "p") #'users-buffer-set-password)
    (define-key m (kbd "u") #'users-buffer-unlock)
    (define-key m (kbd "q") #'users-buffer-quit)
    m)
  "Keymap for `users-buffer-mode'.")

(define-derived-mode users-buffer-mode special-mode "Users"
  "Major mode for the *users* buffer.
read-only view of /etc/passwd and /etc/shadow with editing keys
that all route through core/passwd.el's atomic writers."
  (setq truncate-lines t))

;;;###autoload
(defun users ()
  "Display the *users* buffer.  M-x users."
  (interactive)
  (let ((buf (get-buffer-create users-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'users-buffer-mode)
        (users-buffer-mode))
      (users-buffer--render))
    (display-buffer buf)
    buf))

(provide 'users-buffer)
;;; users.el ends here
