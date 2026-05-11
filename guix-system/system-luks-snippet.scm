;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>

;; system-luks-snippet.scm, the LUKS-rooted-boot delta against
;; system.scm.  this file is NOT loaded by guix; it documents the
;; edits required to produce a LUKS-encrypted-root GEOS image.  copy
;; the forms below into your system.scm, replace LUKS-UUID with the
;; uuid of your pre-formatted LUKS partition (cryptsetup luksFormat
;; output, queryable via `cryptsetup luksUUID /dev/sdaN'), and
;; rebuild.
;;
;; why a snippet instead of a parametric system.scm: the bare-metal
;; install wizard that materialises the LUKS partition in the first
;; place is v0.4 item 3 and still partial.  until that lands, the
;; LUKS flow assumes you have a separate live system to run
;; cryptsetup from.  the QEMU smoke-test path does NOT exercise LUKS;
;; system.scm stays simple so the headless test stays simple.
;;
;; what Guix supplies for free: its stock initrd already knows how to
;; prompt on /dev/console for a LUKS passphrase, call cryptsetup-open
;; on the source uuid, materialise /dev/mapper/<target>, and continue
;; to root mount.  no custom initrd helper is required.  GRUB 2.06+
;; supports LUKS2 directly (Guix's bootloader is well past that
;; cutoff), so /boot can live on the encrypted root and the
;; unencrypted ESP only carries the GRUB stage1.

;;; ---- edit 1: mapped-devices field on the operating-system ----
;;
;; add this field to your operating-system record (the base-os
;; binding in system.scm).  source is the uuid of the on-disk LUKS
;; partition; target is the name /dev/mapper/<target> will materialise
;; under.  geos-root is the convention this project uses; any name is
;; fine as long as the file-systems field below matches.

(mapped-devices
 (list (mapped-device
        (source (uuid "LUKS-UUID-HERE"))
        (target "geos-root")
        (type luks-device-mapping))))

;;; ---- edit 2: root file-system pointer ----
;;
;; replace the file-systems entry that points at %geos-root-uuid with
;; one that points at the mapper device produced by the unlock above.
;; the deterministic-uuid dance in system.scm assumes the root is the
;; partition itself, so under LUKS we drop the dance and point the
;; root at the literal mapper path.

(file-systems
 (cons (file-system
         (mount-point "/")
         (device "/dev/mapper/geos-root")
         (type "ext4")
         (dependencies mapped-devices))
       %base-file-systems))

;;; ---- edit 3: initrd-modules ----
;;
;; the stock %base-initrd-modules does not include the crypto kernel
;; modules.  splice them in alongside the virtio_gpu / psmouse /
;; usbhid additions already in %geos-initrd-modules.

(initrd-modules
 (cons* "dm-crypt"
        "aes"
        "aes_generic"
        "xts"
        "sha256_generic"
        %geos-initrd-modules))

;;; ---- pre-install steps (run from a Guix live ISO) ----
;;
;; 1. wipe and LUKS-format the target partition (LUKS2 default).
;;    cryptsetup luksFormat --type luks2 /dev/sdaN
;;    cryptsetup luksUUID /dev/sdaN   # capture this for LUKS-UUID-HERE above
;;
;; 2. open it once so you can mkfs.
;;    cryptsetup open /dev/sdaN geos-root
;;    mkfs.ext4 -L geos-root /dev/mapper/geos-root
;;
;; 3. mount /dev/mapper/geos-root, herd `guix system init` against
;;    your edited system.scm.  Guix populates /gnu/store, writes the
;;    bootloader to /dev/sda, and tells you to reboot.
;;
;; 4. on reboot, GRUB loads, kernel + initrd unpack, the stock initrd
;;    prompts on /dev/console for the LUKS passphrase, opens the
;;    mapper device, mounts root, and PID 1 takes over as normal.
;;
;; caveats:
;;   - detached headers are out of scope for v0.4.  the header stays
;;     on the encrypted partition.
;;   - no escrow / no key-file fallback in v0.4; passphrase only.
;;   - on a libre-only laptop with no AES-NI, expect slower boot.
;;     XTS-AES at 256 bits without hardware acceleration is workable
;;     but noticeable.
;;   - the *disks* buffer learning to unlock additional LUKS volumes
;;     (data partitions, external drives) is a v0.5 follow-up; for
;;     v0.4 only the root is in scope, and that one is the initrd's
;;     job.
