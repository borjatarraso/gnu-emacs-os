;;; session.el --- per-user emacs lifecycle, supervised under PID 1 -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; v0.5 is where the "every booted emacs is one emacs" model finally
;; ends.  PID-1 emacs stays root and stays the supervisor.  every
;; logged-in user runs in a CHILD emacs spawned via `pid1-spawn-as-uid'
;; (see docs/v05-session-spawn-abi.md for the binding).  this file
;; owns the lifecycle of those children: spawn, register, persist,
;; rehydrate on reboot, POLL liveness, end on logout.
;;
;; poll: a repeating `run-at-time' timer (see `session--arm-poll-timer')
;; walks the registry every `session-poll-interval' seconds and probes
;; /proc/<pid> for each 'running session.  a vanished child transitions
;; the record to 'held and, if no session remains 'running, brings the
;; *login* surface back.  this is the cheap-and-correct interim until
;; pid1 grows a SIGCHLD callback hook.
;;
;; maintenance escape hatch: the kernel cmdline token
;; `geos.login=skip' suppresses the *login* presentation in
;; `session--boot-rehydrate'.  the supervisor emacs is then reachable
;; on /dev/console (or via the exwm session) as it was pre-v0.5.
;; this is for DEBUGGING and RECOVERY only.  in production every boot
;; that finishes rehydrate with no 'running session must land on the
;; *login* buffer; the skip token bypasses the auth boundary entirely
;; and must NEVER be set on a deployed image.  it exists so that a
;; passwd store corruption or a wedged login-mode keymap does not
;; brick the box: an operator with console access can boot the GRUB
;; entry with `geos.login=skip' appended, repair, and reboot.
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
(require 'cmdline)
(require 'panic)
(require 'state)
(require 'supervise)

(condition-case err
    (require 'passwd)
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'session-require-passwd)
     (message "session: passwd require failed: %S" err))))

;; login.el (provides `login-buffer') requires session.el, so we
;; cannot require it back without a load cycle.  declare the one
;; symbol we call from `session--present-login' to silence the
;; byte-compiler; at emacs-startup-hook time the function is bound
;; because the boot gexp loads login.el after session.el.
(declare-function login-show "login" ())

(defconst session--state-prefix "sessions/"
  "state-key prefix under which session records live.
materialised as /var/emacs/sessions/ by `state--ensure-layout'
once the `sessions' subdir is added to `state--subdirs'.")

(defvar session--registry (make-hash-table :test 'equal)
  "Map of username (string) -> `geos-session' record.
the single source of truth for who is logged in right now.
mutated by `session-spawn', `session-end', and the sentinel; mirrored
to disk on every change so a PID-1 restart can rehydrate.")

(defvar session--last-spawn-error nil
  "Structured reason for the most recent `session-spawn' failure.
nil after a successful spawn or before the first attempt.  callers
(notably login.el) may read this immediately after a nil return
from `session-spawn' to render a specific error to the operator
instead of a generic 'spawn returned nil' message.  not persisted;
ephemeral by design.")

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
  ;; v0.6 item 6 plumbing.  the EXWM workspace this user's emacs
  ;; lives on, integer or nil.  populated by `session-record-workspace'
  ;; from `exwm-config--maybe-route-user-window' once exwm has actually
  ;; assigned the window a workspace.  stays nil in console mode (no
  ;; EXWM, no workspaces).  persisted via `session--snapshot' so a
  ;; supervisor restart can re-present the *login* buffer on a
  ;; workspace other than the one a still-running user occupies.
  workspace                             ; integer or nil
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
so 'held survives a reboot.  workspace, when known, is preserved
so a supervisor restart can resume the *login* surface on a
workspace that does not collide with a still-running session."
  (list :name (geos-session-name sess)
        :uid (geos-session-uid sess)
        :gid (geos-session-gid sess)
        :home (geos-session-home sess)
        :started-at (geos-session-started-at sess)
        :supervise-key (geos-session-supervise-key sess)
        :workspace (geos-session-workspace sess)
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

(defconst session-max-workspaces 3
  "Cap on the number of concurrent per-user workspaces.
workspace 0 is reserved for the supervisor's *login* surface;
1..session-max-workspaces are handed out to per-user emacses, one
per logged-in user.  this cap matches the v0.6 plan's 3-user
default; raising it is a one-liner here, but the EXWM workspace
pool may need to be grown to match.

a fourth concurrent login is refused at allocation time: the
caller gets nil, the spawn proceeds without a workspace
assignment, and the per-user window lands wherever EXWM places
it (usually workspace 0, on top of *login*).  that is ugly but
not data-destructive; the operator is meant to log somebody out
before adding another user.")

(defun session-allocate-workspace (name)
  "Pick the EXWM workspace index that NAME should occupy.
sticky across logout / login: if NAME's existing record carries a
:workspace that is in range and is not currently held by another
'running or 'starting session, return that.  otherwise walk
1..`session-max-workspaces' and return the lowest index not held
by any other 'running or 'starting session.  returns nil when all
slots are taken; the caller spawns without a workspace stamp and
lets EXWM place the window.

deliberately does NOT mutate the registry: the caller stamps the
returned index onto the session record via setf, then persists.
this keeps the function safe to call from a probe path (e.g. a
*users* row asking 'where would this user land')."
  (let* ((sess (gethash name session--registry))
         (preferred (and sess (geos-session-workspace sess)))
         (taken
          (let (acc)
            (maphash
             (lambda (k v)
               (when (and (not (and (stringp k) (string= k name)))
                          (memq (geos-session-status v)
                                '(starting running))
                          (integerp (geos-session-workspace v)))
                 (push (geos-session-workspace v) acc)))
             session--registry)
            acc)))
    (cond
     ((and (integerp preferred)
           (>= preferred 1)
           (<= preferred session-max-workspaces)
           (not (memql preferred taken)))
      preferred)
     (t
      (let ((idx 1)
            (found nil))
        (while (and (not found) (<= idx session-max-workspaces))
          (unless (memql idx taken)
            (setq found idx))
          (cl-incf idx))
        found)))))

(defun session-workspace-for-name (name)
  "Return the EXWM workspace index recorded for NAME, or nil.
nil means either the user is not in the registry or the EXWM
manage hook has not fired yet (early in the spawn, before the
per-user emacs has created any window).  the supervisor reads
this to decide where NOT to draw the *login* buffer once a
second login flow lands."
  (let ((sess (gethash name session--registry)))
    (and sess (geos-session-workspace sess))))

(defun session-record-workspace (name idx)
  "Stamp IDX onto NAME's session record and persist.
NAME is the user shortname captured from `geos-user-NAME' by
`exwm-config--maybe-route-user-window'; IDX is whatever
`exwm-config--user-workspace-for' allocated for that name.

we re-persist via `session--persist' so a supervisor restart
sees the workspace assignment and can re-route the next *login*
draw appropriately.  no-op (returns nil) when NAME has no
registry entry: an unregistered window is logged elsewhere by
the EXWM hook as a `exwm-route-unknown-user' breadcrumb; we
must not allocate a phantom session here just because a
spoofed `exwm-instance-name' showed up.

returns IDX on success, nil on no-op."
  (let ((sess (and (stringp name)
                   (integerp idx)
                   (gethash name session--registry))))
    (cond
     ((null sess) nil)
     (t
      (setf (geos-session-workspace sess) idx)
      (session--persist sess)
      idx))))

;; --------------------------------------------------------------------
;; spawn
;; --------------------------------------------------------------------

(defun session--home-ok-p (home)
  "Return t if HOME is safe to chdir into, or a symbol describing why not.
returned symbols: \\='not-absolute, \\='missing, \\='not-a-directory,
\\='unreadable.  the `file-readable-p' check runs as root and so
confirms the directory's mode bits permit root access.  it catches
mode 000 directories and filesystems where even root is denied, but
it does NOT validate that the target user has read access.
defense-in-depth, not a substitute for per-user access checks.
symlinks are followed, deliberately: an operator may legitimately
symlink HOME entries onto a different mount, and a user-controlled
symlink swap between this check and the C-side chdir does not cross
a privilege boundary.  this is defense-in-depth in the parent before
calling `pid1-spawn-as-uid'; the C child still has its silent
fallback to / so a race between this check and exec cannot strand
the child without a cwd."
  (cond
   ((not (and (stringp home) (> (length home) 0) (eq (aref home 0) ?/)))
    'not-absolute)
   ((not (file-exists-p home))    'missing)
   ((not (file-directory-p home)) 'not-a-directory)
   ((not (file-readable-p home))  'unreadable)
   (t t)))

(defun session--ensure-user-state-dir (sess)
  "Ensure /var/emacs/users/NAME/ exists, owned by SESS's uid:gid, mode 0700.
v0.6 item 2.1: the per-user emacs reads (and may write) its own
init.el under /var/emacs/users/NAME/.  the supervisor runs as root,
so it is the only side that can lay the directory down with the
right ownership; once chowned the child has full control of its
own state dir without the supervisor needing to touch it again.

idempotent on the directory: if the dir exists we leave it alone
on the make-directory call but still re-issue chmod and pid1-chown.
re-chmod is harmless on a correctly-moded dir, and re-chown is the
SAFE default if an operator changed the user's uid via passwd
between sessions: the next spawn quietly fixes ownership.

mode 0700 because the directory is per-user state; other users on
the box must not be able to read another user's init.el.

failure posture: non-fatal.  a failed ensure leaves the dir in
whatever state the partial run produced (probably missing, possibly
mis-owned); the child still spawns, but its `-l /var/emacs/users/
NAME/init.el' will silently not happen because session--child-argv
gates it on `file-readable-p'.  the user loses per-user init for
this session; the next spawn retries.  we panic-handle to leave a
breadcrumb but do not propagate.

pid1-chown is gated on `fboundp' so loading session.el on a dev
host (where the pid1 module is not loaded) does not signal."
  (let* ((name (geos-session-name sess))
         (uid  (geos-session-uid sess))
         (gid  (geos-session-gid sess))
         (dir  (format "/var/emacs/users/%s" name)))
    (condition-case err
        (progn
          (unless (file-directory-p dir)
            (make-directory dir t))
          (set-file-modes dir #o700)
          (when (fboundp 'pid1-chown)
            (funcall (symbol-function 'pid1-chown) dir uid gid))
          t)
      (error
       (panic-handle err
                     (cons 'session--ensure-user-state-dir name))
       nil))))

(defconst session--child-program "/usr/bin/emacs"
  "Where the per-user emacs lives.  matches the guix profile's emacs
symlink.  the spawn ABI accepts an absolute path; we hard-code the
canonical one here and the boot wiring keeps it in sync.")

(defconst session--user-init-path "/etc/geos/user-init.el"
  "Absolute path to the system-shipped per-user emacs init.
extra-special-file in guix-system/system.scm symlinks this path to
the local-file for emacs-init/user/user-init.el.  the per-user
emacs is invoked with `-l SESSION--USER-INIT-PATH' so the geos-
logout command and any other v0.6+ system-supplied user-side
defuns are available before the optional /var/emacs/users/<name>/
init.el loads.

load order matters: system init FIRST, then user-specific init.
a per-user init.el can override the system defaults, but the system
defaults are always available even when the user has no per-user
init.el at all.")

(defun session--child-argv (name)
  "argv the child emacs sees.  -Q so we inherit nothing from PID 1's
init tree; --name stamps the X resource name as `geos-user-NAME' so
the supervisor's EXWM can identify which logged-in user owns a new
X client window; -l the system-shipped user-init unconditionally.

argv shape (single form, v0.6 item 2.2 onward):
  (\"emacs\" \"-Q\" \"--name\" \"geos-user-NAME\"
   \"-l\" \"/etc/geos/user-init.el\")

the system user-init at `session--user-init-path' is UNCONDITIONAL.
extra-special-file in guix-system/system.scm guarantees the path
exists on every deployed image.  i deliberately do not gate it on
`file-readable-p': if it ever doesn't exist (degraded boot, broken
image) the child's `-l' fails and emacs exits non-zero, the poller
sees a crashed session, and supervise treats it like any other
crashloop.  loud failure is the correct response.

per-user init.el loading: the system user-init has its own
`user-init--load-per-user' that runs at the END of the load chain
and reads /var/emacs/users/NAME/init.el iff present, regular, and
owned by the running uid.  doing the load USER-SIDE (rather than
through a supervisor-side -l on argv) is the load-bearing v0.6
shift: the ownership/regular-file gates execute under the spawned
uid after privilege drop, which is the only place that check is
meaningful.  a supervisor-side `file-readable-p' as root could not
distinguish a user-owned init.el from a root-owned one; the user-
side load can.

--name placement: after -Q (so -Q's purge of init paths does not
also swallow the resource-name argument) and before -l (argv order
is not load-bearing for emacs, but keeping the X-side switches
together before any -l makes the call site readable).

the supervisor's `exwm-manage-finish-hook' matches on the
`geos-user-' prefix of `exwm-instance-name' to route the window to
the right per-user workspace.  the prefix is the contract.

NAME safety: `passwd-add-user' constrains usernames to [a-zA-Z0-9_-]
on the way into /etc/passwd, so the `geos-user-NAME' concatenation
here cannot inject shell metacharacters, spaces, or anything Xlib
would reject as a resource name.  the upstream gate is what makes
this safe; we deliberately do not re-validate.

runtime-override caveat: the child is a full emacs, so a per-user
init.el can mutate `x-resource-name' (or set the frame `name'
parameter) before the first frame is mapped and defeat the
`geos-user-' stamp.  the supervisor's EXWM routing degrades
gracefully: the window stays on whatever workspace EXWM places it
on.  no security implication; a UX/audit gotcha to keep in mind
once per-user dotfiles become common."
  (list "emacs" "-Q" "--name" (concat "geos-user-" name)
        "-l" session--user-init-path))

(defun session--child-env (name home)
  "Minimal environment for the child emacs.
scrubs PID 1's environment by REPLACING rather than augmenting.
the spawn ABI takes this list and discards everything else.

DISPLAY is passed through from the supervisor when set AND when it
matches the strict shape Xorg actually produces, omitted otherwise.
in console mode PID 1 has no DISPLAY and the child gets none either;
an empty DISPLAY string would be worse than absent (getenv returns
\"\" for set-but-empty, not nil, so the predicate guards the
length explicitly).  the child connects to Xorg via the abstract
UNIX socket at /tmp/.X11-unix/X0; no XAUTHORITY is needed because
the v0.5 Xorg launch passes no -auth flag and the server is
permissive on local connections.  this is a property of how pid1
currently spawns Xorg, not a design promise; if Xorg auth ever gets
added the env list grows to thread XAUTHORITY too.

trust model: the only producer of the supervisor's DISPLAY is
pid1's hard-coded `DISPLAY=:0' (see pid1/emacs-init.c).  the C-side
env validator checks structural well-formedness only (non-empty
KEY, no embedded NUL, presence of `='); it does NOT police newlines,
spaces, or control chars inside the VALUE.  that validation lives
HERE.  if pid1 ever grows an operator-tainted source for DISPLAY
(e.g. a `--display=' argv flag or an /etc/X11/display file) the
regex below is the choke point that must be re-audited before that
source is allowed to reach the child.

the regex is intentionally strict: `:N' or `:N.M' with N and M
digits, nothing else.  no host part, no transport, no shell
metacharacters.  loosen ONLY when a concrete remote/forwarded-
display use case lands; until then stricter is the right default
since the only producer is pid1's `:0'.

a malformed DISPLAY is dropped silently rather than panic-handled:
a panic here would brick login over a config error elsewhere.
failing closed by omission is the right posture, the child just
gets the console-equivalent env."
  (let* ((display (getenv "DISPLAY"))
         (display-ok (and (stringp display)
                          (> (length display) 0)
                          (string-match-p
                           "\\`:[0-9]+\\(\\.[0-9]+\\)?\\'" display)))
         (base (list (concat "USER=" name)
                     (concat "LOGNAME=" name)
                     (concat "HOME=" home)
                     "SHELL=/bin/sh"
                     "PATH=/run/current-system/profile/bin:/usr/bin:/bin"
                     "TERM=linux")))
    (if display-ok
        (append base (list (concat "DISPLAY=" display)))
      base)))

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
    ;; v0.6 item 2.1: lay the per-user state dir down with correct
    ;; ownership BEFORE handing control to the child.  non-fatal on
    ;; failure (see session--ensure-user-state-dir docstring) so we
    ;; do not short-circuit the spawn here; the child boots without
    ;; its optional per-user init.el and the operator sees the
    ;; breadcrumb in *panic*.
    (session--ensure-user-state-dir sess)
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
  (setq session--last-spawn-error nil)
  (cond
   ((not (stringp name)) nil)
   (t
    (let ((pw (session--passwd-entry name)))
      (cond
       ((null pw)
        (setq session--last-spawn-error (list 'unknown-user name))
        (panic-handle (list 'session-spawn-unknown-user name)
                      'session-spawn)
        nil)
       (t
        (let* ((home (plist-get pw :home))
               (home-check (session--home-ok-p home)))
          (cond
           ((not (eq home-check t))
            ;; fail BEFORE allocating the struct, registering with
            ;; supervise, or persisting a 'starting record.  otherwise
            ;; a missing $HOME leaves a stale 'starting breadcrumb on
            ;; disk that rehydrate would treat as a mid-spawn crash.
            (setq session--last-spawn-error
                  (list 'home-bad name home home-check))
            (panic-handle (list 'session-spawn-home-bad
                                name home home-check)
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
              ;; v0.6 item 6.3: claim the workspace BEFORE the child
              ;; spawns.  the EXWM manage-finish hook (in exwm-config)
              ;; then reads `session-workspace-for-name' and routes the
              ;; new window to the pre-claimed index instead of running
              ;; its own allocator.  sticky semantics: a logout-then-
              ;; relogin reuses the prior index when free.
              ;;
              ;; allocation can return nil (all slots taken).  on nil we
              ;; let the workspace slot stay as whatever rehydrate left
              ;; it (likely nil); the EXWM hook falls through to its
              ;; legacy allocator and the window lands wherever it can.
              ;; the user sees an over-the-top window on top of *login*;
              ;; ugly, not data-destructive.  see session-max-workspaces.
              (let ((ws (session-allocate-workspace name)))
                (when (integerp ws)
                  (setf (geos-session-workspace sess) ws)))
              (session--persist sess)
              (cond
               ((session--spawn-child sess)
                (session--persist sess)
                sess)
               (t
                (setq session--last-spawn-error
                      (list 'spawn-child-failed name))
                (setf (geos-session-status sess) 'exited)
                (session--persist sess)
                nil))))))))))))

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

(defun session--snapshot-valid-p (snap key)
  "Return non-nil iff SNAP is a structurally sane persisted session.
KEY is the state-key the snapshot was read from (\"sessions/<name>\");
we cross-check that the snapshot's :name agrees with the basename of
KEY so a renamed-on-disk file cannot smuggle a different identity
back into the registry.  the checks are cheap and the cost of
admitting a torn record is real: a 'running snapshot with garbage
slots makes the boot path skip *login* presentation entirely."
  (and (listp snap)
       (let ((name   (plist-get snap :name))
             (uid    (plist-get snap :uid))
             (gid    (plist-get snap :gid))
             (home   (plist-get snap :home))
             (status (plist-get snap :status)))
         (and (stringp name)
              (string= name (file-name-nondirectory key))
              (integerp uid) (>= uid 1000)
              (integerp gid) (>= gid 1000)
              (stringp home) (> (length home) 0)
              (eq (aref home 0) ?/)
              (memq status '(held running starting exited))))))

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
panic-handles malformed entries (corrupted state file, wrong shape).
records that fail `session--snapshot-valid-p' are dropped entirely:
they are NOT added to the registry and do NOT count toward the
'running tally the boot path checks before presenting *login*."
  (condition-case err
      (let ((snap (state-read key nil)))
        (cond
         ((not (session--snapshot-valid-p snap key))
          ;; malformed record.  surface it in *panic* so an operator
          ;; can investigate, but do not let it influence boot.
          (panic-handle (list 'session--rehydrate-malformed key snap)
                        (cons 'session--rehydrate-malformed
                              (file-name-nondirectory key))))
         (t
          ;; persisted-status is what the previous boot left us with;
          ;; the in-memory struct's :status was mapped to 'held during
          ;; rehydrate construction so the struct represents
          ;; 'held-but-restartable until the spawn succeeds.
          (let* ((persisted-status (plist-get snap :status))
                 (name (plist-get snap :name))
                 (ws   (plist-get snap :workspace))
                 (sess (make-geos-session
                        :name name
                        :uid (plist-get snap :uid)
                        :gid (plist-get snap :gid)
                        :home (plist-get snap :home)
                        :started-at (plist-get snap :started-at)
                        :supervise-key (or (plist-get snap :supervise-key)
                                           (session--supervise-key name))
                        :workspace (and (integerp ws) (>= ws 0) ws)
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
                (session--persist sess)))))))
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
;; auto-teardown poller
;; --------------------------------------------------------------------
;;
;; the supervisor has no SIGCHLD path yet; pid1's child-reaper exists
;; but does not call back into elisp.  until that lands, the only way
;; to notice a per-user emacs that quit or crashed is to look.  this
;; poller is the look.  it is intentionally dumb: probe /proc/<pid>
;; for each 'running session every few seconds, transition the
;; vanished ones to 'held, and if nothing is running anymore present
;; *login* again.  cost: one `file-exists-p' syscall per running
;; session per tick; on a single-user box that is one syscall every
;; three seconds.  when pid1 grows the callback the poller goes away.

(defcustom session-poll-interval 3.0
  "Seconds between liveness probes of running per-user emacs children.
the timer installed by `session--arm-poll-timer' fires at this
cadence and calls `session--poll-children'.  three seconds is fast
enough that the *login* surface comes back promptly when a user
quits their emacs, slow enough that the per-tick cost is invisible
even with a few dozen sessions.  rebind via `cl-letf' to something
tiny (0.01) inside freeze-tests; the timer arming honors the bound
value at arm time."
  :type 'number)

(defvar session--poll-timer nil
  "Timer handle for the auto-teardown poller, or nil when not armed.
held in a defvar so `session--arm-poll-timer' is idempotent across
repeated init-file loads: a second arm cancels the prior timer
before installing the new one.")

(defun session--child-alive-p (pid)
  "Return non-nil iff PID names a live process under /proc.
defensive against nil PID and non-integer PID (returns nil for
both: a session with no recorded child cannot be alive).

/proc-missing fallback diverges by deployment posture, deliberately:

  - under PID 1 (`pid1-as-emacs-p' non-nil) a missing /proc is a
    degraded boot, not a normal state.  we fail closed and return
    nil so the poller observes vanished children and transitions
    them to 'held.  hiding dead-child detection behind a /proc
    mount failure on a deployed image would be exactly the wrong
    posture: the operator needs to SEE the breakage, not have the
    supervisor paper over it by reporting every session alive.

  - on a dev host (`pid1-as-emacs-p' nil or unbound) /proc may
    legitimately be absent (think `emacs --batch' on macOS, or a
    sandbox).  we return t there so loading session.el outside the
    OS does not false-positive every recorded session as dead.

zombie handling: a child that exited but has not been reaped by
its parent (the supervisor's emacs is PPid for these) still has a
/proc/<pid>/ directory, so `file-directory-p' alone reports it
alive.  read /proc/<pid>/status and treat State: Z (zombie) as
dead, so the poller transitions the session to 'held instead of
sitting on a dead child forever.  this matters when the per-user
emacs exits before the supervisor's SIGCHLD handler reaps it (a
window of typically tens of milliseconds, but with no upper
bound).  malformed /proc/<pid>/status counts as alive: a read
that fails mid-flight while the process is being reaped should
not cause a false 'held transition; the next tick reads cleanly.
the /proc/<pid>/status read also covers the comm cross-check the
prior comment flagged as future work: a recycled pid will not
have State: Z immediately, and the supervisor can detect the
identity drift via comm in a later hardening pass.
pid-reuse race: in the window between the child's death and the
next poll tick another process could in principle be assigned the
same pid by the kernel.  on a vanilla linux PID_MAX is 32768 (4M
with the bigger-pids sysctl), the poll interval defaults to 3s,
and a single-user geos box has a handful of processes; the
probability of recycling a freshly-killed emacs's pid inside one
window is small enough to ignore for v0.5."
  (cond
   ((not (integerp pid)) nil)
   ((<= pid 0) nil)
   ((not (file-directory-p "/proc"))
    (not (and (boundp 'pid1-as-emacs-p) pid1-as-emacs-p)))
   ((not (file-directory-p (format "/proc/%d" pid))) nil)
   (t
    (condition-case _err
        (with-temp-buffer
          (insert-file-contents-literally
           (format "/proc/%d/status" pid))
          (goto-char (point-min))
          ;; State line shape: "State:\tZ (zombie)" or "State:\tR (running)" etc.
          (not (re-search-forward "^State:[ \t]+Z" nil t)))
      ;; status read failed; treat as alive so a transient /proc
      ;; race does not flip a real running child to 'held.
      (error t)))))

(defun session--poll-children ()
  "Sweep the registry, transition vanished 'running children to 'held.
if at least one session transitioned and no session remains
'running, present *login* again so the operator is not left
staring at the buffer the dead session happened to have on
screen.

deliberately does NOT call `session-end' on a miss: the child is
already gone, SIGTERM to a nonexistent pid is a no-op or races
with pid reuse.  inline the held-transition (status, clear
child-pid, persist) instead.

skips 'starting records: the window between `setf' of the pid
and `setf' of the status inside `session--spawn-child' is single-
threaded and effectively zero-width; polling 'starting would race
with a legitimate in-flight spawn.

whole body wrapped in condition-case: a wedged poll iteration
must not take down the supervisor."
  (condition-case err
      (let ((any-transitioned nil))
        (dolist (sess (session-list))
          (when (eq (geos-session-status sess) 'running)
            (let ((pid (geos-session-child-pid sess)))
              (unless (session--child-alive-p pid)
                (setf (geos-session-status sess) 'held)
                (setf (geos-session-child-pid sess) nil)
                (session--persist sess)
                (setq any-transitioned t)
                (message
                 "session: %s child pid %S vanished, marking held"
                 (geos-session-name sess) pid)))))
        (when (and any-transitioned
                   (not (cl-some
                         (lambda (s)
                           (eq (geos-session-status s) 'running))
                         (session-list))))
          (session--present-login)))
    (error
     (panic-handle err 'session--poll-children))))

(defun session--arm-poll-timer ()
  "Install the auto-teardown poll timer, cancelling any prior handle.
idempotent: safe to call multiple times.  reads
`session-poll-interval' at arm time, so a rebind only takes
effect after the next arm (a freeze-test that wants a fast tick
should `cl-letf' the var and re-call this).  the timer fires
through `session--poll-children', which is itself wrapped in
panic-handle, so a poll iteration cannot wedge the supervisor.

LOAD-BEARING: the only caller is `session--boot-rehydrate', which
self-removes from `emacs-startup-hook' on first run; that hook's
self-removal is what actually prevents stacked pollers across
repeated init loads.  cancel-then-rearm here is the second line
of defense, not the first.  if the self-remove in
`session--boot-rehydrate' ever regresses, every startup pass
will land here and the cancel-then-rearm is all that stops a
runaway timer stack."
  (when (timerp session--poll-timer)
    (cancel-timer session--poll-timer))
  (setq session--poll-timer
        (run-at-time session-poll-interval
                     session-poll-interval
                     #'session--poll-children)))

;; --------------------------------------------------------------------
;; boot wiring
;; --------------------------------------------------------------------

(defun session--login-skip-requested-p ()
  "Return non-nil iff the operator asked to bypass the *login* buffer.
v0.5 honors `geos.login=skip' on the kernel cmdline; see file
commentary for why this exists and why it is not a production path.
the literal whole-token match lives in `geos-cmdline-token-p' under
core/cmdline.el, the single source of truth for /proc/cmdline
parsing; this function is now a thin alias around it."
  (geos-cmdline-token-p "geos.login=skip"))

(defun session--present-login ()
  "Present the *login* buffer on whatever surface this geos-mode uses.

callers: originally just `session--boot-rehydrate' (boot-tail), as
of the auto-teardown poller this is ALSO called from
`session--poll-children' on a timer tick when the last 'running
session has vanished.  implication: the buffer/window switch can
now happen at any moment the operator might be doing something
else in the supervisor frame (reading *messages*, poking at
*processes*, whatever).  that is jarring (the screen yanks out
from under them) but defensible: when no user session is
'running, the supervisor frame's job IS to present *login*.
returning to a stale buffer would be worse, because the operator
would have no obvious affordance to start a session.  revisit if
the warp turns out to be more disruptive than expected.

v0.5 MVP shape: console mode and UI mode use the same shape, a
full-frame switch on the supervisor's current frame.  UI mode is
expected to diverge in v0.5.x once per-user EXWM workspace routing
lands; until then the `(getenv \"DISPLAY\")' probe is decoration and
both modes do the same thing.  the probe stays so the branch point
is visible (and grep-discoverable) for the future split.

distinguishing console from UI: we check `(getenv \"DISPLAY\")', the
same predicate `exwm-config--should-enable' uses at boot to decide
whether to bring exwm up.  if DISPLAY is set this emacs is the X
client of its own embedded X server (Xorg under pid1's supervision)
and we are in UI mode.  if it is unset we are on a kernel
framebuffer console.  no separate `geos-mode' variable: the
authoritative answer is the env emacs was started with.

never raises: `login-show' is wrapped in condition-case so a wedged
buffer-show path routes through `panic-handle' rather than the boot
default-handler.  this is the privilege boundary; an error here
must NOT leave the supervisor running with no login surface.  if
the error path itself trips before a buffer makes it to the frame,
we synthesise a minimum *login* with a pointer to *panic*: better a
visible breadcrumb than a blank tty."
  (condition-case err
      (let ((buf (login-show)))
        (cond
         ((not (bufferp buf))
          (panic-handle (list 'session-present-login-no-buffer buf)
                        'session--present-login))
         (t
          (let ((mode (if (getenv "DISPLAY") 'ui 'console)))
            (message "session: presenting *login* in %s mode" mode)
            (switch-to-buffer buf)
            (delete-other-windows)))))
    (error
     (panic-handle err 'session--present-login)
     ;; the supervisor must NOT continue with no login surface.  build
     ;; a fallback buffer by hand; if even that fails, log to *Messages*
     ;; and let the operator see a frozen frame rather than nothing.
     (condition-case e2
         (let* ((bname (or (bound-and-true-p login-buffer-name)
                           "*login*"))
                (buf (get-buffer-create bname)))
           (with-current-buffer buf
             (let ((inhibit-read-only t))
               (erase-buffer)
               (insert "*login* render failed.  see *panic*.\n")
               (insert (format "error: %S\n" err))))
           (switch-to-buffer buf)
           (delete-other-windows))
       (error
        (message "session: present-login fallback also failed: %S"
                 e2))))))

;; same gate the other core files use.  on a dev host pid1-as-emacs-p
;; is nil and rehydrate is skipped, so loading the file is side-effect
;; free outside the OS.
;;
;; the hook intentionally fires AFTER `supervise-finalize' because
;; emacs runs `emacs-startup-hook' AFTER `command-line-1' has loaded
;; every `-l' file on the supervisor's argv; the boot gexp loads
;; session.el BEFORE buffers/, userland services, and exwm-config, so
;; calling `session-rehydrate' at file-load time would try to spawn
;; per-user emacses before the rest of the system is up (and before
;; `supervise-finalize' has restored counters).  deferring to
;; emacs-startup-hook makes rehydrate sequence safely against the rest
;; of the boot.  the hook is removed inside its own body so it is
;; idempotent under repeated init-file loads.
;;
;; (v0.6-preview, 2026-05-11) MUST be `emacs-startup-hook', NOT
;; `after-init-hook'.  emacs fires after-init-hook inside
;; `command-line' BEFORE `command-line-1' processes -l args (see
;; startup.el lines ~1543 vs 2866 in emacs 30.2).  the supervisor
;; is started with `-Q -l early-init.el -l ... -l session.el ...',
;; so at after-init-hook time session.el has not been loaded and
;; `add-hook' has not run yet; the hook fires empty and the
;; *login* buffer never appears.  emacs-startup-hook is the
;; AFTER-l-chain hook and is the right one for any startup wiring
;; declared inside a `-l'-loaded file.
(defun session--boot-rehydrate ()
  "emacs-startup-hook entry point.  gated on `pid1-as-emacs-p' and
removes itself on first run.

after rehydrate returns, if no session is `'running' we present the
*login* buffer on whatever surface this geos-mode uses; if at least
one session was rehydrated to `'running' we hand the screen to that
session and skip the login presentation (the persisted state is
the source of truth; an operator who wants out of the restored
session uses the `q' binding in login-mode's :running state).

the `geos.login=skip' kernel cmdline token short-circuits the login
presentation; see file commentary for the rationale."
  (remove-hook 'emacs-startup-hook #'session--boot-rehydrate)
  (when (and (boundp 'pid1-as-emacs-p) pid1-as-emacs-p)
    (condition-case err
        (progn
          (session-rehydrate)
          (cond
           ((session--login-skip-requested-p)
            (message
             "session: geos.login=skip honored, not presenting *login*"))
           ((cl-some (lambda (s)
                       (eq (geos-session-status s) 'running))
                     (session-list))
            (message
             "session: rehydrated running session, skipping *login*"))
           (t
            (session--present-login)))
          ;; arm the auto-teardown poller AFTER rehydrate so the first
          ;; tick sees a stable registry.  same pid1-as-emacs-p gate
          ;; as rehydrate; on a dev host this never fires.  idempotent
          ;; because the hook self-removes on first run and
          ;; `session--arm-poll-timer' cancels any prior handle.
          (session--arm-poll-timer))
      (error
       (panic-handle err 'session-boot-rehydrate)))))

(add-hook 'emacs-startup-hook #'session--boot-rehydrate)

(provide 'session)
;;; session.el ends here
