<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

## 2026-05-23: v0.9.18 canonical Debian Hurd 0.9 image re-roll with pid1 baked in

this is the receipt for the v0.9.17 follow-on #1 flagged at
docs/runlogs/2026-05-23-hurd-v0917-syslog-tail-verify.md and earlier
at the v0.9.16 cold-boot receipt. previous Hurd verify cycles needed
30+ minutes of per-cycle setup (GRUB patching for serial, ssh-key
injection, pid1 binary placement, init swap from sysv to pid1). this
ship is one shell script at iso-build/hurd-image-reroll.sh
(main/7fa3829) that consumes the pristine canonical base image plus
the extracted STATIC=1 pid1 binary and emits a single bootable image
that lands SSH-able in 2-4 minutes with no per-cycle setup. the image
itself is not in the repo; the script is.

## Result

PASS on the load-bearing image-reroll claim. a single invocation of
./iso-build/hurd-image-reroll.sh against the pristine canonical
base produces /home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0918.img
(4,194,304,000 B raw), and that image boots end-to-end on canonical
Debian GNU/Hurd 0.9 with pid1 as actual PID 1, SSH first-try on the
staged key, and the supervised emacs respawning on forced SIGSEGV via
the v0.9.13 supervisor loop. this is the first time pid1 has booted as
actual PID 1 on canonical Debian Hurd 0.9; the v0.9.17 syslog verify
substituted sysv-init at PID 1, which masked an entire ground-truth
domain that this receipt opens.

the caveat that does not soften: the shipped image carries a minimal
sshd-direct init.args (3 slots + an inline --eval), not the canonical
35-file chain. the full chain triggers emacs's kill_emacs_0.eln
trampoline build path on first boot, which needs the `as` assembler,
and canonical Debian Hurd 0.9 has no `as`. the committed script ships
the minimal variant so re-runs produce a bootable image. the full
chain is the explicit v0.9.19 work.

## What this slice ships

- iso-build/hurd-image-reroll.sh (+350 lines, mode 0755) on main at
  7fa3829. consumes the pristine canonical base image plus the
  extracted STATIC=1 pid1 binary and emits the rerolled image.
  preserves stock Debian init at /sbin/init.debian-stock for rescue.
  patches GRUB to route to com0 (3 of 3 multiboot lines). stages the
  ssh authorized_keys, writes the minimal init.args, runs all
  filesystem ops via guestfish with explicit `run` + `mount /dev/sda2`
  (the `-i` shortcut fails on Hurd images, see anomaly 5).

no elisp shipped. no port_hurd.c shipped. no HURD_PORT.md row gained.
this is operator quality-of-life work.

## Build matrix

Linux dev host: shellcheck-clean and `bash -n` clean on
iso-build/hurd-image-reroll.sh; one full end-to-end run on the host
produced the shipped image at
/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0918.img.

Hurd VM (booted from the rerolled image under QEMU, host port 2267,
key /tmp/hurd_vm_key): boots to a login banner on serial in ~2.5
minutes; ssh first-try; PID 1 is the STATIC pid1 binary; forced
SIGSEGV on the supervised emacs respawns clean via PORT_HURD's
supervisor loop.

## Probe run

first-boot uname and release identity (transcript at
/tmp/v0918-rerolled-first-boot-ssh.log):

```
$ uname -a
GNU lambda 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9 x86_64 GNU
$ cat /etc/debian_version
forky/sid
```

PID 1 identity check on first boot. `/sbin/init` is the 1,552,824-byte
STATIC pid1, matching the v0.9.17 STATIC=1 verify BuildID:

```
$ file /sbin/init
/sbin/init: ELF 64-bit LSB executable, x86-64, statically linked,
  BuildID[sha1]=56280a2f..., for GNU/Hurd 0.0.0
$ ls -la /sbin/init.debian-stock
-rwxr-xr-x 1 root root 45192 ... /sbin/init.debian-stock
```

process tree on first boot, abbreviated to the load-bearing rows
(`ps Aw`):

```
PID  COMMAND
1    /sbin/init -a
2    /hurd/startup
3    gnumach
...  /hurd/proc /hurd/auth /hurd/exec /hurd/pflocal /hurd/term ...
30   emacs (supervised)
36   sshd (reparented under emacs)
```

