;;; rpc-server.el --- supervisor side of the user/supervisor RPC -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; v0.6 item 3.  the user-emacs has no `pid1-*' access by design;
;; privileged operations (reboot, poweroff, package install, passwd-
;; set, ...) are reachable only over a unix socket the supervisor
;; owns.  this file is the supervisor side: it binds the socket via
;; `pid1-rpc-listen', polls it on a short timer via `pid1-rpc-poll',
;; reads a sexp request, dispatches to a verb handler, and writes a
;; sexp reply via `pid1-rpc-reply'.
;;
;; authentication: the kernel records the connecting peer's uid and
;; gid at connect() time (SO_PEERCRED) and pid1-rpc-poll returns them
;; in the request plist.  the verb dispatcher uses those for
;; authorisation; no shared secret, no token.  uid 0 is the
;; supervisor (which can be its own client over the same socket for
;; smoke tests).
;;
;; authorisation: per-verb in `rpc-server--verbs'.  the docstring of
;; each verb states what uid range may invoke it.  the default is
;; "any uid"; verbs that mutate user-visible state may require uid 0.
;;
;; wire format (matches pid1-rpc-poll/-reply in pid1/emacs-init.c):
;;   request:  (VERB-STRING ARG1 ARG2 ...)
;;   reply:    (:status STATUS :payload PAYLOAD)
;;               STATUS is one of 'ok, 'error.
;;               PAYLOAD is verb-specific on ok, a message string on
;;               error.
;;
;; trust model for the request sexp:
;;   the payload arrives as bytes from C and is parsed via
;;   `read-from-string'.  we NEVER `eval' it.  the read can produce
;;   arbitrary nested structures up to RPC_PAYLOAD_MAX (64 KiB) but
;;   that bound is enforced C-side; here we trust the size cap and
;;   pattern-match on the structure.  malformed input replies with
;;   (:status error :payload "parse error: ...") and closes.
;;
;; concurrency: the supervisor is single-threaded.  one request at a
;; time, serialised through the 200ms timer.  a slow handler stalls
;; the supervisor's UI for its duration; verbs that need to spawn
;; long-running subprocesses (guix install) MUST use make-process +
;; sentinel and reply immediately with a job-id, not block.  the v0.6
;; verbs are all short (read /var/emacs/journal, call reboot(2)) so
;; this is fine for the MVP.
;;
;; lifecycle: `rpc-server-start' binds the socket, arms the timer.
;; called once from the supervisor's boot tail (init.el).
;; `rpc-server-stop' cancels the timer (the socket fd stays open
;; until the supervisor exits; the kernel cleans up).

