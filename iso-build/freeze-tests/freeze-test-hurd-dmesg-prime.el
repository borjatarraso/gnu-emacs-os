;;; freeze-test-hurd-dmesg-prime.el --- Hurd /var/log/dmesg prime  -*- lexical-binding: t -*-

;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;;; Commentary:
;;
;; pins the v0.9.6 follow-on that primes *journal* from /var/log/dmesg
;; on Hurd at journal-tail startup.  motivation lives in the receipt at
;; docs/runlogs/2026-05-21-v096-kmsg-verify.md: kern.log ships at 0
;; bytes on a fresh Debian Hurd 0.9 boot because gnumach doesn't push
;; boot printfs through /dev/klog, so the day-zero *journal* buffer is
;; empty unless we slurp /var/log/dmesg (the one-shot boot transcript
;; bootlogs wrote out of the gnumach printbuf).
;;
;; tests:
;;
;;   freeze-test-hurd-dmesg/parse-good
;;     calls `journal-buffer--parse-dmesg-record' on a known-good
;;     gnumach printbuf line, asserts the plist has :source 'dmesg, an
;;     expected :msg, and that :time is either nil (we have no anchor)
;;     or a valid time value (renderer fallback to current-time is
;;     allowed by the design).
;;
;;   freeze-test-hurd-dmesg/parse-empty-line
;;     asserts the parser returns nil on empty / whitespace-only input
;;     rather than emitting a record with an empty :msg.
;;
;;   freeze-test-hurd-dmesg/prime-no-file
;;     stubs `geos-kernel-linux-p' to return nil and points the prime
;;     at a guaranteed-absent path so `file-readable-p' is nil,
;;     asserts `journal-tail--prime-from-dmesg' returns cleanly with no
;;     records appended.  the stub is undone via unwind-protect so the
;;     dev-host predicate isn't left lying about its kernel.

;;; Code:

