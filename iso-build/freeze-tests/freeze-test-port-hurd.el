;;; freeze-test-port-hurd.el --- per-slice freeze tests for port_hurd.c -*- lexical-binding: t -*-

;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; SPDX-License-Identifier: GPL-3.0-or-later

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
;;   slice 3 (this commit): freeze-test-port-hurd-auth-drain
;;     asserts (pid1-auth-drain) returns t.  on Linux the body is a
;;     trivial no-op (linux_auth_drain returns 0), so the test should
;;     pass even without geos-kernel == 'hurd as long as the binding
;;     is registered; we keep the same skip-when-unbound pattern so
;;     it runs cleanly on a host emacs without pid1-module.so.  on
;;     Hurd the test exercises the libports bucket drain end-to-end
;;     (the bucket may be empty, which is fine: drain returns 0 on
;;     empty too).
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

(provide 'freeze-test-port-hurd)
;;; freeze-test-port-hurd.el ends here
