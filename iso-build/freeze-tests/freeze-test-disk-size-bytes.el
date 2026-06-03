;;; freeze-test-disk-size-bytes.el --- post-v0.9 disk_size_bytes slot freeze-tests -*- lexical-binding: t -*-

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
;; pins the Linux body of port->disk_size_bytes (the first of the four
;; post-v0.9 port_hurd.c Mach RPC slots; the Linux side ships first to
;; give the elisp consumers something to dispatch against on both
;; kernels).  the slot is exposed to elisp as `pid1-disk-size-bytes';
;; the body reads /sys/block/<NAME>/size and multiplies by 512 per the
;; Documentation/ABI/stable/sysfs-block contract.
;;
;; tests:
;;
;;   freeze-test/disk-size-bytes-linux-shape
;;     on a dev host that has /sys/block/sda/size, calls
;;     (pid1-disk-size-bytes "sda") and asserts the return matches
;;     (* 512 SECTORS) computed from the same sysfs file.  skips with
;;     reason "no /sys/block/sda" if the file does not exist (CI on a
;;     container or a host whose root disk is nvme0n1/vda will skip
;;     cleanly).
;;
;;   freeze-test/disk-size-bytes-bogus-name-nil
;;     calls (pid1-disk-size-bytes "no-such-disk-xyz") and asserts a
;;     nil return.  this exercises the port-layer ENOENT branch through
;;     the module binding's "return nil on -1" convention.
;;
;;   freeze-test/disk-size-bytes-overlong-name-nil
;;     calls (pid1-disk-size-bytes (make-string 1024 ?a)) and asserts a
;;     nil return with no pid1-error raised.  pins the binding's
;;     non_local_exit_clear after extract_cstring_into trips
;;     ENAMETOOLONG; the elisp consumer renders "?" on nil and must not
;;     have to wrap the call in condition-case for this branch.

;;; Code:

(require 'cl-lib)

(defun freeze-test--disk-size-bytes-record (tag result)
  "Bridge to the main freeze-test recorder when present.
falls back to `message' so this file is usable standalone."
  (cond
   ((fboundp 'freeze-test--record)
    (freeze-test--record tag result))
   (t
    (message "freeze-test-disk-size-bytes: %S -> %S" tag result))))

(defun freeze-test/disk-size-bytes-linux-shape ()
  "Pin `pid1-disk-size-bytes' against /sys/block/sda/size on the dev host.
skips if sda is absent."
  (interactive)
  (let ((result 'fail)
        (sysfs "/sys/block/sda/size"))
    (cond
     ((not (fboundp 'pid1-disk-size-bytes))
      (setq result (cons 'skip "pid1-disk-size-bytes unbound")))
     ((not (file-readable-p sysfs))
      (setq result (cons 'skip "no /sys/block/sda")))
     (t
      (let* ((raw (with-temp-buffer
                    (insert-file-contents sysfs)
                    (buffer-string)))
             (sectors (string-to-number raw))
             (want (* 512 sectors))
             (got (pid1-disk-size-bytes "sda")))
        (cond
         ((not (integerp got))
          (setq result (list :not-integer got)))
         ((<= got 0)
          (setq result (list :non-positive got)))
         ((/= got want)
          (setq result (list :mismatch :got got :want want :sectors sectors)))
         (t
          (setq result 'pass))))))
    (freeze-test--disk-size-bytes-record
     'disk-size-bytes/linux-shape result)
    result))

(defun freeze-test/disk-size-bytes-bogus-name-nil ()
  "Pin `pid1-disk-size-bytes' nil return on a name that does not exist."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'pid1-disk-size-bytes))
      (setq result (cons 'skip "pid1-disk-size-bytes unbound")))
     (t
      (let ((got (pid1-disk-size-bytes "no-such-disk-xyz")))
        (setq result (if (null got)
                         'pass
                       (list :not-nil got))))))
    (freeze-test--disk-size-bytes-record
     'disk-size-bytes/bogus-name-nil result)
    result))

(defun freeze-test/disk-size-bytes-overlong-name-nil ()
  "Pin `pid1-disk-size-bytes' nil return on an absurdly long NAME.
the binding traps ENAMETOOLONG from `extract_cstring_into', clears
the pending non-local exit, and returns nil.  this test fails if
the binding leaks a pid1-error through the soft-failure contract."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'pid1-disk-size-bytes))
      (setq result (cons 'skip "pid1-disk-size-bytes unbound")))
     (t
      ;; catch any signal so a regression (B1 returning) shows up as
      ;; :raised rather than aborting the whole runner batch.
      (let* ((arg (make-string 1024 ?a))
             (got (condition-case err
                      (pid1-disk-size-bytes arg)
                    (error (list :raised err)))))
        (setq result
              (cond
               ((null got) 'pass)
               ((and (consp got) (eq (car got) :raised))
                (list :leaked-exit (cdr got)))
               (t (list :not-nil got)))))))
    (freeze-test--disk-size-bytes-record
     'disk-size-bytes/overlong-name-nil result)
    result))

(defun freeze-test-disk-size-bytes ()
  "Run the post-v0.9 disk_size_bytes freeze-tests.
records three results under disk-size-bytes/* tags; returns nil."
  (interactive)
  (freeze-test/disk-size-bytes-linux-shape)
  (freeze-test/disk-size-bytes-bogus-name-nil)
  (freeze-test/disk-size-bytes-overlong-name-nil)
  nil)

(provide 'freeze-test-disk-size-bytes)
;;; freeze-test-disk-size-bytes.el ends here