(require 'cl-lib)

(defun freeze-test--hurd-dmesg-prime-record (tag result)
  "Bridge to the main freeze-test recorder when present.
Falls back to `message' so this file is usable standalone."
  (cond
   ((fboundp 'freeze-test--record)
    (freeze-test--record tag result))
   (t
    (message "freeze-test-hurd-dmesg-prime: %S -> %S" tag result))))

(defun freeze-test-hurd-dmesg/parse-good ()
  "Pin `journal-buffer--parse-dmesg-record' on a known-good line."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'journal-buffer--parse-dmesg-record))
      (setq result (cons 'skip
                         "journal-buffer--parse-dmesg-record unbound")))
     (t
      (let* ((raw "Kernel page fault at address 0x0, eip 0xc0123456")
             (rec (journal-buffer--parse-dmesg-record raw))
             (mismatches nil))
        (cond
         ((null rec)
          (push :nil-on-good-input mismatches))
         (t
          (unless (eq (plist-get rec :source) 'dmesg)
            (push (list :source :got (plist-get rec :source) :want 'dmesg)
                  mismatches))
          (unless (equal (plist-get rec :msg) raw)
            (push (list :msg :got (plist-get rec :msg) :want raw)
                  mismatches))
          (unless (equal (plist-get rec :raw) raw)
            (push (list :raw :got (plist-get rec :raw) :want raw)
                  mismatches))
          (unless (equal (plist-get rec :sev) "info")
            (push (list :sev :got (plist-get rec :sev) :want "info")
                  mismatches))
          ;; :time is nil by design (no anchor in dmesg text) but the
          ;; design also allows a valid time fallback if a future
          ;; revision decides to stamp the prime at boot wall-clock.
          ;; accept either; reject everything else.
          (let ((ts (plist-get rec :time)))
            (unless (or (null ts)
                        (and (consp ts)
                             (integerp (car ts))
                             (integerp (cadr ts))))
              (push (list :time :got ts :want 'nil-or-time)
                    mismatches)))))
        (setq result (if (null mismatches) 'pass mismatches)))))
    (freeze-test--hurd-dmesg-prime-record
     'hurd-dmesg/parse-good result)
    result))

(defun freeze-test-hurd-dmesg/parse-empty-line ()
  "Pin parser returns nil on empty / whitespace-only input."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'journal-buffer--parse-dmesg-record))
      (setq result (cons 'skip
                         "journal-buffer--parse-dmesg-record unbound")))
     (t
      (let* ((empty (journal-buffer--parse-dmesg-record ""))
             (spaces (journal-buffer--parse-dmesg-record "   "))
             (tabs (journal-buffer--parse-dmesg-record "\t\t"))
             (mismatches nil))
        (unless (null empty)
          (push (list :empty :got empty :want nil) mismatches))
        (unless (null spaces)
          (push (list :spaces :got spaces :want nil) mismatches))
        (unless (null tabs)
          (push (list :tabs :got tabs :want nil) mismatches))
        (setq result (if (null mismatches) 'pass mismatches)))))
    (freeze-test--hurd-dmesg-prime-record
     'hurd-dmesg/parse-empty-line result)
    result))

(defun freeze-test-hurd-dmesg/prime-no-file ()
  "Pin `journal-tail--prime-from-dmesg' is a clean no-op when file absent.
Stubs the kernel predicate so the prime takes the Hurd branch, but
points at a guaranteed-absent path so `file-readable-p' bails the
whole thing.  asserts no error is raised and the journal-buffer line
count does not grow."
  (interactive)
  (let ((result 'fail)
        (orig-readable (symbol-function 'file-readable-p))
        (orig-linux-p (and (fboundp 'geos-kernel-linux-p)
                           (symbol-function 'geos-kernel-linux-p))))
    (cond
     ((not (fboundp 'journal-tail--prime-from-dmesg))
      (setq result (cons 'skip
                         "journal-tail--prime-from-dmesg unbound")))
     (t
      (unwind-protect
          (let* ((before (when (get-buffer "*journal*")
                           (with-current-buffer "*journal*"
                             (or (and (boundp 'journal-buffer--line-count)
                                      journal-buffer--line-count)
                                 0))))
                 (raised nil))
            (cl-letf (((symbol-function 'geos-kernel-linux-p)
                       (lambda () nil))
                      ;; spoof file-readable-p to lie about /var/log/dmesg
                      ;; only; everything else delegates to the real one
                      ;; so the function under test can still look up the
                      ;; load path and so on.
                      ((symbol-function 'file-readable-p)
                       (lambda (path)
                         (if (equal path "/var/log/dmesg")
                             nil
                           (funcall orig-readable path)))))
              (condition-case err
                  (journal-tail--prime-from-dmesg)
                (error (setq raised err))))
            (let* ((after (when (get-buffer "*journal*")
                            (with-current-buffer "*journal*"
                              (or (and (boundp 'journal-buffer--line-count)
                                       journal-buffer--line-count)
                                  0))))
                   (mismatches nil))
              (when raised
                (push (list :raised raised) mismatches))
              (when (and before after (/= before after))
                (push (list :line-count :before before :after after)
                      mismatches))
              (setq result (if (null mismatches) 'pass mismatches))))
        ;; restore the predicate even if the body bailed.  cl-letf
        ;; already handles this for its own duration but if the test
        ;; framework decides to bail mid-flight a defensive restore
        ;; keeps the dev-host registry honest.
        (when orig-linux-p
          (fset 'geos-kernel-linux-p orig-linux-p))
        (fset 'file-readable-p orig-readable))))
    (freeze-test--hurd-dmesg-prime-record
     'hurd-dmesg/prime-no-file result)
    result))

(defun freeze-test-hurd-dmesg-prime ()
  "Run the v0.9.6 follow-on dmesg-prime freeze-tests.
Records three results under hurd-dmesg/* tags; returns nil."
  (interactive)
  (freeze-test-hurd-dmesg/parse-good)
  (freeze-test-hurd-dmesg/parse-empty-line)
  (freeze-test-hurd-dmesg/prime-no-file)
  nil)

(provide 'freeze-test-hurd-dmesg-prime)
;;; freeze-test-hurd-dmesg-prime.el ends here