(require 'cl-lib)
(require 'panic)

(defcustom rpc-server-socket-path "/run/geos/super.sock"
  "Absolute path of the AF_UNIX socket the supervisor binds.
matches the path the user-side `rpc-client.el' connects to."
  :type 'string)

(defcustom rpc-server-socket-mode #o666
  "File mode for the bound socket.
the supervisor calls chmod after bind so umask cannot accidentally
exclude other users.  authentication is via SO_PEERCRED, not the
DAC mode, so #o666 here is a connectivity gate not a security
gate.  if the operator wants to restrict access by group, ship
/run/geos/ owned root:geos mode 0750 and set this to #o660."
  :type 'integer)

(defcustom rpc-server-poll-interval 0.2
  "Seconds between calls to `pid1-rpc-poll'.
short enough that an interactive user typing M-x geos-poweroff in
the user-emacs sees the reboot happen within 200ms of clicking
yes.  long enough that the supervisor's idle CPU is not measurable.
rebind via `cl-letf' in freeze-tests to drain the queue faster."
  :type 'number)

(defvar rpc-server--timer nil
  "Timer handle for the RPC poll loop, or nil when not armed.
held in a defvar so `rpc-server-start' is idempotent across
repeated init-file loads: re-arming cancels the prior timer.")

(defvar rpc-server--verbs (make-hash-table :test 'equal)
  "Map of verb (string) to handler function.
each handler has signature (FN UID GID ARGS) -> reply-payload.
UID and GID are integers from SO_PEERCRED.  ARGS is the list tail
of the request sexp, e.g. (verb arg1 arg2) -> ARGS = (arg1 arg2).
the return value is the :payload slot of an `:status ok' reply.
to reply with an error the handler should signal an error via
`error' (NOT `panic-handle'): the dispatcher catches and converts
to :status error.")

(defvar rpc-server--listening nil
  "Non-nil iff `pid1-rpc-listen' has been called successfully.
prevents double-listen across multiple `rpc-server-start' calls
during a single boot.")

(defun rpc-server-register (verb handler)
  "Bind VERB (string) to HANDLER (function).
HANDLER signature: (UID GID ARGS) -> sexp.  re-registration
replaces the prior handler.  this is the only sanctioned way to
add a verb; rebinding the hash directly is fine for freeze-tests
but production code should use this so a future audit gate
(verb-allowlist, gate via :type, ...) has one chokepoint."
  (cond
   ((not (stringp verb))
    (panic-handle (list 'rpc-server-register-bad-verb verb)
                  'rpc-server-register)
    nil)
   ((not (functionp handler))
    (panic-handle (list 'rpc-server-register-bad-handler verb handler)
                  'rpc-server-register)
    nil)
   (t
    (puthash verb handler rpc-server--verbs))))

(defun rpc-server--require-root (uid verb)
  "Signal an error if UID is not 0.
shape: each handler that mutates state calls this first.  the
message is short and includes the verb so the audit log in the
caller's panic-handle is useful."
  (unless (= uid 0)
    (error "rpc verb %s: uid 0 only (saw %d)" verb uid)))

(defun rpc-server--parse (payload)
  "Parse PAYLOAD (a string) into a request sexp.
returns (verb . args) or signals an error with a readable message.
uses `read-from-string' with bounds: the payload size cap is
enforced C-side at RPC_PAYLOAD_MAX, so we only validate shape
here.  the parsed result must be a non-empty list whose head is
a string (the verb).  anything else is a protocol error."
  (let* ((parsed (condition-case e
                     (read-from-string payload)
                   (error (error "parse error: %S" e))))
         (sexp (car parsed)))
    (cond
     ((not (consp sexp))
      (error "request not a list: %S" sexp))
     ((not (stringp (car sexp)))
      (error "request head not a string: %S" (car sexp)))
     (t (cons (car sexp) (cdr sexp))))))

(defun rpc-server--serialise (status payload)
  "Build a reply string from STATUS and PAYLOAD.
STATUS is a symbol (`ok' or `error'); PAYLOAD is any sexp.
the reply shape is `(:status STATUS :payload PAYLOAD)' so the
client can pattern-match without parsing tags.  uses `prin1-to-
string' so back-references and unprintable values are surfaced
as errors at this layer rather than corrupting the wire."
  (prin1-to-string (list :status status :payload payload)))

(defun rpc-server--dispatch (request)
  "Run the handler for REQUEST, return a reply string.
REQUEST is the plist returned by `pid1-rpc-poll' (with :fd
already stripped by the caller; we only need :uid :gid :payload).
on any handler failure, the reply is (:status error :payload
\"message\").  the dispatcher is wrapped so a buggy handler
cannot wedge the poll loop: every error is caught and surfaced as
an error reply, the connection still gets a clean close."
  (condition-case err
      (let* ((uid     (plist-get request :uid))
             (gid     (plist-get request :gid))
             (payload (plist-get request :payload))
             (parsed  (rpc-server--parse payload))
             (verb    (car parsed))
             (args    (cdr parsed))
             (handler (gethash verb rpc-server--verbs)))
        (cond
         ((null handler)
          (rpc-server--serialise 'error (format "unknown verb: %s" verb)))
         (t
          (rpc-server--serialise 'ok (funcall handler uid gid args)))))
    (error
     (rpc-server--serialise 'error (error-message-string err)))))

(defun rpc-server--tick ()
  "One poll iteration: pull a pending request, dispatch, reply.
loops until `pid1-rpc-poll' returns nil so a burst of queued
requests drains in one tick instead of one per 200ms.  the inner
condition-case catches any pid1-error from the C side so a
broken socket does not stall the timer."
  (condition-case err
      (let ((pending t))
        (while pending
          (let ((req (and (fboundp 'pid1-rpc-poll)
                          (funcall (symbol-function 'pid1-rpc-poll)))))
            (cond
             ((null req)
              (setq pending nil))
             (t
              (let* ((fd (plist-get req :fd))
                     (reply (rpc-server--dispatch req)))
                (when (and (integerp fd) (fboundp 'pid1-rpc-reply))
                  (funcall (symbol-function 'pid1-rpc-reply) fd reply))))))))
    (error
     (panic-handle err 'rpc-server--tick))))

(defun rpc-server--arm-timer ()
  "Install the poll timer, cancelling any prior handle.
idempotent.  reads `rpc-server-poll-interval' at arm time; rebinds
take effect on the next arm."
  (when (timerp rpc-server--timer)
    (cancel-timer rpc-server--timer))
  (setq rpc-server--timer
        (run-at-time rpc-server-poll-interval
                     rpc-server-poll-interval
                     #'rpc-server--tick)))

(defun rpc-server--ensure-socket-dir ()
  "Ensure /run/geos/ exists, mode 0755 root:root.
the supervisor is the only writer; mode 0755 lets non-root
clients chdir/stat the dir to find the socket but not unlink
it (the socket inode itself has its own mode set by
`rpc-server-socket-mode').  failures are non-fatal: we log via
panic-handle and let the listen() call surface ENOENT/EACCES."
  (let ((dir (file-name-directory rpc-server-socket-path)))
    (condition-case err
        (progn
          (unless (file-directory-p dir)
            (make-directory dir t))
          (set-file-modes dir #o755))
      (error
       (panic-handle err 'rpc-server--ensure-socket-dir)))))

(defun rpc-server--console-write (msg)
  "Append MSG and a newline to /dev/console.
mirrors the supervise-finalize and boot-marker.el pattern: the
RPC machinery emits its listen-line as a /dev/console marker so
the smoke-test serial log can gate on it.  errors swallowed: a
broken /dev/console must not block the supervisor from arming
the RPC server."
  (let ((write-region-inhibit-fsync t))
    (condition-case _
        (write-region (concat msg "\n") nil "/dev/console" 'append 'nomsg)
      (error nil))))

(defun rpc-server-start ()
  "Bind the RPC socket and arm the poll timer.
called from the supervisor's boot tail; idempotent.  on a dev
host (where `pid1-rpc-listen' is unbound) this is a no-op so the
file loads without side effect.  if listen fails the timer is
still armed but every tick will short-circuit on the unbound
`pid1-rpc-poll' check; this is intentional so a configuration
error does not silently disable the whole RPC machinery."
  (cond
   ((not (fboundp 'pid1-rpc-listen))
    (rpc-server--console-write
     "rpc-server: pid1-rpc-listen unbound, RPC disabled"))
   (rpc-server--listening
    (rpc-server--console-write
     (format "rpc-server: already listening on %s"
             rpc-server-socket-path)))
   (t
    (rpc-server--console-write
     (format "rpc-server: starting on %s" rpc-server-socket-path))
    (rpc-server--ensure-socket-dir)
    (condition-case err
        (progn
          (funcall (symbol-function 'pid1-rpc-listen)
                   rpc-server-socket-path
                   rpc-server-socket-mode)
          (setq rpc-server--listening t)
          (message "rpc: listening on %s" rpc-server-socket-path)
          (rpc-server--console-write
           (format "rpc: listening on %s" rpc-server-socket-path))
          (rpc-server--arm-timer))
      (error
       (rpc-server--console-write
        (format "rpc: start failed: %S" err))
       (panic-handle err 'rpc-server-start))))))

(defun rpc-server-stop ()
  "Cancel the poll timer.
does NOT close the listen socket; the kernel reclaims it on
supervisor exit.  called from freeze-tests to tear down between
cases."
  (when (timerp rpc-server--timer)
    (cancel-timer rpc-server--timer)
    (setq rpc-server--timer nil)))

;; --------------------------------------------------------------------
;; v0.6 verb table
;; --------------------------------------------------------------------

(defun rpc-server--verb-ping (_uid _gid _args)
  "Liveness probe.  any uid.  returns the symbol `pong'.
the verb the freeze-test exercises first to confirm the whole
socket plumbing is wired."
  'pong)

(defun rpc-server--verb-journal-tail (_uid _gid args)
  "Return the last N lines of *Messages* as a list of strings.
ARGS shape: (N).  any uid.  N is clamped to [1, 500] so a
malicious client cannot ask for the entire buffer (which on a
long-running supervisor could be megabytes).  the *Messages*
buffer is the supervisor's audit trail; per-user emacs sees
its own *Messages* but those are not on this wire."
  (let* ((n-raw (or (car args) 50))
         (n (cond ((not (integerp n-raw)) 50)
                  ((< n-raw 1) 1)
                  ((> n-raw 500) 500)
                  (t n-raw))))
    (with-current-buffer (get-buffer-create "*Messages*")
      (save-excursion
        (let (out)
          (goto-char (point-max))
          (forward-line (- n))
          (while (not (eobp))
            (push (buffer-substring-no-properties
                   (line-beginning-position)
                   (line-end-position))
                  out)
            (forward-line 1))
          (nreverse out))))))

(defun rpc-server--verb-reboot (uid _gid _args)
  "Sync and reboot.  any uid.  does not return on success.
logs the requesting uid to *Messages* before the syscall fires so
the audit trail survives the reboot via the journal (once item 4
ships the persistent journal).  for v0.6 the *Messages* line is
ephemeral but still visible to an operator with serial console."
  (message "rpc: reboot requested by uid %d" uid)
  (cond
   ((not (fboundp 'pid1-reboot))
    (error "pid1-reboot unbound"))
   (t
    (let ((panic-allow-kill-emacs t))
      (funcall (symbol-function 'pid1-reboot))
      ;; unreachable on success
      'rebooting))))

(defun rpc-server--verb-poweroff (uid _gid _args)
  "Sync and poweroff.  any uid.  does not return on success."
  (message "rpc: poweroff requested by uid %d" uid)
  (cond
   ((not (fboundp 'pid1-poweroff))
    (error "pid1-poweroff unbound"))
   (t
    (let ((panic-allow-kill-emacs t))
      (funcall (symbol-function 'pid1-poweroff))
      'powering-off))))

(rpc-server-register "ping"         #'rpc-server--verb-ping)
(rpc-server-register "journal-tail" #'rpc-server--verb-journal-tail)
(rpc-server-register "reboot"       #'rpc-server--verb-reboot)
(rpc-server-register "poweroff"     #'rpc-server--verb-poweroff)

;; bottom-of-load auto-start under the same gate the rest of core/ uses
;; (state.el, supervise.el).  dev-host loads (pid1-as-emacs-p unbound or
;; nil) skip this entirely: the file just defines verbs and returns.
;; in the supervisor boot path this is what actually binds the socket;
;; nothing else calls rpc-server-start.
(when (and (boundp 'pid1-as-emacs-p) pid1-as-emacs-p)
  (rpc-server-start))

(provide 'rpc-server)
;;; rpc-server.el ends here
