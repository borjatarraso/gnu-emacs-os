<!-- SPDX-License-Identifier: FSFAP -->

# 2026-05-18: emacs-init booted as PID 1 on GNU/Hurd

First-ever boot of the GEOS supervisor as user-mode init on a
real Hurd kernel.  Receipt + honest list of what broke.

## Result

**PASS at the structural level.**  `/hurd/startup` (Hurd's
bootstrap PID 1) exec'd `/sbin/init`, which is the emacs-init
binary I built earlier today.  emacs-init parsed its argv,
walked through the early-mount sequence, hit several
Hurd-specific failures (documented below), still reached the
supervisor loop, attempted to spawn emacs, hit a crashloop
because `/usr/bin/emacs` is not installed on the Debian Hurd
snapshot, and **the crashloop detector engaged exactly as
designed**: it backed off, logged the holding-pattern message,
and stopped respawning while remaining alive to reap zombies.

Screen capture: `2026-05-18-hurd-pid1-boot-screen.png` (next
to this file).  Verbatim transcript of the visible portion:

```
pid1: mkdir /tmp failed: Read-only file system
/hurd/tmpfs: No default pager (memory manager) is running
Started it
pid1: mount tmpfs -> /tmp (tmpfs) failed: Input/output error
pid1: mkdir /var failed: Read-only file system
tmpfs: too many arguments
Try `tmpfs --help' or `tmpfs --usage' for more information.
pid1: /var mount failed entirely: Input/output error
pid1: INFO no gnu.system= in /etc/geos-cmdline, /run/current-system not linked
      (expected on manual Hurd install)
pid1: sethostname(geos-hurd) failed: Read-only file system
pid1: entering supervisor loop
pid1: execve(emacs) failed
pid1: emacs exited, respawning
pid1: execve(emacs) failed
pid1: emacs exited, respawning
[... eight more respawn cycles ...]
pid1: emacs crashloop, entering holding pattern; supervisor will reap zombies
      but not respawn emacs
```

## What this verifies for real

  - Hurd's `/hurd/startup` -> `/sbin/init` handoff accepts an
    arbitrary ELF as init; no init-specific protocol required.
  - The `GEOS_CMDLINE_PATH` macro flip (`/etc/geos-cmdline`
    instead of `/proc/cmdline`) works: `read_gnu_system_path`
    opened the path, hit the absent-file branch cleanly, and
    logged the documented `INFO no gnu.system=` line.
  - PORT_HURD compile-time gating of the Linux mounts (proc /
    sys / dev / devpts) worked: none of those mounts were
    attempted.
  - `read_geos_mode` -> recovery-protected force-to-console
    path runs: emacs-init proceeded to the supervisor loop
    (the recovery branch was not requested in this boot).
  - The supervision throttle (`core/supervise.el`'s
    counterpart in pid1's C-level respawn cap) is observable:
    after ~10 fast respawns it switched to holding pattern
    and stopped spawning.  This is the behavior under
    "emacs binary missing"; in normal boot the loop spawns
    once successfully and waits.

## What broke (next pulse)

Three issues, all on the pid1 / Hurd-bootstrap seam, none
fatal to the supervisor:

### 1. Root FS is read-only at init time

`/sbin/init` runs **before** Debian Hurd's `checkroot.sh`
remounts root rw.  All three `mkdir` calls for `/var`,
`/tmp`, `/run` fail with `Read-only file system`.  Same for
`sethostname(geos-hurd)`.

**Fix candidate:** on PORT_HURD, defer the early-mount
sequence until after a remount-rw pass.  Either:
  - emacs-init issues the rw remount itself (translator
    swap on `/` via `file_set_translator`), or
  - emacs-init skips the writable-FS-dependent ops on the
    first pass and retries from elisp once the supervisor
    is up.

The second is closer to GEOS's "everything important is
elisp" thesis and lets the C side stay small.

### 2. tmpfs needs a default pager

`/hurd/tmpfs: No default pager (memory manager) is running`
is a Hurd-environment precondition.  Linux's tmpfs uses
kernel memory directly; Hurd's tmpfs is a translator that
needs the default pager up (`/hurd/proxy-defpager` typically).

**Fix candidate:** on PORT_HURD, check for the pager before
attempting tmpfs translators; if absent, fall back to
overlay-style state on the root FS.  Or refuse to mount
tmpfs from the C side and let elisp handle it once
userspace is more complete.

### 3. tmpfs argv: "too many arguments"

The src-filter I added in `hurd_mount` (only pass src to
tmpfs when it matches a size pattern) is correct in
principle but the argv assembly is still wrong: `tmpfs`
is receiving extra tokens past its size argument.  Need to
re-audit `port_hurd.c:hurd_mount` against the actual
`/hurd/tmpfs` CLI.

**Fix candidate:** read `/hurd/tmpfs --help` on the VM,
write a focused unit test in `freeze-tests.el` for the
argv shape produced by `hurd_mount`, fix until the test
passes.

### 4. emacs binary absent (not a bug)

`/usr/bin/emacs` is not installed on the Debian Hurd
snapshot.  emacs-init's respawn-then-throttle behavior
is correct.  Once emacs is installed (or we drop a stub
that exits 0 just to prove the spawn path), the loop will
quiesce.

## Why this is a milestone, not "almost"

For the past two weeks the question "does emacs-init
actually become PID 1 under Hurd's bootstrap" has been a
desk-review hypothesis backed by `port_caps`-slot unit
tests.  This boot collapses that hypothesis to a fact.
The remaining items above are bugs in concrete code
paths I can see and reproduce; they are not unknowns
about the Hurd boot protocol.

## How I reproduced

  1. Built emacs-init with `PORT=hurd` on the VM
     (`gcc -DPORT_HURD ...` driven by `make PORT=hurd`,
     produces a 29216-byte ELF).
  2. Snapshotted the live image to
     `debian-hurd-amd64-20260314.pre-pid1.img` so we can
     restore.
  3. `cp /sbin/init /sbin/init.debian-orig` then
     `cp emacs-init /sbin/init` then
     `cp emacs-init /usr/sbin/init` (sysvinit's
     `update-rc.d` keeps two paths in sync; safer to
     write both).
  4. `system_reset` via the QEMU monitor.  GRUB picked the
     same default entry (no `init=` cmdline on Hurd; the
     init binary is identified by `/sbin/init`'s path).
  5. After ~30s the screen showed the transcript above;
     SSH did not come back (expected, since emacs-init does
     not bring up sshd).
  6. Captured screen via `screendump` on the QEMU monitor,
     converted PPM -> PNG with ImageMagick, copied here.

## What I am doing next, in order

  1. Restore from the pre-pid1 snapshot so the VM is
     usable for the followup edits.
  2. Fix the three items above (#1 the most important; #2
     and #3 are mechanical).
  3. Install a tiny stub at `/usr/bin/emacs` that prints
     a banner and exits, so the supervisor's "spawn
     succeeded" path can be exercised end-to-end without
     dragging a full emacs install onto Hurd.
  4. Re-boot, re-screencap, write the next runlog.
  5. Only after that does it make sense to test
     `pid1-reboot` (the `host_reboot` Mach RPC), since
     that test needs an emacs instance that the supervisor
     can issue the rpc to.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
