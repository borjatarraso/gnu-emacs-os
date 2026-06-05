<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# GEOS internals

A contributor-oriented walkthrough of how GNU/Emacs Operating System
(GEOS) actually boots, runs, and shuts down. If you are reading this,
you probably want to fix something or add something. This document is
the map.

Maintainer: Borja Tarraso <borja.tarraso@member.fsf.org>

## reading order

The OS is still small enough to read in a long evening. As of
v1.0.0: roughly 5600 lines of C (pid1 binary + dynamic module +
shstub + port layer; the `hurd` side branch adds another ~3K for
`port_hurd.c` and friends), roughly 15800 lines of Elisp (core,
wm, userland, buffers, services, auth, install), roughly 1500
lines of Scheme (the operating-system record and the iso-build
wrappers).  The numbers drift between releases; treat them as
orders of magnitude, not contracts.  This document is a guided
tour.  The truth is in the source.

The lifecycle below is one continuous chain from kernel handoff to
power off. Read top to bottom on the first pass.

## stage 0: from POST to the kernel

Outside our scope. The firmware loads GRUB, GRUB loads the Linux
kernel and the initrd. The relevant Linux command line tokens are
listed in `guix-system/system.scm` under `kernel-arguments`:

```
console=tty1 console=ttyS0,115200 gnu.system=/gnu/store/...-system
geos.mode=ui          ; or geos.mode=console
```

`gnu.system=` is the Guix initrd's pointer to this system's
profile. PID 1 reads it later to symlink `/run/current-system`.
`geos.mode=` is the GEOS-specific token (described in
`docs/INSTALL.md`) that picks UI vs console boot.

Linux mounts the initrd, runs the Guix initrd's tiny shell-equivalent
to set up the root filesystem, and then `execve`s the per-system boot
script under `/gnu/store/...-system/boot`. That script is a Guile gexp
produced by `compute-boot-script` in Guix's
`(gnu services)`. Critically, our service
`emacs-init-boot-service` extends `boot-service-type` with a gexp
that runs BEFORE the Shepherd-spawning gexp. See the comment at the
top of `guix-system/system.scm` for the gexp ordering trick that
makes this work.

When the boot script reaches our gexp, it `execl`s the PID 1 binary,
which replaces the process image. Shepherd never runs.

## stage 1: PID 1 (`pid1/emacs-init.c`)

The PID 1 binary does the bare minimum a kernel needs from PID 1:

```
1. argv parsing                       main() in emacs-init.c
2. boot banner                        console("GNU/Emacs Operating System...")
3. mount the pseudo filesystems       do_mount() x6
4. lay down /run/current-system       link_current_system()
5. bring up loopback                  raw_bring_up_lo()
6. install SIGCHLD handler            sigaction(SIGCHLD, ...)
7. parse /proc/cmdline for geos.mode= read_geos_mode()
8. spawn Xorg (UI mode only)          xorg_bring_up() -> spawn_xorg()
9. spawn emacs                        spawn_emacs()
10. supervisor loop                   for(;;) waitpid(-1, ...)
```

### argv layout

The boot gexp passes:

```
argv[1] = absolute path to the emacs binary
argv[2] = absolute path to pid1-module.so (or "")
argv[3] = colon-joined Xorg spec
            "<Xorg-bin>:<xkb-bindir>:<modulepath>:<fontpath>:<conf>"
          empty string disables X (raw smoke tests)
argv[4..] = forwarded into emacs as its argv,
            typically "-Q -l early-init.el -l panic.el -l ..."
```

Anything missing falls back to `/usr/bin/emacs` and no module, which
matches a plain `emacs-init` smoke test outside QEMU.

### the pseudo filesystem mounts

`/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/dev/pts`. Each one is mounted
with `MS_NOSUID|MS_NOEXEC|MS_NODEV` where applicable. EBUSY is treated
as success: the modern Guix initrd already mounts a few of these
before handing off, and re-mounting them is fine. See the long comment
in `do_mount()` for the rationale.

### `/run/current-system`

The Guix indirection that every profile-aware path keys off of:

```
PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin
```

Guix's activation service normally creates this symlink. We replace
the boot script before activation runs, so `link_current_system()`
parses `gnu.system=` from `/proc/cmdline` and stands up the symlink
itself. Without this, `executable-find` inside Emacs returns `nil` for
everything and the `s-&` launcher cannot find xterm.

The path read from `/proc/cmdline` is validated: it must start with
`/gnu/store/`, must not contain `..`, must fit in `PATH_MAX`. A
hostile or malformed cmdline would otherwise let any path become the
profile root. See the comment over `read_gnu_system_path()`.

