;;; session.el --- per-user emacs lifecycle, supervised under PID 1 -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; v0.5 is where the "every booted emacs is one emacs" model finally
;; ends.  PID-1 emacs stays root and stays the supervisor.  every
;; logged-in user runs in a CHILD emacs spawned via `pid1-spawn-as-uid'
;; (see docs/v05-session-spawn-abi.md for the binding).  this file
;; owns the lifecycle of those children: spawn, register, persist,
;; rehydrate on reboot, end on logout.
;;
;; the privilege transition lives in the parent, between fork and
;; exec, inside the pid1 module.  no setuid binary, no helper, no
;; PAM, no nsswitch.  the parent emacs is already root because it is
;; PID 1; that is the only privilege source we need.
;;
;; layering:
;;
;;   login.el       state machine the human sees (*login* buffer)
;;       |
;;       v
;;   passwd-verify  reads /etc/shadow, calls pid1-crypt
;;       |
;;       v
;;   session.el     this file.  spawns the child, supervises it.
;;       |
;;       v
;;   supervise.el   the generic registry.  the child registers like
;;                  every other long-running process and inherits the
;;                  crashloop cap.
;;       |
;;       v
;;   pid1-spawn-as-uid   the C binding that performs the privilege
;;                       transition and execve.
;;
;; persistence: every session record is mirrored under
;; /var/emacs/sessions/<name> via `state-write'.  on PID-1 boot,
;; `session-rehydrate' walks the directory and decides what to
;; restart.  pattern mirrors supervise.el's restore.
;;
;; on the supervise entry: we register every session under
;; supervise.el but with :command nil.  the entry exists for the
;; crashloop cap, the registry listing in the *services* buffer, and
;; the persistence shape, NOT to be a spawner.  the only legitimate
;; spawn path is `session-spawn' -> `pid1-spawn-as-uid', because
;; that is the only path that drops privilege; `supervise--spawn'
;; would call make-process directly as root.  the nil command makes
;; `supervise-start session:NAME' refuse via the (and (listp cmd)
;; (stringp (car cmd))) guard in supervise.el's spawn.

