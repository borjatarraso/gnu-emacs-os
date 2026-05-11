;;; login.el --- *login* state machine, the gate to a per-user emacs -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; the *login* buffer is the thing a human sees first.  it asks for a
;; username, then a password, then verifies against /etc/shadow, then
;; asks `session-spawn' to drop privilege and exec the per-user emacs.
;; same code path in console mode (drawn on /dev/console) and UI mode
;; (drawn on a dedicated EXWM workspace).  this file does NOT decide
;; which surface to draw on; the caller picks.
;;
;; state machine, mirrors the install.el shape:
;;
;;   :prompt-user      user types name, RET
;;        |
;;        v
;;   :prompt-password  user types password (echo suppressed), RET
;;        |
;;        v
;;   :verify           passwd-verify against /etc/shadow
;;        |    failed
;;        |--------> :failed (throttle counted) -> :prompt-user via r
;;        |
;;        v ok
;;   :spawning         session-spawn -> pid1-spawn-as-uid -> child pid
;;        |    failed
;;        |--------> :error -> :prompt-user via r
;;        |
;;        v
;;   :running          show "session active as <name> pid <n>"
;;                     q -> session-end -> :prompt-user
;;
;; throttle: 3 bad attempts inside 30 seconds locks the buffer in
;; :failed for the remainder of that window.  the operator (or a
;; future tty-attached attacker) cannot mash RET forever; we make them
;; wait.  the counter lives in this file, not in passwd.el, because it
;; is a UI concern: the underlying passwd-verify call is stateless and
;; safe to invoke any number of times.

(require 'cl-lib)
(require 'panic)
(require 'passwd)
(require 'session)

(defvar login-buffer-name "*login*"
  "Canonical name of the login state-machine buffer.")

(defvar login--state :prompt-user
  "Current state.  one of :prompt-user :prompt-password :verify
:spawning :running :failed :error.")

(defvar login--user nil
  "Username typed at :prompt-user.  cleared on transition back to
:prompt-user so a stale value never carries across a session.")

(defvar login--password nil
  "Plaintext password buffered between :prompt-password and :verify.
held only for the duration of one verify call; cleared the moment
the verify call returns.  this is the only place plaintext lives
in elisp memory.")

(defvar login--session nil
  "The `geos-session' record returned by `session-spawn' on success.
rendered at :running; cleared on logout.")

(defvar login--last-error nil
  "Free-form description of the last failure, shown in :error.")

(defconst login--throttle-window 30
  "Rolling window in seconds for the bad-attempt throttle.")

