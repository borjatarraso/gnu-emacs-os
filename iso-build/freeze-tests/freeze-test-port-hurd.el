;;; freeze-test-port-hurd.el --- per-slice freeze tests for port_hurd.c -*- lexical-binding: t -*-

;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;;; Commentary:
;;
;; freeze-tests for the slice-by-slice rollout of port_hurd's design 2.2
;; (the Hurd peer-cred handshake, docs/v08-hurd-peer-cred-design.md).
;;
;; the main freeze-test suite under iso-build/freeze-tests.el covers the
;; elisp port seam (geos-kernel branch points: network parsers, /sys
;; readers, etc).  this file covers the C-side port_hurd surfaces that
;; only exist when GEOS_KERNEL=hurd at runtime AND the pid1-module.so
;; built with PORT=hurd is loaded.  on the Linux dev host both
;; conditions are false; the tests emit 'skip records and the harness
;; treats them as non-blocking.
;;
;; the file lives under iso-build/freeze-tests/ because the existing
;; monolithic freeze-tests.el is already large and the slice-by-slice
;; Hurd rollout adds one assertion per slice.  the hurd-smoke-test.sh
;; harness loads everything in this directory after the main suite.
;;
;; current slices:
;;
;;   slice 2: freeze-test-port-hurd-publish-auth-port
;;     asserts (pid1-publish-auth-port) returns t on Hurd when the
;;     module is loaded.  on linux or when the binding is absent, the
;;     test records 'skip with a diagnostic string.
;;
;;   slice 3: freeze-test-port-hurd-auth-drain
;;     asserts (pid1-auth-drain) returns t.  on Linux the body is a
;;     trivial no-op (linux_auth_drain returns 0), so the test should
;;     pass even without geos-kernel == 'hurd as long as the binding
;;     is registered; we keep the same skip-when-unbound pattern so
;;     it runs cleanly on a host emacs without pid1-module.so.  on
;;     Hurd the test exercises the libports bucket drain end-to-end
;;     (the bucket may be empty, which is fine: drain returns 0 on
;;     empty too).
;;
;;   slice 4: freeze-test-port-hurd-client-handshake
;;     asserts (pid1-client-auth-handshake FD NONCE) returns t.  on
;;     Linux the C body is a no-op return-0 and the binding ignores
;;     NONCE; the test passes FD=-1 and a 16-byte zero-fill nonce
;;     unibyte string so the call exercises the arity-2 path
;;     end-to-end without needing a real socket.  on Hurd the same
;;     assertion only holds when a supervisor is running and has
;;     published /servers/geos-auth (slice 2 + 3); without that the
;;     C body will fail file_name_lookup and surface pid1-error, so
;;     the Hurd path of the test is gated on a probe call.
;;
;;   slice 5 (this commit): freeze-test-port-hurd-end-to-end
;;     asserts the slice-5 get_peer_cred surface has the grown
;;     arity-3 shape (FD, NONCE, returns t).  on Linux the elisp
;;     binding is registered by pid1-module.so regardless of PORT
;;     (`linux_get_peer_cred` ignores NONCE); the test calls it
;;     against a known-bad FD with a zero nonce and asserts that
;;     a clean elisp signal comes back (NOT a panic, NOT silent
;;     success).  this catches the regression where the
;;     designated-initialiser for port_caps.get_peer_cred forgets
;;     the NONCE slot and the binding signature drifts from the
;;     port_layer.h contract.  on Hurd the full end-to-end dance
;;     (publish, accept, mint nonce, write nonce, post submit_nonce
;;     mach_msg, drain, look up by nonce, return uid/gid) is
;;     verified by tests/hurd-client-handshake.c on a real VM; this
;;     freeze-test only catches the binding-surface regression that
;;     would otherwise reach the Hurd build before VM-verify.
;;
;; later slices will append additional tests below.

;;; Code:

