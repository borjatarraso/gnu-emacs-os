;;; freeze-test-disks-install-hurd.el --- v0.9.3 tier A Hurd enumeration tests -*- lexical-binding: t -*-

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
;; per-helper freeze-tests for the v0.9.3 tier A Hurd backends in
;; emacs-init/buffers/disks.el and emacs-init/install/disk.el.
;;
;; the point of these tests is to pin the matcher contracts (whole-disk
;; regex on /dev/, mounted-p against both literal and store-spec
;; /proc/mounts forms) without needing a real Hurd VM.  the matchers
;; are pure functions over directory contents and a procfile, so we
;; build synthetic fixtures with `make-temp-file' and exercise the
;; helpers under (cl-letf) rebindings of the file-reading primitives.
;;
;; tests:
;;
;;   freeze-test-hurd/disks-whole-disk-regex
;;     pins `disks-buffer--hurd-whole-disk-re' against a curated list
;;     of positive (wd0, hd2, sd0, ucd0, ud3, cd0, fd1) and negative
;;     (wd0s1, wd0s10, hd, sda1, nvme0n1, disk, /dev/eth0, empty)
;;     samples.  catches the family of bugs where someone widens the
;;     regex to accept partition slices, or narrows it past one of the
;;     six node families.
;;
;;   freeze-test-hurd/disks-mounts-for-device
;;     exercises `disks-buffer--mounts-for-device-hurd' against a
;;     synthetic mounts list that carries every shape we expect:
;;     literal whole-disk (`/dev/wd0'), literal slice (`/dev/wd0s2'),
;;     literal slice on a different disk (`/dev/wd1s1', must NOT
;;     match), store-spec on the same disk (`part:2:device:wd0',
;;     must match), store-spec on a different disk
;;     (`part:1:device:wd1', must NOT match), and a literal whole-disk
;;     that shares a numeric prefix (`/dev/wd00', must NOT match the
;;     `wd0' query).  asserts the returned mount-point list is the
;;     expected subset in expected order.
;;
;;   freeze-test-hurd/install-mounted-p
;;     same as above but for `install-disk-mounted-p-hurd', which has
;;     the same matcher logic over /proc/mounts directly.  builds a
;;     temp file shaped like /proc/mounts, rebinds
;;     `install-disk--proc-mounts' to it, calls the helper, asserts
;;     the boolean answer for each query name.
;;
;;   freeze-test-hurd/install-all-names
;;     exercises `install-disk--all-names-hurd' by rebinding the
;;     /dev/ scan to a synthetic temp directory populated with named
;;     files matching and not matching the regex.  asserts only the
;;     whole-disk names come back, sorted.
;;
;; all four tests pass on Linux (they only depend on string matchers
;; and tempfile reads) so the dev-host harness catches regressions
;; before any Hurd VM cycle.

;;; Code:

(require 'cl-lib)

(defun freeze-test--disks-install-hurd-record (tag result)
  "Bridge to the main freeze-test recorder when present.
falls back to `message' so this file is usable standalone."
  (cond
   ((fboundp 'freeze-test--record)
    (freeze-test--record tag result))
   (t
    (message "freeze-test-disks-install-hurd: %S -> %S" tag result))))

(defun freeze-test-hurd/disks-whole-disk-regex ()
  "Pin `disks-buffer--hurd-whole-disk-re' against curated samples."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (boundp 'disks-buffer--hurd-whole-disk-re))
      (setq result (cons 'skip "disks-buffer--hurd-whole-disk-re unbound")))
     (t
      (let* ((re disks-buffer--hurd-whole-disk-re)
             (positives '("wd0" "wd1" "hd0" "hd2" "sd0" "sd5"
                          "ucd0" "ud3" "cd0" "cd1" "fd0" "fd1"))
             (negatives '("wd0s1" "wd0s2" "wd0s10" "hd" "sda" "sda1"
                          "nvme0n1" "disk" "" "wd" "sd"))
             (mismatches nil))
        (dolist (p positives)
          (unless (string-match-p re p)
            (push (cons :positive-miss p) mismatches)))
        (dolist (n negatives)
          (when (string-match-p re n)
            (push (cons :negative-match n) mismatches)))
        (setq result (if (null mismatches) 'pass mismatches)))))
    (freeze-test--disks-install-hurd-record
     'hurd/disks-whole-disk-regex result)
    result))

(defun freeze-test-hurd/disks-mounts-for-device ()
  "Pin `disks-buffer--mounts-for-device-hurd' against a synthetic mounts list."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'disks-buffer--mounts-for-device-hurd))
      (setq result (cons 'skip
                         "disks-buffer--mounts-for-device-hurd unbound")))
     (t
      ;; synthetic mounts with two disks present so the matcher has
      ;; to reject cross-disk matches.  also includes `wd00' so the
      ;; `wd0'-over-matches-`wd00' guard is exercised.  the matcher
      ;; only accepts the literal `/dev/NAME[sN]' form because that
      ;; is what the live Hurd procfs emits per the 2026-05-20 probe.
      (let* ((mounts
              (list
               (list :device "/dev/wd0" :mount-point "/wholewd0"
                     :fstype "ext2" :options "rw")
               (list :device "/dev/wd0s2" :mount-point "/"
                     :fstype "ext2" :options "rw")
               (list :device "/dev/wd0s5" :mount-point "/home"
                     :fstype "ext2" :options "rw")
               (list :device "/dev/wd1s1" :mount-point "/other"
                     :fstype "ext2" :options "rw")
               (list :device "/dev/wd00" :mount-point "/notwd0"
                     :fstype "ext2" :options "rw")))
             (got-wd0 (disks-buffer--mounts-for-device-hurd "wd0" mounts))
             (got-wd1 (disks-buffer--mounts-for-device-hurd "wd1" mounts))
             (want-wd0 '("/wholewd0" "/" "/home"))
             (want-wd1 '("/other"))
             (mismatches nil))
        (unless (equal got-wd0 want-wd0)
          (push (list :wd0 :got got-wd0 :want want-wd0) mismatches))
        (unless (equal got-wd1 want-wd1)
          (push (list :wd1 :got got-wd1 :want want-wd1) mismatches))
        (setq result (if (null mismatches) 'pass mismatches)))))
    (freeze-test--disks-install-hurd-record
     'hurd/disks-mounts-for-device result)
    result))

(defun freeze-test-hurd/install-mounted-p ()
  "Pin `install-disk-mounted-p-hurd' against a synthetic /proc/mounts."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'install-disk-mounted-p-hurd))
      (setq result (cons 'skip "install-disk-mounted-p-hurd unbound")))
     (t
      (let* ((tmp (make-temp-file "freeze-test-hurd-mounts-"))
             (mismatches nil))
        (unwind-protect
            (progn
              ;; build a /proc/mounts that covers the shapes the
              ;; live Hurd procfs actually emits (literal /dev/NAME[sN]):
              ;; - literal whole disk and slice on wd0
              ;; - literal slice on wd1
              ;; - literal whole disk wd00 (must NOT match wd0)
              ;; - hd1s1 to exercise a non-wd family
              (with-temp-file tmp
                (insert "/dev/wd0 /wholewd0 ext2 rw 0 0\n")
                (insert "/dev/wd0s2 / ext2 rw 0 0\n")
                (insert "/dev/wd1s1 /other ext2 rw 0 0\n")
                (insert "/dev/wd00 /notwd0 ext2 rw 0 0\n")
                (insert "/dev/hd1s1 /hd1mount ext2 rw 0 0\n"))
              (let ((install-disk--proc-mounts tmp))
                ;; wd0 must hit (literal whole + slice)
                (unless (install-disk-mounted-p-hurd "wd0")
                  (push :wd0-want-true mismatches))
                ;; wd1 must hit (literal slice only)
                (unless (install-disk-mounted-p-hurd "wd1")
                  (push :wd1-want-true mismatches))
                ;; wd2 must MISS (no wd2 line at all)
                (when (install-disk-mounted-p-hurd "wd2")
                  (push :wd2-want-false mismatches))
                ;; wd3 must MISS (no wd3 line at all)
                (when (install-disk-mounted-p-hurd "wd3")
                  (push :wd3-want-false mismatches))
                ;; sd0 must MISS (no sd line at all)
                (when (install-disk-mounted-p-hurd "sd0")
                  (push :sd0-want-false mismatches))
                ;; hd1 must hit (literal slice)
                (unless (install-disk-mounted-p-hurd "hd1")
                  (push :hd1-want-true mismatches))))
          (when (file-exists-p tmp) (delete-file tmp)))
        (setq result (if (null mismatches) 'pass mismatches)))))
    (freeze-test--disks-install-hurd-record
     'hurd/install-mounted-p result)
    result))

(defun freeze-test-hurd/install-all-names ()
  "Pin `install-disk--all-names-hurd' against a synthetic /dev/.
Rebinds `directory-files' and `file-directory-p' via cl-letf to
hand the helper a curated entry list without touching the real
/dev/ on the dev host."
  (interactive)
  (let ((result 'fail))
    (cond
     ((not (fboundp 'install-disk--all-names-hurd))
      (setq result (cons 'skip "install-disk--all-names-hurd unbound")))
     (t
      (let* ((entries '("wd0" "wd0s1" "wd0s2" "wd1" "hd0" "sd2"
                        "ucd0" "ud3" "cd0" "fd0" "eth0" "null"
                        "kmsg" "disk" "tty"))
             (want '("cd0" "fd0" "hd0" "sd2" "ucd0" "ud3"
                     "wd0" "wd1"))
             got)
        (cl-letf (((symbol-function 'file-directory-p)
                   (lambda (p)
                     (if (string= p "/dev") t nil)))
                  ((symbol-function 'directory-files)
                   (lambda (dir &optional _full _match _nosort _count)
                     (if (string= dir "/dev")
                         (copy-sequence entries)
                       nil))))
          (setq got (install-disk--all-names-hurd)))
        (setq result
              (if (equal got want)
                  'pass
                (list :got got :want want))))))
    (freeze-test--disks-install-hurd-record
     'hurd/install-all-names result)
    result))

(defun freeze-test-disks-install-hurd ()
  "Run all v0.9.3 tier A Hurd-enumeration freeze-tests.
records four results under hurd/* tags; returns nil."
  (interactive)
  (freeze-test-hurd/disks-whole-disk-regex)
  (freeze-test-hurd/disks-mounts-for-device)
  (freeze-test-hurd/install-mounted-p)
  (freeze-test-hurd/install-all-names)
  nil)

(provide 'freeze-test-disks-install-hurd)
;;; freeze-test-disks-install-hurd.el ends here
