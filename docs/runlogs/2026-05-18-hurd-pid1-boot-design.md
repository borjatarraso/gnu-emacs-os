# 2026-05-18 hurd boot-as-PID-1 design gap

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

## Milestone

Not a "verified" milestone, an "investigated and documented"
milestone. After the 2026-05-17 runtime sweep promoted six
port_caps slots to YES on Debian GNU/Hurd, the obvious next step
was to actually boot emacs-init as the first user-mode process on
the Hurd VM. This runlog captures the blockers I found when I
went to do that, so future me (or anyone picking up the port)
does not re-discover them.

The takeaway up front: booting emacs-init as PID 1 on Hurd is not
the same shape of task as booting it as PID 1 on Linux. The
mechanism is different, the assumptions in `main()` are different,
and the install path is different. This needs a deliberate
Hurd-side boot path, not just a kernel cmdline edit.

## Environment

Same Debian GNU/Hurd 2026-03 snapshot VM as the prior runlogs.
SSH still works over QEMU NAT, console log at `/tmp/hurd-
console.log`, repo cloned at `/root/geos`, emacs-init binary
built at `/root/geos/pid1/emacs-init` (29752 bytes, all 9 slots
present in symbol table, `ldd -r` clean).

VM image snapshot exists for rollback if the boot is attempted
and bricks the install:
`debian-hurd-amd64-20260314.pre-pid1.img` (4 GB).

## What I checked

### no getpid()==1 runtime check

`grep getpid pid1/emacs-init.c` returns nothing. `grep 'PID *1'`
returns only comments. The boot path does not abort if it is
running at PID 2+. So emacs-init can in principle be exec'd by
`/hurd/startup` as user-mode init and proceed.

### Hurd has no init= kernel cmdline

The Hurd boot sequence is:

```
firmware -> GRUB -> multiboot module chain (pci-arbiter, acpi,
                    rumpdisk, ext2fs, exec) -> GNU Mach
GNU Mach -> /hurd/startup (this is PID 1, kernel-spawned,
                           non-replaceable from cmdline)
/hurd/startup -> /sbin/init (user-mode init)
```

There is no `init=` knob the way Linux has one. The user-mode
init binary is `/sbin/init` because `/hurd/startup` is hard-coded
to exec it. The install path for emacs-init on Hurd is "replace
/sbin/init", not "edit kernel cmdline".

On the Debian Hurd snapshot in the VM:

```
$ file /sbin/init
/sbin/init: ELF 32-bit LSB executable, Intel 80386,
            version 1 (GNU/Hurd), dynamically linked, ...
$ stat -c %s /sbin/init
45192
```

A 45 KB dynamically-linked ELF. The replacement binary I built
(`/root/geos/pid1/emacs-init`, 29752 bytes) is smaller, with
fewer dependencies, but it would be the new `/sbin/init` and
would need to do whatever `/sbin/init` does today plus whatever
emacs-init wants to do.

### Linux-only assumptions in main()

