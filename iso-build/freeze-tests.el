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
;;       argv/no-init (no per-user init.el -> 4-element argv),
;;       argv/with-init (per-user init.el readable -> argv ends
;;                       with -l <path>, --name still at index 2-3),
;;       argv/name-injection (contract-pin: this function does NOT
;;                            re-validate NAME; passwd-add-user is
;;                            the upstream gate per the docstring).
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
    (freeze-test--login-snapshot)
    (freeze-test--login-cmdline)
    (freeze-test--login-empty-user))))

;; --------------------------------------------------------------------
;; test 9: spawn shape under abuse (v0.6 starter, 37ddbce)
;; --------------------------------------------------------------------

(defun freeze-test--spawn-shape-modules-loaded-p ()
  "Return non-nil iff both spawn-shape functions are bound.
the umbrella records 'module-not-loaded if either is missing.  I
check the exact two symbols the sub-checks call rather than just
`featurep' on session, because session.el can be half-byte-compiled
on a partial image and slip through `featurep'."
  (and (fboundp 'session--child-env)
       (fboundp 'session--child-argv)))

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
  "Sub-check argv/no-init: returns the 4-element form with --name.
mocks file-readable-p to nil for every call so we do not depend on
what /var/emacs/users/ looks like on the booted image.  pass iff
the return is exactly (\"emacs\" \"-Q\" \"--name\" \"geos-user-u\")."
  (let ((result 'fail))
    (condition-case err
        (cl-letf (((symbol-function 'file-readable-p) (lambda (_) nil)))
          (let ((argv (session--child-argv "u")))
            (setq result
                  (if (equal argv
                             '("emacs" "-Q" "--name" "geos-user-u"))
                      'pass
                    (format "argv shape wrong: %S" argv)))))
      (error
       (panic-handle err 'freeze-test--spawn-argv-no-init)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/argv/no-init result)))

(defun freeze-test--spawn-argv-with-init ()
  "Sub-check argv/with-init: per-user init.el path tacked on at end.
mock file-readable-p to t.  must still have --name geos-user-u at
indices 2-3 and -l /var/emacs/users/u/init.el at the tail."
  (let ((result 'fail))
    (condition-case err
        (cl-letf (((symbol-function 'file-readable-p) (lambda (_) t)))
          (let* ((argv (session--child-argv "u"))
                 (expected '("emacs" "-Q" "--name" "geos-user-u"
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
                             '("emacs" "-Q" "--name" "geos-user-a;b c"))
                      'pass
                    (format "contract drift: %S" argv)))))
      (error
       (panic-handle err 'freeze-test--spawn-argv-name-injection)
       (setq result (format "raised: %S" err))))
    (freeze-test--record 'spawn-shape/argv/name-injection result)))

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
    (freeze-test--spawn-argv-name-injection))))

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