(defconst login--throttle-cap 3
  "Max bad attempts allowed inside the throttle window.
3-in-30s is permissive enough that a typo storm does not lock you
out but tight enough that a brute-force from /dev/console takes
forever.  network logins (v0.6+) will want a tighter cap.")

(defvar login--bad-attempts nil
  "List of float-time entries for recent bad-credential attempts.
trimmed to the window on every check.  not persisted: a reboot
intentionally resets the counter (an attacker who can reboot the
box has already won, no point in punishing the legitimate user
after a power blip).")

;; --------------------------------------------------------------------
;; throttle
;; --------------------------------------------------------------------

(defun login--throttle-trips-p ()
  "Return non-nil if too many bad attempts inside the window.
also trims `login--bad-attempts' to the window as a side effect."
  (let* ((now (float-time))
         (cutoff (- now login--throttle-window))
         (recent (cl-remove-if (lambda (t0) (< t0 cutoff))
                               login--bad-attempts)))
    (setq login--bad-attempts recent)
    (>= (length recent) login--throttle-cap)))

(defun login--note-bad-attempt ()
  "Record a bad-credential timestamp."
  (push (float-time) login--bad-attempts))

;; --------------------------------------------------------------------
;; render
;; --------------------------------------------------------------------

(defun login--header ()
  "Header-line string for the current state."
  (format "*login*  state=%s%s"
          login--state
          (cond
           ((null login--user) "")
           (t (concat "  user=" login--user)))))

(defun login--render ()
  "Repaint the buffer for the current `login--state'."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq header-line-format (login--header))
    (condition-case err
        (pcase login--state
          (:prompt-user      (login--render-prompt-user))
          (:prompt-password  (login--render-prompt-password))
          (:verify           (login--render-busy "verifying credentials..."))
          (:spawning         (login--render-busy "spawning per-user emacs..."))
          (:running          (login--render-running))
          (:failed           (login--render-failed))
          (:error            (login--render-error))
          (_ (insert (format "unknown state: %s\n" login--state))))
      (error
       (panic-handle err 'login--render)
       (insert "render failed, see *panic*\n")))))

(defun login--render-prompt-user ()
  "Username entry."
  (insert "  RET continue    q quit\n\n")
  (insert "=== geos login ===\n\n")
  (insert "  username: ")
  (when login--user (insert login--user))
  (insert "\n\n  Press RET to confirm the username (or type one first).\n"))

(defun login--render-prompt-password ()
  "Password entry.  we never echo the password into the buffer."
  (insert "  RET verify    b back    q quit\n\n")
  (insert "=== password ===\n\n")
  (insert (format "  username: %s\n" (or login--user "?")))
  (insert "  password: <hidden, RET to submit>\n\n")
  (insert "  Press RET to submit; b to back up to the username prompt.\n"))

(defun login--render-running ()
  "Running session view."
  (insert "  q logout (SIGTERM the session emacs)\n\n")
  (insert "=== session active ===\n\n")
  (cond
   ((null login--session)
    (insert "  internal: :running with no session record, see *panic*\n"))
   (t
    (insert (format "  user:        %s\n"
                    (geos-session-name login--session)))
    (insert (format "  uid/gid:     %d/%d\n"
                    (geos-session-uid login--session)
                    (geos-session-gid login--session)))
    (insert (format "  child pid:   %s\n"
                    (or (geos-session-child-pid login--session)
                        "(stubbed)")))
    (insert (format "  started:     %s\n"
                    (format-time-string
                     "%Y-%m-%d %H:%M:%S"
                     (geos-session-started-at login--session))))
    (insert "\n  Press q to log out.\n"))))

(defun login--render-failed ()
  "Bad-credentials view."
  (let ((throttled (login--throttle-trips-p)))
    (insert "  r retry    q quit\n\n")
    (insert "=== bad credentials ===\n\n")
    (cond
     (throttled
      (insert (format "  too many bad attempts (>= %d in %ds).\n"
                      login--throttle-cap login--throttle-window))
      (insert "  retry refused until the window clears.\n"))
     (t
      (insert "  username or password did not match.\n")
      (insert (format "  attempts in window: %d/%d\n\n"
                      (length login--bad-attempts)
                      login--throttle-cap))
      (insert "  press r to retry from the username prompt.\n")))))

(defun login--render-error ()
  "Spawn-or-other internal failure."
  (insert "  r retry    q quit\n\n")
  (insert "=== login error ===\n\n")
  (insert (format "  reason: %S\n\n" login--last-error))
  (insert "  this is not a bad-password error; see *panic* for detail.\n")
  (insert "  press r to retry.\n"))

(defun login--render-busy (msg)
  "Show a transient running-step screen with MSG."
  (insert "  (working)\n\n")
  (insert (format "=== %s ===\n\n" login--state))
  (insert "  " msg "\n"))

;; --------------------------------------------------------------------
;; transitions
;; --------------------------------------------------------------------

(defun login--repaint ()
  "Repaint the *login* buffer if live."
  (let ((buf (get-buffer login-buffer-name)))
    (when buf
      (with-current-buffer buf
        (login--render)))))

(defun login--reset-prompt ()
  "Return to :prompt-user with all transient state cleared.
the password slot is wiped first; never leave plaintext sitting in
a defvar after a transition."
  (setq login--password nil
        login--user nil
        login--session nil
        login--last-error nil
        login--state :prompt-user)
  (login--repaint))

(defun login--enter-verify ()
  "Run passwd-verify and branch on the result.
keeps `login--password' alive only for the duration of this
function; clears it before returning regardless of outcome."
  (setq login--state :verify)
  (login--repaint)
  (let* ((name login--user)
         (pw login--password)
         (ok (condition-case err
                 (passwd-verify name pw)
               (error
                (panic-handle err (cons 'login--enter-verify name))
                nil))))
    ;; wipe the password slot immediately; if anything below panics
    ;; we have already dropped the plaintext.
    (setq login--password nil)
    (cond
     (ok (login--enter-spawning))
     (t
      (login--note-bad-attempt)
      (setq login--state :failed)
      (login--repaint)))))

(defun login--enter-spawning ()
  "Hand off to session-spawn; transition to :running or :error."
  (setq login--state :spawning)
  (login--repaint)
  (condition-case err
      (let ((sess (session-spawn login--user)))
        (cond
         ((null sess)
          (setq login--last-error
                (list 'session-spawn-returned-nil login--user)
                login--state :error)
          (login--repaint))
         (t
          (setq login--session sess
                login--state :running)
          (login--repaint))))
    (error
     (panic-handle err (cons 'login--enter-spawning login--user))
     (setq login--last-error err
           login--state :error)
     (login--repaint))))

;; --------------------------------------------------------------------
;; commands
;; --------------------------------------------------------------------

(defun login-advance ()
  "RET handler.  meaning depends on `login--state'."
  (interactive)
  (pcase login--state
    (:prompt-user
     (let ((name (read-string "username: ")))
       (cond
        ((or (null name) (string-empty-p name))
         (message "login: empty username rejected"))
        (t
         (setq login--user name
               login--state :prompt-password)
         (login--repaint)))))
    (:prompt-password
     (cond
      ((login--throttle-trips-p)
       (setq login--state :failed)
       (login--repaint))
      (t
       ;; single-arg read-passwd: no CONFIRM, no DEFAULT.  do not
       ;; double-prompt the operator and do not stash a default
       ;; cleartext string anywhere.
       (let ((pw (condition-case err
                     (read-passwd "password: ")
                   (error
                    (panic-handle err 'login-advance-readpw)
                    nil))))
         (cond
          ((or (null pw) (string-empty-p pw))
           (message "login: empty password rejected"))
          (t
           (setq login--password pw)
           (login--enter-verify))))))) ; wipes login--password
    (:running
     (message "login: already running as %s, press q to log out"
              (and login--session (geos-session-name login--session))))
    (_
     (message "login: RET has no meaning in state %s" login--state))))

(defun login-back ()
  "b handler.  back up from password prompt to username prompt."
  (interactive)
  (pcase login--state
    (:prompt-password
     (setq login--password nil
           login--state :prompt-user)
     (login--repaint))
    (_ (message "login: no back from %s" login--state))))

(defun login-retry ()
  "r handler.  retry from :failed or :error."
  (interactive)
  (pcase login--state
    ((or :failed :error)
     (cond
      ((and (eq login--state :failed) (login--throttle-trips-p))
       (message "login: throttled, wait %ds" login--throttle-window))
      (t (login--reset-prompt))))
    (_ (message "login: r has no meaning in state %s" login--state))))

(defun login-logout ()
  "q handler.  in :running, end the session and return to prompt.
in any other state, bury the buffer."
  (interactive)
  (pcase login--state
    (:running
     (let ((name (and login--session
                      (geos-session-name login--session))))
       (when name
         (condition-case err
             (session-end name)
           (error
            (panic-handle err (cons 'login-logout name)))))
       (login--reset-prompt)))
    (_ (bury-buffer))))

;; --------------------------------------------------------------------
;; mode + entry
;; --------------------------------------------------------------------

(defvar login-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'login-advance)
    (define-key m (kbd "b")   #'login-back)
    (define-key m (kbd "r")   #'login-retry)
    (define-key m (kbd "q")   #'login-logout)
    m)
  "Keymap for `login-mode'.")

(define-derived-mode login-mode special-mode "Login"
  "Major mode for the *login* state-machine buffer.
see file commentary for the state diagram."
  (setq truncate-lines t))

;;;###autoload
(defun login-show ()
  "Display the *login* buffer at :prompt-user.
this is the entry point the boot wiring calls.  the caller decides
where to display the buffer: in UI mode that is a dedicated EXWM
workspace, in console mode it is the bare frame on /dev/console.
either way, the buffer contents are identical."
  (interactive)
  (let ((buf (get-buffer-create login-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'login-mode)
        (login-mode))
      ;; do not stomp an existing :running session if login-show is
      ;; re-invoked from a menu while a user is already in.  only
      ;; reset when we are NOT mid-session.
      (unless (eq login--state :running)
        (setq login--state :prompt-user
              login--user nil
              login--password nil
              login--session nil
              login--last-error nil))
      (login--render))
    (display-buffer buf)
    buf))

(provide 'login-buffer)
;;; login.el ends here