### boot mode toggle

`read_geos_mode()` reads `/proc/cmdline` for `geos.mode=`. The
recognized values are `ui` (default) and `console`. In console mode,
PID 1 sets `xorg_path = NULL`, `xorg_disabled = 1`, and `display_env =
NULL` so the X bring-up path is fully skipped and Emacs comes up on
`/dev/console` with `TERM=linux`.

### Xorg bring-up (UI mode only)

`xorg_bring_up()` does:

  1. `mkdir /tmp/.X11-unix` with mode 01777 (the standard X socket dir
     permissions).
  2. Unlink any stale `X0` socket from a previous boot.
  3. `spawn_xorg()` to fork-exec the X server (Xorg with the
     `modesetting` driver against `/dev/dri/card0`, configured by
     `xorg-modesetting.conf` from the system profile).
  4. `wait_for_x_socket()` polls for the X0 socket up to 10 seconds.

`spawn_xorg()` redirects stderr to `/tmp/Xorg.0.log` so the boot trace
on `/dev/console` stays clean. The Xorg argv list is composed inline
from the spec we got in `argv[3]`. Input devices (kbd0 on event1,
mouse0 on event4) are statically pinned in the conf file because we
have no udevd; the `# device numbering verified...` comment in
`xorg-modesetting.conf` documents how to re-pin them if the kernel
ever shuffles event nodes.

If Xorg dies post-boot, the supervisor loop notices the SIGCHLD and
calls `xorg_note_respawn()`. That tracks restart attempts in a 60s
sliding window and trips a hard limit of 5 respawns per window
(`XORG_RESPAWN_CAP`). Once tripped, `xorg_disabled` is set and the
session degrades to bare Emacs on `/dev/console` for the rest of this
boot.

### spawn Emacs

`spawn_emacs()` forks, calls `setsid()`, opens `/dev/console`
(falling back to `/dev/tty1`), `dup2`s it onto fds 0/1/2, and
`execve`s the Emacs binary. The envp is fixed-size and includes:

```
TERM=linux
HOME=/root
USER=root
PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin
PID1_MODULE_PATH=/gnu/store/...pid1-module.so   ; if module passed
DISPLAY=:0                                       ; if Xorg up
```

The argv passed to Emacs is the boot gexp's `-l` chain (early-init,
panic, power, use-package shim, network, hostname, network-buffer,
the wm modules, exwm-config, the userland modules, the system-concept
buffers).

### supervisor loop

`for (;;) { spawn_emacs(); waitpid(-1, ...); }` with two distinct
death paths:

  - Emacs died: log "emacs exited, respawning", fall through to outer
    loop's `spawn_emacs()`. `sleep_at_least(1)` throttles crash loops.
  - Xorg died (UI mode): SIGTERM emacs (because it is talking to a
    dead `:0`), wait 5 seconds for clean exit, SIGKILL on timeout.
    Then `xorg_note_respawn()` and try `xorg_bring_up()`. Then fall
    through and respawn emacs against the new Xorg.

The `waitpid(-1)` (any child) is deliberate: we have to react to Xorg
death AND Emacs death AND reap orphans reparented to us by other dead
processes. Tightly waiting on Emacs's pid only would let an Xorg crash
go unnoticed until the user closed their X frame.

## stage 2: Emacs becomes the OS userland

When `execve(emacs ...)` returns successfully, Emacs starts up. The
boot gexp's `-l` chain is processed in order. The interesting files,
in load order:

```
emacs-init/early-init.el          register pid1-error, module-load .so
emacs-init/core/panic.el          *panic* buffer + error trap
emacs-init/core/state.el          /var/emacs/ layout + atomic state-write
emacs-init/core/power.el          M-x geos-poweroff / geos-reboot
emacs-init/core/use-package-shim.el   bootstrap use-package + :comment kw
emacs-init/core/network.el        bring up lo, /proc/net/* parsers
emacs-init/core/hostname.el       read /etc/hostname, sethostname(2)
emacs-init/core/supervise.el      defservice macro, registry, restart policy
emacs-init/buffers/network.el     *network* buffer + 2s refresh timer
emacs-init/user/multimon.el       xrandr-driven workspace placement
emacs-init/user/fonts.el          default face + emoji + CJK fontset
emacs-init/user/input.el          quail input methods
emacs-init/user/exwm-config.el    (exwm-enable), s-&, s-r, s-0..3
emacs-init/user/userland/files.el dired
emacs-init/user/userland/shell.el eshell
emacs-init/user/userland/uname.el eshell/uname rebrand to GEOS
emacs-init/user/userland/git.el   magit
emacs-init/user/userland/web.el   eww
emacs-init/user/userland/mail.el  notmuch
emacs-init/user/userland/chat.el  erc
emacs-init/user/userland/notes.el org
emacs-init/user/userland/pdf.el   pdf-tools
emacs-init/user/userland/init.el  verify all userland-* features loaded
emacs-init/buffers/processes.el   *processes* buffer
emacs-init/buffers/journal.el     *journal* (dd-on-/dev/kmsg)
emacs-init/buffers/services.el    *services* (live supervise.el registry)
emacs-init/buffers/disks.el       *disks* (/proc/partitions)
emacs-init/buffers/packages.el    *packages* (manifest readout)
emacs-init/services/journal-tail.el   defservice for the kmsg follower
emacs-init/core/boot-marker.el    last in chain; supervise-finalize +
                                  /dev/console sentinels for smoke-test
```

