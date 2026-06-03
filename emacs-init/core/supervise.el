;;; supervise.el --- the elisp service supervisor -*- lexical-binding: t -*-
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

;; shepherd is gone.  long-running things in the userland used to keep
;; their own private process handles, their own restart policy (or none),
;; and their own logging story.  the kmsg follower in journal.el is a
;; representative example: it spawns dd, hopes dd stays alive, and if
;; dd dies the buffer silently stops scrolling.  this file is the
;; replacement: one registry, one sentinel, one throttle, one persistent
;; record.
;;
;; non-goals for this revision (deferred to follow-ups):
;;   - :user / :group enforcement (depends on item 4 user accounts; we
;;     record the slot and warn on first restart that it is not enforced)
;;   - :depends-on topological start (cycle detection + ordered walk;
;;     valuable but not required for the MVP service set)
;;   - log-file capture with fsync every 64 KiB (sentinel-side accumulator
;;     buffer; lands when a service actually needs it)
;;   - :start-async sentinel-driven init for services that block at start
;;
;; what IS in scope:
;;   - cl-defstruct supervise-service with the contract slots
;;   - defservice macro + supervise-register imperative form
;;   - supervise-start / supervise-stop / supervise-restart / supervise-resume
;;   - sentinel that applies restart policy and bumps counters
;;   - rolling 60s respawn throttle, cap 5, transitions to 'held
;;   - supervise-registry returning the plist shape services.el wants
;;   - persistence: every state change writes to /var/emacs/services/registry
;;     via state-write; load at boot restores counters across emacs restarts

