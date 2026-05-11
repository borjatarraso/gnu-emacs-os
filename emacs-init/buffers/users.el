;;; users.el --- *users* buffer, the live UI for /etc/passwd -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

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

(defvar users-buffer-name "*users*"
  "Canonical name of the user-list buffer.")

(defun users-buffer--source-available-p ()
  "Return non-nil if the passwd reader is bound."
  (fboundp 'passwd-read-passwd))

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
            (insert (format "  %-16s %5s %5s %-22s %-16s %s\n"
                            "user" "uid" "gid" "home" "shell" "pw"))
            (cond
             ((null users)
              (insert "  (no data)\n"))
             (t
              (dolist (u users)
                (let* ((name (plist-get u :user))
                       (locked (users-buffer--locked-p name shadow))
                       (line (format "  %-16s %5d %5d %-22s %-16s %s"
                                     name
                                     (plist-get u :uid)
                                     (plist-get u :gid)
                                     (plist-get u :home)
                                     (plist-get u :shell)
                                     (if locked "locked" "set"))))
                  (insert (propertize line 'users-row u) "\n")))))
            (insert
             "\nkeys: a=add  d=delete  p=password  g=refresh  q=bury\n"))
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

(defun users-buffer-add ()
  "Prompt for a new username and call `passwd-add-user'.  bound to `a'.
the password is left unset; the new account is locked until `p'."
  (interactive)
  (cond
   ((not (fboundp 'passwd-add-user))
    (message "users-buffer: passwd-add-user unbound"))
   (t
    (let ((name (read-string "New username: ")))
      (when (and name (not (string-empty-p name)))
        (passwd-add-user name)
        (users-buffer-refresh))))))

(defun users-buffer-delete ()
  "Delete the user on the current line.  bound to `d'.
prompts for confirmation.  refuses uid 0 (handled in `passwd-delete-user')."
  (interactive)
  (let ((row (users-buffer-row-at-point)))
    (cond
     ((null row)
      (message "users-buffer: no user on this line"))
     ((not (fboundp 'passwd-delete-user))
      (message "users-buffer: passwd-delete-user unbound"))
     ((not (yes-or-no-p (format "Delete user %s? " (plist-get row :user)))))
     (t
      (passwd-delete-user (plist-get row :user))
      (users-buffer-refresh)))))

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