### early-init.el

Runs before the splash, before `package.el`, before any other Elisp.
Three jobs:

  1. Set `package-enable-at-startup nil` so `package.el` does not wake
     up and fight with our manual loadpath wiring.
  2. Determine if this Emacs is the OS userland by checking
     `(getenv "PID1_MODULE_PATH")`. This is `pid1-as-emacs-p`. Plain
     `emacs -Q` on a dev host returns `nil` here.
  3. If we are PID 1's userland, `module-load` the dynamic module
     from the env path, register `pid1-error` as a real condition,
     and point `user-emacs-directory` at `/var/emacs/`.

The module-load is wrapped in `condition-case` because `panic.el`
has not loaded yet. An ABI mismatch or missing dep at this point
would otherwise be an uncaught error, which on PID 1 is a kernel
panic. Degraded mode (no supervision primitives in elisp) beats that.

### panic.el

Defines the `*panic*` buffer and installs a `command-error-function`
that catches every Emacs-level error and routes it to `panic-handle`
instead of `error`. Every other file in the userland calls
`panic-handle` from its `condition-case` handlers. The single-thread
reality of Emacs (a stuck regex stalls the OS) cannot be fully
mitigated, but this gets us 90% of the way there.

`panic.el` is also the file the `/freeze-test` skill exercises.

### state.el

Lays down `/var/emacs/{journal,packages,network,users,services,dotfiles}`
at boot, detects the mount as ext4 vs tmpfs (`state-mode`), and exposes
`state-read` / `state-write` / `state-delete` for the rest of the
userland. Writes go through a tmpfile + rename + `pid1-fsync-dir`
cycle for crash-consistency on ext4. The contract between this file
and pid1's `mount_var()` is documented in `docs/STATE_LAYOUT.md`.

### supervise.el

The Elisp service supervisor that replaces Shepherd. The
`defservice` macro registers a long-running process with a command,
restart policy (`on-crash`, `on-failure`, `always`, `never`), an
optional `:buffer` and `:filter` for stream handling, and an
optional `:autostart` flag. The supervisor runs the process via
`make-process`, wires a sentinel that consults the policy and a
rolling 60s respawn cap (default 5 attempts), and trips a service
into `'held` state when the cap is exceeded. Restart counters are
persisted via `state-write` so a reboot does not reset the cap on a
service that is genuinely broken. `supervise-finalize` runs from
`boot-marker.el` (the last file in the `-l` chain), restoring
counters and autostarting any service registered earlier in the
chain that did not opt out.

### network.el

Brings up loopback by calling `pid1-bring-up-lo` from the dynamic
module. Also exposes `/proc/net/dev` and `/proc/net/route` parsers
that the `*network*` buffer (in `buffers/network.el`) polls.

### hostname.el

Reads `/etc/hostname` (which Guix bakes from the
`(host-name "lambda")` field in `system.scm`) and calls
`pid1-set-hostname`. This bridges the Shepherd-shaped gap: Guix wrote
the file, but no Shepherd hostname service exists to apply it. After
`hostname-apply` runs, `uname -a` (and any program reading
`/proc/sys/kernel/hostname`) sees `lambda` instead of the kernel
default `(none)`.

### exwm-config.el (UI mode only)

`(exwm-enable)`. EXWM grabs the X root window. The first Emacs frame
is now the WM's workspace. Bindings:

```
s-w               switch workspace by index
s-0..s-3          jump to workspace N
s-&               launch a program (no shell, just exec)
s-r               reset EXWM input mode
```

After `exwm-enable`, the file requires multimon, fonts, input, in
that order. Each is wrapped in `condition-case` so a regression in
one does not undo the working `exwm-enable` above.

### userland/init.el