Reading `pid1/emacs-init.c` main() with a Hurd eye:

  - The pseudo-FS mounts (`/proc proc`, `/sys sysfs`,
    `/dev devtmpfs`, `/run tmpfs`, `/tmp tmpfs`,
    `/dev/pts devpts`) are Linux filesystem names. On Hurd,
    `/proc` is a translator (`/hurd/procfs`), `/sys` does not
    exist as a tree, `/dev` is real, and `devpts` does not
    exist. `do_mount()` logs-and-continues on failure, so this
    is loud but not fatal.
  - `link_current_system()` reads `/proc/cmdline` for
    `gnu.system=`. Hurd has `/proc/cmdline` (via the procfs
    translator) but it does NOT contain a `gnu.system=` token,
    because GEOS-on-Hurd is not yet a guix-system. There is no
    `/run/current-system` to point at because there is no guix-
    system profile in the Hurd VM. This needs a Hurd-specific
    replacement, probably "read the path from `/etc/geos-
    profile` if it exists, otherwise degrade gracefully and let
    elisp's `executable-find` walk `PATH`".
  - `read_geos_mode()` reads `/proc/cmdline` for `geos.mode=`.
    Same problem, same fix shape.
  - The Xorg bring-up assumes Linux DRM device nodes
    (`/dev/dri/card0`) and the modesetting driver. Hurd ships
    Xorg but the device layer is different. Out of scope for
    the v0.7.x abstraction; this is a v0.8+ item.
  - The emacs binary path defaults to `/usr/bin/emacs`. Debian
    Hurd does ship `/usr/bin/emacs` if the package is installed,
    so this might Just Work for a manual install path. For a
    guix-system Hurd install (the eventual end state), this
    needs the same store-path argv plumbing the Linux side has.

### Boot-as-PID-1 install path

If I were to do it today, the procedure on the VM would be:

```
# inside the VM
cp /sbin/init /sbin/init.debian-orig
cp /root/geos/pid1/emacs-init /sbin/init
sync
reboot
```

This would brick the VM if emacs-init aborts before opening
console. Hence the snapshot. Recovery is "restore the qcow2
from the snapshot", not "edit the running system".

I am NOT doing this today because the Hurd-specific boot path
does not exist yet and the boot would fail in a way that does
not teach me anything I do not already know from reading the
source. The path forward is:

  1. Add a `#ifdef PORT_HURD` boot variant in main() that:
     - skips the Linux pseudo-FS mounts (or replaces them with
       no-ops because Hurd's filesystems are translator-attached
       already)
     - reads gnu.system / geos.mode from `/etc/geos-cmdline` (a
       Hurd-specific file written at install time) instead of
       `/proc/cmdline`
     - degrades gracefully when the file is absent
  2. Hurd-side `/run/current-system` linker (or skip the
     symlink entirely if the manual Hurd install does not yet
     have a guix profile)
  3. Skip Xorg bring-up on Hurd in the v0.7.x cycle; console-
     mode boot only for the first verification.
  4. Install emacs-init as `/sbin/init`, restart the VM, watch
     `/tmp/hurd-console.log`.
  5. If boot reaches the emacs banner: verify the supervisor
     came up (look for `/run/geos/super.sock` mode 0600),
     verify `pid1-rpc-poll` answers from a client connection.
  6. If boot fails: restore from snapshot, diagnose, retry.
  7. If boot succeeds and supervisor works: verify
     `pid1-reboot` host_reboot Mach RPC by triggering it from
     elisp. The VM should reboot cleanly. This is the last
     unverified port_caps slot.

## Why this matters

The 2026-05-17 sweep verified that every kernel-touching slot
(mount, hostname, the three networking verbs, get_peer_cred)
behaves correctly when invoked from a user-mode emacs running
on Hurd. That is the function-by-function ground truth. What it
does NOT verify is that the supervisor LOOP itself (the
`for(;;) { spawn_emacs(); waitpid(-1); ... }` in main()) runs
correctly under Hurd's process model and that the system comes
up to a usable state.

Boot-as-PID-1 is the integration test that closes that loop.
Doing it without a Hurd-tuned boot path would be performative;
the boot would fail in main()'s mount sequence or in
link_current_system() and the failure would not teach me
anything beyond "the linux assumptions are still in main()",
which I already know.

Honesty about what I have NOT verified is the point of this
runlog. The verification matrix in `docs/HURD_PORT.md` is the
forward-looking artifact; this runlog is the explicit "here is
why the next checkpoint is not yet checked" so anyone reading
the matrix knows the design work that gates it.

## What remains for boot-as-PID-1

In rough order:

  - `#ifdef PORT_HURD` boot variant in `pid1/emacs-init.c`
    main() (skip Linux-specific mounts, replace `/proc/cmdline`
    parsing with a Hurd-suitable source).
  - Console-only boot for Hurd in v0.7.x (defer Xorg).
  - First boot attempt on the snapshot VM, with restore-from-
    snapshot on every failure.
  - `pid1-reboot` host_reboot verification once the system
    comes up.
  - Promotion of `port->reboot` to "YES on YYYY-MM-DD" in
    `docs/HURD_PORT.md`, with a sanitized runlog under
    `docs/runlogs/` documenting the host_reboot round-trip.

After that, the Hurd port reaches the same milestone the Linux
side reached at v0.1: PID 1 supervises emacs, supervisor RPC
works, reboot works. EXWM and the install wizard are later
milestones.

## References

  - design read: `pid1/emacs-init.c` main() (current head)
  - related runlogs:
      `2026-05-17-hurd-mount-fix.md`,
      `2026-05-17-hurd-ifname-normalization.md`,
      `2026-05-17-hurd-rpc-poll-end-to-end.md`
  - per-slot matrix: `docs/HURD_PORT.md`
  - dual-kernel architecture: `docs/ARCHITECTURE.md` (Level 3)