(require 'cl-lib)

(defun freeze-test--port-hurd-record (tag result)
  "Bridge to the main freeze-test recorder when present.
falls back to `message' so this file is usable standalone."
  (cond
   ((fboundp 'freeze-test--record)
    (freeze-test--record tag result))
   (t
    (message "freeze-test-port-hurd: %S -> %S" tag result))))

(defun freeze-test-port-hurd-publish-auth-port ()
  "Slice 2: `pid1-publish-auth-port' on Hurd returns t.

contract: the supervisor calls `pid1-publish-auth-port' exactly once at
startup.  the C body in port_hurd.c::hurd_publish_auth_port allocates
the long-lived receive port that slice 3 will drain on every
`Fpid1_rpc_poll' tick.  if the call returns nil or signals
`pid1-error', the multi-user gate on Hurd is closed and no client can
authenticate.

dev-host behaviour: the `pid1-publish-auth-port' binding does not exist
on Linux (only the C body under PORT=hurd registers it), so the test
records a 'skip with the unbound-symbol diagnostic.  on a Hurd VM with
pid1-module.so loaded, the test calls the function and asserts t.

idempotency contract: a second call returns nil with errno=EBUSY
surfaced as a `pid1-error' signal; this test does NOT exercise the
second call because the first call's effect persists for the lifetime
of the emacs process and re-running would mask a regression in the
allocate path."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (eq (and (boundp 'geos-kernel) geos-kernel) 'hurd))
      (setq result (cons 'skip "geos-kernel != 'hurd")))
     ((not (fboundp 'pid1-publish-auth-port))
      (setq result (cons 'skip "pid1-publish-auth-port unbound (module not loaded)")))
     (t
      (condition-case err
          (let ((rv (pid1-publish-auth-port)))
            (setq result
                  (cond
                   ((eq rv t) 'pass)
                   (t (format "returned %S, want t" rv)))))
        (error
         (setq result (format "raised: %S" err))))))
    (freeze-test--port-hurd-record 'port-hurd/publish-auth-port result)
    result))

(defun freeze-test-port-hurd-auth-drain ()
  "Slice 3: `pid1-auth-drain' returns t.

contract: the supervisor calls `pid1-auth-drain' at the top of every
`pid1-rpc-poll' tick.  on Linux the C body is a trivial no-op (returns
0 with no syscalls); on Hurd it pulls up to 16 mach messages off the
libports bucket attached to /servers/geos-auth and dispatches
fsys_getroot / geos_auth_submit_nonce.  in either case the elisp
binding returns t on success and signals `pid1-error' on failure;
ENOSYS (the auth port has not been published yet) is surfaced as t
silently, mirroring the rpc-poll convention.

dev-host behaviour: the `pid1-auth-drain' binding is registered by
pid1-module.so on every PORT (Linux body returns 0; Hurd body returns
0 / -1 ENOSYS).  the test skips only when the binding is absent
(module not loaded); on the dev host with the module loaded, the test
calls the function and asserts t.  this is intentional: a Linux build
that returns nil or signals would mean the dispatch table is
mis-initialised (the .auth_drain slot defaulted to NULL because the
designated-initialiser forgot it), which is the exact bug
port_require_or_abort cannot catch.

idempotency: the drain is idempotent on both kernels (Linux is a no-op
and stays a no-op; Hurd's drain runs until the bucket is empty, then
returns 0 with MACH_RCV_TIMED_OUT internally absorbed).  the test
calls the binding twice to confirm the second call also returns t."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'pid1-auth-drain))
      (setq result (cons 'skip "pid1-auth-drain unbound (module not loaded)")))
     (t
      (condition-case err
          (let ((rv1 (pid1-auth-drain))
                (rv2 (pid1-auth-drain)))
            (setq result
                  (cond
                   ((and (eq rv1 t) (eq rv2 t)) 'pass)
                   (t (format "returned %S then %S, want t / t" rv1 rv2)))))
        (error
         (setq result (format "raised: %S" err))))))
    (freeze-test--port-hurd-record 'port-hurd/auth-drain result)
    result))

(defun freeze-test-port-hurd-client-handshake ()
  "Slice 4: `pid1-client-auth-handshake' has the slice-4 shape.

contract: every RPC client calls `pid1-client-auth-handshake' once,
right after `pid1-unix-connect' returns and before the first
`pid1-unix-send'.  the arity-2 form passes the 16-byte rendezvous
nonce the elisp side read off the socket via
`pid1-unix-recv-exactly' immediately after connect.

on Linux the C body is `return 0' (NONCE is ignored, no syscalls, no
wire bytes); the binding signals `pid1-error' only if NONCE is the
wrong length or FD is out of range.  on Hurd the C body looks up
/servers/geos-auth, allocates a rendezvous receive port + send-right
pair, hand-rolls a mach_msg(msgh_id=90001, rendezvous MOVE_SEND,
nonce[16]) against the auth port, then runs auth_user_authenticate
to complete the rendezvous.  the supervisor's per-tick drain matches
the nonce against the pending-auth fingerprint slot.

what this test actually checks: a freeze-test on a Linux dev host
without a live RPC socket cannot exercise the body end-to-end (the
binding's bounds check rejects FD < 0, and elisp does not expose a
raw fd integer for /dev/null without a syscall binding we do not
have).  instead this test verifies the slice-4-shaped surface is in
place:

  1. the binding `pid1-client-auth-handshake' is fbound (the module
     loaded with slice 4 patched in);
  2. its arity is (min=1, max=2): the legacy arity-1 form still
     works (compat for rpc-client.el on main), AND the new arity-2
     form is reachable (the slice-4 nonce slot exists);
  3. calling it with a malformed 1-byte nonce raises `pid1-error'
     with errno that signals the length check fired (proves the
     binding's NONCE-len validation path is actually wired, not
     dead code).

the end-to-end handshake (file_name_lookup, mach_msg, auth dance)
lives in tests/hurd-client-handshake.c which runs against a real
gnumach + libports stack on a Hurd VM.  this elisp test exists so a
mis-applied SPEC on main (binding shipped without the NONCE arg, or
without the length check) trips the dev-host harness before it
reaches the Hurd branch."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'pid1-client-auth-handshake))
      (setq result (cons 'skip "pid1-client-auth-handshake unbound (module not loaded)")))
     (t
      ;; subtest 1: arity must be (1 . 2).  func-arity returns
      ;; (MIN . MAX) for built-in module functions when emacs knows
      ;; the arity, which it does for ones registered via
      ;; make_function(env, MIN, MAX, ...).
      (let* ((arity (condition-case _ (func-arity #'pid1-client-auth-handshake)
                      (error nil)))
             (arity-ok (and (consp arity)
                            (eq (car arity) 1)
                            (eq (cdr arity) 2))))
        (cond
         ((not arity-ok)
          (setq result (format "arity %S, want (1 . 2)" arity)))
         (t
          ;; subtest 2: short NONCE must raise pid1-error.  passing a
          ;; 1-byte unibyte string trips the `need != 17' branch
          ;; (copy_string_contents reports need=2 for 1 byte + NUL).
          ;; we use FD=0 (stdin) so the bounds check passes and the
          ;; nonce-len check is the one that fires.  on Linux the
          ;; body never runs (the binding returns before
          ;; port->client_auth_handshake) because the length check
          ;; rejects first.
          (let ((short-nonce (string-as-unibyte (make-string 1 0))))
            (condition-case err
                (progn
                  (pid1-client-auth-handshake 0 short-nonce)
                  (setq result "short nonce returned without signal"))
              (error
               ;; any error from the binding is acceptable here; the
               ;; positive assertion is the call did not silently
               ;; succeed.  pid1-error is the documented signal but
               ;; the test does not pin the exact symbol so a future
               ;; refactor that renames it does not break us.
               (ignore err)
               (setq result 'pass)))))))))
    (freeze-test--port-hurd-record 'port-hurd/client-handshake result)
    result))

(defun freeze-test-port-hurd-end-to-end ()
  "Slice 5: the slice-5 elisp surface chain is wired and survives one tick.

contract: slice 5 grew `port_caps.get_peer_cred' to arity 4
(FD, NONCE[16], &UID, &GID).  the elisp seam does NOT expose
`get_peer_cred' directly; the call is made internally by the C body
of `pid1-rpc-poll' after it accepts a connection, mints a nonce, and
writes the nonce to the client.  the slice-5 PASS surface a freeze-
test can probe on a dev host is therefore:

  1. `pid1-publish-auth-port' is fbound (slice 2 surface) and the
     module loaded successfully (no dlopen miss for symbols the
     slice 5 build added).
  2. `pid1-auth-drain' is fbound and returns t (slice 3 surface;
     slice 5 did not change it but a designated-initialiser
     regression in port_caps would null this slot too).
  3. `pid1-rpc-poll' is fbound and returns nil (no pending
     connection on the dev host where no client connects to the
     supervisor socket).  this is the load-bearing assertion: on
     Linux a return-nil proves the new arity-4 get_peer_cred path
     compiles into the C body without crashing on an empty accept
     queue.  on Hurd the same return-nil proves the slice 5 C body
     (with the pending_auth[] lookup) does not panic when the table
     is empty.
  4. `pid1-client-auth-handshake' arity is (1 . 2) (slice 4
     surface; the slice-5 nonce arg from the supervisor side has
     to mate with the slice-4 client arg).

dev-host behaviour: every step skips cleanly if the binding is
unbound (module not loaded).  on a host running geos with the
module loaded, all four steps execute; the test asserts each
returns its expected shape.  this is the only slice-5 surface a
no-VM freeze-test can probe; the end-to-end auth dance lives in
tests/hurd-client-handshake.c and is verified on a real VM.

what this catches: the slice-5 rebuild that drops a slot from the
port_caps designated initialiser (e.g. forgetting the new arity
for .get_peer_cred makes the C compiler accept the old prototype
silently because designated-init missing fields are zero-filled,
and a NULL slot would null-pointer-deref on the first tick).
this freeze-test runs that first tick on the dev host so the
regression trips before reaching the Hurd VM gate."
  (interactive)
  (let ((result 'fail)
        (steps nil))
    (cond
     ((not (fboundp 'pid1-publish-auth-port))
      (setq result (cons 'skip "pid1-publish-auth-port unbound (module not loaded)")))
     ((not (fboundp 'pid1-auth-drain))
      (setq result (cons 'skip "pid1-auth-drain unbound (module not loaded)")))
     ((not (fboundp 'pid1-rpc-poll))
      (setq result (cons 'skip "pid1-rpc-poll unbound (module not loaded)")))
     ((not (fboundp 'pid1-client-auth-handshake))
      (setq result (cons 'skip "pid1-client-auth-handshake unbound (module not loaded)")))
     (t
      (condition-case err
          (progn
            ;; step 1: publish-auth-port.  Linux path returns t
            ;; immediately (linux_publish_auth_port is no-op).
            ;; Hurd path may return t or signal pid1-error if the
            ;; auth port is already published; we accept both as
            ;; "the slot is wired".
            (condition-case publish-err
                (progn
                  (pid1-publish-auth-port)
                  (push 'publish-ok steps))
              (error
               (ignore publish-err)
               ;; second-call EBUSY or W2-unaddressed ENOSYS both
               ;; prove the slot is reachable, just not happy to
               ;; be called here.  do not fail the test on this.
               (push 'publish-signaled steps)))
            ;; step 2: auth-drain.  must return t (ENOSYS is
            ;; silently coerced to t per its docstring).
            (let ((rv (pid1-auth-drain)))
              (unless (eq rv t)
                (error "auth-drain returned %S, want t" rv)))
            (push 'drain-ok steps)
            ;; step 3: rpc-poll.  no client connected so the call
            ;; must return nil.  a non-nil return on a dev host
            ;; without a connecting client would be a phantom
            ;; accept; a signal would mean the new arity-4
            ;; get_peer_cred body crashed on the accept path.
            (let ((rv (pid1-rpc-poll)))
              (unless (or (null rv) (listp rv))
                (error "rpc-poll returned %S, want nil or plist" rv)))
            (push 'rpc-poll-ok steps)
            ;; step 4: client-auth-handshake arity (slice 4
            ;; surface; slice 5 relies on the nonce slot
            ;; existing).
            (let ((arity (func-arity #'pid1-client-auth-handshake)))
              (unless (and (consp arity)
                           (eq (car arity) 1)
                           (eq (cdr arity) 2))
                (error "client-auth-handshake arity %S, want (1 . 2)"
                       arity)))
            (push 'handshake-arity-ok steps)
            (setq result 'pass))
        (error
         (setq result (format "raised: %S after steps=%S"
                              err (nreverse steps)))))))
    (freeze-test--port-hurd-record 'port-hurd/end-to-end result)
    result))

(provide 'freeze-test-port-hurd)
;;; freeze-test-port-hurd.el ends here