Walks `userland-modules` and confirms each one provided its feature.
A missing feature is logged via `panic-handle` (degraded mode) but
not raised. The boot success line is also written to `/dev/console`
because the kernel framebuffer console (which the user is staring at
in QEMU) does not see Emacs `message` output once EXWM is up.

## stage 3: a session

You see EXWM with one Emacs frame. The xterm canary started by
`exwm-config.el`'s tail is on workspace 0.

### `M-x eshell`

Opens an eshell buffer. Type `uname -a`. The flow:

  1. eshell reads "uname -a", looks up `eshell/uname` first.
  2. `userland/uname.el` defines `eshell/uname` to inspect the args
     and rebrand the `sysname` field. With `-a`, it formats:
     `GEOS lambda <release> <version> <machine> GNU/Emacs (Linux)`.
  3. The kernel `uname(2)` fields are still consulted via
     `system-name`, `(uname-machine)`, etc., so kernel/hardware info
     stays accurate. Only the `sysname` is overridden. The original
     `Linux` shows in parens at the end so nothing is hidden.

`/bin/sh` is the shstub from `shstub/sh.c`. It does not exec a real
shell; it forwards `sh -c "<cmd>"` to `emacsclient` which evaluates
the command in an eshell buffer. Anything in the system that
shells-out (Guix package post-install, magit's `pre-receive` hook,
etc.) goes through this.

### the system-concept buffers

```
M-x processes      live ps-equivalent, /proc/[0-9]*/stat parser
M-x network        ip-equivalent, /proc/net/* + ioctl
M-x journal        dmesg-equivalent, dd if=/dev/kmsg follower
M-x services       supervised-process registry from core/supervise.el
M-x disks          df+lsblk-equivalent, /proc/partitions + /proc/mounts
M-x packages       manifest readout of the active Guix profile
```

Each buffer derives from `special-mode`, has a refresh timer, and
documents its keys at the top of its file.

## stage 3.5: dual-kernel boundary (v0.7.x and later)

Everything described above is what runs on Linux today. The
v0.7.x cycle factored the kernel-specific surface into an
explicit seam so the same source tree can boot on the GNU Hurd,
which is the next supported kernel. The architectural picture
is in `docs/ARCHITECTURE.md` (Level 3); the contract here is
how it lands in the code.

### the C seam

`pid1/port_layer.h` declares a function-pointer struct
`port_caps` with nine slots: `kernel_name`, `mount`,
`set_hostname`, `bring_up_lo`, `set_address`,
`set_route_default`, `reboot`, `suspend`, `get_peer_cred`.
`pid1/port_linux.c` holds the Linux body for every slot.
`pid1/port_hurd.c` (which lives only on the `hurd` side branch)
holds the Hurd body. `pid1/emacs-init.c` calls `port->X()` and
never touches a raw syscall directly except in code paths that
are demonstrably kernel-agnostic (`open(2)`, `read(2)`, etc).

Wiring happens once, at the very top of `main()`:

```c
port = &port_linux_impl;       /* &port_hurd_impl under PORT=hurd */
port_require_or_abort();
```

`port_require_or_abort` walks every slot and aborts with a loud
`/dev/console` message if any is `NULL`. A missing registration
becomes a crash at boot rather than a null deref the first time
the slot is exercised.

### the elisp seam

`emacs-init/core/port.el` defines `geos-kernel`:

```elisp
(defvar geos-kernel
  (intern (or (getenv "GEOS_KERNEL") "linux")))
```

`pid1` splices `GEOS_KERNEL=<port->kernel_name>` into the envp of
`spawn_emacs` (commit `a53304b`), so the elisp side never has to
call out to `uname -s`. Files that have to do something kernel-
specific (`core/network.el`, `core/state.el`, `buffers/disks.el`,
`install/disk.el`, `user/userland/uname.el`,
`services/journal-tail.el`, `buffers/journal.el`,
`user/userland/audio.el`, `buffers/audio.el`) factor their Linux
bodies into `*-linux` helpers and dispatch through `geos-kernel`.
The Hurd arm either degrades cleanly (nil, banner) or signals
`geos-port-unimplemented` until a real backend lands.

### freeze-test discipline

`iso-build/freeze-tests/freeze-test-port-hurd.el` exercises the
elisp Hurd-arm code paths under a stubbed `geos-kernel = 'hurd`.
A refactor of any Linux arm that silently flattens its Hurd
counterpart fails the `port/*` sub-checks. The sub-checks emit a
`'skip` result class when the underlying module is absent
(`emacs -Q -batch` dev host) so CI can distinguish "module
unbound" from "regression".