(require 'panic)
(require 'state)
(require 'cl-lib)

(cl-defstruct supervise-service
  ;; identity + intent.  these come from the defservice form and do
  ;; not change at runtime.
  name                                  ; symbol, registry key
  command                               ; (PROGRAM ARG ...) for make-process
  env                                   ; alist appended to process-environment
  user group                            ; recorded only, not enforced (see top comment)
  restart                               ; one of 'on-crash 'on-failure 'always 'never
  logfile                               ; path or nil; sentinel writes stderr+stdout here
  depends-on                            ; list of service names; not yet enforced
  buffer                                ; string|buffer|nil; threaded into :buffer of make-process
  filter                                ; function|nil; threaded into :filter of make-process
  autostart                             ; non-nil = supervise-autostart starts at boot
  ;; runtime mutable state.  persisted to disk on every change.
  status                                ; 'stopped 'running 'held 'dead
  pid                                   ; integer or nil
  process                               ; process object or nil
  started-at                            ; time-list or nil
  last-exit                             ; integer exit code or signal symbol, nil if never died
  restarts                              ; total restart count since first start
  respawn-times)                        ; list of float-time entries inside the throttle window

(defvar supervise--registry (make-hash-table :test 'eq)
  "Map of service-name (symbol) -> supervise-service struct.
The single source of truth for what is supervised.  defservice and
supervise-register populate it; the sentinel mutates the runtime
slots; supervise--persist serialises it under /var/emacs/services/.")

;; v0.9.12 slice 9 diagnostic helper.  the supervisor wraps every
;; make-process / sentinel transition in panic-handle, which lands in
;; the in-memory *panic* buffer.  that buffer is invisible to an
;; operator who only has the serial console (the dhclient autostart
;; failure from slice 8 VM-verify was the canonical example: registry
;; said 4 entries, sshd + syslogd spawned, dhclient just did not, and
;; nothing on /dev/console said why).  mirror every interesting
;; transition to /dev/console here too, wrapped in condition-case so a
;; permission-denied or device-missing failure cannot abort the
;; supervisor.  on a dev host /dev/console writes usually need root and
;; the EACCES is swallowed; on the booted OS image we are pid1's child
;; and the writes land in the serial log.
(defun supervise--console (fmt &rest args)
  "Append FMT/ARGS to /dev/console as one line.  swallow all errors."
  (condition-case _
      (let ((write-region-inhibit-fsync t))
        (write-region (apply #'format (concat fmt "\n") args)
                      nil "/dev/console" 'append 'nomsg))
    (error nil)))

(defconst supervise-respawn-window-sec 60
  "Rolling window (seconds) over which `supervise-respawn-cap' applies.
Mirrors XORG_RESPAWN_WINDOW_SEC in pid1/emacs-init.c so a service
with the same crashloop pathology trips at the same wall-clock rate
under both supervisors.")

(defconst supervise-respawn-cap 5
  "Maximum respawns allowed inside `supervise-respawn-window-sec'.
Beyond this the service transitions to 'held and stops respawning
until an operator runs `supervise-resume'.  Same shape as the pid1
Xorg crashloop guard.")

(defconst supervise--state-key "services/registry"
  "state-read / state-write key for the persisted registry.
Lives under /var/emacs/services/, materialised by state--ensure-layout.")

;; --------------------------------------------------------------------
;; persistence
;; --------------------------------------------------------------------

(defun supervise--snapshot-svc (svc)
  "Return a serialisable plist for SVC.
Strips the live process object (a process pointer means nothing
across emacs restarts) and keeps only what we want to restore:
counters, last-exit, status of last write.  the static intent fields
\(command, env, restart\) are NOT persisted because the source of
truth for those is the defservice form on next boot, not the disk."
  (list :name (supervise-service-name svc)
        :status (supervise-service-status svc)
        :restarts (supervise-service-restarts svc)
        :last-exit (supervise-service-last-exit svc)
        :respawn-times (supervise-service-respawn-times svc)))

(defun supervise--persist ()
  "Serialise the registry's mutable state to /var/emacs/services/registry.
Called from every state transition (start/stop/sentinel/resume).
A failed write is logged via panic-handle but does not abort the
caller; the registry stays correct in memory and the next successful
write resyncs disk."
  (condition-case err
      (let (snap)
        (maphash (lambda (_name svc) (push (supervise--snapshot-svc svc) snap))
                 supervise--registry)
        (state-write supervise--state-key snap))
    (error
     (panic-handle err 'supervise--persist))))

(defun supervise--restore-counters ()
  "Read the persisted registry and copy counter slots into in-memory svcs.
Run once after all defservice forms have evaluated (typically from a
post-init hook or directly at the bottom of the boot -l chain).  only
restores counters/status of services that still exist in the in-memory
registry; orphan entries on disk are dropped silently on the next
persist."
  (let ((snap (state-read supervise--state-key nil)))
    (when (listp snap)
      (dolist (entry snap)
        (let* ((name (plist-get entry :name))
               (svc (and (symbolp name) (gethash name supervise--registry))))
          (when svc
            (setf (supervise-service-restarts svc)
                  (or (plist-get entry :restarts) 0))
            (setf (supervise-service-last-exit svc)
                  (plist-get entry :last-exit))
            (setf (supervise-service-respawn-times svc)
                  (or (plist-get entry :respawn-times) nil))
            ;; status restore is tricky: if disk says 'running, that
            ;; was true for the previous emacs but is certainly false
            ;; for this one (no process survives an emacs restart).
            ;; collapse 'running -> 'stopped so the next start is a
            ;; cold start.  preserve 'held though, so a crashloop that
            ;; already tripped the throttle stays tripped across reboots.
            (let ((s (plist-get entry :status)))
              (setf (supervise-service-status svc)
                    (cond ((eq s 'held) 'held)
                          (t 'stopped))))))))))

;; --------------------------------------------------------------------
;; throttle
;; --------------------------------------------------------------------

(defun supervise--throttle-trips-p (svc)
  "Return non-nil if SVC has respawned `supervise-respawn-cap' times
inside the rolling `supervise-respawn-window-sec'.  also trims the
respawn-times slot to drop entries older than the window."
  (let* ((now (float-time))
         (cutoff (- now supervise-respawn-window-sec))
         (recent (cl-remove-if (lambda (t0) (< t0 cutoff))
                               (supervise-service-respawn-times svc))))
    (setf (supervise-service-respawn-times svc) recent)
    (>= (length recent) supervise-respawn-cap)))

(defun supervise--note-respawn (svc)
  "Record a respawn timestamp on SVC."
  (push (float-time) (supervise-service-respawn-times svc)))

;; --------------------------------------------------------------------
;; registry I/O
;; --------------------------------------------------------------------

(defun supervise-register (&rest plist)
  "Imperative defservice.  Accepts the same keyword arguments as the
macro and returns the registered struct.  Re-registering the same name
overwrites the static intent fields but PRESERVES the runtime counters,
so reloading supervise.el under a live system does not zero out
restart history."
  (let* ((name (plist-get plist :name))
         (existing (and (symbolp name) (gethash name supervise--registry)))
         (svc (or existing
                  (make-supervise-service
                   :name name
                   :status 'stopped
                   :restarts 0
                   :respawn-times nil))))
    (unless (symbolp name)
      (panic-handle (list 'supervise-register-bad-name name)
                    'supervise-register))
    (setf (supervise-service-command svc) (plist-get plist :command))
    (setf (supervise-service-env svc) (plist-get plist :env))
    (setf (supervise-service-user svc) (plist-get plist :user))
    (setf (supervise-service-group svc) (plist-get plist :group))
    (setf (supervise-service-restart svc)
          (or (plist-get plist :restart) 'on-crash))
    (setf (supervise-service-logfile svc) (plist-get plist :logfile))
    (setf (supervise-service-depends-on svc) (plist-get plist :depends-on))
    (setf (supervise-service-buffer svc) (plist-get plist :buffer))
    (setf (supervise-service-filter svc) (plist-get plist :filter))
    ;; autostart defaults to t.  use plist-member so an explicit nil
    ;; can opt out without being mistaken for "value missing".
    (setf (supervise-service-autostart svc)
          (if (plist-member plist :autostart)
              (plist-get plist :autostart)
            t))
    (puthash name svc supervise--registry)
    (supervise--persist)
    svc))

(defmacro defservice (name &rest plist)
  "Declarative service registration.  NAME is an unquoted symbol; PLIST
is the same keyword set `supervise-register' takes (minus :name, which
is taken from NAME).  values are taken AS DATA: a :command of
\(\"/bin/true\") is the literal one-element list, not a function call,
and :restart on-crash is the symbol on-crash, not a variable lookup.
expands via apply so the plist is consumed exactly once at runtime.

  (defservice journal-kmsg
    :command (\"/run/current-system/profile/bin/dd\" \"if=/dev/kmsg\" ...)
    :restart on-crash)

prefer this over supervise-register at top-level for grep-ability."
  (declare (indent 1))
  `(apply #'supervise-register :name ',name ',plist))

(defun supervise-registry ()
  "Return the registry as a list of plists, sorted by service name.
Plist contract matches what buffers/services.el's renderer expects:
  :name :kind :status :pid :restarts :started-at :process
:kind is hardcoded 'process for now; timer/sentinel kinds land later."
  (let (out)
    (maphash
     (lambda (_name svc)
       (push (list :name (supervise-service-name svc)
                   :kind 'process
                   :status (supervise-service-status svc)
                   :pid (supervise-service-pid svc)
                   :restarts (supervise-service-restarts svc)
                   :started-at (supervise-service-started-at svc)
                   :process (supervise-service-process svc))
             out))
     supervise--registry)
    (sort out (lambda (a b)
                (string< (symbol-name (plist-get a :name))
                         (symbol-name (plist-get b :name)))))))

(defun supervise-status (name)
  "Return the current status symbol for NAME, or nil if not registered."
  (let ((svc (gethash name supervise--registry)))
    (and svc (supervise-service-status svc))))

;; --------------------------------------------------------------------
;; sentinel + spawn
;; --------------------------------------------------------------------

(defun supervise--sentinel (proc _event)
  "Process sentinel for every supervised service.
Runs on emacs's main loop so it MUST NOT block.  decides:
  - record exit code / signal
  - apply restart policy (skipped if user already stopped or held)
  - check throttle, transition to 'held if tripped
  - persist updated counters

PROC's plist carries :supervise-service back to us via process-get."
  (let ((svc (process-get proc :supervise-service)))
    (when (and svc (memq (process-status proc) '(exit signal failed)))
      (let* ((code (process-exit-status proc))
             (sig  (process-status proc))
             (prior-status (supervise-service-status svc))
             (user-stopped (memq prior-status '(stopped held))))
        ;; slice 9 breadcrumb: every exit transition lands on /dev/console
        ;; so the operator can see WHY a service died without attaching
        ;; emacsclient to peek at the *panic* buffer.
        (supervise--console
         "supervise: sentinel name=%s status=%S code=%S prior=%S"
         (supervise-service-name svc) sig code prior-status)
        (setf (supervise-service-last-exit svc)
              (if (eq sig 'signal) (cons 'signal code) code))
        (setf (supervise-service-pid svc) nil)
        (setf (supervise-service-process svc) nil)
        ;; only flip to 'dead if the user did NOT already stop or hold
        ;; this service.  preserving 'stopped means a manual stop is
        ;; visible in the registry instead of being overwritten by an
        ;; exit event triggered by our own delete-process call.
        (unless user-stopped
          (setf (supervise-service-status svc) 'dead))
        (cond
         (user-stopped
          ;; user (or restart-counter persistence at boot) already
          ;; decided this service should not run.  record exit, do
          ;; not respawn.
          (supervise--persist))
         (t
          (let* ((policy (supervise-service-restart svc))
                 (clean (and (eq sig 'exit) (zerop code)))
                 (want-restart
                  (or (eq policy 'always)
                      (and (eq policy 'on-failure) (not clean))
                      (and (eq policy 'on-crash) (eq sig 'signal))
                      (and (eq policy 'on-crash) (and (eq sig 'exit)
                                                      (not (zerop code)))))))
            (cond
             ((not want-restart)
              (supervise--persist))
             ((supervise--throttle-trips-p svc)
              (setf (supervise-service-status svc) 'held)
              (message "supervise: %s held after %d crashes in %ds window"
                       (supervise-service-name svc)
                       supervise-respawn-cap
                       supervise-respawn-window-sec)
              (supervise--persist))
             (t
              (cl-incf (supervise-service-restarts svc))
              (supervise--note-respawn svc)
              (supervise--persist)
              (condition-case err
                  (supervise--spawn svc)
                (error
                 (panic-handle err
                               (cons 'supervise--sentinel-restart
                                     (supervise-service-name svc))))))))))))))

(defun supervise--spawn (svc)
  "Start SVC's command via make-process.  attaches the sentinel and
records pid + started-at + status='running.  caller is responsible
for any throttle decisions.  raises through panic-handle on a bad
command shape; returns nil in that case so the caller can short."
  (let* ((name (symbol-name (supervise-service-name svc)))
         (cmd (supervise-service-command svc))
         (env-extra (supervise-service-env svc)))
    ;; slice 9 breadcrumb: log the spawn attempt BEFORE make-process so
    ;; the operator can tell a service that never tried to spawn
    ;; (autostart never reached it) from one that tried and failed.
    (supervise--console "supervise: spawn name=%s cmd=%S" name cmd)
    (cond
     ((not (and (listp cmd) (stringp (car cmd))))
      (supervise--console "supervise: spawn name=%s BAD-COMMAND %S" name cmd)
      (panic-handle (list 'supervise--spawn-bad-command cmd) name)
      nil)
     (t
      (when (and (or (supervise-service-user svc)
                     (supervise-service-group svc))
                 (zerop (supervise-service-restarts svc)))
        ;; one-shot warning: we recorded the slot but make-process
        ;; can't setuid before exec.  proper enforcement waits on
        ;; item 4's setuid helper; until then, services run as the
        ;; supervisor's uid (root in the OS image).
        (message "supervise: %s requests user/group but enforcement is deferred to item 4"
                 name))
      (let* ((process-environment
              (append (mapcar (lambda (kv) (format "%s=%s" (car kv) (cdr kv)))
                              env-extra)
                      process-environment))
             ;; if :buffer was a string, get-or-create the buffer so a
             ;; respawn always lands in the same place.  callers that
             ;; want a fresh buffer per spawn can pass a buffer object
             ;; from a :pre-spawn hook (not implemented yet) or supply
             ;; nil and accept make-process's default-named buffer.
             (buf-spec (supervise-service-buffer svc))
             (buf (cond
                   ((bufferp buf-spec) buf-spec)
                   ((stringp buf-spec) (get-buffer-create buf-spec))
                   (t nil)))
             (filter-fn (supervise-service-filter svc))
             (proc-args (list :name (concat "supervise:" name)
                              :command cmd
                              :noquery t
                              :connection-type 'pipe
                              :sentinel #'supervise--sentinel)))
        (when buf (setq proc-args (append proc-args (list :buffer buf))))
        (when filter-fn
          (setq proc-args (append proc-args (list :filter filter-fn))))
        (condition-case err
            (let ((proc (apply #'make-process proc-args)))
              (process-put proc :supervise-service svc)
              (setf (supervise-service-process svc) proc)
              (setf (supervise-service-pid svc) (process-id proc))
              (setf (supervise-service-started-at svc) (current-time))
              (setf (supervise-service-status svc) 'running)
              ;; slice 9 breadcrumb: the spawn worked; record pid so a
              ;; later "no log activity" complaint can be correlated
              ;; against ps output.
              (supervise--console "supervise: spawn name=%s pid=%S OK"
                                  name (process-id proc))
              proc)
          (error
           ;; slice 9 breadcrumb: make-process raised.  before this
           ;; slice the error went straight to panic-handle and the
           ;; operator saw nothing on /dev/console.  now we surface the
           ;; error text first, then re-signal so the outer
           ;; condition-case in supervise-start / supervise--sentinel
           ;; can still route to panic-handle.
           (supervise--console "supervise: spawn name=%s FAILED %S" name err)
           (signal (car err) (cdr err)))))))))

;; --------------------------------------------------------------------
;; commands
;; --------------------------------------------------------------------

(defun supervise-start (name)
  "Start the service NAME.  no-op if already 'running.  refuses 'held."
  (interactive
   (list (intern (completing-read "start service: "
                                  (mapcar (lambda (e) (symbol-name (plist-get e :name)))
                                          (supervise-registry))
                                  nil t))))
  (let ((svc (gethash name supervise--registry)))
    (cond
     ((null svc)
      (panic-handle (list 'supervise-start-unknown name) 'supervise-start))
     ((eq (supervise-service-status svc) 'running)
      (message "supervise: %s already running" name))
     ((eq (supervise-service-status svc) 'held)
      (message "supervise: %s is held; M-x supervise-resume first" name))
     (t
      (condition-case err
          (progn (supervise--spawn svc)
                 (supervise--persist))
        (error
         (panic-handle err (cons 'supervise-start name))))))))

(defun supervise-stop (name)
  "Stop the service NAME by sending SIGTERM.  status -> 'stopped.
The sentinel will record the exit but the restart-policy check sees
status 'stopped and skips respawn."
  (interactive
   (list (intern (completing-read "stop service: "
                                  (mapcar (lambda (e) (symbol-name (plist-get e :name)))
                                          (supervise-registry))
                                  nil t))))
  (let ((svc (gethash name supervise--registry)))
    (cond
     ((null svc)
      (panic-handle (list 'supervise-stop-unknown name) 'supervise-stop))
     (t
      (let ((proc (supervise-service-process svc)))
        (setf (supervise-service-status svc) 'stopped)
        (when (process-live-p proc)
          (condition-case err
              (delete-process proc)
            (error
             (panic-handle err (cons 'supervise-stop name)))))
        (setf (supervise-service-process svc) nil)
        (setf (supervise-service-pid svc) nil)
        (supervise--persist))))))

(defun supervise-restart (name)
  "Stop then start NAME."
  (interactive
   (list (intern (completing-read "restart service: "
                                  (mapcar (lambda (e) (symbol-name (plist-get e :name)))
                                          (supervise-registry))
                                  nil t))))
  (supervise-stop name)
  (supervise-start name))

(defun supervise-resume (name)
  "Clear 'held status on NAME so it can start again.  does not start it."
  (interactive
   (list (intern (completing-read "resume held service: "
                                  (mapcar (lambda (e) (symbol-name (plist-get e :name)))
                                          (cl-remove-if-not
                                           (lambda (e) (eq (plist-get e :status) 'held))
                                           (supervise-registry)))
                                  nil t))))
  (let ((svc (gethash name supervise--registry)))
    (when svc
      (setf (supervise-service-status svc) 'stopped)
      (setf (supervise-service-respawn-times svc) nil)
      (supervise--persist)
      (message "supervise: %s resumed (call supervise-start to actually run)" name))))

;; --------------------------------------------------------------------
;; boot-time autostart
;; --------------------------------------------------------------------

(defun supervise-autostart ()
  "Start every registered non-'held service.  call from a post-init
hook AFTER all defservice forms have evaluated and after
`supervise--restore-counters' has run.  services already 'held by
the persisted registry stay held until an operator resumes them."
  (maphash
   (lambda (name svc)
     (cond
      ((eq (supervise-service-status svc) 'held)
       ;; slice 9 breadcrumb: a held service silently NOT starting at
       ;; boot is the same operator-confusion failure mode as a service
       ;; that fails to spawn.  log the skip so it is visible.
       (supervise--console "supervise: autostart name=%s SKIP held" name))
      (t
       (supervise--console "supervise: autostart name=%s" name)
       (condition-case err
           (supervise-start name)
         (error
          (supervise--console "supervise: autostart name=%s ERROR %S" name err)
          (panic-handle err (cons 'supervise-autostart name)))))))
   supervise--registry))

;; --------------------------------------------------------------------
;; finalize (called from boot-marker.el AFTER all defservice forms ran)
;; --------------------------------------------------------------------

(defun supervise-finalize ()
  "Restore persisted counters, autostart non-held services, emit boot marker.
Must be invoked AFTER every -l file that contains a defservice has
finished loading.  the cleanest spot is boot-marker.el (loaded last
in the boot gexp); any earlier and the registry is incomplete and
restore-counters would silently drop entries that have not registered
yet.

Idempotent in spirit: a second call would re-read the same disk
snapshot and re-attempt to start anything we already started, so the
already-running guard in `supervise-start' is what keeps the second
call honest.  do not loop on this."
  (when (and (boundp 'pid1-as-emacs-p) pid1-as-emacs-p)
    (condition-case err (supervise--restore-counters)
      (error (panic-handle err 'supervise-finalize-restore)))
    (condition-case err (supervise-autostart)
      (error (panic-handle err 'supervise-finalize-autostart)))
    (supervise--console "supervise: registry loaded %d entries"
                        (hash-table-count supervise--registry))))

(provide 'supervise)
;;; supervise.el ends here
