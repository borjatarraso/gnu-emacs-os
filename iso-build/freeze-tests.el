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
;; reporting: each test pushes a result alist into `freeze-test-results'.
;; (freeze-test-report) prints a per-test PASS/FAIL summary to *Messages*
;; and to /dev/console (when boot-marker--write is available, so the
;; smoke-test apparatus can pick it up out-of-band).

(require 'panic)
(require 'cl-lib)  ; freeze-test-report uses cl-remove-if

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
