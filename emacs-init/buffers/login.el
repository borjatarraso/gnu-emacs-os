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
(require 'state)

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

(defconst login--throttle-window 60
  "Rolling window in seconds for the bad-attempt throttle.
v0.5 had 30s.  v0.6 item 5.2 widens to 60s so a slow-typed brute
force does not slip past the cap by spreading attempts across two
30-second buckets.")

(defconst login--throttle-cap 5
  "Max bad attempts allowed inside the throttle window.
v0.5 had 3.  v0.6 item 5.2 raises to 5 so an honest typo storm is
still survivable (most people fat-finger their password 2-3 times
before getting it right) while a brute-forcer hitting the cap eats
a sit-for stall on every cap-trip.  network logins (v0.7+) will
want a tighter cap when that surface lands.")

(defconst login--throttle-stall-sec 5
  "Seconds to sit-for after the throttle trips.
the supervisor is single-threaded, so this stalls the RPC poller
and the child-exit poller for the duration.  acceptable because:
nobody is logged in during the *login* stall (no per-user emacs to
keep alive); the RPC channel only serves logged-in users; the
child-exit poller has nothing to reap when no session is running.
the stall is the whole point: a brute-forcer trying credentials
from a tty gets rate-limited at 1 attempt per 5 seconds once the
cap is hit, not bounded only by serial-line bandwidth.")

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
;; per-user lockout (v0.6 item 5.3)
;; --------------------------------------------------------------------
;;
;; the throttle above counts ALL bad attempts in one global ring.  a
;; targeted attack against one user is therefore amplified by typos
;; from other users (one user's typos help the attacker's count
;; nothing; it counts toward the same global cap).  the per-user
;; lockout below is the answer: 10 fails against ONE username inside
;; 5 minutes flips that username to a `:locked-until' record under
;; /var/emacs/lockouts/NAME.  while the lock is active the verify
;; path refuses without even hashing the candidate password (so an
;; attacker cannot use timing to confirm the lock is in place).
;;
;; the lockout file is supervisor-owned because /var/emacs/lockouts/
;; is laid down by state.el's --ensure-layout, which runs as the
;; supervisor (root).  the user themselves cannot tamper with it
;; without already being logged in (a fresh per-user emacs has no
;; write access to /var/emacs/lockouts/).
;;
;; unlock paths:
;;   a) wait for the duration to elapse and re-try.
;;   b) the *users* buffer's `u' key (only the supervisor can reach
;;      that buffer with file-write privileges).

(defconst login--lockout-window 300
  "Rolling window for the per-user fail counter, in seconds (5 minutes).
wider than `login--throttle-window' because the lockout is the
heavier hammer: the throttle slows things down, the lockout shuts
them off.  the wider window also makes a slow-typing attacker
visible: 1 wrong attempt per 30s for 5 minutes still trips it.")

(defconst login--lockout-cap 10
  "Per-user fail count that trips the lockout.
10 inside 5 minutes is more than enough room for an honest typo
storm even if the operator is interrupted, drinks coffee, comes
back, and tries again, but tight enough that a brute-forcer ends
up locked out before they probe more than a few passwords.")

(defconst login--lockout-duration 900
  "How long a lockout lasts once tripped, in seconds (15 minutes).
the operator either waits (legitimate user, recovered from typo
storm) or asks an admin to unlock via the *users* buffer.  shorter
than overnight so a forgotten lockout does not strand a user; long
enough that an unattended brute-force burns a usable amount of
attacker patience.")

(defvar login--per-user-fails nil
  "Alist `((USERNAME . (T1 T2 ...))...)` of recent bad attempts per user.
each value is a list of float-time timestamps.  trimmed on every
check, like `login--bad-attempts'.  not persisted: a reboot resets
the per-user counts (the lockout FILE persists across reboots when
state is persistent, the counter does not).")

(defconst login--lockouts-dir "/var/emacs/lockouts/"
  "Directory where per-user lockout records live.  one file per name.
state.el creates this in `state--ensure-layout' at boot.")

(defun login--lockout-path (name)
  "Return the absolute path to NAME's lockout file."
  (concat login--lockouts-dir name))

(defun login--note-per-user-fail (name)
  "Push a float-time entry into NAME's per-user fail list."
  (when (and name (not (string-empty-p name)))
    (let* ((cell (assoc name login--per-user-fails))
           (now (float-time)))
      (cond
       (cell (setcdr cell (cons now (cdr cell))))
       (t (push (cons name (list now)) login--per-user-fails))))))

(defun login--per-user-lockout-trips-p (name)
  "Return non-nil if NAME has hit `login--lockout-cap' inside the window.
trims NAME's slot to the window as a side effect.  returns nil for
an empty or unknown name (the bad-username case is covered by the
global throttle, not the per-user lockout)."
  (let ((cell (and name (not (string-empty-p name))
                   (assoc name login--per-user-fails))))
    (when cell
      (let* ((now (float-time))
             (cutoff (- now login--lockout-window))
             (recent (cl-remove-if (lambda (t0) (< t0 cutoff))
                                   (cdr cell))))
        (setcdr cell recent)
        (>= (length recent) login--lockout-cap)))))

(defun login--lockout-write (name)
  "Persist a lockout for NAME under /var/emacs/lockouts/NAME.
expiry is now + `login--lockout-duration'.  returns t on success,
nil on failure (panic-handled internally).  uses `with-temp-file'
because state-write enforces a key/path shape we don't want here:
the directory is dedicated and the basename is the username."
  (condition-case err
      (let* ((now (float-time))
             (rec (list (cons 'user name)
                        (cons 'locked-at now)
                        (cons 'locked-until
                              (+ now login--lockout-duration))))
             (path (login--lockout-path name))
             (tmp  (concat path ".tmp"))
             (print-length nil)
             (print-level nil)
             (coding-system-for-write 'utf-8))
        (unless (file-directory-p login--lockouts-dir)
          (make-directory login--lockouts-dir t))
        (with-temp-file tmp
          (let ((standard-output (current-buffer)))
            (prin1 rec)))
        (rename-file tmp path t)
        (when (fboundp 'pid1-fsync-dir)
          (condition-case _ (pid1-fsync-dir login--lockouts-dir) (error nil)))
        t)
    (error
     (panic-handle err `(login--lockout-write . ,name))
     nil)))

(defun login--lockout-read (name)
  "Return the locked-until float for NAME, or nil if no record.
a parse failure logs to *panic* and returns nil (don't strand a
user because a lockout file got corrupted; refuse to enforce
something we cannot read)."
  (let ((path (login--lockout-path name)))
    (cond
     ((not (file-readable-p path)) nil)
     (t
      (condition-case err
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (cdr (assq 'locked-until (read (current-buffer)))))
        (error
         (panic-handle err `(login--lockout-read . ,name))
         nil))))))

(defun login--lockout-active-p (name)
  "Return non-nil if NAME has an unexpired lockout on file.
expired records are deleted as a side effect: an operator who
waits out the duration finds their account immediately usable on
the next login attempt without needing an admin."
  (let ((until (login--lockout-read name)))
    (cond
     ((null until) nil)
     ((< until (float-time))
      (login--lockout-clear name)
      nil)
     (t until))))

(defun login--lockout-clear (name)
  "Remove NAME's lockout file.  returns t whether or not it existed.
bound under the `u' key in the *users* buffer; also called from
`login--lockout-active-p' when an expired record is observed."
  (condition-case err
      (let ((path (login--lockout-path name)))
        (when (file-exists-p path)
          (delete-file path))
        ;; also clear the in-memory per-user counter so the user
        ;; starts fresh.  otherwise the next 0 bad attempts would
        ;; trip the lockout again.
        (setq login--per-user-fails
              (cl-remove-if (lambda (cell) (string= (car cell) name))
                            login--per-user-fails))
        t)
    (error
     (panic-handle err `(login--lockout-clear . ,name))
     nil)))

;; --------------------------------------------------------------------
;; audit log
;; --------------------------------------------------------------------

(defconst login--audit-file "auth.log"
  "Basename under /var/emacs/journal/ where login attempts are appended.
one sexp per line.  alist shape:
  ((time . \"2026-05-12T13:00:00Z\") (user . \"tester\") (result . :ok))
or
  ((time . ...) (user . ...) (result . :fail) (reason . :wrong-password))
on a tmpfs root the file vanishes on reboot.  the *journal* buffer
shows `state: tmpfs' in its header so the operator knows the audit
trail is volatile.")

(defun login--audit-record (user result &optional reason)
  "Append one audit record for USER with RESULT to the auth log.
RESULT is :ok or :fail.  REASON, when supplied, is a keyword like
:wrong-password, :throttled, :unknown-user, :spawn-failed."
  (let* ((ts (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
         (rec (append (list (cons 'time ts)
                            (cons 'user (or user "?"))
                            (cons 'result result))
                      (and reason (list (cons 'reason reason))))))
    (condition-case err
        (state-append-journal login--audit-file rec)
      (error
       (panic-handle err 'login--audit-record)
       nil))))

(defun login--audit-last-success ()
  "Return (USER . TIMESTRING) of the most recent :ok audit entry, or nil.
walks /var/emacs/journal/auth.log from the bottom up.  the audit
log appends new records, so scanning in reverse is one pass.  the
file is small for any sane operator (one record per login attempt,
human-paced) so we load the whole thing into a buffer once.

returns nil if the file is missing or no :ok record is present.
parse errors on individual lines are silently skipped: a truncated
last line (mid-write crash) or a future-format extension should
not blank the footer."
  (let ((path (concat state-root "journal/" login--audit-file)))
    (cond
     ((not (file-readable-p path)) nil)
     (t
      (condition-case err
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-max))
            (let (found)
              (while (and (not found)
                          (> (line-number-at-pos) 1)
                          (zerop (forward-line -1)))
                (let ((line (buffer-substring-no-properties
                             (line-beginning-position)
                             (line-end-position))))
                  (unless (string-empty-p line)
                    (condition-case _
                        (let ((rec (car (read-from-string line))))
                          (when (eq (cdr (assq 'result rec)) :ok)
                            (setq found
                                  (cons (cdr (assq 'user rec))
                                        (cdr (assq 'time rec))))))
                      (error nil)))))
              found))
        (error
         (panic-handle err 'login--audit-last-success)
         nil))))))

;; --------------------------------------------------------------------
;; multi-session footer (v0.6 item 6.2)
;; --------------------------------------------------------------------

(defun login--running-sessions ()
  "Return the list of `geos-session' records currently in 'running.
nil when session.el is not loaded or no session is live; that nil
return suppresses the footer entirely (no \"0 sessions\" noise on
a fresh boot)."
  (and (fboundp 'session-list)
       (cl-remove-if-not
        (lambda (s) (eq (geos-session-status s) 'running))
        (condition-case _ (session-list) (error nil)))))

(defun login--render-sessions-footer ()
  "Insert a one-line-per-session listing of every 'running record.
intended for the :prompt-user and :running screens so an operator
who lands on *login* sees who is already logged in and on which
workspace.  prints nothing when the registry has no live entries."
  (let ((live (login--running-sessions)))
    (when live
      (insert "\n  active sessions:\n")
      (dolist (s live)
        (let ((ws (geos-session-workspace s)))
          (insert (format "    %-16s pid=%-7s ws=%s\n"
                          (geos-session-name s)
                          (or (geos-session-child-pid s) "?")
                          (cond
                           ((integerp ws) (format "%d" ws))
                           (t "?")))))))))

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
  "Username entry.
the last-login footer is read from /var/emacs/journal/auth.log so
an operator sees `last login: NAME @ TIMESTAMP' under the prompt.
a fresh image with no auth.log yet shows nothing (we don't print
`last login: never' because that's noise during the empty common
case).  if the auth log lives on tmpfs the footer resets every
reboot; the *journal* header already tells the operator that, so
we don't re-print the warning here."
  (insert "  RET continue    q quit\n\n")
  (insert "=== geos login ===\n\n")
  (insert "  username: ")
  (when login--user (insert login--user))
  (insert "\n\n  Press RET to confirm the username (or type one first).\n")
  (let ((last (and (fboundp 'login--audit-last-success)
                   (login--audit-last-success))))
    (when (consp last)
      (insert (format "\n  last login: %s @ %s\n"
                      (or (car last) "?")
                      (or (cdr last) "?")))))
  (login--render-sessions-footer))

(defun login--render-prompt-password ()
  "Password entry.  we never echo the password into the buffer."
  (insert "  RET verify    b back    q quit\n\n")
  (insert "=== password ===\n\n")
  (insert (format "  username: %s\n" (or login--user "?")))
  (insert "  password: <hidden, RET to submit>\n\n")
  (insert "  Press RET to submit; b to back up to the username prompt.\n"))

(defun login--render-running ()
  "Running session view.
the footer lists every concurrently logged-in user; v0.6 item 6.2
allows the supervisor to host more than one session simultaneously.
the `n' key starts a fresh login flow without ending the current
one (the session this view documents is just the most recent
spawn; older sessions live on under their own workspaces and
remain reachable via EXWM)."
  (insert "  q logout (SIGTERM this session's emacs)    "
          "n new login    s switch to ws\n\n")
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
    (let ((ws (geos-session-workspace login--session)))
      (insert (format "  workspace:   %s\n"
                      (cond
                       ((integerp ws) (format "%d" ws))
                       (t "(unassigned, EXWM hook has not fired yet)")))))
    (insert (format "  started:     %s\n"
                    (format-time-string
                     "%Y-%m-%d %H:%M:%S"
                     (geos-session-started-at login--session))))
    (insert "\n  Press q to log out this session, "
            "n to start another login.\n")
    (login--render-sessions-footer))))

(defun login--render-failed ()
  "Bad-credentials view.
shows one of three sub-states: lockout active (per-user file on
disk, retry refused until expiry), throttle tripped (global cap
inside window, retry refused for the window), or plain bad creds
(retry available)."
  (let* ((throttled (login--throttle-trips-p))
         (locked-until (and login--user
                            (login--lockout-active-p login--user))))
    (insert "  r retry    q quit\n\n")
    (insert "=== bad credentials ===\n\n")
    (cond
     (locked-until
      (insert (format "  account %s is locked.\n" login--user))
      (insert (format "  unlock at: %s\n"
                      (format-time-string "%Y-%m-%d %H:%M:%S"
                                          locked-until)))
      (insert "  ask an admin to run the *users* buffer u key,\n")
      (insert "  or wait for the lockout to expire and retry.\n"))
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

(defun login--format-error (reason)
  "Render REASON as a one-line human sentence.
REASON is whatever ended up in `login--last-error'.  the structured
shapes come from `session--last-spawn-error' (set in core/session.el)
plus a legacy fallback for pre-W5 images.  unknown shapes fall
through to a generic `internal failure:' line so an operator still
sees something printable.  this helper MUST NOT raise: a malformed
reason is itself a symptom we want rendered, not a second crash."
  (condition-case _
      (pcase reason
        (`(unknown-user ,name)
         (format "no account for %s" name))
        (`(home-bad ,name ,home not-absolute)
         (format "home path for %s is not absolute: %s" name home))
        (`(home-bad ,name ,home missing)
         (format "home directory for %s is missing: %s" name home))
        (`(home-bad ,name ,home not-a-directory)
         (format "home path for %s exists but is not a directory: %s"
                 name home))
        (`(home-bad ,name ,home unreadable)
         (format "home directory for %s is unreadable: %s" name home))
        (`(home-bad ,name ,home ,other)
         ;; defensive default: if session--home-ok-p grows a new
         ;; failure symbol we still print something useful.
         (format "home directory for %s failed sanity check (%s): %s"
                 name other home))
        (`(spawn-child-failed ,name)
         (format (concat "spawn failed for %s (parent reject or child "
                         "execve failed); see *panic* for the exit signal")
                 name))
        (`(session-spawn-returned-nil ,name)
         (format (concat "spawn for %s returned nil with no structured "
                         "reason; this image predates W5")
                 name))
        (_
         (format "internal failure: %S" reason)))
    ;; pcase itself raising would be a bug, but if it does we still
    ;; want a printable string rather than blowing up the renderer.
    (error (format "internal failure: %S" reason))))

(defun login--render-error ()
  "Spawn-or-other internal failure."
  (insert "  r retry    q quit\n\n")
  (insert "=== login error ===\n\n")
  (insert "  " (login--format-error login--last-error) "\n\n")
  (insert (format "  reason: %S\n" login--last-error))
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
function; clears it before returning regardless of outcome.

if the username has an active lockout, refuses without hashing the
candidate password.  not hashing is a deliberate timing-side-channel
defence: an attacker probing whether a name is locked must measure
something other than verify latency."
  (setq login--state :verify)
  (login--repaint)
  (let* ((name login--user)
         (pw login--password)
         (locked (and name (login--lockout-active-p name))))
    ;; lockout short-circuits the verify path.  wipe the password
    ;; slot now (we never look at it) so a panic below cannot leak
    ;; plaintext.
    (cond
     (locked
      (setq login--password nil)
      (login--audit-record name :fail :locked-out)
      (setq login--state :failed)
      (login--repaint)
      (sit-for login--throttle-stall-sec))
     (t
      (let ((ok (condition-case err
                    (passwd-verify name pw)
                  (error
                   (panic-handle err (cons 'login--enter-verify name))
                   nil))))
        ;; wipe the password slot immediately; if anything below panics
        ;; we have already dropped the plaintext.
        (setq login--password nil)
        (cond
         (ok
          ;; a successful login clears any in-flight per-user fail
          ;; counter.  no lockout file is on disk (we checked above);
          ;; the in-memory counter would otherwise carry stale typos
          ;; from this session into the next.
          (setq login--per-user-fails
                (cl-remove-if (lambda (cell) (string= (car cell) name))
                              login--per-user-fails))
          (login--audit-record name :ok)
          (login--enter-spawning))
         (t
          (login--note-bad-attempt)
          (login--note-per-user-fail name)
          (cond
           ((login--per-user-lockout-trips-p name)
            (login--lockout-write name)
            (login--audit-record name :fail :locked-out))
           (t
            (login--audit-record name :fail :wrong-password)))
          (setq login--state :failed)
          (login--repaint))))))))

(defun login--enter-spawning ()
  "Hand off to session-spawn; transition to :running or :error."
  (setq login--state :spawning)
  (login--repaint)
  (condition-case err
      (let ((sess (session-spawn login--user)))
        (cond
         ((null sess)
          (login--audit-record login--user :fail :spawn-failed)
          (setq login--last-error
                (or (and (boundp 'session--last-spawn-error)
                         session--last-spawn-error)
                    (list 'session-spawn-returned-nil login--user))
                login--state :error)
          (login--repaint))
         (t
          (setq login--session sess
                login--state :running)
          (login--repaint))))
    (error
     (panic-handle err (cons 'login--enter-spawning login--user))
     (login--audit-record login--user :fail :spawn-raised)
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
       (login--audit-record login--user :fail :throttled)
       (setq login--state :failed)
       (login--repaint)
       ;; supervisor stalls here for stall-sec.  see the docstring on
       ;; `login--throttle-stall-sec' for why blocking is OK at the
       ;; *login* surface.  sit-for returns nil on input arrival; we
       ;; ignore the return value because the stall is the goal, not
       ;; "wait for nothing-to-happen."
       (sit-for login--throttle-stall-sec))
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
  "r handler.  retry from :failed or :error.
when the throttle is tripped, refuse with a sit-for stall so an
operator mashing `r' eats the same per-attempt rate limit as
mashing RET on :prompt-password."
  (interactive)
  (pcase login--state
    ((or :failed :error)
     (cond
      ((and (eq login--state :failed) (login--throttle-trips-p))
       (message "login: throttled, wait %ds" login--throttle-window)
       (sit-for login--throttle-stall-sec))
      (t (login--reset-prompt))))
    (_ (message "login: r has no meaning in state %s" login--state))))

(defun login-logout ()
  "q handler.  in :running, end the session and return to prompt.
in any other state, bury the buffer.

after `session-end' on the most-recent session, if any other
sessions remain 'running we transition back to :prompt-user so
the operator can keep working, not to bury the buffer.  the
multi-session footer will still list the survivors."
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

(defun login-new-session ()
  "n handler.  start a new login flow without ending the current one.
v0.6 item 6.2: the supervisor can host more than one logged-in
user at a time.  pressing `n' from :running rolls *login* back to
:prompt-user with `login--session' cleared.  the prior session
keeps running under its own workspace; the multi-session footer
lists it on the way back."
  (interactive)
  (pcase login--state
    (:running
     ;; do NOT call session-end here.  the old session lives on
     ;; under its own workspace; n is "add another user", not
     ;; "swap the current user".
     (setq login--password nil
           login--user nil
           login--session nil
           login--last-error nil
           login--state :prompt-user)
     (login--repaint))
    (_ (message "login: n has no meaning in state %s" login--state))))

(defun login-switch-workspace ()
  "s handler.  jump to a running session's workspace.
in UI mode the per-user emacs lives on an EXWM workspace; this
key prompts for a session name (with completion against the
running registry) and calls `exwm-workspace-switch' on the
recorded index.  no-op in console mode (no EXWM).

picks the *only* running session without a prompt when there is
exactly one; this is the common case after `n' has spawned a
second user and the operator wants to flip back to the first."
  (interactive)
  (let* ((live (login--running-sessions))
         (with-ws (cl-remove-if-not
                   (lambda (s) (integerp (geos-session-workspace s)))
                   live)))
    (cond
     ((null with-ws)
      (message "login: no running session has a recorded workspace"))
     ((not (fboundp 'exwm-workspace-switch))
      (message "login: exwm-workspace-switch unbound (console mode?)"))
     (t
      (let* ((names (mapcar #'geos-session-name with-ws))
             (pick (cond
                    ((= (length names) 1) (car names))
                    (t (completing-read "switch to session: "
                                        names nil t))))
             (sess (cl-find-if (lambda (s)
                                 (string= (geos-session-name s) pick))
                               with-ws))
             (ws (and sess (geos-session-workspace sess))))
        (cond
         ((not (integerp ws))
          (message "login: no workspace for %s" pick))
         (t
          (condition-case err
              (exwm-workspace-switch ws)
            (error
             (panic-handle err (cons 'login-switch-workspace pick)))))))))))

;; --------------------------------------------------------------------
;; mode + entry
;; --------------------------------------------------------------------

(defvar login-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'login-advance)
    (define-key m (kbd "b")   #'login-back)
    (define-key m (kbd "r")   #'login-retry)
    (define-key m (kbd "q")   #'login-logout)
    (define-key m (kbd "n")   #'login-new-session)
    (define-key m (kbd "s")   #'login-switch-workspace)
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
      ;; reset when we are NOT mid-session.  the registry cross-check
      ;; (2026-05-11) covers the auto-teardown path: the poller flips
      ;; the registry status to 'held when a child vanishes, but the
      ;; login buffer's `login--state' is private and stays at
      ;; :running until something here resets it.  if no session is
      ;; actually 'running anymore, treat the buffer's :running as
      ;; stale and reset back to :prompt-user so the next user sees a
      ;; live prompt instead of "session active as ghost-tester".
      ;;
      ;; v0.6 item 6.2: under multi-user the cross-check also needs
      ;; to confirm THIS buffer's `login--session' is still 'running.
      ;; the prior shape was "any session running -> keep :running",
      ;; which renders a stale record when the buffer's session died
      ;; while a different user's session is still alive.  the
      ;; tightened predicate refuses to keep :running unless the
      ;; specific session this buffer holds is still in the
      ;; registry as 'running.
      (let ((session-still-live
             (and (eq login--state :running)
                  login--session
                  (fboundp 'session-get)
                  (let ((cur (session-get
                              (geos-session-name login--session))))
                    (and cur (eq (geos-session-status cur) 'running))))))
        (unless session-still-live
          (setq login--state :prompt-user
                login--user nil
                login--password nil
                login--session nil
                login--last-error nil)))
      (login--render))
    (display-buffer buf)
    buf))

(provide 'login-buffer)
;;; login.el ends here