GRUB serial routing on first boot, visible on host stdio (vs. the
pristine image's silent gfxterm). 3 of 3 multiboot lines carry
`console=com0` (main entry plus two advanced-submenu rescue entries;
the sed ERE `\t{1,2}` matches both tab-depths):

```
terminal_output serial console
... multiboot /boot/gnumach-... root=device:wd0s2 console=com0
... module  /hurd/ext2fs.static ... console=com0
... module  /lib/ld.so.1 ... console=com0
```

respawn proof on first boot (serial at
/tmp/v0918-rerolled-first-boot-serial.log). the inline --eval reaches
its tail print, then I sent SIGSEGV to the supervised emacs:

```
v0918-min: ready, dropping into event loop
/hurd/crash: ... (28) crashed, signal {no:11, code:11, error:0}
pid1: emacs exited, respawning
v0918-min: ready, dropping into event loop
v0918-min: ready, dropping into event loop
```

three `ready` cycles, two crash + respawn transitions, all honored by
PORT_HURD's supervisor loop.

idempotency on second boot from the same image, no state carried
(transcripts at /tmp/v0918-rerolled-second-boot-{serial,ssh}.log).
same SSH key, same port 2267, uptime 2.3 minutes at probe time. PID 1
is still pid1, supervised emacs still at PID 30, sshd still at PID 36.
the image is reproducibly bootable.

## Open follow-ons (do NOT block this receipt's commit)

1. the canonical 35-file init.args chain wedges supervised emacs on
   pid1-as-actual-PID-1. the `-l` chain triggers emacs's
   kill_emacs_0.eln trampoline build path, which needs the `as`
   assembler at runtime. canonical Debian Hurd 0.9 has no `as`, so
   emacs cannot complete the trampoline write and exits. the v0.9.17
   syslog verify masked this entire domain by running stock sysv at
   PID 1. the shipped image carries a minimal sshd-direct init.args
   (3 slots + inline --eval that opts out of native-comp, settrans
   pfinet eth0, spawns `sshd -D -e`); the committed script was
   updated to ship that same minimal variant so re-runs produce a
   bootable image. next step: either add `as` (or a precompiled
   trampoline drop-in) to the bake step, or extend the
   no-native-comp opt-out further up the canonical load chain, then
   re-roll under the full chain and re-run this probe.

2. `if=virtio` boot fails on Hurd:
   `ext2fs: part:2:device:wd0: No such device or address`. gnumach
   hardcodes `wd0` (IDE naming). the operator must use
   `-drive file=...,if=ide,index=0` plus `-device e1000,netdev=net0`
   instead of virtio. not a script concern (the script does not
   choose disk/NIC backends), but worth a HURD_BOOT.md doc update.
   next step: write that doc line in the v0.9.19 cycle.

3. pfinet requires explicit
   `settrans -fgap /servers/socket/2 /hurd/pfinet -i /dev/eth0 -a 10.0.2.15 -m 255.255.255.0 -g 10.0.2.2`
   before sshd can accept connections. wired into the minimal
   init.args inline today. the full-chain `core/network.el` path does
   this differently; a hurd-bootstrap helper may be needed when the
   full chain ships under item 1. next step: factor a helper once
   item 1 lands.

4. /etc/hostname missing from pristine canonical image. pid1 logs
   `defaulting to lambda`, uname reports `GNU lambda 0.9`. cosmetic.
   next step: have the bake script write /etc/hostname during the
   guestfish session (nice-to-have, v0.9.19).

5. guestfish `-i` fails on Hurd images
   (`mount_ro_stub: /dev/wd0s2: No such file or directory`). all
   guestfish invocations in the script use explicit `run` plus
   `mount /dev/sda2 /`. /dev/sda1 is swap, /dev/sda2 is ext2 root;
   verified via virt-filesystems. this is documented behavior of the
   script today, not a bug. next step: none unless libguestfs gains
   Hurd autodetect upstream.

## Preserved artifacts

```
/home/overdrive/hurd-vm/debian-hurd-amd64-20260314.pre-pid1.img
  (pristine canonical base, treated read-only)
/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0918.img
  (the rerolled image, 4,194,304,000 B, mtime 2026-05-23 20:25)
/tmp/v0918-rerolled-first-boot-serial.log
/tmp/v0918-rerolled-first-boot-ssh.log
/tmp/v0918-rerolled-second-boot-serial.log
/tmp/v0918-rerolled-second-boot-ssh.log
/tmp/hurd_vm_key                       (SSH private key)
iso-build/hurd-image-reroll.sh         (committed at main/7fa3829)
```

## Files touched on the main branch

- docs/runlogs/2026-05-23-hurd-v0918-image-reroll.md (+this file)

the next time the rerolled-image boot path on canonical Debian Hurd
0.9 changes, 2026-05-23 is the bisect waypoint that says pid1 booted
clean as actual PID 1 here.

## license

This document is licensed under the GNU Free Documentation License,
Version 1.3 or any later version published by the Free Software
Foundation; with no Invariant Sections, no Front-Cover Texts, and no
Back-Cover Texts.

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3 or
any later version published by the Free Software Foundation; with no
Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.  A
copy of the license is included in the file `COPYING.DOC` at the top
of this distribution.
