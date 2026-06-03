<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

# 2026-05-18: emacs spawned by pid1 on GNU/Hurd

Followup to `2026-05-18-hurd-pid1-boot-result.md`.  The
supervisor's crashloop is gone; emacs is up and `*scratch*`
renders on the Hurd console.

## Result

**PASS.**  emacs-init exec'd `/usr/bin/emacs` and the standard
`*scratch*` greeting appears verbatim on /dev/console:

```
;; To create a file, visit it with `C-x C-f' and enter text in its buffer.

-=1-:---  F1  *scratch*    All L4   (Lisp Interaction ElDoc) --------
```

Screen capture: `2026-05-18-hurd-pid1-emacs-spawn-screen.png`.

## What changed since the previous runlog

One C change, two diagnostic improvements, one habit change:

  - `pid1/emacs-init.c`: argv[1..3] now require a leading `/`
    before being accepted as emacs-path / module-path / Xorg-spec.
    Hurd's `/hurd/startup` passes a sysvinit-style runlevel token
    (`"6"` after a clean shutdown -r) as argv[1].  The old code
    blindly set `emacs_path = argv[1]`, so execve was called on
    `"6"` and returned ENOENT in a tight loop.  The fix is on
    both main and the hurd branch.  Skeptic asked for a
    breadcrumb log when the guard rejects an argv entry, and for
    the same `/` check to apply to argv[2] and argv[3]; both
    landed.
  - `pid1/emacs-init.c`: execve failure log emits errno first,
    path second, so snprintf truncation drops the path tail
    rather than the errno.  A 4096-byte /gnu/store path would
    otherwise have hidden the actual failure reason.
  - `cp /sbin/init /sbin/init.debian-orig` always BEFORE the
    swap-in, and clean `shutdown -r now` from inside the VM
    always BEFORE any QEMU monitor reset.  Two earlier attempts
    today used `system_reset` directly and corrupted ext2fs into
    a maintenance-shell boot.  Restored from snapshot both times.

## What this verifies for real

  - The full chain works: `gnumach` -> `/hurd/startup` ->
    `/sbin/init` (= emacs-init) -> supervisor loop ->
    `execve("/usr/bin/emacs")` -> emacs running with
    `*scratch*` rendered on /dev/console.
  - The argv contract is now Hurd-safe.  emacs-init no longer
    misreads a runlevel as an executable path.
  - The crashloop detector + holding-pattern in the supervisor
    was already proven on the previous boot; this boot proves
    the success path next to it.
  - The diagnostic format is the one we want long-term:
    `pid1: execve failed (ENOENT): /usr/bin/emacs` reads as a
    sentence.

## What is still pending verification

  - `port->reboot` (host_reboot Mach RPC).  Cannot be tested
    from outside without driving keystrokes into the Hurd
    console; the QEMU sendkey path is mechanical but messy.
    The function builds and links against -lmach; verifying it
    end-to-end is the last gating step before promoting the
    row in HURD_PORT.md from "builds" to "verified".
  - Bootstrap-order noise from the previous runlog: read-only
    root at init time, tmpfs default pager missing, tmpfs argv
    shape.  These are tracked separately as task #104.  They
    do not block "emacs spawned at all".

## Why this is the v0.7.x Hurd milestone

The two questions that have driven the Hurd side branch for
the past two months were:

  1. Does Hurd's bootstrap actually let an arbitrary ELF act
     as `/sbin/init`, or does it require a sysvinit-specific
     protocol?  Answered yes on the previous boot.
  2. Does the same emacs-init.c that supervises emacs on Linux
     also supervise emacs on Hurd, given the port_caps seam
     and the PORT_HURD ifdef gating?  Answered yes on this
     boot.

The remaining work on the Hurd branch is no longer about
"does it boot at all" but about cleaning up the bootstrap-
order diagnostics and ticking the reboot RPC across the
finish line.  Both are tracked as concrete tasks.

## Reproduction

  1. Restore from `debian-hurd-amd64-20260314.pre-pid1.img`
     snapshot.
  2. SCP rebased `pid1/emacs-init.c` + `pid1/port_layer.h` +
     `pid1/port_hurd.c` + `pid1/Makefile` to the VM.
  3. `cd /root/geos/pid1 && make PORT=hurd STATIC=0` -> 29280-byte
     ELF.
  4. `cp /sbin/init /sbin/init.debian-orig`
     `cp emacs-init /sbin/init`
     `cp emacs-init /usr/sbin/init`
     `sync`
  5. `shutdown -r now` from inside the VM (NOT
     `system_reset` from QEMU monitor: hard reset corrupts
     ext2fs, drops to maintenance shell on next boot).
  6. After ~30s, `screendump /tmp/hurd-screen.ppm` from QEMU
     monitor, convert to PNG.  Greeting line appears as
     above.
