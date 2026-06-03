<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

# 2026-05-30 v0.9.23 install wizard slice C live-verify on Hurd

Continuation of docs/runlogs/2026-05-30-hurd-v0922-slice-b-ide-e1000.md.
Task #210, the last v1.x install-wizard slice that was blocked on
having a canonical Hurd image that boots end-to-end with the
supervisor up. v0.9.22 unblocked it; v0.9.23 closes it.

The slice C code already shipped at main/db3c14b in the v0.9.x
codebase: `install-yes` was already relaxed so both
`geos-kernel-linux-p` and `geos-kernel-hurd-p` advance through the
same mkfs.ext4 + grub-install + grub-mkconfig chain, and `install/`
already used `make-process` for both binaries with no shell wrapping.
What was outstanding was the live VM-verify that the elisp wrapper
chain actually drives mkfs.ext4 and grub-install end-to-end on real
canonical Debian Hurd 0.9.

## Result

PASS, both halves.

- `install-mkfs-ext4` against `/dev/wd1s1` returns `(t nil)` from its
  callback. The resulting ext4 mounts via `settrans -a /mnt/wd1
  /hurd/ext2fs /dev/wd1s1` and lists `lost+found`, proving the
  filesystem is real and reachable.
- `install-grub-install` against `/dev/wd1` with
  `--boot-directory=/mnt/wd1/boot` returns `(t nil)` from its
  callback. The work buffer shows "Installation finished. No error
  reported." and the exit-status line shows `code=0`.
  `/mnt/wd1/boot/grub/i386-pc/core.img` is 28,424 bytes and the MBR
  (first 512 bytes of `/dev/wd1`) contains the GRUB signature plus the
  `Geom` error string.

## How it was verified

Test rig: v0.9.22 image (debian-hurd-amd64-geos-v0922.img qcow2
overlay) booted under QEMU with a second IDE disk attached as the
install target:

```
qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \
    -drive file=...v0922.img,if=ide,index=0,format=qcow2 \
    -drive file=/tmp/v0922-installc-target.qcow2,if=ide,index=1,format=qcow2 \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2266-:22 \
    -device e1000,netdev=net0 \
    -nographic -serial file:... -display none
```

The second disk enumerated as `/dev/wd1` first try; storeio attached
automatically (`/hurd/storeio @/dev/disk:wd1`).

Probe sequence over ssh into the supervised emacs:

1. Verify binaries present:
   `/usr/sbin/mkfs.ext4` + `/usr/sbin/grub-install` +
   `/usr/sbin/grub-mkconfig` all exist on canonical Hurd.

2. Partition the second disk with a single Linux primary covering
   all 2 GiB. fdisk reports "Re-reading the partition table failed:
   Function not implemented" (gnumach BLKRRPART isn't there), but
   showtrans /dev/wd1s1 returns `/hurd/storeio -T typed
   part:1:device:@/dev/disk:wd1` so storeio is already serving the
   new partition node. The kernel re-read failure is harmless for
   the slot the wizard targets.

3. Confirm both elisp wrappers are loaded in the supervised emacs:
   ```
   emacsclient --eval "(fboundp 'install-mkfs-ext4)"  -> t
   emacsclient --eval "(fboundp 'install-grub-install)" -> t
   ```

4. Drive install-mkfs-ext4 through its sentinel callback:
   ```elisp
   (let ((done nil) (res nil))
     (install-mkfs-ext4 "/dev/wd1s1" "geos-elisp-test"
       (lambda (ok reason) (setq done t res (list ok reason))))
     (while (not done) (sleep-for 0.3))
     res)
   ```
   Result: `(t nil)`. Mount and list confirms lost+found is there.

5. Drive install-grub-install through its sentinel callback against
   the partition's parent disk:
   ```elisp
   (install-grub-install "/dev/wd1" "/mnt/wd1"
     (lambda (ok reason) (setq done t res (list ok reason))))
   ```
   Result: `(t nil)`. Verification reads back from the test disk:
   - `ls /mnt/wd1/boot/grub/` -> `fonts grubenv i386-pc locale`
   - `ls -la /mnt/wd1/boot/grub/i386-pc/core.img` -> 28,424 bytes
   - `dd if=/dev/wd1 bs=512 count=1 | strings` -> contains `GRUB`
   - work buffer tail: `Installation finished. No error reported.`
     followed by `--- grub-install exit: status=exit code=0 ---`

## What this slice ships

No code change. Slice C's load-bearing code is already on main:

- `emacs-init/buffers/install.el` (main/db3c14b): `install-yes` gate
  passes both `geos-kernel-linux-p` and `geos-kernel-hurd-p` through
  the same `install--enter-format` path. The hurd arm of
  `install--partitions-for` returns a plist; `install--part-node`
  resolves it to a `/dev/wd0sN` string downstream.
- `emacs-init/install/mkfs.el`: `install-mkfs-ext4` uses
  `make-process` with `(mkfs.ext4 -F -L label device)` argv.
- `emacs-init/install/grub.el`: `install-grub-install` uses
  `make-process` with `(grub-install --target=i386-pc
  --boot-directory=TARGET/boot DEVICE)` argv.

v0.9.23 ships this receipt only, plus a README entry and the matching
memory update. The HURD_PORT matrix row for install slice C flips
from "code-shipped, VM-verify pending" to "code-shipped, VM-verified".

## Followups closed by this release

- task #210 (v1.x install wizard slice C: relax + VM-verify). Closed
  by the live-verify above.

## Followups still open

- task #213 (v0.9.19 follow-on #2: glibc Hurd __mach_msg SIGSEGV from
  pselect on supervised emacs). The supervised emacs ran several
  minutes under this verify cycle (driving emacsclient evals, holding
  a mounted ext2fs translator, owning the sshd autostart) without
  the SIGSEGV. Status: not reproduced under v0.9.22 / v0.9.23 verify
  conditions. Closing this task is contingent on a longer or busier
  soak; downgrading the urgency.

- task #188 (geos-hurd-ensure-path). Stays HOLD per the project
  no-premature-abstraction rule.

## Lesson recorded

emacsclient on canonical Hurd still emits `setsockopt: Protocol not
available` on every connection (the v0.9.19 bucket-2 SO_RCVTIMEO
deferred-upstream item). It is cosmetic: the eval still returns the
correct value. Every probe in this cycle had to tail past that line.
Future receipts should not let it cloud the verdict.