### boot path differs on Hurd

On Linux, GRUB hands the kernel an `init=` cmdline that names
the pid1 binary directly. On Hurd, GRUB hands a multiboot module
chain (pci-arbiter, acpi, rumpdisk, ext2fs, exec) and the
microkernel spawns `/hurd/startup` as the unconditional PID 1.
`/hurd/startup` then `execve`s `/sbin/init` as the user-mode
init. The install path for emacs-init on Hurd is "replace
`/sbin/init`", not "edit the kernel cmdline".

The pseudo-filesystem mounts in `main()` (`/proc`, `/sys`,
`/dev`, `/run`, `/tmp`, `/dev/pts`) also need different
treatment on Hurd: `/proc` is a translator, `/dev` is real,
`/sys` does not exist. The Hurd boot path skips the Linux-
specific entries; `do_mount` already logs-and-continues on
failure, but the gnu.system=-derived `/run/current-system`
linkage in `link_current_system()` needs a Hurd analogue that
does not depend on `/proc/cmdline`. This design gap is tracked
in `docs/runlogs/2026-05-18-hurd-pid1-boot-design.md`.

### verification ladder

Promotion from "code-side written" to "actually runs on Hurd"
goes through three states, tracked in `docs/HURD_PORT.md`:

  1. **NO**: never touched a real Hurd kernel.
  2. **builds on Hurd YYYY-MM-DD**: compiles + links + `ldd -r`
     clean against real Hurd headers and libraries; symbol
     table shows the slot; body NOT exercised against a live
     Mach RPC server.
  3. **YES on YYYY-MM-DD**: actually invoked on a running Hurd
     kernel and observed to do the right thing.

Each "YES" promotion is backed by a sanitized verification
receipt under `docs/runlogs/YYYY-MM-DD-<tag>.md`. Receipts are
append-only: a regression gets a new dated runlog, not an edit
to the historical one.

## stage 4: shutdown

Two paths:

  - `M-x geos-poweroff` -> `(pid1-poweroff)` -> the C side calls
    `sync()` then `reboot(RB_POWER_OFF)`. The kernel kills every
    process and on QEMU the ACPI shutdown event closes the QEMU
    window. On bare metal the firmware actually cuts power.
  - `M-x geos-reboot` -> `(pid1-reboot)` -> `sync()` +
    `reboot(RB_AUTOBOOT)`. Restart.

These commands live in `emacs-init/core/power.el`. The dynamic module
is the only thing in the system with `CAP_SYS_BOOT`; without the
module, both calls fail with EPERM and the `*panic*` buffer gets the
event. Without these, there is no way to shut down: there is no
`/sbin/poweroff` because there is no Shepherd to know about it.

## what to read next

  - `docs/ARCHITECTURE.md` for the three-zoom-level picture of the
    whole stack, including the Level 3 dual-kernel detail.
  - `pid1/emacs-init.c` end-to-end. The whole PID 1 path is one file.
  - `pid1/port_layer.h` + `pid1/port_linux.c` for the kernel seam.
    Skim `pid1/port_hurd.c` on the `hurd` side branch for the
    second backend.
  - `emacs-init/core/panic.el`. The error-trap pattern is the most
    important piece of project-wide style.
  - `emacs-init/core/state.el` and `docs/STATE_LAYOUT.md`. The
    persistence contract that every other concept buffer keys off of.
  - `emacs-init/core/supervise.el`. The `defservice` macro and the
    sentinel/restart loop that stand in for Shepherd. Read alongside
    `emacs-init/services/journal-tail.el` for a working consumer.
  - `guix-system/system.scm`. The `simple-service ... boot-service-type`
    block is the trick that lets us stand up an Emacs userland on top
    of an unmodified Guix base. Read the comments carefully if you
    want to extend it.
  - `docs/ROADMAP.md` for what is unfinished and why.

## what NOT to do

  - Do not add a Shepherd service. Service supervision is Elisp.
  - Do not add a shell. Eshell is the only shell.
  - Do not call `error` from a hot path; use `panic-handle`.
  - Do not add a feature without a `:comment` justification on its
    `use-package` block.
  - Do not bypass the panic trap "just for one quick debug". You will
    forget. Then PID 1's userland will die. Then the supervisor will
    respawn Emacs in a tight loop. Then I will be unhappy.

## getting changes upstream

Read `CONTRIBUTING.md` if it exists; if not, open an issue first and
describe what you want to change. Patches that touch `pid1/` or
`emacs-init/core/` get a skeptic review. `/freeze-test`,
`/no-shell-check`, and `/attribution-scan` all pass before merge.

Welcome.

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
