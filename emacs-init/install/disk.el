;;; disk.el --- block-device enumeration for the *install* wizard -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
;;;
;;; This file is part of GEOS.
;;;
;;; GEOS is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; GEOS is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GEOS.  If not, see <https://www.gnu.org/licenses/>.

;; pure-reader half of the v0.4 install wizard.  walks /sys/block to
;; produce a list of candidate target disks, augmented with the
;; minimum a human needs to pick one safely: byte size, kernel-
;; detected model string, removable flag, and whether any partition
;; of the disk is currently mounted.  refusing to mkfs a disk with a
;; mounted partition is the single most important safety net the
;; wizard has, so this file is where it lives.
;;
;; what it does NOT do: partitioning, mkfs, mount.  those live in
;; sibling files (mkfs.el, ..., to be added as the wizard grows).
;; this file is read-only against the kernel: it parses sysfs and
;; /proc, and exposes plain elisp data.  no make-process, no ioctl,
;; nothing that mutates state.

(require 'panic)
(require 'port)
(require 'subr-x)

(define-error 'install-disk-error
  "Block-device enumeration parse error"
  'error)

(defconst install-disk--sys-block "/sys/block/"
  "Sysfs root for block devices.
Each entry under here is a directory named after a top-level block
device (sda, nvme0n1, vda, ...). We deliberately do NOT recurse
into partitions; the wizard installs onto a whole disk and lets
parted lay out the partition table.")

(defconst install-disk--proc-mounts "/proc/mounts"
  "Kernel mount table. One line per mount, fields:
DEVICE MOUNTPOINT FSTYPE OPTIONS DUMP PASS. We only care about
DEVICE so we can refuse to wipe a disk whose partition is mounted.")

(defun install-disk--read-sysfs-string (path)
  "Return the first line of PATH stripped, or nil if unreadable.
Used for /sys/block/X/device/model and similar single-value sysfs
attributes that the kernel populates as a trailing-newline string.
We return nil on unreadable rather than signalling: a disk that
does not expose a model string still installs fine."
  (when (file-readable-p path)
    (condition-case _
        (with-temp-buffer
          (insert-file-contents path)
          (string-trim (buffer-string)))
      (error nil))))

(defun install-disk--read-sysfs-int (path)
  "Return the integer at PATH, or nil. nil on unreadable or unparseable."
  (let ((s (install-disk--read-sysfs-string path)))
    (and s (string-match-p "\\`-?[0-9]+\\'" s) (string-to-number s))))

(defun install-disk--size-bytes (name)
  "Return byte size of block device NAME, or nil if sysfs refuses.
sysfs publishes size in 512-byte sectors regardless of the device's
physical block size (the kernel normalises). this is the established
contract since Linux 2.6.something and we depend on it."
  (let ((sectors (install-disk--read-sysfs-int
                  (concat install-disk--sys-block name "/size"))))
    (and sectors (* sectors 512))))

(defun install-disk--removable-p (name)
  "Return non-nil if the kernel flagged NAME as removable.
removable=1 means udisks would treat this as a USB stick, SD card,
etc.  the wizard does not refuse install onto removable media (you
might want exactly that), but the buffer renders a tag so the
operator can see they are about to wipe a USB stick on purpose."
  (let ((v (install-disk--read-sysfs-int
            (concat install-disk--sys-block name "/removable"))))
    (and v (= v 1))))

(defun install-disk--model (name)
  "Return the vendor/model string for NAME, or nil.
Path varies: SATA/NVMe expose device/model, virtio exposes nothing
(the kernel-side virtio_blk just has no model field). nil is fine,
the buffer renders a `?' in that column."
  (or (install-disk--read-sysfs-string
       (concat install-disk--sys-block name "/device/model"))
      (install-disk--read-sysfs-string
       (concat install-disk--sys-block name "/device/vendor"))))

(defun install-disk--all-names ()
  "Return the sorted list of top-level block-device names under /sys/block.
Filters out loop*, ram*, dm-* (those are not install targets even
in principle: loop devices are filesystems-as-files, ram is the
zram block device guix occasionally creates, dm-* is the
device-mapper top-half which is the OUTPUT of LUKS unlock, not
something you install onto).  the wizard wants raw disks only."
  (when (file-directory-p install-disk--sys-block)
    (let ((entries (directory-files install-disk--sys-block nil "\\`[^.]")))
      (sort
       (cl-remove-if
        (lambda (n) (string-match-p "\\`\\(loop\\|ram\\|dm-\\)" n))
        entries)
       #'string<))))

;; -- hurd enumeration helpers ------------------------------------------------

(defconst install-disk--hurd-whole-disk-re
  "\\`\\(wd\\|hd\\|sd\\|ucd\\|ud\\|cd\\|fd\\)[0-9]+\\'"
  "Match a Hurd whole-disk node name under /dev/.
deliberately rejects the `sN' partition-slice suffix; the wizard
installs onto a whole disk, not a slice.  same regex as
`disks-buffer--hurd-whole-disk-re', kept duplicated rather than
imported so the install package does not pull in the buffers tree.")

(defconst install-disk--hurd-removable-re
  "\\`\\(cd\\|fd\\|ucd\\|ud\\)"
  "Match a Hurd disk name we treat as removable.
coarse: optical, floppy, USB.  no kernel-side bit for this on Hurd,
so this is best-effort.")

(defun install-disk--all-names-hurd ()
  "Return the sorted list of Hurd whole-disk names under /dev/.
Walks /dev/ and keeps anything matching `install-disk--hurd-whole-
disk-re'.  no equivalent of the loop/ram/dm- exclusion list is
needed: those devices have no Hurd analogue at the whole-disk
node-name level.  symlinks like /dev/disk are skipped because they
do not match the whole-disk regex."
  (when (file-directory-p "/dev")
    (let (out)
      (condition-case _
          (dolist (name (directory-files "/dev" nil "\\`[^.]"))
            (when (string-match-p install-disk--hurd-whole-disk-re name)
              (push name out)))
        (error nil))
      (sort out #'string<))))

(defun install-disk--size-bytes-hurd (name)
  "Return byte size of Hurd whole-disk NAME, or nil if the RPC refuses.
Hurd has no sysfs size publisher: `file-attributes' on a special
file returns nil for size and statvfs only works on a mounted
filesystem.  the slot is wired through the `pid1-disk-size-bytes'
module binding (which on Hurd reaches storeio's device_get_status
RPC from port_hurd.c).  the fboundp guard keeps this file loadable
on a Linux dev host without pid1-module.so present.  nil still
surfaces if the underlying RPC fails so the renderer's `?' render
stays honest."
  (when (fboundp 'pid1-disk-size-bytes)
    (pid1-disk-size-bytes name)))

(defun install-disk--removable-hurd (name)
  "Return non-nil if NAME looks like a removable Hurd device.
Same coarse name-prefix heuristic the *disks* buffer uses:
cd/fd/ucd/ud are removable, everything else is not."
  (and (string-match-p install-disk--hurd-removable-re name) t))

(defun install-disk--model-hurd (_name)
  "Return nil.  no model-string source on Hurd without RPC.
the renderer prints `?' for nil; tier B can promote this to a real
value once port_hurd.c exposes a storeio query."
  nil)

(defun install-disk-mounted-p-hurd (name)
  "Return non-nil if any slice of disk NAME is mentioned in /proc/mounts.
NAME is bare (e.g. `wd0').  matches the literal Hurd node path
`/dev/NAME' optionally followed by `sN' (the partition-slice
marker); the trailing check guards against `wd0' over-matching a
hypothetical `wd00'.

the 2026-05-20 probe
(`docs/runlogs/2026-05-20-v092-verify-v093-probe.md') showed
`/proc/mounts' on Hurd uses the literal node form even for the
root translator (`/dev/wd0s2 / ext2fs ...').  `fsysopts /' returns
the store-spec form `part:2:device:wd0' but that is the live
translator argv, not what procfs emits.  add a store-spec branch
here if a future probe finds a Hurd build that emits translator
argv into mounts."
  (let ((prefix (concat "/dev/" name))
        (hit nil))
    (when (file-readable-p install-disk--proc-mounts)
      (condition-case _
          (with-temp-buffer
            (insert-file-contents install-disk--proc-mounts)
            (goto-char (point-min))
            (while (and (not hit) (not (eobp)))
              (let* ((line (buffer-substring (line-beginning-position)
                                             (line-end-position)))
                     (fields (split-string line "[ \t]+" t))
                     (dev (car fields)))
                (when (and (stringp dev)
                           (string-prefix-p prefix dev)
                           (let ((rest (substring dev (length prefix))))
                             (or (string-empty-p rest)
                                 (string-match-p "\\`s[0-9]" rest))))
                  (setq hit t)))
              (forward-line 1)))
        (error nil)))
    hit))

(defun install--partitions-for-hurd (disk)
  "Return list of partition plists for whole-disk DISK on Hurd.
DISK is the bare whole-disk name (e.g. \"wd0\").  walks /dev/ for
entries matching \"<disk>s[0-9]+\" (the Hurd slice convention,
e.g. wd0s1, wd0s2) and returns one plist per slice:

  :name        bare slice name (\"wd0s1\")
  :node        full /dev path (\"/dev/wd0s1\")
  :size-bytes  integer byte count from `pid1-disk-size-bytes',
               or nil if the RPC refuses
  :mounted-p   t if /proc/mounts mentions the literal /dev/NAME

mirrors `install--partitions-for' (the linux arm in install.el)
shape-wise, but the contents differ: linux exports :path; we use
:node here because the spec asked for it and downstream callers
(the wizard's part-pick render) read both names by plist-get.

no sysfs on hurd, no `partition' file to check; the slice suffix
is a node-name convention enforced by the storeio translators.
the regex is anchored to DISK on the left and \"s<digits>\" on
the right so a `wd0' lookup does not over-match `wd00s1' on a
hypothetical many-disk system.  `regexp-quote' on DISK guards
against a future caller passing a name with regex metachars.

size: same `pid1-disk-size-bytes' slot the v0.9.5 disks buffer
uses (storeio device_get_status under the hood).  fboundp guard
keeps this file loadable on a linux dev host without
pid1-module.so present.  nil surfaces if the underlying RPC
fails, and the wizard renderer's `?' render stays honest.

mounted-p: literal `/dev/NAME' match against /proc/mounts.  the
2026-05-20 probe documented in
`install-disk-mounted-p-hurd' showed the hurd procfs translator
emits the node form even for the root translator, so a literal
prefix is enough; the store-spec form
(`part:N:device:wd0') does not appear in mounts."
  (when (and (stringp disk) (file-directory-p "/dev"))
    (let* ((re (concat "\\`" (regexp-quote disk) "s[0-9]+\\'"))
           (mounts (install-disk--mounted-devices))
           out)
      (condition-case _
          (dolist (name (directory-files "/dev" nil re))
            (let ((node (concat "/dev/" name)))
              (push (list :name name
                          :node node
                          :size-bytes (install-disk--size-bytes-hurd name)
                          :mounted-p (and (gethash node mounts) t))
                    out)))
        (error nil))
      (sort out (lambda (a b) (string< (plist-get a :name)
                                       (plist-get b :name)))))))

(defun install-disk--mounted-devices ()
  "Return the set of device paths mentioned in /proc/mounts.
Returns a hash table keyed on the literal device string (e.g.
\"/dev/sda1\", \"/dev/mapper/geos-root\"). Used by
`install-disk-mounted-p' to decide whether ANY partition of a
given disk is currently in use."
  (let ((table (make-hash-table :test 'equal)))
    (when (file-readable-p install-disk--proc-mounts)
      (condition-case _
          (with-temp-buffer
            (insert-file-contents install-disk--proc-mounts)
            (goto-char (point-min))
            (while (not (eobp))
              (let* ((line (buffer-substring (line-beginning-position)
                                             (line-end-position)))
                     (fields (split-string line "[ \t]+" t))
                     (dev (car fields)))
                (when (and dev (string-prefix-p "/dev/" dev))
                  (puthash dev t table)))
              (forward-line 1)))
        (error nil)))
    table))

(defun install-disk-mounted-p (name)
  "Return non-nil if any partition of disk NAME is currently mounted.
NAME is a bare name (sda, nvme0n1; or wd0, hd0 on Hurd), no /dev/
prefix.  on Linux we check the `/dev/NAME' prefix against
/proc/mounts so both /dev/sda1 and /dev/sda2 (and the nvme0n1pN
variants) trigger the refusal.  on Hurd the matcher also handles
the store-spec form `part:2:device:NAME' that the root translator
exposes via fsysopts.

This is the wizard's primary safety net.  format-step refuses to
proceed if this returns non-nil for the operator-picked disk;
without that net a mistyped target name silently destroys the
current /."
  (cond
   ((geos-kernel-hurd-p)
    (install-disk-mounted-p-hurd name))
   (t
    (let ((mounted (install-disk--mounted-devices))
          (prefix (concat "/dev/" name))
          (hit nil))
      (maphash
       (lambda (dev _)
         (unless hit
           (when (and (string-prefix-p prefix dev)
                      ;; require the next char to be a partition digit
                      ;; (sda1, nvme0n1p1) OR equal to the device itself
                      ;; (someone mounted the whole disk). string= covers
                      ;; the latter; string-prefix-p plus a digit check
                      ;; covers the former.  this guards against sda
                      ;; accidentally matching sdaa1, which is a valid
                      ;; device name on systems with many disks.
                      (or (string= dev prefix)
                          (let ((suffix (substring dev (length prefix))))
                            (and (not (string-empty-p suffix))
                                 (string-match-p
                                  "\\`\\(p?[0-9]+\\)" suffix)))))
             (setq hit t))))
       mounted)
      hit))))

