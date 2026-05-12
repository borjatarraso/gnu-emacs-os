;;; disk.el --- block-device enumeration for the *install* wizard -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

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
NAME is a bare name (sda, nvme0n1), no /dev/ prefix.  we check the
prefix `/dev/NAME' against /proc/mounts so both /dev/sda1 and
/dev/sda2 (and their nvme0n1pN variants) trigger the refusal.

This is the wizard's primary safety net.  format-step refuses to
proceed if this returns non-nil for the operator-picked disk;
without that net a mistyped target name silently destroys the
current /."
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
    hit))

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

Hurd guard: the install wizard is linux-only.  the implementation
reads /sys/block (no sysfs on hurd) and the wizard's downstream
steps (mkfs / grub-install i386-pc) also do not port.  per the hurd
spike work order, install/ is NOT branched; it refuses with a clear
error.  routed through `geos-port-unimplemented' for the *panic*
trail and returns nil so the *install* buffer renders an empty
disk list with a banner."
  (cond
   ((not (geos-kernel-linux-p))
    (geos-port-unimplemented 'install-wizard)
    nil)
   (t
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
       nil)))))

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
