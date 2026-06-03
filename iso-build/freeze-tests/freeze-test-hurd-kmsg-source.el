;;; freeze-test-hurd-kmsg-source.el --- Hurd arm of journal-kmsg wired -*- lexical-binding: t -*-

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
;; pins the v0.9.6 Hurd arm of services/journal-tail.el against the
;; v0.9.6 probe receipt at docs/runlogs/2026-05-21-hurd-kmsg-probe.md.
;; the receipt rules out a port_caps slot for kmsg on Hurd: there is no
;; mach_get_kernel_messages RPC, /proc/kmsg does not exist, /dev/klog
;; blocks and has no history, and inetutils-syslogd ships by default
;; and drains /dev/klog into /var/log/kern.log.  the wiring is pure
;; elisp against `tail -F --lines=+1 /var/log/kern.log' under
;; supervise.el.
;;
;; tests:
;;
;;   freeze-test-hurd-kmsg/service-command-under-hurd
;;     stubs `geos-kernel-linux-p' to return nil, re-loads
;;     services/journal-tail.el so its top-level supervise-register sees
;;     the stub, asserts the registered `journal-kmsg' service has the
;;     expected hurd :command and :autostart is non-nil (we no longer
;;     hold the service inert on hurd).  on exit restores the linux
;;     wiring so the dev-host registry is not left in a hurd shape.
;;
;;   freeze-test-hurd-kmsg/parse-syslog-good
;;     calls `journal-buffer--parse-syslog-record' against a known-good
;;     kern.log line and asserts the returned plist carries the right
;;     :source, :sev, :msg, and a non-nil :time.
;;
;;   freeze-test-hurd-kmsg/parse-syslog-bad
;;     calls the parser against a malformed line (one with no host: msg
;;     shape) and asserts it returns nil rather than raising.

;;; Code:

(require 'cl-lib)

(defun freeze-test--hurd-kmsg-source-record (tag result)
  "Bridge to the main freeze-test recorder when present.
falls back to `message' so this file is usable standalone."
  (cond
   ((fboundp 'freeze-test--record)
    (freeze-test--record tag result))
   (t
    (message "freeze-test-hurd-kmsg-source: %S -> %S" tag result))))

(defun freeze-test-hurd-kmsg/service-command-under-hurd ()
  "Pin the `journal-kmsg' service shape when geos-kernel is hurd.
re-loads services/journal-tail.el under a stubbed
`geos-kernel-linux-p' so the top-level supervise-register branch
evaluates the hurd arm, then reads the registry back.  on exit
re-loads the file under the real predicate so the dev-host
registry returns to the linux shape."
  (interactive)
  (let ((result 'fail)
        (file (locate-library "journal-tail")))
    (cond
     ((null file)
      (setq result (cons 'skip "journal-tail not on load-path")))
     ((not (fboundp 'supervise-register))
      (setq result (cons 'skip "supervise-register unbound")))
     (t
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'geos-kernel-linux-p)
                       (lambda () nil)))
              (load file nil t))
            (let* ((entry (and (fboundp 'supervise-registry)
                               (cl-find 'journal-kmsg (supervise-registry)
                                        :key (lambda (e) (plist-get e :name)))))
                   (svc (and (boundp 'supervise--registry)
                             (gethash 'journal-kmsg supervise--registry)))
                   (cmd (and svc (supervise-service-command svc)))
                   (autostart (and svc (supervise-service-autostart svc)))
                   (want-cmd '("tail" "-F" "--lines=+1" "/var/log/kern.log"))
                   (mismatches nil))
              (unless entry
                (push :no-registry-entry mismatches))
              (unless (equal cmd want-cmd)
                (push (list :cmd :got cmd :want want-cmd) mismatches))
              (unless autostart
                (push (list :autostart :got autostart :want 'non-nil)
                      mismatches))
              (setq result (if (null mismatches) 'pass mismatches))))
        ;; restore: re-load with the real predicate so we do not leave
        ;; the dev-host registry pointing at /var/log/kern.log.
        (ignore-errors (load file nil t)))))
    (freeze-test--hurd-kmsg-source-record
     'hurd-kmsg/service-command-under-hurd result)
    result))

(defun freeze-test-hurd-kmsg/parse-syslog-good ()
  "Pin `journal-buffer--parse-syslog-record' on a known-good line."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'journal-buffer--parse-syslog-record))
      (setq result (cons 'skip
                         "journal-buffer--parse-syslog-record unbound")))
     (t
      (let* ((raw "May 21 00:34:12 geos-hurd vmunix: cd0: dos partition I/O error")
             (rec (journal-buffer--parse-syslog-record raw))
             (mismatches nil))
        (cond
         ((null rec)
          (push :nil-on-good-input mismatches))
         (t
          (unless (eq (plist-get rec :source) 'syslog)
            (push (list :source :got (plist-get rec :source) :want 'syslog)
                  mismatches))
          (unless (equal (plist-get rec :sev) "info")
            (push (list :sev :got (plist-get rec :sev) :want "info")
                  mismatches))
          (unless (and (stringp (plist-get rec :msg))
                       (string-match-p "dos partition I/O error"
                                       (plist-get rec :msg)))
            (push (list :msg :got (plist-get rec :msg)) mismatches))
          (unless (plist-get rec :time)
            (push :nil-time mismatches))))
        (setq result (if (null mismatches) 'pass mismatches)))))
    (freeze-test--hurd-kmsg-source-record
     'hurd-kmsg/parse-syslog-good result)
    result))

(defun freeze-test-hurd-kmsg/parse-syslog-bad ()
  "Pin `journal-buffer--parse-syslog-record' returns nil on malformed input."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'journal-buffer--parse-syslog-record))
      (setq result (cons 'skip
                         "journal-buffer--parse-syslog-record unbound")))
     (t
      ;; no host + tag suffix.  the regex demands at least
      ;; "MMM DD HH:MM:SS HOST TAGREST"; a bare timestamp + word should
      ;; not pass.  also try a flat-out garbage string.
      (let* ((bad-1 "this is not a syslog line")
             (bad-2 "")
             (bad-3 "May 21 00:34:12 onlyhostnoMSG")
             (got-1 (condition-case err
                        (journal-buffer--parse-syslog-record bad-1)
                      (error (list :raised err))))
             (got-2 (condition-case err
                        (journal-buffer--parse-syslog-record bad-2)
                      (error (list :raised err))))
             (got-3 (condition-case err
                        (journal-buffer--parse-syslog-record bad-3)
                      (error (list :raised err))))
             (mismatches nil))
        (dolist (pair (list (cons :bad-1 got-1)
                            (cons :bad-2 got-2)
                            (cons :bad-3 got-3)))
          (let ((tag (car pair))
                (got (cdr pair)))
            (cond
             ((null got) nil)
             ((and (consp got) (eq (car got) :raised))
              (push (list tag :raised (cdr got)) mismatches))
             (t (push (list tag :got got :want 'nil) mismatches)))))
        (setq result (if (null mismatches) 'pass mismatches)))))
    (freeze-test--hurd-kmsg-source-record
     'hurd-kmsg/parse-syslog-bad result)
    result))

(defun freeze-test-hurd-kmsg-source ()
  "Run the v0.9.6 Hurd-arm journal-kmsg freeze-tests.
records three results under hurd-kmsg/* tags; returns nil."
  (interactive)
  (freeze-test-hurd-kmsg/service-command-under-hurd)
  (freeze-test-hurd-kmsg/parse-syslog-good)
  (freeze-test-hurd-kmsg/parse-syslog-bad)
  nil)

(provide 'freeze-test-hurd-kmsg-source)
;;; freeze-test-hurd-kmsg-source.el ends here