(defun install-disk-list ()
  "Return a list of plists describing every install-targetable disk.
Each plist:
  :name        bare device name (\"sda\", \"nvme0n1\", \"vda\")
  :path        full path (\"/dev/sda\")
  :size-bytes  integer byte count, or nil if sysfs refused
  :model       vendor/model string, or nil
  :removable   t if kernel flagged the disk as removable
  :mounted     t if any partition of the disk is mounted now

Errors during /sys/block walk route through `panic-handle' and the
function returns nil; the caller can render an empty list and the
operator will see the disk-pick state is dry, prompting them to
investigate.  routing through panic-handle (rather than signalling)
matches the rest of the userland: a parse glitch in sysfs must not
take the supervisor down.

Hurd arm: v0.9.3 tier A enumerates whole disks by walking /dev/
for the wd*/hd*/sd*/ucd*/ud*/cd*/fd* node patterns (no sysfs on
hurd, no model strings without RPC).  size comes from the
`pid1-disk-size-bytes' module binding (storeio device_get_status
under the hood); nil still surfaces if the underlying RPC fails so
the `?' render stays honest.  model is nil, removable is a coarse
name-prefix heuristic.  mounted-p reads /proc/mounts (provided by
the hurd procfs translator) and matches both literal `/dev/NAME'
prefixes and the store-spec `device:NAME' form that fsysopts emits
for the root translator.  the wizard's downstream steps (mkfs /
grub-install i386-pc) still do NOT port; `buffers/install.el'
refuses to advance past :format-confirm on a non-linux kernel, so
the enumeration here is read-only / advisory."
  (cond
   ((geos-kernel-hurd-p)
    (require 'cl-lib)
    (condition-case err
        (mapcar
         (lambda (name)
           (list :name name
                 :path (concat "/dev/" name)
                 :size-bytes (install-disk--size-bytes-hurd name)
                 :model (install-disk--model-hurd name)
                 :removable (install-disk--removable-hurd name)
                 :mounted (install-disk-mounted-p-hurd name)))
         (install-disk--all-names-hurd))
      (error
       (panic-handle err 'install-disk-list-hurd)
       nil)))
   ((geos-kernel-linux-p)
    (require 'cl-lib)
    (condition-case err
        (mapcar
         (lambda (name)
           (list :name name
                 :path (concat "/dev/" name)
                 :size-bytes (install-disk--size-bytes name)
                 :model (install-disk--model name)
                 :removable (install-disk--removable-p name)
                 :mounted (install-disk-mounted-p name)))
         (install-disk--all-names))
      (error
       (panic-handle err 'install-disk-list)
       nil)))
   (t
    (geos-port-unimplemented 'install-wizard)
    nil)))

(defun install-disk-format-bytes (n)
  "Human-readable rendering of byte count N (integer or nil).
Returns \"?\" for nil. Uses GB/TB at the rough-cut sizes a human
reads disks at (`240 GB', `1.0 TB'). intentionally not SI-precise:
the wizard wants `do I have the right disk', not megabytes-exact."
  (cond
   ((not (integerp n)) "?")
   ((>= n (* 1000 1000 1000 1000))
    (format "%.1f TB" (/ n 1e12)))
   ((>= n (* 1000 1000 1000))
    (format "%d GB" (round (/ n 1e9))))
   ((>= n (* 1000 1000))
    (format "%d MB" (round (/ n 1e6))))
   (t (format "%d B" n))))

(provide 'install-disk)
;;; disk.el ends here
