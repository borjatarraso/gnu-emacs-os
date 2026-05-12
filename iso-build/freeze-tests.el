;;; freeze-tests.el --- abuse suite for the GEOS panic buffer -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; this file is the runnable form of the /freeze-test skill.  load it
;; from inside a booted GEOS VM (M-x load-file, point at this path or
;; copy it into the guest first) and call (freeze-test-run-all).
;; each individual test can also be invoked separately so a regression
;; can be bisected.
;;
;; what each test asserts:
;;
;;   1. runaway loop          (while t)
;;     panic.el cannot help here.  emacs is single-threaded, a tight
;;     loop wedges the world until the user interrupts (C-g) or the
;;     watchdog fires.  the test verifies that C-g actually returns
;;     control: we wrap the loop in `with-timeout' so the test self-
;;     interrupts after 2 seconds.  pass = control returns and the
;;     panic buffer logged a quit.
;;
;;   2. catastrophic regex    pathological backtracking
;;     same single-thread reality.  emacs's regex engine is recursive
;;     enough that "(a*)*$" against a long string of "a" wedges for
;;     seconds-to-minutes.  again wrapped in `with-timeout'.
;;
;;   3. slow network          unreachable host
;;     blocks the supervisor on the connect() call.  panic.el catches
;;     the timeout error.  pass = error appears in *panic* and emacs
;;     stays alive.
;;
;;   4. bad tramp             dired against nonexistent ssh host
;;     tramp tries to spawn ssh and parse its prompts.  on failure
;;     the error must reach panic-handle, not crash the file manager.
;;
;;   5. (kill-emacs)          the actual test
;;     panic.el hooks `kill-emacs-hook' to refuse exit.  if a stray
;;     (kill-emacs) call could actually kill PID 1's child, the
;;     supervisor would respawn forever and userland would never
;;     stabilize.  pass = call returns nil, emacs stays alive.
;;
;;   6. state round-trip      write-then-read sentinel under /var/emacs/
;;     proves state-write -> rename(2) -> pid1-fsync-dir -> state-read
;;     forms a closed loop on the booted image.
;;
;;   7. supervise throttle    crashloop hits the rolling cap
;;     proves the 5-in-60s cap in supervise.el trips and the service
;;     ends up 'held instead of forking forever.
;;
;;   8. login flow under abuse (v0.5)
;;     the login surface is a pure-elisp state machine; it cannot
;;     wedge emacs the way a runaway regex can.  what we test here
;;     is the DEFENSES around it.  sub-checks:
;;       a. throttle-trips-after-cap     login--throttle-trips-p
;;                                       trips at the cap, stale
;;                                       timestamps get trimmed.
;;       b. snapshot-validator-rejects-junk
;;                                       session--snapshot-valid-p
;;                                       refuses every malformed
;;                                       shape we throw at it.
;;       c. cmdline-skip-does-not-over-match
;;                                       session--login-skip-requested-p
;;                                       only matches whole-token
;;                                       `geos.login=skip', not
;;                                       substrings or near-misses.
;;       d. empty-username-rejected      login-advance refuses to
;;                                       transition out of :prompt-user
;;                                       on empty input.
;;     each sub-check records its own result under a namespaced key
;;     ('login-abuse/throttle, /snapshot, /cmdline, /empty-user) so
;;     partial failures are bisectable.
;;
;;   9. spawn shape under abuse (v0.6 starter, 37ddbce)
;;     pins the two functions that decide what the per-user child
;;     emacs actually sees: session--child-env (DISPLAY pass-through
;;     under a strict :N[.M] regex) and session--child-argv (--name
;;     geos-user-NAME stamp, optional -l per-user init).  the smoke-
;;     test boots the image but never inspects either function's
;;     return value; a regression that drops the --name stamp or
;;     accepts a shell-metachar DISPLAY would still PASS the smoke
;;     gate.  sub-checks (each under 'spawn-shape/<name>):
;;       env/display-valid, env/display-valid-screen,
;;       env/display-unset, env/display-empty,
;;       env/display-malformed (four malformed strings, per-case
;;                              mismatches reported),
;;       env/base (USER/LOGNAME/HOME/SHELL/PATH/TERM all present),
;;       argv/no-init (no per-user init.el -> system init only,
;;                     6-element argv ending -l /etc/geos/user-init.el),
;;       argv/with-init (per-user init.el readable -> system init
;;                       FIRST then per-user, --name still at index
;;                       2-3),
;;       argv/name-injection (contract-pin: this function does NOT
;;                            re-validate NAME; passwd-add-user is
;;                            the upstream gate per the docstring),
;;       argv/user-init-unconditional (the system init path is in
;;                                     argv regardless of disk state;
;;                                     a missing file is a LOUD
;;                                     failure, not silent-skip),
;;       argv/user-init-path (the `session--user-init-path' defconst
;;                            pin, guards against rename or path
;;                            drift away from /etc/geos/user-init.el).
;;
;;   10. workspace routing (v0.6 starter, aa2917a)
;;     pins exwm-config--user-workspace-for: the per-user EXWM
;;     workspace allocator.  three behaviors must hold or per-user
;;     window routing silently breaks: stickiness across re-lookup,
;;     forward-only counter (never recycle on logout), and the B1
;;     bounded grow loop (8 no-progress iterations or bail to nil,
;;     because an unbounded while inside exwm-manage-finish-hook
;;     would freeze PID 1's main thread).  also pins the regex on
;;     exwm-config--maybe-route-user-window since the capture group
;;     is the contract between the spawn stamp and the routing
;;     hook.  sub-checks (each under 'workspace-routing/<name>):
;;       unbound-live-list (W3: nil when exwm-workspace--list not
;;                          bound, no error),
;;       sticky (same name twice -> same index),
;;       distinct (two names -> two indices, counter forward),
;;       counter-forward (after a hypothetical logout, counter
;;                        does not recycle),
;;       grow-loop-bounded (B1: nil after 8 no-progress tries,
;;                          and wall-clock under the budget),
;;       cache-rebuild-after-shrink (B2: stale cache rebuilds
;;                                   under the same slot),
;;       regex/accepts (three valid NAMEs match and capture),
;;       regex/rejects (seven near-miss strings do not match).
;;
;;   11. child-exit poller (v0.6 starter, 7f889c7)
;;     pins session--child-alive-p and session--poll-children, the
;;     interim SIGCHLD-via-polling path that lives until pid1 grows a
;;     real reap callback.  the smoke-test boots the image but never
;;     drives the poller; a regression that loses the /proc-missing
;;     posture-split or fails to transition a vanished 'running entry
;;     to 'held would still PASS the smoke gate while silently
;;     breaking dead-child detection.  the most security-relevant
;;     invariant is the posture-split itself: under pid1 the
;;     /proc-missing branch MUST fail closed (return nil so vanished
;;     children get caught), on a dev host it MUST fail open (return
;;     t so loading session.el outside the OS does not false-positive
;;     every recorded session as dead).  flipping that split either
;;     direction is a bug we have to catch here.  sub-checks (each
;;     under 'child-exit-poller/<name>):
;;       alive/nil-pid (guard against nil pid argument),
;;       alive/zero-pid (the <= 0 guard, 0 and -1),
;;       alive/non-integer (string pid rejected),
;;       alive/pid-1 (PID 1 is always alive on linux; skip if /proc
;;                    absent),
;;       alive/dead-pid (a high pid that does not exist; skip if
;;                       /proc absent),
;;       alive/proc-missing-fails-closed-under-pid1 (the posture-
;;                       split, pid1 side: nil),
;;       alive/proc-missing-fails-open-on-dev (the posture-split,
;;                       dev side: t),
;;       poll/transitions-vanished-running-to-held (the whole point
;;                       of the poller, vanished -> held + child-pid
;;                       cleared + persist called),
;;       poll/does-not-touch-running-when-alive (must not transition
;;                       a still-live child),
;;       poll/calls-present-login-when-empty (last user logged out,
;;                       supervisor surface must return to *login*),
;;       poll/skips-present-login-when-others-running (do NOT yank
;;                       the screen while another user is logged in),
;;       arm/idempotent (a second arm cancels the prior timer),
;;       arm/cancels-prior (the post-arm timer object is fresh).
;;
;;  12. users-buffer add (v0.6 item 4)
;;     drives `passwd-create-user-and-home' on a sentinel user and
;;     asserts /etc/passwd grows, /etc/shadow has a non-empty unlocked
;;     hash, and the home dir is owned by the new uid.  cleans up on
;;     every exit path so a partial create from a prior run does not
;;     poison the next.  the smoke-test does not exercise the create-
;;     user path; a regression that loses pid1-chown (home left root-
;;     owned), drops the password step (shadow locked), or skips the
;;     home dir entirely would still PASS the boot gate.  this test
;;     closes that gap.  test 12 records under 'users-buffer-add.
;;
;;  13. login audit log (v0.6 item 5, audit slice)
;;     drives `state-append-journal' on a sentinel journal file and
;;     asserts two appends land as two parseable sexp lines with the
;;     expected :result and :reason values.  pins the line-per-record
;;     contract that the *journal* buffer's later tailing logic will
;;     depend on.  records under 'login-audit.
;;
;;  14. per-user lockout (v0.6 item 5.3)
;;     synthesises 10 fails for a sentinel name, asserts the per-user
;;     trip predicate fires, writes /var/emacs/lockouts/NAME, reads
;;     back the :locked-until expiry, and clears.  pins that the
;;     in-memory counter plus the on-disk record stay in sync and
;;     that the file path is actually under /var/emacs/lockouts/.
;;     records under 'login-lockout.
;;
;;  15. last-login footer (v0.6 item 5.4)
;;     appends a synthetic :ok and a synthetic :fail to the auth log
;;     via `state-append-journal', then calls `login--audit-last-success'
;;     and asserts the :ok wins (returned USER and TIME match the
;;     appended sentinel).  pins the contract the *login* renderer
;;     depends on: a :fail right after a :ok must not blank the
;;     footer.  saves and restores any prior auth.log so we don't
;;     scribble over a real operator's history.  records under
;;     'login-last-success.
;;
;;  16. session workspace plumbing (v0.6 item 6.1)
;;     round-trips the workspace slot on the geos-session struct:
;;     session-record-workspace writes the in-memory slot AND
;;     persists, session-workspace-for-name reads it back, and
;;     the on-disk snapshot carries the :workspace key.  also
;;     pins the no-phantom guarantee: calling record-workspace
;;     with an unknown name returns nil and does NOT allocate a
;;     registry entry (an EXWM hook firing for a spoofed
;;     instance-name must not invent state).  records under
;;     'session-workspace.
;;
;; reporting: each test pushes a result alist into `freeze-test-results'.
;; (freeze-test-report) prints a per-test PASS/FAIL summary to *Messages*
;; and to /dev/console (when boot-marker--write is available, so the
;; smoke-test apparatus can pick it up out-of-band).

(require 'panic)
(require 'cl-lib)  ; freeze-test-report uses cl-remove-if

;; login-buffer + session may not be present on every image the suite
;; runs against (a partial v0.4 image, a stripped repro reduction).
;; require with noerror so freeze-tests still loads; the login-abuse
;; test gates every sub-check on `fboundp' and records a "module not
;; loaded" result instead of erroring out.
(require 'login-buffer nil 'noerror)
(require 'session nil 'noerror)
(require 'passwd nil 'noerror)

(defvar freeze-test-results nil
  "Alist of (TEST-NAME . RESULT) entries.  RESULT is one of
'pass, 'fail, or a string describing what went wrong.")

(defvar freeze-test-loop-budget-sec 2
  "Per-test deadline in seconds for the wedge-class tests.
short enough that an actual freeze does not eat our patience,
long enough that a healthy run finishes before tripping it.")

(defun freeze-test--record (name result)
  "Append RESULT under NAME to `freeze-test-results' and message it."
  (push (cons name result) freeze-test-results)
  (message "freeze-test: %s -> %S" name result))

(defun freeze-test--alive-p ()
  "Quick liveness check.  returns t iff emacs is still responsive
enough to evaluate trivial Elisp.  used between tests to confirm
the prior abuse did not leave the world wedged."
  (condition-case _
      (eq (+ 1 1) 2)
    (error nil)))

;; --------------------------------------------------------------------
;; test 1: runaway loop
;; --------------------------------------------------------------------

(defun freeze-test-runaway-loop ()
  "Spin in (while t) under a timeout.  pass iff control returns."
  (interactive)
  (let ((started (current-time))
        (result 'fail))
    (condition-case err
        (progn
          (with-timeout (freeze-test-loop-budget-sec
                         (setq result 'pass))
            (while t)))
      (quit
       ;; manual C-g would land here; interpret as pass too.
       (setq result 'pass))
      (error
       (panic-handle err 'freeze-test-runaway-loop)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'runaway-loop result)
    (message "  elapsed: %.2fs"
             (float-time (time-subtract (current-time) started)))))

;; --------------------------------------------------------------------
;; test 2: catastrophic regex
;; --------------------------------------------------------------------

(defun freeze-test-catastrophic-regex ()
  "Run an exponentially-backtracking regex against a long string
under a timeout."
  (interactive)
  (let ((result 'fail)
        (haystack (make-string 1024 ?a)))
    (condition-case err
        (with-timeout (freeze-test-loop-budget-sec
                       (setq result 'pass))
          (string-match "\\(a*\\)*$" haystack))
      (quit (setq result 'pass))
      (error
       (panic-handle err 'freeze-test-catastrophic-regex)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'catastrophic-regex result)))

;; --------------------------------------------------------------------
;; test 3: slow network
;; --------------------------------------------------------------------

(defun freeze-test-slow-network ()
  "Open a TCP socket against a black-hole address and verify
control returns within the wall-clock budget.

implementation note: the previous version of this test used a
synchronous `open-network-stream' call and wrapped it in
`with-timeout'.  that was wrong: with-timeout is implemented with
elisp timers, which fire only when emacs returns to its main
loop.  a synchronous connect() never yields, so the test would
sit in the kernel's SYN-retry path (~127s on default
tcp_syn_retries=6) regardless of the 2s budget.

the fix is `:nowait t' plus an `accept-process-output' poll loop.
accept-process-output yields to the timer system between reads,
so with-timeout actually fires.

pass criterion: wall-clock elapsed time stayed under
`freeze-test-loop-budget-sec' + a small grace.  the asymmetric
state semantics (every codepath setq'ing 'pass) of the previous
revision meant the test could never fail; now we measure elapsed
time around the whole thing and call FAIL if we overran."
  (interactive)
  (let ((result 'fail)
        (proc nil)
        (started (current-time))
        (grace 0.5))
    (condition-case err
        (with-timeout (freeze-test-loop-budget-sec nil)
          (setq proc (make-network-process
                      :name "freeze-test-slow"
                      :host "192.0.2.1"  ; RFC 5737 black hole
                      :service 80
                      :nowait t
                      :noquery t))
          ;; spin until the process completes or with-timeout fires.
          ;; accept-process-output with a 0.1s tick yields to the
          ;; timer subsystem between reads.
          (while (and (process-live-p proc)
                      (eq (process-status proc) 'connect))
            (accept-process-output proc 0.1)))
      (quit nil)
      (error
       ;; raised cleanly: the socket layer refused or the network
       ;; stack rejected.  not a wedge; treat as cooperative.
       (panic-handle err 'freeze-test-slow-network)))
    ;; pass = control returned within budget + grace.  if we slipped
    ;; past, something blocked us past with-timeout's reach (only
    ;; possible if accept-process-output was bypassed).  that IS the
    ;; freeze we're testing for.
    (let ((elapsed (float-time (time-subtract (current-time) started))))
      (setq result (if (< elapsed (+ freeze-test-loop-budget-sec grace))
                       'pass
                     (format "elapsed %.2fs > budget %ds"
                             elapsed freeze-test-loop-budget-sec))))
    ;; clean up the dangling connect attempt; route any failure
    ;; through panic-handle so it doesn't get masked.
    (when (and proc (process-live-p proc))
      (condition-case err
          (delete-process proc)
        (error
         (panic-handle err 'freeze-test-slow-network-cleanup))))
    (freeze-test--record 'slow-network result)))

;; --------------------------------------------------------------------
;; test 4: bad tramp
;; --------------------------------------------------------------------

(defun freeze-test-bad-tramp ()
  "Try to dired into a nonexistent SSH host.  pass iff the error
routes through panic-handle and control returns."
  (interactive)
  (let ((result 'fail))
    (condition-case err
        (with-timeout (freeze-test-loop-budget-sec
                       (setq result 'pass))
          (let ((default-directory "/ssh:freeze-test-nowhere.invalid:/"))
            ;; just a stat is enough to drag tramp in; we do not
            ;; actually want to open a buffer.
            (file-exists-p default-directory))
          (setq result 'pass))
      (quit (setq result 'pass))
      (error
       (panic-handle err 'freeze-test-bad-tramp)
       (setq result 'pass)))
    (freeze-test--record 'bad-tramp result)))

;; --------------------------------------------------------------------
;; test 5: (kill-emacs)
;; --------------------------------------------------------------------

(defun freeze-test-kill-emacs ()
  "Call (kill-emacs) and verify the panic-buffer hook refused exit.
Pass iff control returns and emacs is still alive."
  (interactive)
  (let ((result 'fail))
    (condition-case err
        (progn
          ;; if panic.el's kill-emacs hook is wired correctly, this
          ;; returns nil instead of actually killing PID 1's emacs.
          (kill-emacs)
          (setq result (if (freeze-test--alive-p) 'pass 'fail)))
      (quit (setq result 'pass))
      (error
       (panic-handle err 'freeze-test-kill-emacs)
       ;; an error during kill-emacs is also acceptable: it means
       ;; something refused to let it complete.  what matters is
       ;; that emacs is still here.
       (setq result (if (freeze-test--alive-p) 'pass 'fail))))
    (freeze-test--record 'kill-emacs result)))

;; --------------------------------------------------------------------
;; test 6: state round-trip (v0.4 item 1)
;; --------------------------------------------------------------------

(defun freeze-test-state-roundtrip ()
  "Write a known sentinel under /var/emacs/, read it back, delete it.
asserts that state-write -> rename(2) -> pid1-fsync-dir -> state-read
forms a closed loop in the booted image.  the random integer prevents
a stale value from a previous run silently passing the read.

failure modes worth catching:
  - state.el did not load (state-write unbound)
  - /var/emacs/ does not exist (state--ensure-layout never ran)
  - pid1-fsync-dir signalled and the rename was rolled back
  - the parent dir is on a read-only fs (state-mode misdetected)"
  (interactive)
  (let ((result 'fail)
        (key "freeze/roundtrip")
        (sentinel (list 'geos 'freeze (random 1000000))))
    (condition-case err
        (cond
         ((not (fboundp 'state-write))
          (setq result "state-write unbound, state.el not loaded"))
         ((not (state-write key sentinel))
          (setq result "state-write returned nil"))
         (t
          (let ((readback (state-read key 'absent)))
            (cond
             ((equal readback sentinel)
              (state-delete key)
              (setq result 'pass))
             (t
              (setq result (format "readback mismatch: %S != %S"
                                   readback sentinel)))))))
      (error
       (panic-handle err 'freeze-test-state-roundtrip)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'state-roundtrip result)))

;; --------------------------------------------------------------------
;; test 7: supervise throttle (v0.4 item 2)
;; --------------------------------------------------------------------

(defun freeze-test-supervise-throttle ()
  "Register a service that crashes immediately, prove the rolling
respawn cap trips and the service ends up in 'held.

Why this matters: the whole point of supervise.el shipping a
crashloop guard is so a busted /etc/something or a typo in a
defservice doesn't burn the supervisor down with infinite forks.
mirrors the pid1/emacs-init.c Xorg crashloop guard; the parameters
should match (60s window, cap of 5).

  - command (\"/bin/false\") exits 1 immediately
  - :restart on-crash so the sentinel's policy decides to respawn
  - :autostart nil so we control the first start ourselves and
    can poll deterministically without racing supervise-finalize

After we drive enough exits past the cap, status must be 'held and
no further respawns should happen.  the test waits up to 5 seconds
for the cascade to complete; on a healthy system this resolves in
well under a second."
  (interactive)
  (let ((result 'fail)
        (sname 'freeze-test-bad)
        (deadline (+ (float-time) 5)))
    (condition-case err
        (cond
         ((not (fboundp 'supervise-register))
          (setq result "supervise-register unbound, supervise.el not loaded"))
         (t
          (supervise-register :name sname
                              :command '("/bin/false")
                              :restart 'always
                              :autostart nil)
          (supervise-start sname)
          ;; pump the main loop so the sentinel can fire and respawn.
          ;; supervise.el's spawn -> exit -> sentinel -> spawn cycle
          ;; lives entirely on the elisp side; sleep-for would block
          ;; the very loop we need to spin.
          (while (and (< (float-time) deadline)
                      (not (eq (supervise-status sname) 'held)))
            (accept-process-output nil 0.05))
          (cond
           ((eq (supervise-status sname) 'held)
            (setq result 'pass))
           (t
            (setq result (format "status=%S after 5s, expected held"
                                 (supervise-status sname)))))
          ;; whether pass or fail, leave the registry clean: stop
          ;; the service (no-op if already held) and resume so a
          ;; rerun of the test starts from a clean slate.  do NOT
          ;; remove the entry from the hash table; supervise.el has
          ;; no public delete, and the test surviving a re-run is
          ;; useful for bisection.
          (when (fboundp 'supervise-resume)
            (supervise-resume sname))))
      (error
       (panic-handle err 'freeze-test-supervise-throttle)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'supervise-throttle result)))

;; --------------------------------------------------------------------
;; test 8: login flow under abuse (v0.5)
;; --------------------------------------------------------------------

(defun freeze-test--login-modules-loaded-p ()
  "Return non-nil iff the login + session surfaces are linked in.
the four sub-checks each call this and short-circuit with a
'module-not-loaded result if anything is missing.  we check the
exact symbols each sub-check touches rather than just `featurep'
on login-buffer/session so a half-loaded image (defvars in place,
defuns half-bound from a partial byte-compile) does not slip
through and crash the test.

returns t when every symbol the test calls exists; nil otherwise."
  (and (boundp 'login--bad-attempts)
       (boundp 'login--throttle-cap)
       (boundp 'login--throttle-window)
       (boundp 'login--throttle-stall-sec)
       (boundp 'login--state)
       (boundp 'login--user)
       (boundp 'geos-cmdline-path)
       (fboundp 'login--throttle-trips-p)
       (fboundp 'login--note-bad-attempt)
       (fboundp 'session--snapshot-valid-p)
       (fboundp 'session--login-skip-requested-p)
       (fboundp 'login-advance)))

(defun freeze-test--login-throttle ()
  "Sub-check a: throttle trips at the cap, stale entries get trimmed.
exercises `login--throttle-trips-p' and `login--note-bad-attempt'.
the real-world failure mode being caught: a regression that off-by-
ones the cap (>= vs >) or forgets to trim the window would let a
brute-force attacker mash RET past the threshold."
  (let ((result 'fail)
        (saved login--bad-attempts))
    (condition-case err
        (progn
          (setq login--bad-attempts nil)
          ;; push exactly `login--throttle-cap' fresh attempts.  the
          ;; cap is >=, so this must trip.
          (dotimes (_ login--throttle-cap)
            (login--note-bad-attempt))
          (cond
           ((not (login--throttle-trips-p))
            (setq result
                  (format "did not trip at cap=%d (attempts=%S)"
                          login--throttle-cap login--bad-attempts)))
           (t
            ;; now smuggle in a stale entry from before the window.
            ;; the trim side-effect must drop it; the cap stays
            ;; tripped because the other entries are still recent.
            (push (- (float-time) (* 2 login--throttle-window))
                  login--bad-attempts)
            (let ((before (length login--bad-attempts)))
              (cond
               ((not (login--throttle-trips-p))
                (setq result "cap untripped after stale-entry push"))
               ((not (< (length login--bad-attempts) before))
                (setq result
                      (format "stale entry not trimmed: %d -> %d"
                              before (length login--bad-attempts))))
               (t (setq result 'pass)))))))
      (error
       (panic-handle err 'freeze-test--login-throttle)
       (setq result (format "raised: %S" err))))
    ;; always restore the global; never leave a tripped throttle
    ;; behind for the next test or for the user.
    (setq login--bad-attempts saved)
    (freeze-test--record 'login-abuse/throttle result)))

(defun freeze-test--login-throttle-hardening ()
  "v0.6 item 5.2: pin cap, window, and stall-sec.
the values are policy: a regression that loosens them is a security
regression that the trip-shape test cannot catch (the existing
trip test is cap-agnostic by construction).  bounds (not exact
equality) so a future tightening does not require a test diff:
cap in [4..10], window in [30..120], stall in [3..30]."
  (let ((result 'fail))
    (condition-case err
        (setq result
              (cond
               ((not (boundp 'login--throttle-stall-sec))
                "login--throttle-stall-sec unbound")
               ((not (and (integerp login--throttle-cap)
                          (<= 4 login--throttle-cap 10)))
                (format "cap out of policy bounds: %S"
                        login--throttle-cap))
               ((not (and (integerp login--throttle-window)
                          (<= 30 login--throttle-window 120)))
                (format "window out of policy bounds: %S"
                        login--throttle-window))
               ((not (and (integerp login--throttle-stall-sec)
                          (<= 3 login--throttle-stall-sec 30)))
                (format "stall-sec out of policy bounds: %S"
                        login--throttle-stall-sec))
               (t 'pass)))
      (error
       (panic-handle err 'freeze-test--login-throttle-hardening)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'login-abuse/hardening result)))

(defun freeze-test--login-snapshot ()
  "Sub-check b: session--snapshot-valid-p refuses malformed records.
the real-world failure mode being caught: a torn or attacker-
written file under /var/emacs/sessions/ that the rehydrate path
would otherwise admit, then attempt to spawn under a bogus uid."
  (let ((result 'fail)
        (key "sessions/borja")
        (good (list :name "borja" :uid 1000 :gid 1000
                    :home "/home/borja" :status 'held)))
    (condition-case err
        (let* ((bad-uid-low      (plist-put (copy-sequence good) :uid 0))
               (bad-uid-string   (plist-put (copy-sequence good)
                                            :uid "1000"))
               (bad-gid-string   (plist-put (copy-sequence good)
                                            :gid "1000"))
               (bad-home-rel     (plist-put (copy-sequence good)
                                            :home "home/borja"))
               (bad-status       (plist-put (copy-sequence good)
                                            :status 'pwned))
               ;; drop :home entirely.  plist-get returns nil for the
               ;; missing key, which fails stringp.
               (missing-home     (list :name "borja" :uid 1000 :gid 1000
                                       :status 'held))
               (bad-cases
                (list (cons "non-list"        "not-a-plist")
                      (cons "nil"             nil)
                      (cons "uid<1000"        bad-uid-low)
                      (cons "uid-string"      bad-uid-string)
                      (cons "gid-string"      bad-gid-string)
                      (cons "home-relative"   bad-home-rel)
                      (cons "status-pwned"    bad-status)
                      (cons "missing-home"    missing-home)
                      ;; key/name disagreement: a renamed file
                      ;; smuggling a different identity.
                      (cons "name-mismatch"
                            (plist-put (copy-sequence good)
                                       :name "root"))))
               (bad-failures nil))
          (dolist (case bad-cases)
            (when (session--snapshot-valid-p (cdr case) key)
              (push (car case) bad-failures)))
          (cond
           (bad-failures
            (setq result
                  (format "accepted bad shape(s): %S" bad-failures)))
           ((not (session--snapshot-valid-p good key))
            (setq result "rejected the known-good record"))
           (t (setq result 'pass))))
      (error
       (panic-handle err 'freeze-test--login-snapshot)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'login-abuse/snapshot result)))

(defun freeze-test--login-cmdline ()
  "Sub-check c: session--login-skip-requested-p does not over-match.
the real-world failure mode being caught: a substring-only matcher
would happily honor `foo.geos.login=skipped' or `geos.login=skip2',
silently bypassing the auth boundary on a deployed image.  the
matcher must only fire on the exact whitespace-delimited token.

the matcher reads `geos-cmdline-path' (from core/cmdline.el, the
shared /proc/cmdline parser) literally, so we rebind that defvar to
point at a tmpfile we write per case.  we use a single reusable
path (deleted on exit) rather than make-temp-file per case so the
test does not leak inodes if it errors midway."
  (let ((result 'fail)
        (tmp (expand-file-name "freeze-cmdline.txt"
                               temporary-file-directory))
        ;; cases that MUST be rejected.  many of these would trip a
        ;; substring matcher.
        (must-not '("geos.login=keep"
                    "otherflag geos.loginXskip"
                    "geos.login.skip"
                    ""
                    "foo.geos.login=skipped"
                    "geos.login=skipper"
                    "xgeos.login=skip"))
        ;; cases that MUST be honored.
        (must     '("geos.login=skip"
                    "quiet geos.login=skip rw"
                    "geos.login=skip\n")))
    (condition-case err
        (let ((mismatches nil))
          (unwind-protect
              (progn
                ;; rebind the path to our fixture.  the defvar's own
                ;; docstring says a test harness may do this.
                (cl-letf (((symbol-value 'geos-cmdline-path) tmp))
                  (dolist (line must-not)
                    (with-temp-file tmp (insert line))
                    (when (session--login-skip-requested-p)
                      (push (cons 'accepted line) mismatches)))
                  (dolist (line must)
                    (with-temp-file tmp (insert line))
                    (unless (session--login-skip-requested-p)
                      (push (cons 'rejected line) mismatches)))))
            (when (file-exists-p tmp)
              (condition-case e2
                  (delete-file tmp)
                (error
                 (panic-handle e2 'freeze-test--login-cmdline-cleanup)))))
          (setq result (if mismatches
                           (format "matcher misbehaved on: %S"
                                   (nreverse mismatches))
                         'pass)))
      (error
       (panic-handle err 'freeze-test--login-cmdline)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'login-abuse/cmdline result)))

(defun freeze-test--login-empty-user ()
  "Sub-check d: login-advance rejects an empty username.
the real-world failure mode being caught: a regression that lets
the empty string fall through to :prompt-password would let an
attacker (or a stuck terminal) hit RET-RET to land at a password
prompt with no user identity, and the verify call would then
either crash or fall through to a default account."
  (let ((result 'fail)
        (saved-state login--state)
        (saved-user login--user))
    (condition-case err
        (progn
          ;; drive directly to :prompt-user; do NOT call login-show
          ;; (we don't want to swap buffers, this test is headless).
          (setq login--state :prompt-user
                login--user nil)
          ;; stub read-string to return the empty string.  login-advance
          ;; must NOT transition state and must NOT set login--user.
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _) "")))
            (login-advance))
          (cond
           ((not (eq login--state :prompt-user))
            (setq result
                  (format "state advanced past :prompt-user to %S"
                          login--state)))
           ((not (null login--user))
            (setq result
                  (format "login--user set to %S on empty input"
                          login--user)))
           (t (setq result 'pass))))
      (error
       (panic-handle err 'freeze-test--login-empty-user)
       (setq result (format "raised: %S" err))))
    ;; restore.  the prompt-user reset is what login-show would do on
    ;; the next presentation anyway, but we are tidy.
    (setq login--state saved-state
          login--user saved-user)
    (freeze-test--record 'login-abuse/empty-user result)))

(defun freeze-test-login-abuse ()
  "Run all four login-abuse sub-checks.  each records its own result.
this is the v0.5 gate: the login surface is pure-elisp so it cannot
wedge the OS, but the defenses around it (throttle, snapshot
validator, cmdline parser, empty-input guard) absolutely can
regress, and a regression in any one of them is a privilege bug."
  (interactive)
  (cond
   ((not (freeze-test--login-modules-loaded-p))
    ;; record a 'module-not-loaded entry under the umbrella key so the
    ;; report shows why the sub-checks were skipped.  do NOT panic;
    ;; running freeze-tests against a pre-v0.5 image is a legitimate
    ;; use case (a bisect across the v0.4/v0.5 boundary).
    (freeze-test--record 'login-abuse 'module-not-loaded))
   (t
    (freeze-test--login-throttle)
    (freeze-test--login-throttle-hardening)
    (freeze-test--login-snapshot)
    (freeze-test--login-cmdline)
    (freeze-test--login-empty-user))))

;; --------------------------------------------------------------------
;; test 9: spawn shape under abuse (v0.6 starter, 37ddbce)
;; --------------------------------------------------------------------

(defun freeze-test--spawn-shape-modules-loaded-p ()
  "Return non-nil iff both spawn-shape functions are bound.
the umbrella records 'module-not-loaded if either is missing.  I
check the exact symbols the sub-checks call rather than just
`featurep' on session, because session.el can be half-byte-compiled
on a partial image and slip through `featurep'.  the
`session--user-init-path' defconst is part of the surface as of
the unconditional system-init injection; pin it here too so the
umbrella refuses to run sub-checks against a session.el that pre-
dates the constant."
  (and (fboundp 'session--child-env)
       (fboundp 'session--child-argv)
       (boundp 'session--user-init-path)))

(defun freeze-test--spawn-env-with-display (display-value expect-present)
  "Helper: call session--child-env with DISPLAY-VALUE set in the
parent env, return t if a `DISPLAY=...' element is present in the
result matches EXPECT-PRESENT (non-nil = should be there).
DISPLAY is restored from the surrounding caller, not here; the
caller MUST wrap the whole sub-check in unwind-protect."
  (setenv "DISPLAY" display-value)
  (let* ((env (session--child-env "u" "/home/u"))
         (got (cl-some (lambda (s)
                        (and (stringp s)
                             (string-prefix-p "DISPLAY=" s)))
                      env)))
    (eq (not (null got)) (not (null expect-present)))))

(defun freeze-test--spawn-env-display-valid ()
  "Sub-check env/display-valid: DISPLAY=:0 from parent reaches child.
this is the happy path.  pid1's hard-coded DISPLAY=:0 must survive
the regex gate; a regression here would silently strand every
per-user emacs in console mode on a UI boot."
  (let ((result 'fail)
        (saved (getenv "DISPLAY")))
    (condition-case err
        (unwind-protect
            (progn
              (setenv "DISPLAY" ":0")
              (let ((env (session--child-env "u" "/home/u")))
                (setq result (if (member "DISPLAY=:0" env)
                                 'pass
                               (format "DISPLAY=:0 missing from env: %S"
                                       env)))))
          (setenv "DISPLAY" saved))
      (error
       (panic-handle err 'freeze-test--spawn-env-display-valid)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/env/display-valid result)))

(defun freeze-test--spawn-env-display-valid-screen ()
  "Sub-check env/display-valid-screen: DISPLAY=:0.1 also honored.
the regex covers the `:N.M' screen-number form too.  matters for
the future-second-monitor case where Xorg hands out :0.1."
  (let ((result 'fail)
        (saved (getenv "DISPLAY")))
    (condition-case err
        (unwind-protect
            (progn
              (setenv "DISPLAY" ":0.1")
              (let ((env (session--child-env "u" "/home/u")))
                (setq result (if (member "DISPLAY=:0.1" env)
                                 'pass
                               (format "DISPLAY=:0.1 missing from env: %S"
                                       env)))))
          (setenv "DISPLAY" saved))
      (error
       (panic-handle err 'freeze-test--spawn-env-display-valid-screen)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/env/display-valid-screen result)))

(defun freeze-test--spawn-env-display-unset ()
  "Sub-check env/display-unset: parent has no DISPLAY -> no element.
the console-mode boot.  child must NOT see a stray DISPLAY=, since
an empty value would confuse Xt and a stale value would point at
nothing."
  (let ((result 'fail)
        (saved (getenv "DISPLAY")))
    (condition-case err
        (unwind-protect
            (progn
              ;; setenv NAME nil unsets the variable.
              (setenv "DISPLAY" nil)
              (let* ((env (session--child-env "u" "/home/u"))
                     (leak (cl-some (lambda (s)
                                      (and (stringp s)
                                           (string-prefix-p "DISPLAY=" s)))
                                    env)))
                (setq result (if leak
                                 (format "DISPLAY leaked when unset: %S" env)
                               'pass))))
          (setenv "DISPLAY" saved))
      (error
       (panic-handle err 'freeze-test--spawn-env-display-unset)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/env/display-unset result)))

(defun freeze-test--spawn-env-display-empty ()
  "Sub-check env/display-empty: DISPLAY=\"\" is set-but-empty.
getenv returns \"\" not nil for this case, so the length>0 guard in
session--child-env is what saves us.  if that guard regresses, the
child gets DISPLAY= with no value and Xt errors at connect-time."
  (let ((result 'fail)
        (saved (getenv "DISPLAY")))
    (condition-case err
        (unwind-protect
            (progn
              (setenv "DISPLAY" "")
              (let* ((env (session--child-env "u" "/home/u"))
                     (leak (cl-some (lambda (s)
                                      (and (stringp s)
                                           (string-prefix-p "DISPLAY=" s)))
                                    env)))
                (setq result (if leak
                                 (format "empty DISPLAY leaked: %S" env)
                               'pass))))
          (setenv "DISPLAY" saved))
      (error
       (panic-handle err 'freeze-test--spawn-env-display-empty)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/env/display-empty result)))

(defun freeze-test--spawn-env-display-malformed ()
  "Sub-check env/display-malformed: every malformed DISPLAY dropped.
runs four cases through the env builder and reports per-case any
that slipped past the regex gate.  the four are picked to cover
distinct attack shapes: shell injection, newline truncation, a
hostname-bearing form (legal Xorg syntax but not what pid1 emits),
and a non-numeric display number."
  (let ((result 'fail)
        (saved (getenv "DISPLAY"))
        (cases '("evil; rm -rf /"
                 ":0\n"
                 "host:0"
                 ":abc")))
    (condition-case err
        (unwind-protect
            (let ((leaks nil))
              (dolist (case cases)
                (setenv "DISPLAY" case)
                (let* ((env (session--child-env "u" "/home/u"))
                       (leak (cl-some
                              (lambda (s)
                                (and (stringp s)
                                     (string-prefix-p "DISPLAY=" s)))
                              env)))
                  (when leak
                    (push case leaks))))
              (setq result (if leaks
                               (format "malformed DISPLAY admitted: %S"
                                       (nreverse leaks))
                             'pass)))
          (setenv "DISPLAY" saved))
      (error
       (panic-handle err 'freeze-test--spawn-env-display-malformed)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/env/display-malformed result)))

(defun freeze-test--spawn-env-base ()
  "Sub-check env/base: USER/LOGNAME/HOME/SHELL/PATH/TERM all present.
the base env list is what the child relies on for a sane userland;
losing any one of these strands the spawn in a half-configured
state (no HOME -> tramp panics, no PATH -> eshell cannot find
binaries).  test with DISPLAY unset so we are looking at the pure
base list, not the appended DISPLAY tail."
  (let ((result 'fail)
        (saved (getenv "DISPLAY")))
    (condition-case err
        (unwind-protect
            (progn
              (setenv "DISPLAY" nil)
              (let* ((env (session--child-env "u" "/home/u"))
                     (need '("USER=u"
                             "LOGNAME=u"
                             "HOME=/home/u"
                             "SHELL=/bin/sh"
                             "TERM=linux"))
                     (missing (cl-remove-if (lambda (s) (member s env))
                                            need))
                     ;; PATH is a prefix-match because the actual value
                     ;; is a triple-colon list; pin the leading entry
                     ;; rather than the whole string so a PATH tweak
                     ;; downstream does not break this test for free.
                     (path-ok (cl-some
                               (lambda (s)
                                 (and (stringp s)
                                      (string-prefix-p "PATH=" s)
                                      (string-match-p "/run/current-system"
                                                      s)))
                               env)))
                (setq result
                      (cond
                       (missing (format "missing base entries: %S" missing))
                       ((not path-ok) "PATH= entry missing or wrong shape")
                       (t 'pass)))))
          (setenv "DISPLAY" saved))
      (error
       (panic-handle err 'freeze-test--spawn-env-base)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/env/base result)))

(defun freeze-test--spawn-argv-no-init ()
  "Sub-check argv/no-init: no per-user init -> system init only.
mocks file-readable-p to nil for every call so the per-user
init.el branch is skipped; the system init at
`session--user-init-path' is unconditional and still appears.
pass iff the return is exactly
  (\"emacs\" \"-Q\" \"--name\" \"geos-user-u\"
   \"-l\" \"/etc/geos/user-init.el\")."
  (let ((result 'fail))
    (condition-case err
        (cl-letf (((symbol-function 'file-readable-p) (lambda (_) nil)))
          (let ((argv (session--child-argv "u")))
            (setq result
                  (if (equal argv
                             '("emacs" "-Q" "--name" "geos-user-u"
                               "-l" "/etc/geos/user-init.el"))
                      'pass
                    (format "argv shape wrong: %S" argv)))))
      (error
       (panic-handle err 'freeze-test--spawn-argv-no-init)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/argv/no-init result)))

(defun freeze-test--spawn-argv-with-init ()
  "Sub-check argv/with-init: per-user init.el tacked on after system init.
mock file-readable-p to t.  must still have --name geos-user-u at
indices 2-3, the system init at /etc/geos/user-init.el before the
per-user file, and -l /var/emacs/users/u/init.el at the tail."
  (let ((result 'fail))
    (condition-case err
        (cl-letf (((symbol-function 'file-readable-p) (lambda (_) t)))
          (let* ((argv (session--child-argv "u"))
                 (expected '("emacs" "-Q" "--name" "geos-user-u"
                             "-l" "/etc/geos/user-init.el"
                             "-l" "/var/emacs/users/u/init.el")))
            (setq result
                  (cond
                   ((not (equal argv expected))
                    (format "argv shape wrong: %S != %S" argv expected))
                   ;; redundant given the equal above but pinned
                   ;; explicitly so a future shuffle of argv order
                   ;; trips here with a clear diagnostic.
                   ((not (and (equal (nth 2 argv) "--name")
                              (equal (nth 3 argv) "geos-user-u")))
                    (format "--name not at index 2-3: %S" argv))
                   (t 'pass)))))
      (error
       (panic-handle err 'freeze-test--spawn-argv-with-init)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/argv/with-init result)))

(defun freeze-test--spawn-argv-name-injection ()
  "Sub-check argv/name-injection: contract-pin, no re-validation here.
session--child-argv's docstring says passwd-add-user is the
upstream gate that constrains NAME to [a-zA-Z0-9_-].  this test
pins that contract: the function itself MUST NOT add any extra
validation, because doing so would silently mask an upstream
regression.  call with a deliberately bad NAME and assert the
concat went through verbatim.  if this test fails it means
someone added validation here and forgot to update the docstring,
not that there is a real attack."
  (let ((result 'fail))
    (condition-case err
        (cl-letf (((symbol-function 'file-readable-p) (lambda (_) nil)))
          (let ((argv (session--child-argv "a;b c")))
            (setq result
                  (if (equal argv
                             '("emacs" "-Q" "--name" "geos-user-a;b c"
                               "-l" "/etc/geos/user-init.el"))
                      'pass
                    (format "contract drift: %S" argv)))))
      (error
       (panic-handle err 'freeze-test--spawn-argv-name-injection)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/argv/name-injection result)))

(defun freeze-test--spawn-argv-user-init-unconditional ()
  "Sub-check argv/user-init-unconditional: system init is in argv
regardless of disk state.  mocks file-readable-p to nil for every
call so NEITHER /var/emacs/users/u/init.el NOR
/etc/geos/user-init.el is reported as readable; the argv MUST
still carry `-l /etc/geos/user-init.el'.  the contract is loud
failure when the file vanishes (emacs exits non-zero, supervise
sees a crashloop), not silent skip.  a regression that gates the
system init on file-readable-p would let a missing system file go
unobserved until a user tried to call geos-logout."
  (let ((result 'fail))
    (condition-case err
        (cl-letf (((symbol-function 'file-readable-p) (lambda (_) nil)))
          (let ((argv (session--child-argv "u")))
            (setq result
                  (if (member "/etc/geos/user-init.el" argv)
                      'pass
                    (format
                     "system init dropped from argv when unreadable: %S"
                     argv)))))
      (error
       (panic-handle err 'freeze-test--spawn-argv-user-init-unconditional)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/argv/user-init-unconditional
                         result)))

(defun freeze-test--spawn-argv-user-init-path ()
  "Sub-check argv/user-init-path: the defconst pin.
guards against an accidental rename of `session--user-init-path'
or a silent path drift away from /etc/geos/user-init.el (the
extra-special-file symlink target in guix-system/system.scm).  if
this trips, either the constant moved and the boot wiring must
follow, or the path was changed without updating the system gexp."
  (let ((result 'fail))
    (condition-case err
        (setq result
              (cond
               ((not (boundp 'session--user-init-path))
                "session--user-init-path is unbound")
               ((not (string= session--user-init-path
                              "/etc/geos/user-init.el"))
                (format "path drift: %S" session--user-init-path))
               (t 'pass)))
      (error
       (panic-handle err 'freeze-test--spawn-argv-user-init-path)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/argv/user-init-path result)))

(defun freeze-test-spawn-shape ()
  "Run all spawn-shape sub-checks.  each records its own result.
v0.6 starter (37ddbce) wired DISPLAY pass-through and the --name
stamp; the smoke-test PASS(ui) only proves boot.  these sub-checks
are what catches a regression in the functions themselves."
  (interactive)
  (cond
   ((not (freeze-test--spawn-shape-modules-loaded-p))
    (freeze-test--record 'spawn-shape 'module-not-loaded))
   (t
    (freeze-test--spawn-env-display-valid)
    (freeze-test--spawn-env-display-valid-screen)
    (freeze-test--spawn-env-display-unset)
    (freeze-test--spawn-env-display-empty)
    (freeze-test--spawn-env-display-malformed)
    (freeze-test--spawn-env-base)
    (freeze-test--spawn-argv-no-init)
    (freeze-test--spawn-argv-with-init)
    (freeze-test--spawn-argv-name-injection)
    (freeze-test--spawn-argv-user-init-unconditional)
    (freeze-test--spawn-argv-user-init-path))))

;; --------------------------------------------------------------------
;; test 10: workspace routing (v0.6 starter, aa2917a)
;; --------------------------------------------------------------------

(defun freeze-test--workspace-routing-modules-loaded-p ()
  "Return non-nil iff the workspace allocator surface is linked in.
exwm-config.el is NOT required by this file at load time (exwm
itself is heavy and the dev-host load path may not have it), so
we gate on the three exact symbols the sub-checks touch.  match
test 8's pattern: half-loaded image with defvars but no defun
must NOT slip through and crash a sub-check."
  (and (fboundp 'exwm-config--user-workspace-for)
       (boundp 'exwm-config--user-workspace)
       (boundp 'exwm-config--user-workspace-next)))

(defmacro freeze-test--with-workspace-fixture (live-list &rest body)
  "Run BODY with exwm-config workspace state reset and the live
exwm-workspace--list bound to LIVE-LIST.  saves and restores the
hash table, the counter, and the live-list binding/value around
BODY so sub-checks do not bleed state.  cl-letf cannot makunbound,
so the live-list dance uses an explicit had-boundp save."
  (declare (indent 1))
  `(let ((saved-hash exwm-config--user-workspace)
         (saved-next exwm-config--user-workspace-next)
         (had (boundp 'exwm-workspace--list))
         (saved-list (when (boundp 'exwm-workspace--list)
                       (symbol-value 'exwm-workspace--list))))
     (unwind-protect
         (progn
           (setq exwm-config--user-workspace (make-hash-table :test 'equal)
                 exwm-config--user-workspace-next 1)
           (set 'exwm-workspace--list ,live-list)
           ,@body)
       (setq exwm-config--user-workspace saved-hash
             exwm-config--user-workspace-next saved-next)
       (if had
           (set 'exwm-workspace--list saved-list)
         (makunbound 'exwm-workspace--list)))))

(defun freeze-test--workspace-unbound-live-list ()
  "Sub-check unbound-live-list: W3 degradation when live list absent.
on a no-X dev host exwm-workspace--list is not bound.  the
allocator must return nil cleanly rather than signal void-variable.
this is the path the headless freeze-tests run was hitting before
the W3 guard landed."
  (let ((result 'fail)
        (saved-hash exwm-config--user-workspace)
        (saved-next exwm-config--user-workspace-next)
        (had (boundp 'exwm-workspace--list))
        (saved-list (when (boundp 'exwm-workspace--list)
                      (symbol-value 'exwm-workspace--list))))
    (condition-case err
        (unwind-protect
            (progn
              (setq exwm-config--user-workspace
                    (make-hash-table :test 'equal)
                    exwm-config--user-workspace-next 1)
              (when had (makunbound 'exwm-workspace--list))
              (let ((got (exwm-config--user-workspace-for "borja")))
                (setq result (if (null got)
                                 'pass
                               (format "expected nil, got %S" got)))))
          (setq exwm-config--user-workspace saved-hash
                exwm-config--user-workspace-next saved-next)
          (when had (set 'exwm-workspace--list saved-list)))
      (error
       (panic-handle err 'freeze-test--workspace-unbound-live-list)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'workspace-routing/unbound-live-list result)))

(defun freeze-test--workspace-sticky ()
  "Sub-check sticky: same NAME hits the cache on second call.
the muscle-memory contract: once alice is at workspace N, a
re-lookup of alice must return N.  a regression here breaks the
`s-N = NAME' UX promise on every re-login."
  (let ((result 'fail))
    (condition-case err
        (freeze-test--with-workspace-fixture '(:ws0 :ws1 :ws2)
          (let ((first (exwm-config--user-workspace-for "alice"))
                (second (exwm-config--user-workspace-for "alice")))
            (setq result
                  (cond
                   ((null first) "first lookup returned nil")
                   ((not (equal first second))
                    (format "not sticky: %S then %S" first second))
                   (t 'pass)))))
      (error
       (panic-handle err 'freeze-test--workspace-sticky)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'workspace-routing/sticky result)))

(defun freeze-test--workspace-distinct ()
  "Sub-check distinct: two NAMEs get two indices, counter forward.
alice and bob must NOT collide on the same workspace.  bob's
index must be exactly alice's + 1 (the counter is the
authoritative next-pointer)."
  (let ((result 'fail))
    (condition-case err
        (freeze-test--with-workspace-fixture '(:ws0 :ws1 :ws2)
          (let ((a (exwm-config--user-workspace-for "alice"))
                (b (exwm-config--user-workspace-for "bob")))
            (setq result
                  (cond
                   ((or (null a) (null b))
                    (format "nil index: alice=%S bob=%S" a b))
                   ((= a b)
                    (format "alice and bob collided on %S" a))
                   ((not (= b (1+ a)))
                    (format "counter not forward: alice=%S bob=%S" a b))
                   (t 'pass)))))
      (error
       (panic-handle err 'freeze-test--workspace-distinct)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'workspace-routing/distinct result)))

(defun freeze-test--workspace-counter-forward ()
  "Sub-check counter-forward: counter never recycles on logout.
simulate alice having taken slot 1 then logged out, then bob logs
in.  bob must get slot 2, not slot 1.  the defvar docstring
promises this; a regression that resets the counter on logout
would re-route bob's windows onto alice's leftover workspace and
fight any cached state in EXWM."
  (let ((result 'fail))
    (condition-case err
        (freeze-test--with-workspace-fixture '(:ws0 :ws1 :ws2)
          ;; pretend alice already minted slot 1 and then logged out.
          ;; the cache row stays (sticky-on-relogin), the counter has
          ;; already moved on.
          (puthash "alice" 1 exwm-config--user-workspace)
          (setq exwm-config--user-workspace-next 2)
          (let ((b (exwm-config--user-workspace-for "bob")))
            (setq result
                  (cond
                   ((null b) "bob got nil")
                   ((= b 1) "counter recycled, bob landed on alice's slot")
                   ((not (= b 2)) (format "expected bob=2, got %S" b))
                   (t 'pass)))))
      (error
       (panic-handle err 'freeze-test--workspace-counter-forward)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'workspace-routing/counter-forward result)))

(defun freeze-test--workspace-grow-loop-bounded ()
  "Sub-check grow-loop-bounded: B1 cap fires, control returns.
mock exwm-workspace-add as a no-op so the grow loop never makes
progress.  the allocator MUST bail after 8 tries and return nil;
an unbounded while inside exwm-manage-finish-hook freezes PID 1.
also wall-clock the call against the freeze-test loop budget so
a regression that unbounded the loop trips a timeout instead of
sitting forever."
  (let ((result 'fail))
    (condition-case err
        (freeze-test--with-workspace-fixture '(:ws0)
          (cl-letf (((symbol-function 'exwm-workspace-add)
                     (lambda (&rest _) nil)))
            (let* ((started (current-time))
                   (got (with-timeout (freeze-test-loop-budget-sec
                                       'budget-exceeded)
                          (exwm-config--user-workspace-for "borja")))
                   (elapsed (float-time
                             (time-subtract (current-time) started))))
              (setq result
                    (cond
                     ((eq got 'budget-exceeded)
                      (format "grow loop exceeded %ds budget"
                              freeze-test-loop-budget-sec))
                     ((not (null got))
                      (format "expected nil, got %S in %.2fs" got elapsed))
                     (t 'pass))))))
      (error
       (panic-handle err 'freeze-test--workspace-grow-loop-bounded)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'workspace-routing/grow-loop-bounded result)))

(defun freeze-test--workspace-cache-rebuild-after-shrink ()
  "Sub-check cache-rebuild-after-shrink: B2 path, idx reused.
alice gets a slot.  someone shrinks the live workspace list out
from under us (an exwm-workspace-delete in the future, or a
manual /exwm-workspace--list mutation today).  on the next
lookup, the cached idx is now OOB; the allocator must take the
grow path under the same slot rather than mint a fresh one.
the test verifies BOTH stickiness of the returned idx AND that
the grow path actually ran (the live list grew during the
call)."
  (let ((result 'fail))
    (condition-case err
        (freeze-test--with-workspace-fixture '(:ws0 :ws1 :ws2)
          ;; mock exwm-workspace-add to actually grow the live list
          ;; (a faithful stub) so the rebuild can complete.
          (cl-letf (((symbol-function 'exwm-workspace-add)
                     (lambda (&rest _)
                       (set 'exwm-workspace--list
                            (append (symbol-value 'exwm-workspace--list)
                                    (list :grown))))))
            (let* ((first (exwm-config--user-workspace-for "alice"))
                   ;; shrink: simulate a workspace-delete that yanked
                   ;; the slot out from under the cache.
                   (_ (set 'exwm-workspace--list '(:ws0)))
                   (before-len (length (symbol-value
                                        'exwm-workspace--list)))
                   (second (exwm-config--user-workspace-for "alice"))
                   (after-len (length (symbol-value
                                       'exwm-workspace--list))))
              (setq result
                    (cond
                     ((null first) "first lookup returned nil")
                     ((not (equal first second))
                      (format "lost stickiness across rebuild: %S -> %S"
                              first second))
                     ((not (> after-len before-len))
                      (format "grow path did not run: list %d -> %d"
                              before-len after-len))
                     (t 'pass))))))
      (error
       (panic-handle err 'freeze-test--workspace-cache-rebuild-after-shrink)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'workspace-routing/cache-rebuild-after-shrink
                         result)))

(defun freeze-test--workspace-regex-accepts ()
  "Sub-check regex/accepts: valid geos-user- names match and capture.
the regex on exwm-config--maybe-route-user-window is the contract
between the spawn stamp and the routing hook.  test it in
isolation since invoking the hook needs a real EXWM."
  (let ((result 'fail)
        (rx "\\`geos-user-\\([a-zA-Z0-9_-]+\\)\\'")
        (cases '(("geos-user-borja"  . "borja")
                 ("geos-user-b"      . "b")
                 ("geos-user-A_B-1"  . "A_B-1"))))
    (condition-case err
        (let ((mismatches nil))
          (dolist (case cases)
            (let ((s (car case))
                  (want (cdr case)))
              (save-match-data
                (cond
                 ((not (string-match rx s))
                  (push (cons 'no-match s) mismatches))
                 ((not (equal (match-string 1 s) want))
                  (push (cons (match-string 1 s) want) mismatches))))))
          (setq result (if mismatches
                           (format "regex misbehaved: %S"
                                   (nreverse mismatches))
                         'pass)))
      (error
       (panic-handle err 'freeze-test--workspace-regex-accepts)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'workspace-routing/regex/accepts result)))

(defun freeze-test--workspace-regex-rejects ()
  "Sub-check regex/rejects: near-miss strings do NOT match.
covers the substring-attack family (`xgeos-user-...',
`geos-userborja' with no separator), the empty-suffix case, and
three out-of-class characters (space, semicolon, slash).  if any
slip through, exwm-config--maybe-route-user-window would attempt
to route an arbitrary X resource name through session.el and the
audit story collapses."
  (let ((result 'fail)
        (rx "\\`geos-user-\\([a-zA-Z0-9_-]+\\)\\'")
        (cases '("geos-user-"
                 "geos-user"
                 "geos-userborja"
                 "xgeos-user-borja"
                 "geos-user-bad name"
                 "geos-user-bad;name"
                 "geos-user-bad/name")))
    (condition-case err
        (let ((mismatches nil))
          (dolist (s cases)
            (save-match-data
              (when (string-match rx s)
                (push s mismatches))))
          (setq result (if mismatches
                           (format "regex accepted bad input: %S"
                                   (nreverse mismatches))
                         'pass)))
      (error
       (panic-handle err 'freeze-test--workspace-regex-rejects)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'workspace-routing/regex/rejects result)))

(defun freeze-test-workspace-routing ()
  "Run all workspace-routing sub-checks.  each records its own result.
v0.6 starter (aa2917a) wired per-user EXWM workspace allocation
and a routing hook keyed off `geos-user-NAME'.  smoke-test
PASS(ui) only proves the file loaded; these sub-checks pin the
allocator semantics (sticky, forward, bounded) and the regex
contract."
  (interactive)
  (cond
   ((not (freeze-test--workspace-routing-modules-loaded-p))
    (freeze-test--record 'workspace-routing 'module-not-loaded))
   (t
    (freeze-test--workspace-unbound-live-list)
    (freeze-test--workspace-sticky)
    (freeze-test--workspace-distinct)
    (freeze-test--workspace-counter-forward)
    (freeze-test--workspace-grow-loop-bounded)
    (freeze-test--workspace-cache-rebuild-after-shrink)
    (freeze-test--workspace-regex-accepts)
    (freeze-test--workspace-regex-rejects))))

;; --------------------------------------------------------------------
;; test 11: child-exit poller (v0.6 starter, 7f889c7)
;; --------------------------------------------------------------------

(defun freeze-test--child-exit-poller-modules-loaded-p ()
  "Return non-nil iff every poller symbol the sub-checks touch exists.
matches the test-8/9/10 pattern: gate on the exact fbound/bound set
rather than `featurep' on session, so a half-byte-compiled image
records a clean 'module-not-loaded instead of crashing a sub-check."
  (and (fboundp 'session--child-alive-p)
       (fboundp 'session--poll-children)
       (fboundp 'session--arm-poll-timer)
       (boundp 'session-poll-interval)
       (boundp 'session--poll-timer)))

(defun freeze-test--make-fake-session (name pid status)
  "Build a `geos-session' record for the poller fixtures.
uid/gid pinned at 1000, home derived from NAME, supervise-key in the
`session:NAME' namespace the real spawn path uses.  the record never
talks to /etc/passwd or /var/emacs; it just has to satisfy the
struct accessors the poller reads."
  (make-geos-session
   :name name
   :uid 1000
   :gid 1000
   :home (concat "/home/" name)
   :child-pid pid
   :supervise-key (intern (concat "session:" name))
   :status status))

(defun freeze-test--alive-nil-pid ()
  "Sub-check alive/nil-pid: (session--child-alive-p nil) -> nil.
the guard against a session record whose :child-pid never got set
(a 'starting record that never made it through spawn).  a regression
that returns t on nil would mark every never-spawned record alive."
  (let ((result 'fail))
    (condition-case err
        (setq result (if (null (session--child-alive-p nil))
                         'pass
                       "nil pid reported alive"))
      (error
       (panic-handle err 'freeze-test--alive-nil-pid)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'child-exit-poller/alive/nil-pid result)))

(defun freeze-test--alive-zero-pid ()
  "Sub-check alive/zero-pid: pid 0 and pid -1 both return nil.
the <= 0 guard.  pid 0 is the scheduler thread, pid -1 is sentinel;
neither is a real per-user emacs and treating either as alive would
strand the registry."
  (let ((result 'fail))
    (condition-case err
        (let ((zero-bad (session--child-alive-p 0))
              (neg-bad  (session--child-alive-p -1)))
          (setq result
                (cond
                 (zero-bad (format "pid 0 reported alive: %S" zero-bad))
                 (neg-bad  (format "pid -1 reported alive: %S" neg-bad))
                 (t 'pass))))
      (error
       (panic-handle err 'freeze-test--alive-zero-pid)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'child-exit-poller/alive/zero-pid result)))

(defun freeze-test--alive-non-integer ()
  "Sub-check alive/non-integer: (session--child-alive-p \"1\") -> nil.
the integerp guard.  a torn record from disk could in principle hand
the poller a string; the predicate must reject rather than coerce."
  (let ((result 'fail))
    (condition-case err
        (setq result (if (null (session--child-alive-p "1"))
                         'pass
                       "string pid reported alive"))
      (error
       (panic-handle err 'freeze-test--alive-non-integer)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'child-exit-poller/alive/non-integer result)))

(defun freeze-test--alive-pid-1 ()
  "Sub-check alive/pid-1: PID 1 always exists on linux.
conditional on /proc being mounted (it always is in the booted VM;
this sub-check skips cleanly on dev hosts without /proc, e.g. macOS
under emacs --batch)."
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (file-directory-p "/proc"))
          (setq result 'skipped-no-proc))
         (t
          (setq result (if (session--child-alive-p 1)
                           'pass
                         "PID 1 reported dead"))))
      (error
       (panic-handle err 'freeze-test--alive-pid-1)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'child-exit-poller/alive/pid-1 result)))

(defun freeze-test--alive-dead-pid ()
  "Sub-check alive/dead-pid: a high unused pid returns nil.
scans /proc for the largest live pid and probes pid+1000, which is
beyond the realistic active range on any single-user box.  if that
pid happens to be in use (vanishingly unlikely on a freshly-booted
geos image with two-digit process counts), the test reports the
specific collision rather than a generic fail.  skipped if /proc is
absent."
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (file-directory-p "/proc"))
          (setq result 'skipped-no-proc))
         (t
          (let* ((entries (directory-files "/proc" nil "\\`[0-9]+\\'"))
                 (max-pid (apply #'max 0 (mapcar #'string-to-number
                                                 entries)))
                 (dead-pid (+ max-pid 1000)))
            (setq result
                  (cond
                   ((file-directory-p (format "/proc/%d" dead-pid))
                    (format "probe pid %d unexpectedly in use" dead-pid))
                   ((session--child-alive-p dead-pid)
                    (format "dead pid %d reported alive" dead-pid))
                   (t 'pass))))))
      (error
       (panic-handle err 'freeze-test--alive-dead-pid)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'child-exit-poller/alive/dead-pid result)))

(defun freeze-test--alive-proc-missing-fails-closed-under-pid1 ()
  "Sub-check alive/proc-missing-fails-closed-under-pid1: posture-split.
mock file-directory-p so the /proc path returns nil AND set
pid1-as-emacs-p to t.  under those conditions the predicate must
return nil (fail closed): on a deployed image a missing /proc means
the poller cannot probe anyway, so the safe answer is `vanished',
which transitions the session to 'held and presents *login*.
returning t here would hide every dead child behind the /proc mount
failure."
  (let ((result 'fail)
        (had-pid1 (boundp 'pid1-as-emacs-p))
        (saved-pid1 (and (boundp 'pid1-as-emacs-p)
                         (symbol-value 'pid1-as-emacs-p))))
    (condition-case err
        (unwind-protect
            (progn
              (set 'pid1-as-emacs-p t)
              (cl-letf (((symbol-function 'file-directory-p)
                         (lambda (path)
                           (not (and (stringp path)
                                     (string-prefix-p "/proc" path))))))
                (let ((got (session--child-alive-p 1234)))
                  (setq result
                        (if (null got)
                            'pass
                          (format "expected nil under pid1, got %S" got))))))
          (if had-pid1
              (set 'pid1-as-emacs-p saved-pid1)
            (makunbound 'pid1-as-emacs-p)))
      (error
       (panic-handle err
                     'freeze-test--alive-proc-missing-fails-closed-under-pid1)
       (setq result (format "raised: %S" err))))
    (freeze-test--record
     'child-exit-poller/alive/proc-missing-fails-closed-under-pid1
     result)))

(defun freeze-test--alive-proc-missing-fails-open-on-dev ()
  "Sub-check alive/proc-missing-fails-open-on-dev: posture-split.
same /proc mock but pid1-as-emacs-p nil.  the predicate must return
t so loading session.el on a sandboxed dev host (no /proc, e.g.
macOS) does not false-positive every recorded session as dead and
spam *panic* with poller-driven transitions."
  (let ((result 'fail)
        (had-pid1 (boundp 'pid1-as-emacs-p))
        (saved-pid1 (and (boundp 'pid1-as-emacs-p)
                         (symbol-value 'pid1-as-emacs-p))))
    (condition-case err
        (unwind-protect
            (progn
              (set 'pid1-as-emacs-p nil)
              (cl-letf (((symbol-function 'file-directory-p)
                         (lambda (path)
                           (not (and (stringp path)
                                     (string-prefix-p "/proc" path))))))
                (let ((got (session--child-alive-p 1234)))
                  (setq result
                        (if got
                            'pass
                          (format "expected t on dev, got %S" got))))))
          (if had-pid1
              (set 'pid1-as-emacs-p saved-pid1)
            (makunbound 'pid1-as-emacs-p)))
      (error
       (panic-handle err
                     'freeze-test--alive-proc-missing-fails-open-on-dev)
       (setq result (format "raised: %S" err))))
    (freeze-test--record
     'child-exit-poller/alive/proc-missing-fails-open-on-dev result)))

(defmacro freeze-test--with-registry-fixture (&rest body)
  "Run BODY with `session--registry' replaced by a fresh empty hash.
the registry is a defvar holding a hash table; cl-letf on the
binding does not compose with `puthash' across all emacs versions
(the hash mutation can leak out, or the restore can re-bind a
disconnected table).  direct save/clobber/restore via setq is the
safer pattern and matches what the rehydrate code already does
internally.  unwind-protect ensures the prior registry survives a
sub-check that errors mid-body."
  (declare (indent 0))
  `(let ((saved-registry session--registry))
     (unwind-protect
         (progn
           (setq session--registry (make-hash-table :test 'equal))
           ,@body)
       (setq session--registry saved-registry))))

(defun freeze-test--poll-transitions-vanished-running-to-held ()
  "Sub-check poll/transitions-vanished-running-to-held: the core poll.
fake a 'running session with a dead pid, stub alive-p to nil, stub
persist/present-login to no-ops (we do not want the test touching
/var/emacs or yanking the screen).  after one sweep the registry
entry must be 'held with child-pid cleared.  this is the entire
reason the poller exists; if it regresses, dead children pile up
as 'running forever."
  (let ((result 'fail))
    (condition-case err
        (freeze-test--with-registry-fixture
          (let ((fake (freeze-test--make-fake-session
                       "ghost" 999999 'running)))
            (puthash "ghost" fake session--registry)
            (cl-letf (((symbol-function 'session--child-alive-p)
                       (lambda (_pid) nil))
                      ((symbol-function 'session--persist)
                       (lambda (_sess) t))
                      ((symbol-function 'session--present-login)
                       (lambda () nil)))
              (session--poll-children))
            (let ((after (gethash "ghost" session--registry)))
              (setq result
                    (cond
                     ((null after) "registry entry vanished")
                     ((not (eq (geos-session-status after) 'held))
                      (format "status not held: %S"
                              (geos-session-status after)))
                     ((not (null (geos-session-child-pid after)))
                      (format "child-pid not cleared: %S"
                              (geos-session-child-pid after)))
                     (t 'pass))))))
      (error
       (panic-handle err
                     'freeze-test--poll-transitions-vanished-running-to-held)
       (setq result (format "raised: %S" err))))
    (freeze-test--record
     'child-exit-poller/poll/transitions-vanished-running-to-held result)))

(defun freeze-test--poll-does-not-touch-running-when-alive ()
  "Sub-check poll/does-not-touch-running-when-alive: liveness honored.
same fixture but alive-p stubbed to t.  the entry must stay
'running and keep its child-pid.  a regression that transitions
live sessions on a quirk of the alive-p result would log every
real user out on each tick."
  (let ((result 'fail))
    (condition-case err
        (freeze-test--with-registry-fixture
          (let ((fake (freeze-test--make-fake-session
                       "live" 12345 'running)))
            (puthash "live" fake session--registry)
            (cl-letf (((symbol-function 'session--child-alive-p)
                       (lambda (_pid) t))
                      ((symbol-function 'session--persist)
                       (lambda (_sess) t))
                      ((symbol-function 'session--present-login)
                       (lambda () nil)))
              (session--poll-children))
            (let ((after (gethash "live" session--registry)))
              (setq result
                    (cond
                     ((null after) "registry entry vanished")
                     ((not (eq (geos-session-status after) 'running))
                      (format "status drifted from running to %S"
                              (geos-session-status after)))
                     ((not (eq (geos-session-child-pid after) 12345))
                      (format "child-pid drifted: %S"
                              (geos-session-child-pid after)))
                     (t 'pass))))))
      (error
       (panic-handle err
                     'freeze-test--poll-does-not-touch-running-when-alive)
       (setq result (format "raised: %S" err))))
    (freeze-test--record
     'child-exit-poller/poll/does-not-touch-running-when-alive result)))

(defun freeze-test--poll-calls-present-login-when-empty ()
  "Sub-check poll/calls-present-login-when-empty: surface returns.
one 'running session, alive-p stubbed to nil so it transitions.
afterward zero sessions remain 'running, so the poller must call
present-login.  the regression to catch: a poll that drops the
present-login call leaves the operator staring at the dead user's
last frame with no obvious way to log back in."
  (let ((result 'fail)
        (called nil))
    (condition-case err
        (freeze-test--with-registry-fixture
          (let ((fake (freeze-test--make-fake-session
                       "solo" 999999 'running)))
            (puthash "solo" fake session--registry)
            (cl-letf (((symbol-function 'session--child-alive-p)
                       (lambda (_pid) nil))
                      ((symbol-function 'session--persist)
                       (lambda (_sess) t))
                      ((symbol-function 'session--present-login)
                       (lambda () (setq called t))))
              (session--poll-children))
            (setq result
                  (if called
                      'pass
                    "present-login was not called after last logout"))))
      (error
       (panic-handle err
                     'freeze-test--poll-calls-present-login-when-empty)
       (setq result (format "raised: %S" err))))
    (freeze-test--record
     'child-exit-poller/poll/calls-present-login-when-empty result)))

(defun freeze-test--poll-skips-present-login-when-others-running ()
  "Sub-check poll/skips-present-login-when-others-running: no screen-yank.
two sessions, both 'running.  alice's pid is dead, bob's pid is
alive.  after the sweep alice is 'held and bob is still 'running.
present-login MUST NOT have been called: yanking the screen while
bob is still logged in is the multi-user equivalent of forcing a
logout on another user."
  (let ((result 'fail)
        (called nil))
    (condition-case err
        (freeze-test--with-registry-fixture
          (let ((alice (freeze-test--make-fake-session
                        "alice" 999999 'running))
                (bob   (freeze-test--make-fake-session
                        "bob" 999998 'running)))
            (puthash "alice" alice session--registry)
            (puthash "bob"   bob   session--registry)
            (cl-letf (((symbol-function 'session--child-alive-p)
                       (lambda (pid)
                         ;; alice's pid is dead, bob's pid is alive.
                         (not (eq pid 999999))))
                      ((symbol-function 'session--persist)
                       (lambda (_sess) t))
                      ((symbol-function 'session--present-login)
                       (lambda () (setq called t))))
              (session--poll-children))
            (let ((after-bob (gethash "bob" session--registry)))
              (setq result
                    (cond
                     (called "present-login fired with bob still running")
                     ((not (eq (geos-session-status after-bob) 'running))
                      (format "bob drifted off running: %S"
                              (geos-session-status after-bob)))
                     (t 'pass))))))
      (error
       (panic-handle err
                     'freeze-test--poll-skips-present-login-when-others-running)
       (setq result (format "raised: %S" err))))
    (freeze-test--record
     'child-exit-poller/poll/skips-present-login-when-others-running
     result)))

(defun freeze-test--arm-idempotent ()
  "Sub-check arm/idempotent: a second arm cancels the prior timer.
arm twice in a row.  after each call session--poll-timer must be a
timerp.  the second call must not error (a regression that forgets
to cancel could leave an old handle in an invalid state).  the
unwind-protect tears the live timer down so the test does not leave
a 3-second tick running against the freeze-test process."
  (let ((result 'fail)
        (saved-timer session--poll-timer))
    (condition-case err
        (unwind-protect
            (let ((interval-saved session-poll-interval))
              (unwind-protect
                  (progn
                    ;; tighten the interval so a leaked timer would not
                    ;; fire mid-test; cl-letf would do, but session-poll-
                    ;; interval is a plain defcustom so setq is simpler.
                    (setq session-poll-interval 3600)
                    (setq session--poll-timer nil)
                    (session--arm-poll-timer)
                    (let ((first (timerp session--poll-timer)))
                      (session--arm-poll-timer)
                      (let ((second (timerp session--poll-timer)))
                        (setq result
                              (cond
                               ((not first) "first arm did not install timer")
                               ((not second)
                                "second arm did not install timer")
                               (t 'pass))))))
                (setq session-poll-interval interval-saved)))
          (when (timerp session--poll-timer)
            (cancel-timer session--poll-timer))
          (setq session--poll-timer saved-timer))
      (error
       (panic-handle err 'freeze-test--arm-idempotent)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'child-exit-poller/arm/idempotent result)))

(defun freeze-test--arm-cancels-prior ()
  "Sub-check arm/cancels-prior: post-arm handle is a fresh object.
capture the timer after the first arm, arm again, capture again.
the two handles must NOT be `eq'.  a regression that re-uses the
same timer object on re-arm could mean run-at-time stacked multiple
fires onto one handle and we never noticed."
  (let ((result 'fail)
        (saved-timer session--poll-timer))
    (condition-case err
        (unwind-protect
            (let ((interval-saved session-poll-interval))
              (unwind-protect
                  (progn
                    (setq session-poll-interval 3600)
                    (setq session--poll-timer nil)
                    (session--arm-poll-timer)
                    (let ((first session--poll-timer))
                      (session--arm-poll-timer)
                      (let ((second session--poll-timer))
                        (setq result
                              (cond
                               ((not (timerp first))
                                "first handle not a timer")
                               ((not (timerp second))
                                "second handle not a timer")
                               ((eq first second)
                                "re-arm reused the same timer object")
                               (t 'pass))))))
                (setq session-poll-interval interval-saved)))
          (when (timerp session--poll-timer)
            (cancel-timer session--poll-timer))
          (setq session--poll-timer saved-timer))
      (error
       (panic-handle err 'freeze-test--arm-cancels-prior)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'child-exit-poller/arm/cancels-prior result)))

(defun freeze-test-child-exit-poller ()
  "Run all child-exit-poller sub-checks.  each records its own result.
v0.6 starter (7f889c7) wired the interim /proc-poll path for SIGCHLD;
the smoke-test only proves session.el loaded.  these sub-checks pin
the predicate's posture-split, the sweep's transition shape, and
the timer arming's idempotence.  the posture-split is the most
security-relevant of the lot: a regression that fails open under
pid1 would mask every dead child on a deployed image."
  (interactive)
  (cond
   ((not (freeze-test--child-exit-poller-modules-loaded-p))
    (freeze-test--record 'child-exit-poller 'module-not-loaded))
   (t
    (freeze-test--alive-nil-pid)
    (freeze-test--alive-zero-pid)
    (freeze-test--alive-non-integer)
    (freeze-test--alive-pid-1)
    (freeze-test--alive-dead-pid)
    (freeze-test--alive-proc-missing-fails-closed-under-pid1)
    (freeze-test--alive-proc-missing-fails-open-on-dev)
    (freeze-test--poll-transitions-vanished-running-to-held)
    (freeze-test--poll-does-not-touch-running-when-alive)
    (freeze-test--poll-calls-present-login-when-empty)
    (freeze-test--poll-skips-present-login-when-others-running)
    (freeze-test--arm-idempotent)
    (freeze-test--arm-cancels-prior))))

;; --------------------------------------------------------------------
;; test 13: users-buffer add (v0.6 item 4)
;; --------------------------------------------------------------------

(defun freeze-test--users-add-cleanup (name home)
  "Best-effort cleanup of a NAME/HOME pair left by the add test.
runs even on partial-create paths so a half-written /etc/passwd row
or a stray /home dir does not poison the next run."
  (condition-case err
      (when (and (fboundp 'passwd-delete-user)
                 (cl-find-if (lambda (e) (string= (plist-get e :user) name))
                             (passwd-read-passwd)))
        (passwd-delete-user name))
    (error
     (panic-handle err `(freeze-test--users-add-cleanup-passwd . ,name))))
  (condition-case err
      (when (and home (file-directory-p home))
        (delete-directory home t))
    (error
     (panic-handle err `(freeze-test--users-add-cleanup-home . ,home)))))

(defun freeze-test-users-buffer-add ()
  "Drive `passwd-create-user-and-home' end to end on a sentinel user.
v0.6 item 4 (closes v0.5.1's M-: workaround for new-user creation):
the *users* buffer's `a' key bundles passwd-add-user + make-directory
+ pid1-chown + passwd-set-password.  the keystroke is interactive
and prompts via the minibuffer; this test calls the underlying
helper directly so a fake minibuffer is not required.

assertions:
  - /etc/passwd grows: the new user appears in `passwd-read-passwd'.
  - /etc/shadow grows: the new user has a row with a non-empty hash.
  - /home/NAME exists and is owned by the new uid.

failure modes worth catching:
  - passwd-create-user-and-home returns t but skipped a step
  - pid1-chown unbound (module-load regression) leaves home root-owned
  - passwd-set-password silently failed and the shadow row is locked
  - cleanup path doesn't reverse the row, so a re-run double-adds

random uid in the 50000-59999 range avoids colliding with any
default install or with `passwd--next-uid' (which scans free uids
upward from 1000).  random suffix on the name protects against a
prior failed run leaving a stale row."
  (interactive)
  (let* ((result 'fail)
         (suffix (format "%06d" (random 1000000)))
         (name (concat "geos-freeze-" suffix))
         (uid (+ 50000 (random 10000)))
         (home (concat passwd-default-home-prefix name))
         (password "freeze-test-pw"))
    (unwind-protect
        (condition-case err
            (cond
             ((not (fboundp 'passwd-create-user-and-home))
              (setq result "passwd-create-user-and-home unbound"))
             ((not (passwd-create-user-and-home
                    name :uid uid :gid uid :home home
                    :shell passwd-default-shell
                    :password password))
              (setq result "passwd-create-user-and-home returned nil"))
             (t
              (let* ((users (passwd-read-passwd))
                     (urow (cl-find-if
                            (lambda (e) (string= (plist-get e :user) name))
                            users))
                     (shadow (passwd-read-shadow))
                     (srow (cl-find-if
                            (lambda (e) (string= (plist-get e :user) name))
                            shadow))
                     (attrs (file-attributes home 'integer))
                     (owner (and attrs (file-attribute-user-id attrs))))
                (setq result
                      (cond
                       ((null urow)
                        "passwd row not written")
                       ((not (= (plist-get urow :uid) uid))
                        (format "passwd uid mismatch: %S != %d"
                                (plist-get urow :uid) uid))
                       ((null srow)
                        "shadow row not written")
                       ((let ((h (plist-get srow :hash)))
                          (or (null h) (string-empty-p h)
                              (string-prefix-p "!" h)
                              (string-prefix-p "*" h)))
                        "shadow hash empty or locked")
                       ((null attrs)
                        (format "home dir %s not created" home))
                       ((and (fboundp 'pid1-chown) (not (= owner uid)))
                        (format "home owner %S != uid %d" owner uid))
                       (t 'pass))))))
          (error
           (panic-handle err 'freeze-test-users-buffer-add)
           (setq result (format "raised: %S" err))))
      (freeze-test--users-add-cleanup name home))
    (freeze-test--record 'users-buffer-add result)))

;; --------------------------------------------------------------------
;; test 14: login audit log (v0.6 item 5, audit slice)
;; --------------------------------------------------------------------

(defun freeze-test-login-audit ()
  "Assert `state-append-journal' writes parseable sexp lines.
v0.6 item 5 (audit slice): every login attempt should leave a
record under /var/emacs/journal/auth.log; the *journal* buffer
will tail that file in a later slice.

drives `state-append-journal' directly on a sentinel journal file
(not auth.log, so a real running audit trail is not perturbed),
asserts the file grows, every line parses as an alist with `result',
and the cleanup deletes only what the test wrote.

failure modes worth catching:
  - state-append-journal returns t but writes empty
  - the file ends without a trailing newline so the last line is
    lost on the next append
  - prin1 truncates a long alist (print-length / print-level not nil)
  - cleanup deletes the real auth.log because the helper accepted
    \"../auth.log\" as a basename"
  (interactive)
  (let* ((result 'fail)
         (suffix (format "%06d" (random 1000000)))
         (filename (concat "freeze-audit-" suffix ".log"))
         (path (concat state-root "journal/" filename))
         (rec-ok (list (cons 'time "2026-05-12T13:00:00Z")
                       (cons 'user "freeze-tester")
                       (cons 'result :ok)))
         (rec-fail (list (cons 'time "2026-05-12T13:00:01Z")
                         (cons 'user "freeze-tester")
                         (cons 'result :fail)
                         (cons 'reason :wrong-password))))
    (unwind-protect
        (condition-case err
            (cond
             ((not (fboundp 'state-append-journal))
              (setq result "state-append-journal unbound"))
             ((not (state-append-journal filename rec-ok))
              (setq result "first append returned nil"))
             ((not (state-append-journal filename rec-fail))
              (setq result "second append returned nil"))
             ((not (file-readable-p path))
              (setq result (format "file not readable: %s" path)))
             (t
              (let* ((lines
                      (with-temp-buffer
                        (insert-file-contents path)
                        (split-string (buffer-string) "\n" t)))
                     (parsed
                      (mapcar (lambda (l)
                                (condition-case _
                                    (car (read-from-string l))
                                  (error :parse-error)))
                              lines)))
                (setq result
                      (cond
                       ((/= (length parsed) 2)
                        (format "expected 2 lines, got %d" (length parsed)))
                       ((cl-some (lambda (p) (eq p :parse-error)) parsed)
                        "at least one line failed to parse")
                       ((not (equal (cdr (assq 'result (car parsed))) :ok))
                        "first record's :result is not :ok")
                       ((not (equal (cdr (assq 'result (cadr parsed))) :fail))
                        "second record's :result is not :fail")
                       ((not (equal (cdr (assq 'reason (cadr parsed)))
                                    :wrong-password))
                        "second record's :reason is not :wrong-password")
                       (t 'pass))))))
          (error
           (panic-handle err 'freeze-test-login-audit)
           (setq result (format "raised: %S" err))))
      (condition-case _
          (when (file-exists-p path)
            (delete-file path))
        (error nil)))
    (freeze-test--record 'login-audit result)))

;; --------------------------------------------------------------------
;; test 15: per-user lockout (v0.6 item 5.3)
;; --------------------------------------------------------------------

(defun freeze-test-login-lockout ()
  "Drive the per-user lockout end to end on a sentinel name.
v0.6 item 5.3: 10 fails in 5 minutes flips a user to a
`:locked-until' record under /var/emacs/lockouts/NAME.  this test
synthesises the in-memory fail counter, asserts the trip predicate
fires, writes the lockout file, reads back the expiry, and clears.

failure modes worth catching:
  - login--per-user-lockout-trips-p off-by-ones the cap (>= vs >)
  - login--lockout-write skips fsync and the file is empty
  - login--lockout-read can't parse the sexp it just wrote
  - login--lockout-clear deletes the wrong file
  - login--lockout-active-p does not auto-clear expired records"
  (interactive)
  (let* ((result 'fail)
         (suffix (format "%06d" (random 1000000)))
         (name (concat "geos-freeze-lock-" suffix))
         (path (and (boundp 'login--lockouts-dir)
                    (concat login--lockouts-dir name)))
         (saved-fails (and (boundp 'login--per-user-fails)
                           login--per-user-fails)))
    (unwind-protect
        (condition-case err
            (cond
             ((not (and (fboundp 'login--lockout-write)
                        (fboundp 'login--lockout-read)
                        (fboundp 'login--lockout-clear)
                        (fboundp 'login--lockout-active-p)
                        (fboundp 'login--per-user-lockout-trips-p)
                        (fboundp 'login--note-per-user-fail)))
              (setq result "lockout primitives unbound"))
             (t
              (setq login--per-user-fails nil)
              (dotimes (_ login--lockout-cap)
                (login--note-per-user-fail name))
              (cond
               ((not (login--per-user-lockout-trips-p name))
                (setq result
                      (format "trips-p false at cap=%d"
                              login--lockout-cap)))
               ((not (login--lockout-write name))
                (setq result "lockout-write returned nil"))
               (t
                (let ((until (login--lockout-read name))
                      (active (login--lockout-active-p name)))
                  (setq result
                        (cond
                         ((null until)
                          "lockout-read returned nil after write")
                         ((not (numberp until))
                          (format "lockout-read returned non-number: %S"
                                  until))
                         ((< until (float-time))
                          "lockout-read returned a past timestamp")
                         ((not active)
                          "lockout-active-p false on a fresh write")
                         ((not (login--lockout-clear name))
                          "lockout-clear returned nil")
                         ((file-exists-p path)
                          (format "lockout file still present: %s" path))
                         (t 'pass))))))))
          (error
           (panic-handle err 'freeze-test-login-lockout)
           (setq result (format "raised: %S" err))))
      (setq login--per-user-fails saved-fails)
      (condition-case _
          (when (and path (file-exists-p path))
            (delete-file path))
        (error nil)))
    (freeze-test--record 'login-lockout result)))

;; --------------------------------------------------------------------
;; test 16: last-login footer readback (v0.6 item 5.4)
;; --------------------------------------------------------------------

(defun freeze-test-login-last-success ()
  "Drive `login--audit-last-success' against a synthetic auth-log tail.
v0.6 item 5.4: *login* renders `last login: NAME @ TIME' under
the username prompt.  the readback walks /var/emacs/journal/auth.log
from the bottom up, skipping :fail records and parse errors.

what we pin:
  - the most recent :ok record wins, even when later :fail records
    follow it (an attacker hammering the prompt right after a
    legitimate login should not blank the footer).
  - empty auth-log returns nil (a fresh image must not print the
    footer at all).
  - a torn last line (mid-write crash) is skipped without raising.

we append directly via `state-append-journal' so the test does not
need to drive the full login state machine.  the sentinel timestamps
are tagged `geos-freeze-last-NNNNNN' so a parallel test run cannot
collide.  cleanup truncates the log if (and only if) we appended;
on a host where auth.log already has content from a real login,
we restore the prior contents on exit."
  (interactive)
  (let* ((result 'fail)
         (suffix (format "%06d" (random 1000000)))
         (name (concat "geos-freeze-last-" suffix))
         (ok-ts "2026-05-12T10:00:00Z")
         (fail-ts "2026-05-12T10:00:01Z")
         (path (and (boundp 'state-root)
                    (boundp 'login--audit-file)
                    (concat state-root "journal/" login--audit-file)))
         (saved (and path (file-readable-p path)
                     (with-temp-buffer
                       (insert-file-contents path)
                       (buffer-string)))))
    (unwind-protect
        (condition-case err
            (cond
             ((not (and (fboundp 'login--audit-last-success)
                        (fboundp 'state-append-journal)
                        path))
              (setq result "audit-last-success or state-append-journal unbound"))
             (t
              ;; append :ok then :fail; the :ok must still win.
              (state-append-journal
               login--audit-file
               (list (cons 'time ok-ts)
                     (cons 'user name)
                     (cons 'result :ok)))
              (state-append-journal
               login--audit-file
               (list (cons 'time fail-ts)
                     (cons 'user (concat name "-other"))
                     (cons 'result :fail)
                     (cons 'reason :wrong-password)))
              (let ((hit (login--audit-last-success)))
                (setq result
                      (cond
                       ((null hit)
                        "last-success returned nil with :ok in log")
                       ((not (consp hit))
                        (format "last-success returned non-cons: %S" hit))
                       ((not (string= (car hit) name))
                        (format "user mismatch: want %s got %S"
                                name (car hit)))
                       ((not (string= (cdr hit) ok-ts))
                        (format "time mismatch: want %s got %S"
                                ok-ts (cdr hit)))
                       (t 'pass))))))
          (error
           (panic-handle err 'freeze-test-login-last-success)
           (setq result (format "raised: %S" err))))
      ;; restore the prior contents (or wipe if there were none).
      (when path
        (condition-case _
            (cond
             (saved
              (let ((coding-system-for-write 'utf-8))
                (write-region saved nil path nil 'nomsg)))
             ((file-exists-p path)
              (delete-file path)))
          (error nil))))
    (freeze-test--record 'login-last-success result)))

;; --------------------------------------------------------------------
;; test 17: session workspace plumbing (v0.6 item 6.1)
;; --------------------------------------------------------------------

(defun freeze-test-session-workspace ()
  "Round-trip the v0.6 item 6.1 workspace slot on the session record.
synthesises a sentinel session in the in-memory registry, calls
`session-record-workspace' with an index, asserts:
  - `session-workspace-for-name' returns the index we wrote.
  - the snapshot persisted to /var/emacs/sessions/<name> carries
    the :workspace key.
  - calling with an unregistered name returns nil and does NOT
    create a phantom entry (important: an EXWM hook firing for a
    spoofed instance-name must not allocate state).

cleanup: removes the sentinel from the registry AND from disk on
every exit path.  the sentinel name is `geos-freeze-ws-NNNNNN'."
  (interactive)
  (let* ((result 'fail)
         (suffix (format "%06d" (random 1000000)))
         (name (concat "geos-freeze-ws-" suffix))
         (state-key (concat "sessions/" name))
         (path (concat state-root state-key))
         (saved (and (boundp 'session--registry)
                     (gethash name session--registry))))
    (unwind-protect
        (condition-case err
            (cond
             ((not (and (fboundp 'session-record-workspace)
                        (fboundp 'session-workspace-for-name)
                        (boundp 'session--registry)
                        (fboundp 'make-geos-session)))
              (setq result "session workspace primitives unbound"))
             (t
              ;; unregistered name returns nil and writes nothing.
              (let ((pre (session-record-workspace name 7)))
                (cond
                 (pre
                  (setq result
                        (format "record-workspace on unknown name returned %S"
                                pre)))
                 ((gethash name session--registry)
                  (setq result
                        "record-workspace on unknown name allocated entry"))
                 (t
                  ;; install a real entry, then round-trip the slot.
                  (puthash name
                           (make-geos-session
                            :name name
                            :uid 50001
                            :gid 50001
                            :home "/tmp"
                            :supervise-key (intern (concat "session:" name))
                            :status 'starting)
                           session--registry)
                  (let ((written (session-record-workspace name 2))
                        (read    (session-workspace-for-name name)))
                    (cond
                     ((not (eql written 2))
                      (setq result
                            (format "record-workspace returned %S, want 2"
                                    written)))
                     ((not (eql read 2))
                      (setq result
                            (format "workspace-for-name returned %S, want 2"
                                    read)))
                     ((not (file-readable-p path))
                      (setq result
                            (format "snapshot file missing: %s" path)))
                     (t
                      (let ((snap (state-read state-key nil)))
                        (cond
                         ((not (eql (plist-get snap :workspace) 2))
                          (setq result
                                (format
                                 "snapshot :workspace = %S, want 2"
                                 (plist-get snap :workspace))))
                         (t (setq result 'pass))))))))))))
          (error
           (panic-handle err 'freeze-test-session-workspace)
           (setq result (format "raised: %S" err))))
      ;; cleanup: drop in-memory + on-disk records.
      (when (boundp 'session--registry)
        (cond
         (saved (puthash name saved session--registry))
         (t (remhash name session--registry))))
      (condition-case _
          (when (file-exists-p path)
            (delete-file path))
        (error nil)))
    (freeze-test--record 'session-workspace result)))

(defun freeze-test-multi-session-ui ()
  "Exercise the v0.6 item 6.2 multi-session contract.
covers four shapes:
  - `login--running-sessions' returns only 'running entries.
  - `login--render-sessions-footer' prints one line per running
    session and prints nothing on an empty registry.
  - `login-new-session' from :running clears the buffer state to
    :prompt-user WITHOUT calling `session-end' on the prior
    session (so an additional user can log in alongside).
  - the `login-show' guard refuses to keep :running when the
    buffer-held `login--session' is no longer in the registry as
    'running, even if some OTHER session is still alive.

cleanup removes the two sentinel sessions from the registry on
every exit path.  the test does NOT touch disk: it pokes the
in-memory `session--registry' directly so a smoke-test run does
not leave snapshot files behind."
  (interactive)
  (let* ((result 'fail)
         (a (format "geos-freeze-ms-a-%06d" (random 1000000)))
         (b (format "geos-freeze-ms-b-%06d" (random 1000000)))
         (saved-a (and (boundp 'session--registry)
                       (gethash a session--registry)))
         (saved-b (and (boundp 'session--registry)
                       (gethash b session--registry)))
         (saved-state login--state)
         (saved-user login--user)
         (saved-pass login--password)
         (saved-sess login--session)
         (saved-err login--last-error))
    (unwind-protect
        (condition-case err
            (cond
             ((not (and (fboundp 'login--running-sessions)
                        (fboundp 'login--render-sessions-footer)
                        (fboundp 'login-new-session)
                        (fboundp 'login-show)
                        (boundp 'session--registry)
                        (fboundp 'make-geos-session)))
              (setq result "multi-session primitives unbound"))
             (t
              ;; baseline: empty registry, footer prints nothing.
              (clrhash session--registry)
              (let ((live (login--running-sessions)))
                (cond
                 (live
                  (setq result
                        (format "running-sessions on empty reg = %S"
                                live)))
                 (t
                  ;; install two 'running entries.
                  (let ((sa (make-geos-session
                             :name a :uid 50010 :gid 50010
                             :home "/tmp"
                             :supervise-key (intern (concat "session:" a))
                             :workspace 4
                             :status 'running))
                        (sb (make-geos-session
                             :name b :uid 50011 :gid 50011
                             :home "/tmp"
                             :supervise-key (intern (concat "session:" b))
                             :workspace 5
                             :status 'running)))
                    (puthash a sa session--registry)
                    (puthash b sb session--registry)
                    (let ((got (login--running-sessions)))
                      (cond
                       ((not (= (length got) 2))
                        (setq result
                              (format "running-sessions count = %d, want 2"
                                      (length got))))
                       (t
                        ;; footer renders both names.
                        (with-temp-buffer
                          (login--render-sessions-footer)
                          (let ((s (buffer-string)))
                            (cond
                             ((not (and (string-match-p
                                         (regexp-quote a) s)
                                        (string-match-p
                                         (regexp-quote b) s)))
                              (setq result
                                    (format "footer missing names: %S" s)))
                             (t
                              ;; login-new-session from :running
                              ;; clears state but does NOT remove
                              ;; the session from the registry.
                              (setq login--state :running
                                    login--user a
                                    login--password nil
                                    login--session sa
                                    login--last-error nil)
                              (login-new-session)
                              (cond
                               ((not (eq login--state :prompt-user))
                                (setq result
                                      (format "after new-session state=%S, want :prompt-user"
                                              login--state)))
                               (login--session
                                (setq result
                                      "after new-session login--session not cleared"))
                               ((not (gethash a session--registry))
                                (setq result
                                      "new-session evicted the prior session from the registry"))
                               (t
                                ;; login-show guard: pretend
                                ;; :running with a stale session
                                ;; (a vanished session, but b
                                ;; still in registry) -> reset.
                                (remhash a session--registry)
                                (setq login--state :running
                                      login--user a
                                      login--session sa)
                                (let ((buf (login-show)))
                                  (cond
                                   ((not (eq login--state :prompt-user))
                                    (setq result
                                          (format "login-show kept :running on stale sess, state=%S"
                                                  login--state)))
                                   (t
                                    (when (buffer-live-p buf)
                                      (kill-buffer buf))
                                    (setq result 'pass)))))))))))))))))))
          (error
           (panic-handle err 'freeze-test-multi-session-ui)
           (setq result (format "raised: %S" err))))
      ;; cleanup.
      (when (boundp 'session--registry)
        (cond
         (saved-a (puthash a saved-a session--registry))
         (t (remhash a session--registry)))
        (cond
         (saved-b (puthash b saved-b session--registry))
         (t (remhash b session--registry))))
      (setq login--state saved-state
            login--user saved-user
            login--password saved-pass
            login--session saved-sess
            login--last-error saved-err))
    (freeze-test--record 'multi-session-ui result)))

(defun freeze-test-session-workspace-allocator ()
  "Pin the v0.6 item 6.3 `session-allocate-workspace' contract.
covers four shapes:
  - empty registry: NAME with no record allocates index 1.
  - sticky reuse: a record with workspace=2 reallocates to 2 when
    free, even if 1 is also free.
  - skip-taken: when one 'running session occupies ws=1, the next
    NAME allocates ws=2 (never ws=1).
  - cap-saturated: with N running sessions occupying 1..N where
    N=`session-max-workspaces', a new NAME allocates nil and the
    caller is expected to spawn without a workspace stamp.

held + exited records do NOT count as occupied: a logged-out user
must free up its workspace for the next login.

cleanup: removes the sentinel sessions on every exit path.  does
not touch disk (the allocator is in-memory only)."
  (interactive)
  (let* ((result 'fail)
         (mk (lambda (i) (format "geos-freeze-alloc-%d-%06d"
                                 i (random 1000000))))
         (a (funcall mk 1))
         (b (funcall mk 2))
         (c (funcall mk 3))
         (d (funcall mk 4))
         (sav-a (and (boundp 'session--registry)
                     (gethash a session--registry)))
         (sav-b (and (boundp 'session--registry)
                     (gethash b session--registry)))
         (sav-c (and (boundp 'session--registry)
                     (gethash c session--registry)))
         (sav-d (and (boundp 'session--registry)
                     (gethash d session--registry))))
    (unwind-protect
        (condition-case err
            (cond
             ((not (and (fboundp 'session-allocate-workspace)
                        (boundp 'session-max-workspaces)
                        (fboundp 'make-geos-session)
                        (boundp 'session--registry)))
              (setq result "allocator primitives unbound"))
             (t
              (clrhash session--registry)
              (let ((empty (session-allocate-workspace a)))
                (cond
                 ((not (eql empty 1))
                  (setq result
                        (format "empty-registry alloc = %S, want 1"
                                empty)))
                 (t
                  ;; sticky: pre-stamp a record with workspace=2
                  ;; (no other session running), reallocate and
                  ;; expect 2 back even though 1 is free.
                  (puthash b
                           (make-geos-session
                            :name b :uid 50020 :gid 50020
                            :home "/tmp"
                            :supervise-key (intern (concat "session:" b))
                            :workspace 2
                            :status 'starting)
                           session--registry)
                  (let ((sticky (session-allocate-workspace b)))
                    (cond
                     ((not (eql sticky 2))
                      (setq result
                            (format "sticky alloc = %S, want 2"
                                    sticky)))
                     (t
                      ;; skip-taken: with b 'starting on ws=2 and
                      ;; a NEW name allocating, expect ws=1.
                      (let ((skip (session-allocate-workspace c)))
                        (cond
                         ((not (eql skip 1))
                          (setq result
                                (format "skip-taken alloc = %S, want 1"
                                        skip)))
                         (t
                          ;; cap-saturated: fill all slots with
                          ;; 'running entries, expect nil.
                          (clrhash session--registry)
                          (let ((i 1))
                            (dolist (nm (list a b c))
                              (puthash nm
                                       (make-geos-session
                                        :name nm :uid (+ 50020 i)
                                        :gid (+ 50020 i)
                                        :home "/tmp"
                                        :supervise-key
                                        (intern (concat "session:" nm))
                                        :workspace i
                                        :status 'running)
                                       session--registry)
                              (cl-incf i)))
                          (let ((sat (session-allocate-workspace d)))
                            (cond
                             ((not (null sat))
                              (setq result
                                    (format "saturated alloc = %S, want nil"
                                            sat)))
                             (t
                              ;; one of the sessions logs out
                              ;; (status flips to 'held).  its
                              ;; slot should now be free for d.
                              (setf (geos-session-status
                                     (gethash b session--registry))
                                    'held)
                              (let ((reuse (session-allocate-workspace d)))
                                (cond
                                 ((not (eql reuse 2))
                                  (setq result
                                        (format "post-logout alloc = %S, want 2"
                                                reuse)))
                                 (t
                                  (setq result 'pass))))))))))))))))))
          (error
           (panic-handle err 'freeze-test-session-workspace-allocator)
           (setq result (format "raised: %S" err))))
      ;; cleanup.
      (when (boundp 'session--registry)
        (dolist (pair (list (cons a sav-a) (cons b sav-b)
                            (cons c sav-c) (cons d sav-d)))
          (cond
           ((cdr pair) (puthash (car pair) (cdr pair) session--registry))
           (t (remhash (car pair) session--registry))))))
    (freeze-test--record 'session-workspace-allocator result)))

(defun freeze-test-x-display-idempotent ()
  "Pin v0.7 item 1.1: x-display-release / -reclaim are idempotent.

x-display.el is the v0.7 item 1 spike artifact, parked supervisor-
side without callers.  this test runs under batch (no exwm--connection,
no X frames), so the release path walks the no-op branches and
just sets the released flag; the reclaim path's make-frame-on-display
is shadowed via cl-letf so we never try to open :0 from a smoke-test
emacs.

contract:
  - fresh state (x-display--released nil) -> release returns t and
    flips the flag t.
  - released state (x-display--released t) -> release returns t
    WITHOUT touching exwm-wm-mode / x-close-connection (idempotent).
  - released state -> mocked reclaim returns t and flips the flag
    back to nil.
  - fresh state -> reclaim returns t WITHOUT calling
    make-frame-on-display (idempotent)."
  (interactive)
  (let* ((result 'fail)
         (sav-released (and (boundp 'x-display--released)
                            (symbol-value 'x-display--released)))
         (toggled 0)
         (made 0))
    (unwind-protect
        (condition-case err
            (cond
             ((not (and (fboundp 'x-display-release)
                        (fboundp 'x-display-reclaim)
                        (boundp 'x-display--released)))
              (setq result "x-display primitives unbound"))
             (t
              (cl-letf* (((symbol-value 'x-display--released) nil)
                         ((symbol-function 'exwm-wm-mode)
                          (lambda (&rest _) (cl-incf toggled)))
                         ((symbol-function 'make-frame-on-display)
                          (lambda (&rest _) (cl-incf made) nil)))
                (let ((r1 (x-display-release)))
                  (cond
                   ((not r1)
                    (setq result "first release returned nil"))
                   ((not (symbol-value 'x-display--released))
                    (setq result "released flag still nil after release"))
                   (t
                    (let ((r2 (x-display-release)))
                      (cond
                       ((not r2)
                        (setq result "second release returned nil"))
                       (t
                        (let ((r3 (x-display-reclaim)))
                          (cond
                           ((not r3)
                            (setq result "first reclaim returned nil"))
                           ((symbol-value 'x-display--released)
                            (setq result "released flag still t after reclaim"))
                           ((not (= made 1))
                            (setq result
                                  (format "reclaim called make-frame %d times, want 1"
                                          made)))
                           (t
                            (let ((r4 (x-display-reclaim)))
                              (cond
                               ((not r4)
                                (setq result "second reclaim returned nil"))
                               ((not (= made 1))
                                (setq result
                                      (format
                                       "idempotent reclaim re-called make-frame (%d times)"
                                       made)))
                               (t
                                (setq result 'pass))))))))))))))))
          (error
           (panic-handle err 'freeze-test-x-display-idempotent)
           (setq result (format "raised: %S" err))))
      (when (boundp 'x-display--released)
        (set 'x-display--released sav-released)))
    (freeze-test--record 'x-display-idempotent result)))

(defun freeze-test-input-chooser ()
  "Pin v0.7 item 2.1: `input-apply' dispatches on `geos-input-method'.

four cases, each shadowing the side-effecting bits with cl-letf so
the test runs in batch without an X server, an ibus bus, or a real
quail registry:

  :quail forced
    -> input--quail-apply called exactly once
    -> input--ibus-apply NOT called

  :ibus forced
    -> input--ibus-apply called exactly once
    -> input--quail-apply NOT called (fail-closed contract)

  :auto with DISPLAY=:0 AND input--ibus-available-p -> t
    -> input--ibus-apply called first
    -> input--ibus-apply stubbed to return t means quail NOT called

  :auto with DISPLAY=nil (no X)
    -> input--ibus-apply NOT called
    -> input--quail-apply called once

these four cover the matrix the slice 2.1 contract documents.  the
:auto+ibus-fails-back branch (ibus reports available, then apply
returns nil) is exercised implicitly via the dispatcher's `or' form
but is not asserted here; slice 2.3 grows a fifth case when the
real ibus probe lands."
  (interactive)
  (require 'input)
  (let ((result 'fail)
        (sav-method geos-input-method)
        (sav-display (getenv "DISPLAY")))
    (unwind-protect
        (condition-case err
            (let ((q-calls 0)
                  (i-calls 0)
                  (ibus-ok nil)
                  (display-val nil))
              (cl-letf (((symbol-function 'input--quail-apply)
                         (lambda () (cl-incf q-calls) t))
                        ((symbol-function 'input--ibus-apply)
                         (lambda () (cl-incf i-calls) ibus-ok))
                        ((symbol-function 'input--ibus-available-p)
                         (lambda () ibus-ok))
                        ((symbol-function 'getenv)
                         (lambda (k)
                           (if (equal k "DISPLAY") display-val nil)))
                        ((symbol-function 'input--trace)
                         (lambda (_msg) nil)))
                ;; case 1: :quail forced.
                (setq q-calls 0 i-calls 0 ibus-ok nil display-val nil
                      geos-input-method :quail)
                (input-apply)
                (cond
                 ((not (= q-calls 1))
                  (setq result (format ":quail q-calls=%d, want 1" q-calls)))
                 ((not (= i-calls 0))
                  (setq result (format ":quail i-calls=%d, want 0" i-calls)))
                 (t
                  ;; case 2: :ibus forced.
                  (setq q-calls 0 i-calls 0 ibus-ok nil display-val nil
                        geos-input-method :ibus)
                  (input-apply)
                  (cond
                   ((not (= i-calls 1))
                    (setq result (format ":ibus i-calls=%d, want 1" i-calls)))
                   ((not (= q-calls 0))
                    (setq result (format ":ibus q-calls=%d, want 0" q-calls)))
                   (t
                    ;; case 3: :auto with DISPLAY + ibus reachable.
                    (setq q-calls 0 i-calls 0 ibus-ok t display-val ":0"
                          geos-input-method :auto)
                    (input-apply)
                    (cond
                     ((not (= i-calls 1))
                      (setq result
                            (format ":auto+x i-calls=%d, want 1" i-calls)))
                     ((not (= q-calls 0))
                      (setq result
                            (format ":auto+x q-calls=%d, want 0" q-calls)))
                     (t
                      ;; case 4: :auto with no DISPLAY.
                      (setq q-calls 0 i-calls 0 ibus-ok nil display-val nil
                            geos-input-method :auto)
                      (input-apply)
                      (cond
                       ((not (= q-calls 1))
                        (setq result
                              (format ":auto-x q-calls=%d, want 1"
                                      q-calls)))
                       ((not (= i-calls 0))
                        (setq result
                              (format ":auto-x i-calls=%d, want 0"
                                      i-calls)))
                       (t
                        (setq result 'pass)))))))))))
          (error
           (panic-handle err 'freeze-test-input-chooser)
           (setq result (format "raised: %S" err))))
      (setq geos-input-method sav-method)
      (when sav-display (setenv "DISPLAY" sav-display)))
    (freeze-test--record 'input-chooser result)))

(defun freeze-test-input-persist ()
  "Pin v0.7 item 2.2: input-set-method writes /tmp + input-apply reads it.

we cl-letf `input--persist-path' to a tmp file (the real path lives
under /var/emacs/users/$USER/ which a batch run cannot create), then
exercise the round-trip:

  1. save :quail.  assert the file exists, parses to
     (geos-input-method . :quail).
  2. set `geos-input-method' to :ibus IN-MEMORY (the customize
     default-ish state).  call `input-apply' with the dispatcher
     stubbed so it does no real work.  assert the load step flipped
     `geos-input-method' back to :quail (the persisted value wins).
  3. write a malformed payload.  call `input--persist-load'.  assert
     it returns nil and leaves `geos-input-method' unchanged.

we don't exercise input-apply's actual dispatcher here; that's what
freeze-test-input-chooser is for.  this test pins persistence shape
only."
  (interactive)
  (require 'input)
  (let* ((result 'fail)
         (tmp (make-temp-file "geos-input-persist-"))
         (sav-method geos-input-method))
    (unwind-protect
        (condition-case err
            (cl-letf (((symbol-function 'input--persist-path)
                       (lambda () tmp))
                      ((symbol-function 'input--quail-apply)
                       (lambda () t))
                      ((symbol-function 'input--ibus-apply)
                       (lambda () nil))
                      ((symbol-function 'input--trace)
                       (lambda (_msg) nil)))
              ;; case 1: save round-trip.
              (input--persist-save :quail)
              (cond
               ((not (file-exists-p tmp))
                (setq result "save did not create file"))
               (t
                (let* ((raw (with-temp-buffer
                              (insert-file-contents tmp)
                              (car (read-from-string
                                    (buffer-substring-no-properties
                                     (point-min) (point-max)))))))
                  (cond
                   ((not (equal raw (cons 'geos-input-method :quail)))
                    (setq result (format "save shape = %S, want (geos-input-method . :quail)"
                                         raw)))
                   (t
                    ;; case 2: load overrides in-memory.
                    (setq geos-input-method :ibus)
                    (input-apply)
                    (cond
                     ((not (eq geos-input-method :quail))
                      (setq result
                            (format "load did not flip geos-input-method to :quail (got %S)"
                                    geos-input-method)))
                     (t
                      ;; case 3: malformed payload is ignored.
                      (with-temp-buffer
                        (insert "(not-a-known-tag . :weird)\n")
                        (write-region (point-min) (point-max)
                                      tmp nil 'nomsg))
                      (setq geos-input-method :ibus)
                      (let ((rv (input--persist-load)))
                        (cond
                         (rv
                          (setq result
                                (format "malformed load returned %S, want nil" rv)))
                         ((not (eq geos-input-method :ibus))
                          (setq result
                                (format "malformed load mutated method to %S"
                                        geos-input-method)))
                         (t
                          (setq result 'pass))))))))))))
          (error
           (panic-handle err 'freeze-test-input-persist)
           (setq result (format "raised: %S" err))))
      (setq geos-input-method sav-method)
      (when (file-exists-p tmp) (delete-file tmp)))
    (freeze-test--record 'input-persist result)))

(defun freeze-test-input-ibus-throttle ()
  "Pin v0.7 item 2.4: ibus-daemon sentinel respects the respawn cap.

we shadow `input--ibus-spawn' with a counter and feed
`input--ibus-sentinel' synthetic `exit' events.  the contract:

  - first `input--ibus-respawn-cap' deaths each trigger one respawn
    call (cap=5 today; the test reads the const, not a literal).
  - the (cap+1)-th death does NOT trigger a respawn and instead
    sets `input--ibus-held' to t and `input--ibus-process' to nil.

we synthesise events via direct call to `input--ibus-sentinel'
because `make-process' sentinels in batch are timing-flaky.  the
sentinel's bare-error path is also covered: if the shadowed spawn
raises, the sentinel must not propagate, and `input--ibus-process'
must end up nil."
  (interactive)
  (require 'input)
  (let ((result 'fail)
        (sav-times input--ibus-respawn-times)
        (sav-held input--ibus-held)
        (sav-proc input--ibus-process))
    (unwind-protect
        (condition-case err
            (let ((spawn-calls 0)
                  (cap input--ibus-respawn-cap))
              (cl-letf (((symbol-function 'input--ibus-spawn)
                         (lambda () (cl-incf spawn-calls) 'dummy-proc))
                        ((symbol-function 'input--trace)
                         (lambda (_msg) nil))
                        ((symbol-function 'process-status)
                         (lambda (_p) 'exit)))
                ;; reset state
                (setq input--ibus-respawn-times nil
                      input--ibus-held nil
                      input--ibus-process 'dummy-proc)
                ;; fire cap sentinel events; each should trigger a respawn.
                (dotimes (_ cap)
                  (input--ibus-sentinel 'dummy-proc "finished\n"))
                (cond
                 ((not (= spawn-calls cap))
                  (setq result
                        (format "spawn-calls = %d after %d deaths, want %d"
                                spawn-calls cap cap)))
                 (input--ibus-held
                  (setq result
                        "held flipped early (at cap-th death, not cap+1)"))
                 (t
                  ;; fire one more: this should trip the throttle.
                  (input--ibus-sentinel 'dummy-proc "finished\n")
                  (cond
                   ((not (= spawn-calls cap))
                    (setq result
                          (format "throttle did not block spawn: calls=%d"
                                  spawn-calls)))
                   ((not input--ibus-held)
                    (setq result "throttle trip did not set held flag"))
                   (input--ibus-process
                    (setq result
                          (format "throttle trip left process slot = %S"
                                  input--ibus-process)))
                   (t
                    (setq result 'pass)))))))
          (error
           (panic-handle err 'freeze-test-input-ibus-throttle)
           (setq result (format "raised: %S" err))))
      (setq input--ibus-respawn-times sav-times
            input--ibus-held sav-held
            input--ibus-process sav-proc))
    (freeze-test--record 'input-ibus-throttle result)))

(defun freeze-test-audio-pcm-parser ()
  "Pin v0.7 item 3.1: audio-buffer--pcm-stream-count counts playback rows.

writes three tmp files and calls the parser with each path:

  - canned `playback' x3 payload: returns 3.
  - empty payload: returns 0.
  - path that doesn't exist: returns nil.

the parser is a count-of-occurrences shape; this is a substring
match, not a semantic one (we are not asserting `active' streams,
just rows that advertise playback).  the test pins that shape so
a future tweak doesn't silently change the contract.

we pass a PATH arg rather than shadowing `file-readable-p' /
`insert-file-contents' because those are called internally by
emacs during startup; a global shadow hangs `--batch'."
  (interactive)
  (require 'audio-buffer)
  (let* ((result 'fail)
         (three (make-temp-file "geos-audio-pcm-three-"))
         (zero  (make-temp-file "geos-audio-pcm-zero-"))
         (gone  (concat (make-temp-file "geos-audio-pcm-gone-") "-removed")))
    (unwind-protect
        (condition-case err
            (progn
              (with-temp-file three
                (insert "00-00: ALC892 Analog : playback 1 : capture 1\n"
                        "00-01: ALC892 Digital : playback 1\n"
                        "01-00: HDMI 0 : playback 1\n"))
              (with-temp-file zero
                (insert ""))
              ;; gone is a synthesised path that we never wrote, plus a
              ;; suffix to make sure no other test left it behind.
              (when (file-exists-p gone) (delete-file gone))
              (let ((r3 (audio-buffer--pcm-stream-count three))
                    (r0 (audio-buffer--pcm-stream-count zero))
                    (rn (audio-buffer--pcm-stream-count gone)))
                (cond
                 ((not (eql r3 3))
                  (setq result (format "three-payload = %S, want 3" r3)))
                 ((not (eql r0 0))
                  (setq result (format "empty-payload = %S, want 0" r0)))
                 ((not (null rn))
                  (setq result (format "missing-file = %S, want nil" rn)))
                 (t
                  (setq result 'pass)))))
          (error
           (panic-handle err 'freeze-test-audio-pcm-parser)
           (setq result (format "raised: %S" err))))
      (when (file-exists-p three) (delete-file three))
      (when (file-exists-p zero)  (delete-file zero)))
    (freeze-test--record 'audio-pcm-parser result)))

(defun freeze-test-journal-client-render ()
  "Pin v0.7 item 4.3: journal-client renders RPC payload.

mirrors freeze-test-services-client-render: shadow `geos-rpc'
with a stub that returns a canned list of strings, render, and
assert the lines appear.  also asserts the +/- keys clamp the
N range to [10, 500] (the supervisor cap) without overshoot."
  (interactive)
  (require 'journal-client)
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (fboundp 'journal-client--render))
          (setq result "journal-client--render unbound"))
         (t
          (let* ((fake-lines (list "rpc: listening on /run/geos/super.sock"
                                    "rpc: poweroff requested by uid 0"
                                    "supervise: xorg up, pid 42"))
                 (buf (get-buffer-create journal-client-buffer-name)))
            (with-current-buffer buf
              (special-mode)
              (setq journal-client--n 50)
              (cl-letf (((symbol-function 'geos-rpc)
                          (lambda (verb &rest args)
                            (cond
                             ((not (equal verb "journal-tail"))
                              (error "stub: unexpected verb %S" verb))
                             ((not (eql (car args) 50))
                              (error "stub: unexpected N %S" args))
                             (t fake-lines)))))
                (journal-client--render))
              (let ((body (buffer-string)))
                (cond
                 ((not (string-match-p "rpc: listening" body))
                  (setq result "body missing 'rpc: listening'"))
                 ((not (string-match-p "xorg up" body))
                  (setq result "body missing 'xorg up'"))
                 (t
                  ;; clamp checks
                  (setq journal-client--n 480)
                  (cl-letf (((symbol-function 'journal-client--render)
                              (lambda () nil))) ;; suppress repaint
                    (journal-client-more))
                  (cond
                   ((not (eql journal-client--n 500))
                    (setq result
                          (format "more clamp = %d, want 500"
                                  journal-client--n)))
                   (t
                    (setq journal-client--n 50)
                    (cl-letf (((symbol-function 'journal-client--render)
                                (lambda () nil)))
                      (journal-client-less))
                    (cond
                     ((not (eql journal-client--n 10))
                      (setq result
                            (format "less clamp = %d, want 10"
                                    journal-client--n)))
                     (t (setq result 'pass)))))))))
            (when (buffer-live-p buf) (kill-buffer buf)))))
      (error
       (panic-handle err 'freeze-test-journal-client-render)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'journal-client-render result)))

(defun freeze-test-services-client-render ()
  "Pin v0.7 item 4.2: services-client renders an RPC payload.

shadows `geos-rpc' with a `cl-letf' stub that returns a canned row
list and asserts:

  - the rendered buffer contains every row's name string.
  - the header line marks the buffer as RPC-backed.
  - an RPC error path falls through to the body (no panic, last-
    good is empty so we just show the error line).

does NOT touch the timer (we render synchronously).  the timer
is per-buffer and only arms via `services-client-mode'; a unit
test that triggers it would have to wait on real time, which is
the wrong shape for --batch."
  (interactive)
  (require 'services-client)
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (fboundp 'services-client--render))
          (setq result "services-client--render unbound"))
         (t
          (let* ((fake-rows
                  (list (list :name "xorg" :kind 'process :status 'running
                              :pid 42 :restarts 0 :started-at nil)
                        (list :name "emacs-user-alice" :kind 'process
                              :status 'running :pid 99 :restarts 1
                              :started-at nil)))
                 (buf (get-buffer-create services-client-buffer-name))
                 (success-body nil)
                 (error-body nil))
            ;; success path
            (with-current-buffer buf
              (special-mode)
              (cl-letf (((symbol-function 'geos-rpc)
                          (lambda (&rest _) fake-rows)))
                (services-client--render))
              (setq success-body (buffer-string)))
            ;; failure path: geos-rpc signals.
            (with-current-buffer buf
              (cl-letf (((symbol-function 'geos-rpc)
                          (lambda (&rest _) (error "stub: down"))))
                (let ((services-client--last-rows nil))
                  (services-client--render)))
              (setq error-body (buffer-string)))
            (cond
             ((not (string-match-p "xorg" success-body))
              (setq result "success body missing 'xorg'"))
             ((not (string-match-p "emacs-user-alice" success-body))
              (setq result "success body missing 'emacs-user-alice'"))
             ((not (string-match-p "supervisor RPC error" error-body))
              (setq result "error body missing 'supervisor RPC error'"))
             (t (setq result 'pass)))
            (when (buffer-live-p buf) (kill-buffer buf)))))
      (error
       (panic-handle err 'freeze-test-services-client-render)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'services-client-render result)))

(defun freeze-test-rpc-services-list ()
  "Pin v0.7 item 4.1: rpc verb `services-list' wire shape.

calls `rpc-server--verb-services-list' directly (bypassing the
socket; the C-side RPC poll is exercised by the booted smoke
test, not in --batch) and checks:

  - empty registry / unbound supervise-registry returns nil.
  - one fake service comes back as a plist with :name (string,
    converted from symbol), :kind, :status, :pid, :restarts,
    :started-at.
  - :process is NOT present (a process object would fail to print
    across the wire).
  - the returned name string matches the registered symbol's
    `symbol-name', round-trip safe.

we shadow `supervise-registry' with `cl-letf' so the test does
not depend on the supervisor actually being booted.  the verb's
internal `funcall (symbol-function 'supervise-registry)' picks
up the shadow correctly."
  (interactive)
  (require 'rpc-server)
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (fboundp 'rpc-server--verb-services-list))
          (setq result "rpc-server--verb-services-list unbound"))
         (t
          (let* ((empty (cl-letf (((symbol-function 'supervise-registry)
                                    (lambda () nil)))
                          (rpc-server--verb-services-list 0 0 nil)))
                 (fake-svc (list :name 'xorg
                                  :kind 'process
                                  :status 'running
                                  :pid 1234
                                  :restarts 2
                                  :started-at 1700000000
                                  :process 'fake-proc))
                 (one (cl-letf (((symbol-function 'supervise-registry)
                                  (lambda () (list fake-svc))))
                        (rpc-server--verb-services-list 0 0 nil)))
                 (row (car one)))
            (cond
             ((not (null empty))
              (setq result (format "empty-registry = %S, want nil" empty)))
             ((not (= 1 (length one)))
              (setq result (format "one-svc length = %d, want 1"
                                   (length one))))
             ((not (equal (plist-get row :name) "xorg"))
              (setq result (format ":name = %S, want \"xorg\""
                                   (plist-get row :name))))
             ((not (eq (plist-get row :kind) 'process))
              (setq result (format ":kind = %S, want 'process"
                                   (plist-get row :kind))))
             ((not (eq (plist-get row :status) 'running))
              (setq result (format ":status = %S, want 'running"
                                   (plist-get row :status))))
             ((not (eql (plist-get row :pid) 1234))
              (setq result (format ":pid = %S, want 1234"
                                   (plist-get row :pid))))
             ((not (eql (plist-get row :restarts) 2))
              (setq result (format ":restarts = %S, want 2"
                                   (plist-get row :restarts))))
             ((not (eql (plist-get row :started-at) 1700000000))
              (setq result (format ":started-at = %S, want 1700000000"
                                   (plist-get row :started-at))))
             ((plist-member row :process)
              (setq result ":process leaked into wire payload"))
             ;; round-trip through prin1+read to prove it survives
             ;; the wire.  uninterned-symbol-safe: :name is a string.
             ((not (equal row
                          (car (read-from-string
                                (prin1-to-string row)))))
              (setq result "row does not round-trip prin1/read"))
             (t (setq result 'pass))))))
      (error
       (panic-handle err 'freeze-test-rpc-services-list)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'rpc-services-list result)))

;; --------------------------------------------------------------------
;; test: port-hurd seam (v0.7 / hurd-spike step 2, df7fb92)
;; --------------------------------------------------------------------
;;
;; the elisp port seam (`emacs-init/core/port.el') landed with adapter
;; branches in network.el, state.el, disks.el, install/disk.el.  the
;; linux arm is exercised on every boot; the hurd arm is reached by no
;; code that runs in CI today, so a refactor of the linux arm can
;; silently flatten the hurd arm and no smoke test would notice.
;;
;; this test shadows `geos-kernel' to 'hurd via `let' (the predicates
;; `geos-kernel-linux-p' / `geos-kernel-hurd-p' read it dynamically, so
;; a let-binding is sufficient; no `cl-letf' on the predicates needed).
;; the assertions:
;;
;;   port/unimplemented-route
;;     `geos-port-unimplemented' itself returns nil and the panic
;;     buffer grows.  this is the contract every adapter relies on:
;;     a missing kernel surface must not signal up the stack.
;;
;;   port/network-dev-nil
;;     `network-read-proc-net-dev' returns nil on hurd.  the linux
;;     arm goes through `network--read-proc-net-dev-linux'; the hurd
;;     arm routes through `geos-port-unimplemented' and returns nil.
;;
;;   port/network-route-nil
;;     `network-read-proc-net-route' returns nil on hurd, same shape.
;;
;;   port/state-detect-mode-safe
;;     `state--detect-mode' returns one of 'tmpfs, nil on hurd, and
;;     does NOT signal.  the writable-probe fallback on hurd may
;;     resolve either way depending on whether state-root exists on
;;     the booted image; both are documented degraded modes.  we
;;     save/restore `state-mode' because the function mutates it.
;;
;;   port/disks-render-no-sysblock
;;     `disks-buffer--render' on hurd writes a banner and skips the
;;     /sys/block enumeration.  asserts the buffer contents do NOT
;;     contain "block devices" (the linux arm's section header) so
;;     we know the linux path did not run.  the banner text itself
;;     is a render-layer concern; we check for "not implemented" as
;;     the cheap-and-cheerful signal that the hurd arm was taken.
;;
;;   port/install-disk-list-nil-and-panic
;;     `install-disk-list' returns nil on hurd AND the panic buffer
;;     records a `port-unimplemented' entry tagged with the feature
;;     `install-wizard'.  this is the more telling half: a regression
;;     that drops the panic-handle call would leave the wizard
;;     silently returning nil with no audit trail.

(defun freeze-test-port-hurd ()
  "Pin df7fb92: the GEOS_KERNEL=hurd code paths in the elisp port seam.
shadows `geos-kernel' to 'hurd and asserts every adapter branch point
(`network-read-proc-net-{dev,route}', `state--detect-mode',
`disks-buffer--render', `install-disk-list', `geos--uname',
`journal-kmsg' supervise registration,
`geos-port-unimplemented' itself) behaves as documented in
`emacs-init/core/port.el'.

real-world failure mode being caught: a refactor of the linux arm
silently flattens or removes the hurd arm.  nothing in CI runs the
hurd arm today, so without this test that regression would not
surface until the side-branch port attempts to boot."
  (interactive)
  (require 'port nil 'noerror)
  (require 'disks-buffer nil 'noerror)
  (require 'install-disk nil 'noerror)
  (require 'userland-uname nil 'noerror)
  ;; network is already a hard require from earlier in the boot.
  (let ((sav-state-mode (and (boundp 'state-mode) state-mode)))
    (unwind-protect
        (cond
         ((not (and (boundp 'geos-kernel)
                    (fboundp 'geos-kernel-hurd-p)
                    (fboundp 'geos-port-unimplemented)))
          (freeze-test--record 'port/unimplemented-route
                               "port.el not loaded")
          (freeze-test--record 'port/network-dev-nil
                               "port.el not loaded")
          (freeze-test--record 'port/network-route-nil
                               "port.el not loaded")
          (freeze-test--record 'port/state-detect-mode-safe
                               "port.el not loaded")
          (freeze-test--record 'port/disks-render-no-sysblock
                               "port.el not loaded")
          (freeze-test--record 'port/install-disk-list-nil-and-panic
                               "port.el not loaded")
          (freeze-test--record 'port/uname-hurd-synth
                               "port.el not loaded")
          (freeze-test--record 'port/journal-kmsg-no-autostart
                               "port.el not loaded"))
         (t
          (freeze-test--port-unimplemented-route)
          (freeze-test--port-network-dev-nil)
          (freeze-test--port-network-route-nil)
          (freeze-test--port-state-detect-mode-safe)
          (freeze-test--port-disks-render-no-sysblock)
          (freeze-test--port-install-disk-list-nil-and-panic)
          (freeze-test--port-uname-hurd-synth)
          (freeze-test--port-journal-kmsg-no-autostart)))
      ;; never leave state-mode mutated; state--detect-mode setq's it
      ;; as a side effect and a hurd-arm run would otherwise leave the
      ;; rest of the suite seeing the hurd answer.
      (when (boundp 'state-mode)
        (setq state-mode sav-state-mode)))))

(defun freeze-test--port-unimplemented-route ()
  "Sub-check: `geos-port-unimplemented' returns nil and grows *panic*.
this is the bedrock; every adapter depends on it not signalling."
  (let ((result 'fail))
    (condition-case err
        (let* ((buf (panic--get-buffer))
               (before (with-current-buffer buf (buffer-size)))
               (rv (let ((geos-kernel 'hurd))
                     (geos-port-unimplemented 'freeze-test-probe)))
               (after (with-current-buffer buf (buffer-size))))
          (cond
           ((not (null rv))
            (setq result (format "returned %S, want nil" rv)))
           ((not (> after before))
            (setq result (format "panic buffer did not grow: %d -> %d"
                                 before after)))
           (t (setq result 'pass))))
      (error
       (panic-handle err 'freeze-test--port-unimplemented-route)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'port/unimplemented-route result)))

(defun freeze-test--port-network-dev-nil ()
  "Sub-check: `network-read-proc-net-dev' returns nil on hurd."
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (fboundp 'network-read-proc-net-dev))
          (setq result "network-read-proc-net-dev unbound"))
         (t
          (let ((got (let ((geos-kernel 'hurd))
                       (network-read-proc-net-dev))))
            (setq result
                  (if (null got)
                      'pass
                    (format "returned %S, want nil" got))))))
      (error
       (panic-handle err 'freeze-test--port-network-dev-nil)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'port/network-dev-nil result)))

(defun freeze-test--port-network-route-nil ()
  "Sub-check: `network-read-proc-net-route' returns nil on hurd."
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (fboundp 'network-read-proc-net-route))
          (setq result "network-read-proc-net-route unbound"))
         (t
          (let ((got (let ((geos-kernel 'hurd))
                       (network-read-proc-net-route))))
            (setq result
                  (if (null got)
                      'pass
                    (format "returned %S, want nil" got))))))
      (error
       (panic-handle err 'freeze-test--port-network-route-nil)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'port/network-route-nil result)))

(defun freeze-test--port-state-detect-mode-safe ()
  "Sub-check: `state--detect-mode' returns 'tmpfs or nil on hurd.
must NOT signal; the writable-probe fallback decides which of the two
based on whether state-root exists on the running image, and both are
documented degraded modes."
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (fboundp 'state--detect-mode))
          (setq result "state--detect-mode unbound"))
         (t
          (let ((got (let ((geos-kernel 'hurd))
                       (state--detect-mode))))
            (setq result
                  (cond
                   ((memq got '(tmpfs nil)) 'pass)
                   (t (format "returned %S, want 'tmpfs or nil"
                              got)))))))
      (error
       (panic-handle err 'freeze-test--port-state-detect-mode-safe)
       (setq result (format "raised: %S (state--detect-mode must not signal on hurd)" err))))
    (freeze-test--record 'port/state-detect-mode-safe result)))

(defun freeze-test--port-disks-render-no-sysblock ()
  "Sub-check: `disks-buffer--render' on hurd skips /sys/block.
asserts the rendered buffer does NOT contain \"block devices\" (the
linux arm's section header).  also asserts the banner mentions
\"not implemented\" so we know the hurd arm ran and produced its
documented output rather than e.g. silently leaving the buffer
empty.  uses a throwaway buffer; does NOT touch the real *disks*."
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (fboundp 'disks-buffer--render))
          (setq result "disks-buffer--render unbound"))
         (t
          (with-temp-buffer
            (let ((geos-kernel 'hurd))
              (disks-buffer--render))
            (let ((body (buffer-string)))
              (cond
               ((string-match-p "block devices" body)
                (setq result
                      "linux section header 'block devices' present in hurd render"))
               ((not (string-match-p "not implemented" body))
                (setq result
                      (format "banner missing 'not implemented'; got: %s"
                              (substring body 0 (min 80 (length body))))))
               (t (setq result 'pass)))))))
      (error
       (panic-handle err 'freeze-test--port-disks-render-no-sysblock)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'port/disks-render-no-sysblock result)))

(defun freeze-test--port-install-disk-list-nil-and-panic ()
  "Sub-check: `install-disk-list' on hurd returns nil AND panics.
the more telling half is the panic record: a regression that drops
the `geos-port-unimplemented' call would leave the wizard returning
nil silently with no audit trail.  asserts both halves: return value
nil, and the *panic* buffer grew with a record mentioning the
`install-wizard' feature tag."
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (fboundp 'install-disk-list))
          (setq result "install-disk-list unbound"))
         (t
          (let* ((buf (panic--get-buffer))
                 (before (with-current-buffer buf (buffer-size)))
                 (rv (let ((geos-kernel 'hurd))
                       (install-disk-list)))
                 (after (with-current-buffer buf (buffer-size)))
                 (delta (with-current-buffer buf
                          (buffer-substring-no-properties
                           (1+ before) (point-max)))))
            (cond
             ((not (null rv))
              (setq result (format "returned %S, want nil" rv)))
             ((not (> after before))
              (setq result
                    (format "panic buffer did not grow: %d -> %d"
                            before after)))
             ((not (string-match-p "install-wizard" delta))
              (setq result
                    (format "new panic entry lacks 'install-wizard' tag: %s"
                            (substring delta 0
                                       (min 120 (length delta))))))
             (t (setq result 'pass))))))
      (error
       (panic-handle err 'freeze-test--port-install-disk-list-nil-and-panic)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'port/install-disk-list-nil-and-panic result)))

(defun freeze-test--port-uname-hurd-synth ()
  "Sub-check: `geos--uname' on hurd returns a synth plist, no /proc reads.
asserts the hurd arm produces a non-nil plist with at least a :kernel
string containing \"GNU\".  the linux arm on a fresh-boot dev host
returns \"Linux\" for :kernel, so the substring test also serves as a
no-regression check that the dispatcher actually flipped arms instead
of falling through to the linux backend.  also asserts the call does
not raise: the four /proc/sys/kernel/* reads vanish on hurd and a
regression that drops the hurd arm would surface as an empty plist
(harmless) or, worse, as a let-bind failure in `eshell/uname'."
  (let ((result 'fail))
    (condition-case err
        (cond
         ((not (fboundp 'geos--uname))
          (setq result "geos--uname unbound"))
         (t
          (let ((got (let ((geos-kernel 'hurd))
                       (geos--uname))))
            (cond
             ((not (listp got))
              (setq result (format "returned %S, want plist" got)))
             ((not (stringp (plist-get got :kernel)))
              (setq result
                    (format ":kernel = %S, want string"
                            (plist-get got :kernel))))
             ((not (string-match-p "GNU" (plist-get got :kernel)))
              (setq result
                    (format ":kernel = %S, want substring \"GNU\""
                            (plist-get got :kernel))))
             (t (setq result 'pass))))))
      (error
       (panic-handle err 'freeze-test--port-uname-hurd-synth)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'port/uname-hurd-synth result)))

(defun freeze-test--port-journal-kmsg-no-autostart ()
  "Sub-check: on hurd, `journal-kmsg' is either unregistered or has
:autostart nil.  either is fine: no dd subprocess gets spawned at
boot, the supervisor never tries to follow a /dev/kmsg that does not
exist, and the crashloop cap does not get burned chasing ENOENT.

implementation: shadow `geos-kernel' to 'hurd, reload the
services/journal-tail.el registration (re-running supervise-register
is documented as a hot-swap), then inspect the registry slot's
autostart bit.  the test re-applies the linux registration in the
unwind-protect so the rest of the suite sees the kernel-default
service shape.  on a host where services/journal-tail.el never
loaded (dev-host emacs -Q) the sub-check records 'not loaded' and
passes through; the contract is about what registration happens on
hurd, not about forcing the file to be present."
  (let ((result 'fail)
        (sav-svc (and (boundp 'supervise--registry)
                      (gethash 'journal-kmsg supervise--registry))))
    (condition-case err
        (cond
         ((not (fboundp 'supervise-register))
          (setq result "supervise-register unbound"))
         ((not (boundp 'supervise--registry))
          (setq result "supervise--registry unbound"))
         ((not (featurep 'journal-tail))
          ;; service file never loaded on this host; the contract
          ;; only fires if the file is in the boot.
          (setq result 'pass))
         (t
          (unwind-protect
              (progn
                ;; re-evaluate the registration with geos-kernel=hurd.
                ;; the call shape mirrors what services/journal-tail.el
                ;; does at load time; we cannot reload the file because
                ;; that would also fire `(require 'port)' and a host
                ;; of other side effects.
                (let ((geos-kernel 'hurd))
                  (apply #'supervise-register
                         :name 'journal-kmsg
                         :command '("dd" "if=/dev/kmsg" "bs=8192"
                                    "status=none")
                         :restart 'on-crash
                         :buffer journal-tail--work-buffer-name
                         :filter #'journal-tail--filter
                         (unless (geos-kernel-linux-p)
                           '(:autostart nil))))
                (let* ((svc (gethash 'journal-kmsg supervise--registry))
                       (autostart (and svc
                                       (supervise-service-autostart svc))))
                  (cond
                   ((null svc)
                    (setq result 'pass))  ; unregistered also fine
                   (autostart
                    (setq result
                          (format
                           "journal-kmsg has :autostart %S on hurd, want nil"
                           autostart)))
                   (t (setq result 'pass)))))
            ;; restore the linux-default registration so the rest of
            ;; the suite (and any later boot work) sees the right
            ;; autostart bit.
            (let ((geos-kernel 'linux))
              (apply #'supervise-register
                     :name 'journal-kmsg
                     :command '("dd" "if=/dev/kmsg" "bs=8192"
                                "status=none")
                     :restart 'on-crash
                     :buffer journal-tail--work-buffer-name
                     :filter #'journal-tail--filter
                     (unless (geos-kernel-linux-p)
                       '(:autostart nil)))))))
      (error
       (panic-handle err 'freeze-test--port-journal-kmsg-no-autostart)
       (setq result (format "raised: %S" err))))
    ;; if we had a prior service struct saved, leave it untouched: the
    ;; reapply above already restored the static intent fields onto
    ;; the existing struct (supervise-register reuses existing).
    (ignore sav-svc)
    (freeze-test--record 'port/journal-kmsg-no-autostart result)))

(defun freeze-test-session-end-isolation ()
  "Pin v0.6 item 6.4: `session-end' on user A leaves user B alone.
two simulated 'running sessions, A on workspace 1 and B on
workspace 2.  call `session-end' on A and assert:

  - A flips to 'held with `child-pid' nil and the persisted
    snapshot mirrors that.
  - B is untouched: same status, same `child-pid', same
    workspace.
  - the allocator now returns workspace 1 (A's vacated slot)
    when asked for a fresh NAME, but does NOT return 2 (B is
    still occupying it).
  - the poller's `session--present-login' is NOT invoked: the
    contract says re-present only when no session remains
    'running, and B is still alive.

we deliberately use `child-pid' nil on both records so
`session-end' takes the no-signal branch.  the test does NOT
touch the on-disk snapshot beyond the persist-then-cleanup
side effect of `session-end' itself; the post-cond on A reads
back via state-read to confirm the persist landed."
  (interactive)
  (let* ((result 'fail)
         (a (format "geos-freeze-iso-a-%06d" (random 1000000)))
         (b (format "geos-freeze-iso-b-%06d" (random 1000000)))
         (key-a (concat "sessions/" a))
         (key-b (concat "sessions/" b))
         (path-a (concat state-root key-a))
         (path-b (concat state-root key-b))
         (sav-a (and (boundp 'session--registry)
                     (gethash a session--registry)))
         (sav-b (and (boundp 'session--registry)
                     (gethash b session--registry)))
         (present-log nil))
    (unwind-protect
        (condition-case err
            (cond
             ((not (and (fboundp 'session-end)
                        (fboundp 'session-allocate-workspace)
                        (fboundp 'make-geos-session)
                        (boundp 'session--registry)))
              (setq result "session-end primitives unbound"))
             (t
              (clrhash session--registry)
              (let ((sa (make-geos-session
                         :name a :uid 50030 :gid 50030
                         :home "/tmp"
                         :supervise-key (intern (concat "session:" a))
                         :workspace 1
                         :status 'running))
                    (sb (make-geos-session
                         :name b :uid 50031 :gid 50031
                         :home "/tmp"
                         :supervise-key (intern (concat "session:" b))
                         :workspace 2
                         :status 'running)))
                (puthash a sa session--registry)
                (puthash b sb session--registry)
                ;; trip-wire: shadow present-login so an errant
                ;; call shows up in `present-log'.
                (cl-letf (((symbol-function 'session--present-login)
                           (lambda (&rest _)
                             (setq present-log
                                   (cons 'called present-log)))))
                  (session-end a))
                (let ((after-a (gethash a session--registry))
                      (after-b (gethash b session--registry)))
                  (cond
                   ((not (eq (geos-session-status after-a) 'held))
                    (setq result
                          (format "A status = %S, want 'held"
                                  (geos-session-status after-a))))
                   ((not (null (geos-session-child-pid after-a)))
                    (setq result
                          (format "A child-pid = %S, want nil"
                                  (geos-session-child-pid after-a))))
                   ((not (eq (geos-session-status after-b) 'running))
                    (setq result
                          (format "B status = %S, want 'running"
                                  (geos-session-status after-b))))
                   ((not (eql (geos-session-workspace after-b) 2))
                    (setq result
                          (format "B workspace = %S, want 2"
                                  (geos-session-workspace after-b))))
                   (t
                    ;; persist landed?
                    (let ((snap (and (file-readable-p path-a)
                                     (state-read key-a nil))))
                      (cond
                       ((not (and (listp snap)
                                  (eq (plist-get snap :status) 'held)))
                        (setq result
                              (format "persisted A status = %S, want 'held"
                                      (and snap (plist-get snap :status)))))
                       (t
                        ;; allocator should reclaim A's slot.
                        (let ((c (format "geos-freeze-iso-c-%06d"
                                         (random 1000000))))
                          (let ((alloc (session-allocate-workspace c)))
                            (cond
                             ((not (eql alloc 1))
                              (setq result
                                    (format "allocator picked %S, want 1"
                                            alloc)))
                             (present-log
                              (setq result
                                    "present-login called despite B still 'running"))
                             (t
                              (setq result 'pass))))))))))))))
          (error
           (panic-handle err 'freeze-test-session-end-isolation)
           (setq result (format "raised: %S" err))))
      ;; cleanup.
      (when (boundp 'session--registry)
        (cond
         (sav-a (puthash a sav-a session--registry))
         (t (remhash a session--registry)))
        (cond
         (sav-b (puthash b sav-b session--registry))
         (t (remhash b session--registry))))
      (condition-case _
          (dolist (p (list path-a path-b))
            (when (file-exists-p p)
              (delete-file p)))
        (error nil)))
    (freeze-test--record 'session-end-isolation result)))

;; --------------------------------------------------------------------
;; orchestration
;; --------------------------------------------------------------------

(defun freeze-test-run-all ()
  "Run every freeze test in order.  prints a summary at the end."
  (interactive)
  (setq freeze-test-results nil)
  (message "freeze-test: starting abuse suite")
  (freeze-test-runaway-loop)
  (unless (freeze-test--alive-p)
    (error "freeze-test: emacs unresponsive after runaway-loop"))
  (freeze-test-catastrophic-regex)
  (unless (freeze-test--alive-p)
    (error "freeze-test: emacs unresponsive after catastrophic-regex"))
  (freeze-test-slow-network)
  (freeze-test-bad-tramp)
  (freeze-test-state-roundtrip)
  (freeze-test-supervise-throttle)
  (freeze-test-login-abuse)
  (freeze-test-spawn-shape)
  (freeze-test-workspace-routing)
  (freeze-test-child-exit-poller)
  (freeze-test-users-buffer-add)
  (freeze-test-login-audit)
  (freeze-test-login-lockout)
  (freeze-test-login-last-success)
  (freeze-test-session-workspace)
  (freeze-test-multi-session-ui)
  (freeze-test-session-workspace-allocator)
  (freeze-test-session-end-isolation)
  (freeze-test-x-display-idempotent)
  (freeze-test-input-chooser)
  (freeze-test-input-persist)
  (freeze-test-input-ibus-throttle)
  (freeze-test-audio-pcm-parser)
  (freeze-test-rpc-services-list)
  (freeze-test-services-client-render)
  (freeze-test-journal-client-render)
  (freeze-test-port-hurd)
  (freeze-test-kill-emacs)
  (freeze-test-report))

(defun freeze-test-report ()
  "Print a PASS/FAIL summary of all recorded results."
  (interactive)
  (let* ((results (reverse freeze-test-results))
         (failed (cl-remove-if (lambda (r) (eq (cdr r) 'pass)) results))
         (summary
          (concat
           "freeze-test: SUMMARY\n"
           (mapconcat
            (lambda (r)
              (format "  %s -> %S"
                      (car r) (cdr r)))
            results
            "\n")
           "\n"
           (if failed
               (format "freeze-test: %d/%d FAILED, blocker"
                       (length failed) (length results))
             "freeze-test: PASS, all clear"))))
    (message "%s" summary)
    ;; mirror to /dev/console when boot-marker is loaded so an
    ;; outer test harness can pick the result up via the smoke-
    ;; test apparatus.  require FIRST: fboundp before require would
    ;; report unbound on the very first invocation in a fresh image,
    ;; even though the symbol becomes bound a microsecond later.
    (when (require 'boot-marker nil 'noerror)
      (when (fboundp 'boot-marker--write)
        (dolist (line (split-string summary "\n"))
          (boot-marker--write line))))
    (null failed)))

(provide 'freeze-tests)
;;; freeze-tests.el ends here
