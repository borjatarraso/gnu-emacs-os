;;; freeze-test-hurd-disk-size-bytes.el --- Hurd arm of disk_size_bytes wired -*- lexical-binding: t -*-

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
;; pins the two Hurd elisp consumer sites of the `pid1-disk-size-bytes'
;; module binding once they stop returning a hard nil and start calling
;; into the slot.  the binding signature is fixed at
;; (pid1-disk-size-bytes NAME) -> integer-or-nil; the slot's Hurd body
;; lives on the side branch in port_hurd.c, the Linux body in
;; port_linux.c shipped with the slot (see freeze-test-disk-size-bytes.el
;; for the per-kernel shape pinning).
;;
;; tests:
;;
;;   freeze-test/hurd-disk-size-bytes-binding-shape
;;     calls (pid1-disk-size-bytes "wd0") and asserts the return is
;;     integerp or null.  skips if the binding is not fboundp, same way
;;     freeze-test-disk-size-bytes.el skips when /sys/block/sda is
;;     missing on the dev host.  this is the cross-kernel contract: the
;;     two userland sites do not care which kernel they're on, only
;;     that the binding either gives them a byte count or nil.
;;
;;   freeze-test/hurd-install-disk-size-bytes-shape
;;     calls `install-disk--size-bytes-hurd' with "wd0" and asserts the
;;     return is integerp or null.  this is the wrapper site in
;;     emacs-init/install/disk.el; it must surface nil cleanly when
;;     pid1-disk-size-bytes is unbound on a dev host, and forward the
;;     integer otherwise.

;;; Code:

(require 'cl-lib)

(defun freeze-test--hurd-disk-size-bytes-record (tag result)
  "Bridge to the main freeze-test recorder when present.
falls back to `message' so this file is usable standalone."
  (cond
   ((fboundp 'freeze-test--record)
    (freeze-test--record tag result))
   (t
    (message "freeze-test-hurd-disk-size-bytes: %S -> %S" tag result))))

(defun freeze-test/hurd-disk-size-bytes-binding-shape ()
  "Pin `pid1-disk-size-bytes' return shape on a single string arg.
skips if the binding is not loaded (consistent with how
`freeze-test-disk-size-bytes.el' skips when /sys/block/sda is
absent)."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'pid1-disk-size-bytes))
      (setq result (cons 'skip "pid1-disk-size-bytes unbound")))
     (t
      ;; wrap in condition-case so a regression that leaks pid1-error
      ;; through the soft-failure contract shows up as :raised rather
      ;; than killing the whole runner batch.
      (let ((got (condition-case err
                     (pid1-disk-size-bytes "wd0")
                   (error (list :raised err)))))
        (setq result
              (cond
               ((null got) 'pass)
               ((integerp got)
                (if (>= got 0) 'pass (list :negative got)))
               ((and (consp got) (eq (car got) :raised))
                (list :leaked-exit (cdr got)))
               (t (list :wrong-type got)))))))
    (freeze-test--hurd-disk-size-bytes-record
     'hurd-disk-size-bytes/binding-shape result)
    result))

(defun freeze-test/hurd-install-disk-size-bytes-shape ()
  "Pin `install-disk--size-bytes-hurd' return shape on \"wd0\".
the wrapper must surface nil cleanly when the binding is unbound,
and forward an integer when it is bound."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'install-disk--size-bytes-hurd))
      (setq result (cons 'skip "install-disk--size-bytes-hurd unbound")))
     (t
      (let ((got (condition-case err
                     (install-disk--size-bytes-hurd "wd0")
                   (error (list :raised err)))))
        (setq result
              (cond
               ((null got) 'pass)
               ((integerp got)
                (if (>= got 0) 'pass (list :negative got)))
               ((and (consp got) (eq (car got) :raised))
                (list :leaked-exit (cdr got)))
               (t (list :wrong-type got)))))))
    (freeze-test--hurd-disk-size-bytes-record
     'hurd-disk-size-bytes/install-wrapper-shape result)
    result))

(defun freeze-test-hurd-disk-size-bytes ()
  "Run the Hurd-arm disk_size_bytes wiring freeze-tests.
records two results under hurd-disk-size-bytes/* tags; returns nil."
  (interactive)
  (freeze-test/hurd-disk-size-bytes-binding-shape)
  (freeze-test/hurd-install-disk-size-bytes-shape)
  nil)

(provide 'freeze-test-hurd-disk-size-bytes)
;;; freeze-test-hurd-disk-size-bytes.el ends here