(require 'cl-lib)
(require 'panic)
(require 'state)
(require 'supervise)

(condition-case err
    (require 'passwd)
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'session-require-passwd)
     (message "session: passwd require failed: %S" err))))

(defconst session--state-prefix "sessions/"
  "state-key prefix under which session records live.
materialised as /var/emacs/sessions/ by `state--ensure-layout'
once the `sessions' subdir is added to `state--subdirs'.")

(defvar session--registry (make-hash-table :test 'equal)
  "Map of username (string) -> `geos-session' record.
the single source of truth for who is logged in right now.
mutated by `session-spawn', `session-end', and the sentinel; mirrored
to disk on every change so a PID-1 restart can rehydrate.")

(cl-defstruct geos-session
  ;; identity, taken from /etc/passwd at spawn time and frozen
  ;; thereafter.  if the operator changes a user's uid we will only
  ;; observe that on the next login.
  name                                  ; string, /etc/passwd :user
  uid                                   ; integer
  gid                                   ; integer
  home                                  ; string, /etc/passwd :home
  ;; lifecycle
  started-at                            ; time-list at spawn
  child-pid                             ; integer or nil
  supervise-key                         ; symbol used in supervise registry
  ;; one of: 'held 'starting 'running 'exited
  ;;   'held      explicitly logged out OR rehydrated from persisted held
  ;;   'starting  pid1-spawn-as-uid returned, child not yet observed alive
  ;;   'running   child observed alive (supervise marked it 'running)
  ;;   'exited    child died and restart policy declined to respawn
  status)

;; --------------------------------------------------------------------
;; persistence
;; --------------------------------------------------------------------

(defun session--state-key (name)
  "state-key for the per-session record of NAME.
no encoding: usernames are restricted to [a-zA-Z0-9_-] by
`passwd-add-user', so concatenation is safe and `state--safe-key-p'
will accept the result."
  (concat session--state-prefix name))

(defun session--snapshot (sess)
  "Return a serialisable plist for SESS.
omits child-pid because a pid number is meaningless after a PID-1
restart (the kernel will have reassigned it).  status is preserved
so 'held survives a reboot."
  (list :name (geos-session-name sess)
        :uid (geos-session-uid sess)
        :gid (geos-session-gid sess)
        :home (geos-session-home sess)
        :started-at (geos-session-started-at sess)
        :supervise-key (geos-session-supervise-key sess)
        :status (geos-session-status sess)))

(defun session--persist (sess)
  "Write SESS to /var/emacs/sessions/<name>.
panic-handles a write failure; in-memory registry stays correct
and the next persist will resync disk."
  (condition-case err
      (state-write (session--state-key (geos-session-name sess))
                   (session--snapshot sess))
    (error
     (panic-handle err
                   (cons 'session--persist (geos-session-name sess)))
     nil)))

(defun session--forget (name)
  "Remove the on-disk record for NAME.  called nowhere for v0.5.
kept here for symmetry with `passwd-delete-user' wiring later."
  (condition-case err
      (state-delete (session--state-key name))
    (error
     (panic-handle err (cons 'session--forget name))
     nil)))

;; --------------------------------------------------------------------
;; lookup helpers
;; --------------------------------------------------------------------

(defun session--passwd-entry (name)
  "Return the /etc/passwd plist for NAME, or nil."
  (cl-find-if (lambda (e) (string= (plist-get e :user) name))
              (passwd-read-passwd)))

(defun session--supervise-key (name)
  "Return the symbol session.el uses to register NAME under supervise.
namespaced so a service called `borja' (none exists, but
hypothetically) does not collide."
  (intern (concat "session:" name)))

(defun session-get (name)
  "Return the in-memory record for NAME, or nil."
  (gethash name session--registry))

(defun session-list ()
  "Return a list of `geos-session' records, sorted by name.
the *users* buffer's login column reads this.  records in 'held
status are included; callers that want only live sessions filter
on (eq (geos-session-status s) 'running) themselves."
  (let (out)
    (maphash (lambda (_k v) (push v out)) session--registry)
    (sort out (lambda (a b)
                (string< (geos-session-name a)
                         (geos-session-name b))))))

(defun session-count-for-uid (uid)
  "Return the number of 'running sessions for UID.
used by the *users* buffer's per-row login column."
  (let ((n 0))
    (dolist (s (session-list))
      (when (and (= (geos-session-uid s) uid)
                 (eq (geos-session-status s) 'running))
        (cl-incf n)))
    n))

;; --------------------------------------------------------------------
;; spawn
;; --------------------------------------------------------------------

(defconst session--child-program "/usr/bin/emacs"
  "Where the per-user emacs lives.  matches the guix profile's emacs
symlink.  the spawn ABI accepts an absolute path; we hard-code the
canonical one here and the boot wiring keeps it in sync.")

(defun session--child-argv (name)
  "argv the child emacs sees.  -Q so we inherit nothing from PID 1's
init tree; -l the per-user init.el iff it exists.  the file is
optional by design: v0.5 has no per-user dotfile story, since there
is no bash and no .bashrc.  if /var/emacs/users/NAME/init.el exists
it loads; otherwise the child gets a clean -Q environment."
  (let* ((init (format "/var/emacs/users/%s/init.el" name))
         (base (list "emacs" "-Q")))
    (if (file-readable-p init)
        (append base (list "-l" init))
      base)))

(defun session--child-env (name home)
  "Minimal environment for the child emacs.
scrubs PID 1's environment by REPLACING rather than augmenting.
the spawn ABI takes this list and discards everything else."
  (list (concat "USER=" name)
        (concat "LOGNAME=" name)
        (concat "HOME=" home)
        "SHELL=/bin/sh"
        "PATH=/run/current-system/profile/bin:/usr/bin:/bin"
        "TERM=linux"))

(defun session--spawn-child (sess)
  "Call `pid1-spawn-as-uid' for SESS and stash the returned pid.
returns t on success, nil on any failure (with panic-handle
breadcrumb).  this is the chokepoint where the v0.5 spawn ABI
contract is actually exercised; before pid1-engineer lands the
binding the call is stubbed via `fboundp' and the function returns
nil cleanly so the file loads on a v0.4 image."
  (cond
   ((not (fboundp 'pid1-spawn-as-uid))
    (message "session: pid1-spawn-as-uid unbound, stubbed login for %s"
             (geos-session-name sess))
    nil)
   (t
    (condition-case err
        (let* ((name (geos-session-name sess))
               (pid (funcall (symbol-function 'pid1-spawn-as-uid)
                             (geos-session-uid sess)
                             (geos-session-gid sess)
                             name
                             session--child-program
                             (session--child-argv name)
                             (session--child-env
                              name (geos-session-home sess)))))
          (cond
           ((not (integerp pid))
            (panic-handle (list 'session-spawn-bad-return pid)
                          (cons 'session--spawn-child
                                (geos-session-name sess)))
            nil)
           (t
            (setf (geos-session-child-pid sess) pid)
            (setf (geos-session-status sess) 'running)
            (setf (geos-session-started-at sess) (current-time))
            t)))
      (error
       (panic-handle err
                     (cons 'session--spawn-child
                           (geos-session-name sess)))
       nil)))))

(defun session-spawn (name)
  "Spawn a per-user emacs for NAME and register it.
returns the `geos-session' record on success, nil on failure.
panic-handles every failure path; never raises.

steps:
  1. resolve NAME against /etc/passwd; bail if unknown.
  2. allocate or reuse the in-memory session record.
  3. register under supervise.el so the crashloop cap applies.
     restart policy is 'never: a logged-out session must NOT come
     back on its own, the user re-logs in deliberately.
  4. persist the (status=starting) record so a crash mid-spawn
     leaves a breadcrumb on disk.
  5. call `pid1-spawn-as-uid' via `session--spawn-child'.
  6. on success, persist again with status=running and the child pid.
  7. on failure, mark the record 'exited and persist."
  (cond
   ((not (stringp name)) nil)
   (t
    (let ((pw (session--passwd-entry name)))
      (cond
       ((null pw)
        (panic-handle (list 'session-spawn-unknown-user name)
                      'session-spawn)
        nil)
       (t
        (let* ((existing (gethash name session--registry))
               (sess (or existing
                         (make-geos-session
                          :name name
                          :uid (plist-get pw :uid)
                          :gid (plist-get pw :gid)
                          :home (plist-get pw :home)
                          :supervise-key (session--supervise-key name)
                          :status 'starting))))
          ;; refresh uid/gid/home from passwd in case the operator
          ;; changed them between sessions.  identity in the struct
          ;; is "name"; the rest are cached lookups.
          (setf (geos-session-uid sess) (plist-get pw :uid))
          (setf (geos-session-gid sess) (plist-get pw :gid))
          (setf (geos-session-home sess) (plist-get pw :home))
          (setf (geos-session-status sess) 'starting)
          (puthash name sess session--registry)
          (session--register-with-supervise sess)
          (session--persist sess)
          (cond
           ((session--spawn-child sess)
            (session--persist sess)
            sess)
           (t
            (setf (geos-session-status sess) 'exited)
            (session--persist sess)
            nil)))))))))

(defun session--register-with-supervise (sess)
  "Register SESS under supervise.el.
restart policy is 'never: a user emacs that exits is logout, not
crash.  supervise's crashloop cap still trips on rapid failure so
a misconfigured user init.el can't fork-bomb the box.

we register with :autostart nil so supervise-autostart at boot does
not try to spawn an unauthenticated session; `session-rehydrate'
decides what to restart based on persisted status."
  (condition-case err
      (supervise-register
       :name (geos-session-supervise-key sess)
       ;; we never let supervise spawn this.  real spawn is
       ;; pid1-spawn-as-uid, called from session-spawn.  nil here
       ;; makes supervise-start refuse, see the
       ;; (and (listp cmd) (stringp (car cmd))) guard in
       ;; supervise--spawn (supervise.el ~line 316).  without that
       ;; refusal, an operator typing M-x supervise-start
       ;; session:NAME would call make-process directly from PID 1
       ;; and spawn the per-user emacs as ROOT.
       :command nil
       :user (geos-session-name sess)
       :group (geos-session-name sess)
       :restart 'never
       :autostart nil)
    (error
     (panic-handle err
                   (cons 'session--register-with-supervise
                         (geos-session-name sess))))))

;; --------------------------------------------------------------------
;; end
;; --------------------------------------------------------------------

(defun session-end (name)
  "Mark NAME's session 'held and SIGTERM the child.
returns t on success.  no-op if the user has no session record."
  (let ((sess (gethash name session--registry)))
    (cond
     ((null sess) nil)
     (t
      (let ((pid (geos-session-child-pid sess)))
        (setf (geos-session-status sess) 'held)
        (setf (geos-session-child-pid sess) nil)
        (cond
         ((and (integerp pid) (fboundp 'signal-process))
          (condition-case err
              (signal-process pid 'TERM)
            (error
             (panic-handle err (cons 'session-end name)))))
         ((integerp pid)
          ;; signal-process is core, this branch is paranoia.  leave
          ;; the breadcrumb so we know if it ever happens.
          (panic-handle (list 'session-end-no-signal pid)
                        (cons 'session-end name))))
        (session--persist sess)
        t)))))

;; --------------------------------------------------------------------
;; rehydrate (boot path)
;; --------------------------------------------------------------------

(defun session--rehydrate-one (key)
  "Read the persisted record at KEY and re-create the in-memory entry.
KEY is a state-key like \"sessions/borja\".  decides:
  - status 'running on disk     -> attempt respawn (the previous PID
                                   is gone, this is a fresh child)
  - status 'held on disk        -> create record in 'held, do not spawn
  - status 'starting on disk    -> previous boot crashed mid-spawn;
                                   treat as 'exited, leave for the
                                   operator to retry via login
  - status 'exited on disk      -> leave as 'exited; the *users*
                                   buffer will not show a live session
panic-handles malformed entries (corrupted state file, wrong shape)."
  (condition-case err
      (let ((snap (state-read key nil)))
        (when (and (listp snap) (stringp (plist-get snap :name)))
          ;; persisted-status is what the previous boot left us with;
          ;; the in-memory struct's :status was mapped to 'held during
          ;; rehydrate construction so the struct represents
          ;; 'held-but-restartable until the spawn succeeds.
          (let* ((persisted-status (plist-get snap :status))
                 (name (plist-get snap :name))
                 (sess (make-geos-session
                        :name name
                        :uid (plist-get snap :uid)
                        :gid (plist-get snap :gid)
                        :home (plist-get snap :home)
                        :started-at (plist-get snap :started-at)
                        :supervise-key (or (plist-get snap :supervise-key)
                                           (session--supervise-key name))
                        :status (pcase persisted-status
                                  ('held 'held)
                                  ('running 'held)  ; will respawn below
                                  ('starting 'exited)
                                  (_ 'exited)))))
            (puthash name sess session--registry)
            (session--register-with-supervise sess)
            ;; supervise.el's pattern collapses 'running -> 'stopped on
            ;; restore so a cold start is required.  we do the same but
            ;; gate the actual spawn on whether the previous status was
            ;; 'running; 'held stays held.
            (when (eq persisted-status 'running)
              (setf (geos-session-status sess) 'starting)
              (session--persist sess)
              (unless (session--spawn-child sess)
                (setf (geos-session-status sess) 'exited)
                (session--persist sess))))))
    (error
     (panic-handle err (cons 'session--rehydrate-one key)))))

(defun session-rehydrate ()
  "Walk /var/emacs/sessions/ and restore the session registry.
called once from the boot tail under the same `pid1-as-emacs-p'
gate other core files use.  idempotent in spirit: calling twice
re-reads the same records; the supervise-register call is
re-register-safe."
  (condition-case err
      (let ((dir (concat state-root "sessions/")))
        (when (file-directory-p dir)
          (dolist (f (directory-files dir nil "\\`[^.]"))
            ;; skip .tmp files left over from a crashed state-write
            (unless (string-suffix-p ".tmp" f)
              (session--rehydrate-one
               (concat session--state-prefix f))))))
    (error
     (panic-handle err 'session-rehydrate))))

;; --------------------------------------------------------------------
;; boot wiring
;; --------------------------------------------------------------------

;; same gate the other core files use.  on a dev host pid1-as-emacs-p
;; is nil and rehydrate is skipped, so loading the file is side-effect
;; free outside the OS.
;;
;; the hook intentionally fires AFTER `supervise-finalize' because
;; emacs runs `after-init-hook' once the `-l' chain is fully loaded;
;; the boot gexp loads session.el BEFORE buffers/, userland services,
;; and exwm-config, so calling `session-rehydrate' at file-load time
;; would try to spawn per-user emacses before the rest of the system
;; is up (and before `supervise-finalize' has restored counters).
;; deferring to after-init-hook makes rehydrate sequence safely
;; against the rest of the boot.  the hook is removed inside its own
;; body so it is idempotent under repeated init-file loads.
(defun session--boot-rehydrate ()
  "after-init-hook entry point.  gated on `pid1-as-emacs-p' and
removes itself on first run."
  (remove-hook 'after-init-hook #'session--boot-rehydrate)
  (when (and (boundp 'pid1-as-emacs-p) pid1-as-emacs-p)
    (condition-case err
        (session-rehydrate)
      (error
       (panic-handle err 'session-boot-rehydrate)))))

(add-hook 'after-init-hook #'session--boot-rehydrate)

(provide 'session)
;;; session.el ends here
