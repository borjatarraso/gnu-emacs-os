;;; freeze-test-arm-parent-death.el --- v0.9.8 arm_parent_death freeze-tests -*- lexical-binding: t -*-

;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
;;
;; This file is part of GEOS.
;;
;; GEOS is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; GEOS is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GEOS.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; pins the v0.9.8 arm_parent_death port slot.  the slot is exposed to
;; elisp as `pid1-arm-parent-death' (arity 1, integer signal number);
;; the Linux body dispatches to prctl(PR_SET_PDEATHSIG) and the Hurd
;; body returns ENOSYS until the v0.9.9 MACH_NOTIFY_DEAD_NAME watcher-
;; thread slice lands.  the slot is meant to be called from a post-fork
;; child before exec; calling it from the supervisor emacs arms a
;; death-link from the supervisor to whatever pid started emacs.  for
;; the freeze-test on a Linux dev host this side effect is harmless
;; (the test emacs is short-lived and the dev-host shell outlives it).
;;
;; the receipt for the slot shape is
;; `docs/runlogs/2026-05-21-hurd-xorg-probe.md' (probes F, F2, G).
;;
;; tests:
;;
;;   arm-parent-death/slot-bound
;;     asserts `pid1-arm-parent-death' is fbound when the module is
;;     loaded.  skips with reason when the symbol is unbound (no module
;;     in a bare `emacs -Q -batch').
;;
;;   arm-parent-death/linux-prctl-call
;;     on Linux, calls `(pid1-arm-parent-death 15)' (SIGTERM) and
;;     asserts t with no signal.  this exercises the prctl(PR_SET_
;;     PDEATHSIG) Linux body end-to-end.  skips when geos-kernel is
;;     not 'linux (Hurd has a different code path covered by the
;;     enosys test).
;;
;;   arm-parent-death/raises-pid1-error-class
;;     drives the binding's actual failure path by passing an
;;     out-of-range signal number (999).  the C-side range guard
;;     short-circuits with errno=EINVAL and signals.  asserts the
;;     signal class is exactly `pid1-error' (not a bare `error'), so
;;     callers can `condition-case` narrowly on the right symbol.
;;     this is the test that actually exercises the C-to-elisp error
;;     plumbing; the previous `hurd-enosys-tolerated' test wrapped a
;;     cl-letf stub in condition-case and so only confirmed `signal'
;;     raises a signal (B2, skeptic 2026-05-21).
;;
;;   arm-parent-death/error-shape
;;     same trigger (out-of-range signal), assert the signalled data
;;     is the documented shape: a one-element list whose only element
;;     is a string starting with "pid1: " and containing the
;;     strerror() text for EINVAL ("Invalid argument").  pins both
;;     the message-prefix convention and the strerror-suffix
;;     contract.  the honest test of ENOSYS-from-Hurd lives in the
;;     hurd-smoke-test harness; the C body actually returns ENOSYS
;;     only on a real Debian Hurd 0.9 VM, where this binding
;;     dispatches to port_hurd's arm_parent_death.  the dev-host
;;     binary always dispatches to port_linux which never returns
;;     ENOSYS, so the only honest dev-host check is the error shape.
;;
;; chose option B over option A (per skeptic 2026-05-21).  option A
;; would add a -DPID1_TEST_HOOKS=1 build flag that forces the C
;; backend to return ENOSYS regardless of dispatch table; module
;; surgery for a single freeze-test is overkill.  option B exercises
;; the same plumbing (C-side range guard, pid1_signal_errno,
;; non_local_exit dispatch) with the existing binary.

;;; Code:

(require 'cl-lib)

;; ensure `pid1-error' is a defined error symbol.  the canonical
;; definition lives in `emacs-init/early-init.el', which the booted
;; supervisor loads before any freeze-test runs.  the host-side runner
;; may run this file standalone (no early-init.el on the load path), so
;; we re-define defensively.  define-error is idempotent for the same
;; parent class.
(unless (get 'pid1-error 'error-conditions)
  (define-error 'pid1-error "PID1 supervision error"))

(defun freeze-test--arm-parent-death-record (tag result)
  "Bridge to the main freeze-test recorder when present.
falls back to `message' so this file is usable standalone."
  (cond
   ((fboundp 'freeze-test--record)
    (freeze-test--record tag result))
   (t
    (message "freeze-test-arm-parent-death: %S -> %S" tag result))))

(defun freeze-test/arm-parent-death-slot-bound ()
  "Pin `pid1-arm-parent-death' is fbound when the module is loaded."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'pid1-arm-parent-death))
      (setq result (cons 'skip "pid1-arm-parent-death unbound (module not loaded)")))
     (t
      ;; func-arity returns (MIN . MAX) for module functions registered
      ;; via make_function(env, MIN, MAX, ...).  the slot is arity 1.
      (let ((arity (condition-case _ (func-arity #'pid1-arm-parent-death)
                     (error nil))))
        (cond
         ((not (consp arity))
          (setq result (format "arity %S, want a cons" arity)))
         ((not (and (eq (car arity) 1) (eq (cdr arity) 1)))
          (setq result (format "arity %S, want (1 . 1)" arity)))
         (t
          (setq result 'pass))))))
    (freeze-test--arm-parent-death-record
     'arm-parent-death/slot-bound result)
    result))

(defun freeze-test/arm-parent-death-linux-prctl-call ()
  "On Linux, `(pid1-arm-parent-death 15)' returns t with no signal.
this exercises the prctl(PR_SET_PDEATHSIG, SIGTERM) Linux body.
the side effect is harmless on a dev host: the test emacs is
short-lived and the dev-host shell outlives it.  skips when
geos-kernel != 'linux."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'pid1-arm-parent-death))
      (setq result (cons 'skip "pid1-arm-parent-death unbound (module not loaded)")))
     ((not (eq (and (boundp 'geos-kernel) geos-kernel) 'linux))
      (setq result (cons 'skip "geos-kernel != 'linux")))
     (t
      (condition-case err
          (let ((rv (pid1-arm-parent-death 15)))
            (setq result
                  (cond
                   ((eq rv t) 'pass)
                   (t (format "returned %S, want t" rv)))))
        (error
         (setq result (format "raised: %S" err))))))
    (freeze-test--arm-parent-death-record
     'arm-parent-death/linux-prctl-call result)
    result))

(defun freeze-test/arm-parent-death-raises-pid1-error-class ()
  "Pin: the binding's failure path raises `pid1-error', not `error'.
trigger via an out-of-range signal number (999).  the C-side range
guard `if (sig < 1 || sig > NSIG - 1)' short-circuits to
`pid1_signal_errno(env, ..., EINVAL)' which calls
`env->non_local_exit_signal(env, intern(\"pid1-error\"), data)'.
the elisp side must see exactly `pid1-error' as the signal symbol;
this is what lets callers `condition-case (err)` narrowly instead
of swallowing every error.  on a Linux dev host this hits the real
C code path with no stub; the binding is dispatched all the way
through the port table to `port_linux_impl' (which is irrelevant
here because the range guard fires before dispatch)."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'pid1-arm-parent-death))
      (setq result (cons 'skip "pid1-arm-parent-death unbound (module not loaded)")))
     (t
      (let ((caught nil))
        (condition-case err
            (pid1-arm-parent-death 999)
          (pid1-error
           (setq caught (cons 'pid1-error err)))
          (error
           ;; landed in `error' but not `pid1-error'; record so the
           ;; failure message names the actual class we got.
           (setq caught (cons 'other err))))
        (setq result
              (cond
               ((null caught)
                "binding returned without signalling on signal=999")
               ((eq (car caught) 'pid1-error)
                'pass)
               (t (format "raised %S, want pid1-error class; data: %S"
                          (car-safe (cdr caught)) caught)))))))
    (freeze-test--arm-parent-death-record
     'arm-parent-death/raises-pid1-error-class result)
    result))

(defun freeze-test/arm-parent-death-error-shape ()
  "Pin: the signalled data is `(\"pid1: ...: <strerror>\")'.
same trigger as the class test (signal=999, hits the C-side range
guard, signals EINVAL).  the data list must be one element, the
element must be a string, the string must start with `pid1: ' and
contain `Invalid argument' (the glibc strerror(EINVAL) text).  this
pins the message-prefix convention so a future refactor that drops
the prefix or changes the suffix format will fail loudly instead
of silently breaking elisp callers that match on the text."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'pid1-arm-parent-death))
      (setq result (cons 'skip "pid1-arm-parent-death unbound (module not loaded)")))
     (t
      (let ((caught nil))
        (condition-case err
            (pid1-arm-parent-death 999)
          (pid1-error
           (setq caught err)))
        (setq result
              (cond
               ((null caught)
                "binding returned without signalling on signal=999")
               ((not (consp caught))
                (format "signal data not a cons: %S" caught))
               ;; caught is (pid1-error . DATA); the DATA from
               ;; pid1_signal_errno is itself a single-string list.
               (t
                (let* ((data (cdr caught))
                       (msg (car-safe data))
                       (mismatches nil))
                  (unless (and (listp data) (= (length data) 1))
                    (push (list :shape :got data :want 'one-element-list)
                          mismatches))
                  (unless (stringp msg)
                    (push (list :msg-type :got msg :want 'string)
                          mismatches))
                  (when (stringp msg)
                    (unless (string-prefix-p "pid1: " msg)
                      (push (list :prefix :got msg :want "pid1: ")
                            mismatches))
                    ;; strerror(EINVAL) is "Invalid argument" on glibc;
                    ;; the message also contains the prefix string
                    ;; "signal out of range" before the strerror suffix.
                    (unless (string-match-p "Invalid argument" msg)
                      (push (list :strerror :got msg
                                  :want "contains 'Invalid argument'")
                            mismatches)))
                  (setq result (if (null mismatches) 'pass mismatches)))))))))
    (freeze-test--arm-parent-death-record
     'arm-parent-death/error-shape result)
    result))

(defun freeze-test-arm-parent-death ()
  "Run the v0.9.8 arm_parent_death freeze-tests.
records four results under arm-parent-death/* tags; returns nil."
  (interactive)
  (freeze-test/arm-parent-death-slot-bound)
  (freeze-test/arm-parent-death-linux-prctl-call)
  (freeze-test/arm-parent-death-raises-pid1-error-class)
  (freeze-test/arm-parent-death-error-shape)
  nil)

(provide 'freeze-test-arm-parent-death)
;;; freeze-test-arm-parent-death.el ends here
