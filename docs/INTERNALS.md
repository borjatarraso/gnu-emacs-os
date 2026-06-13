<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# GEOS internals

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Written and maintained by Borja Tarraso <borja.tarraso@member.fsf.org>.

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".

A contributor-oriented walkthrough of how GNU/Emacs Operating System
(GEOS) actually boots, runs, and shuts down. If you are reading this,
you probably want to fix something or add something. This document is
the map.

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

# GNU Free Documentation License

Version 1.3, 3 November 2008

Copyright (C) 2000, 2001, 2002, 2007, 2008 Free Software Foundation,
Inc. <https://fsf.org/>

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.

## 0. PREAMBLE

The purpose of this License is to make a manual, textbook, or other
functional and useful document "free" in the sense of freedom: to
assure everyone the effective freedom to copy and redistribute it,
with or without modifying it, either commercially or noncommercially.
Secondarily, this License preserves for the author and publisher a way
to get credit for their work, while not being considered responsible
for modifications made by others.

This License is a kind of "copyleft", which means that derivative
works of the document must themselves be free in the same sense. It
complements the GNU General Public License, which is a copyleft
license designed for free software.

We have designed this License in order to use it for manuals for free
software, because free software needs free documentation: a free
program should come with manuals providing the same freedoms that the
software does. But this License is not limited to software manuals; it
can be used for any textual work, regardless of subject matter or
whether it is published as a printed book. We recommend this License
principally for works whose purpose is instruction or reference.

## 1. APPLICABILITY AND DEFINITIONS

This License applies to any manual or other work, in any medium, that
contains a notice placed by the copyright holder saying it can be
distributed under the terms of this License. Such a notice grants a
world-wide, royalty-free license, unlimited in duration, to use that
work under the conditions stated herein. The "Document", below, refers
to any such manual or work. Any member of the public is a licensee,
and is addressed as "you". You accept the license if you copy, modify
or distribute the work in a way requiring permission under copyright
law.

A "Modified Version" of the Document means any work containing the
Document or a portion of it, either copied verbatim, or with
modifications and/or translated into another language.

A "Secondary Section" is a named appendix or a front-matter section of
the Document that deals exclusively with the relationship of the
publishers or authors of the Document to the Document's overall
subject (or to related matters) and contains nothing that could fall
directly within that overall subject. (Thus, if the Document is in
part a textbook of mathematics, a Secondary Section may not explain
any mathematics.) The relationship could be a matter of historical
connection with the subject or with related matters, or of legal,
commercial, philosophical, ethical or political position regarding
them.

The "Invariant Sections" are certain Secondary Sections whose titles
are designated, as being those of Invariant Sections, in the notice
that says that the Document is released under this License. If a
section does not fit the above definition of Secondary then it is not
allowed to be designated as Invariant. The Document may contain zero
Invariant Sections. If the Document does not identify any Invariant
Sections then there are none.

The "Cover Texts" are certain short passages of text that are listed,
as Front-Cover Texts or Back-Cover Texts, in the notice that says that
the Document is released under this License. A Front-Cover Text may be
at most 5 words, and a Back-Cover Text may be at most 25 words.

A "Transparent" copy of the Document means a machine-readable copy,
represented in a format whose specification is available to the
general public, that is suitable for revising the document
straightforwardly with generic text editors or (for images composed of
pixels) generic paint programs or (for drawings) some widely available
drawing editor, and that is suitable for input to text formatters or
for automatic translation to a variety of formats suitable for input
to text formatters. A copy made in an otherwise Transparent file
format whose markup, or absence of markup, has been arranged to thwart
or discourage subsequent modification by readers is not Transparent.
An image format is not Transparent if used for any substantial amount
of text. A copy that is not "Transparent" is called "Opaque".

Examples of suitable formats for Transparent copies include plain
ASCII without markup, Texinfo input format, LaTeX input format, SGML
or XML using a publicly available DTD, and standard-conforming simple
HTML, PostScript or PDF designed for human modification. Examples of
transparent image formats include PNG, XCF and JPG. Opaque formats
include proprietary formats that can be read and edited only by
proprietary word processors, SGML or XML for which the DTD and/or
processing tools are not generally available, and the
machine-generated HTML, PostScript or PDF produced by some word
processors for output purposes only.

The "Title Page" means, for a printed book, the title page itself,
plus such following pages as are needed to hold, legibly, the material
this License requires to appear in the title page. For works in
formats which do not have any title page as such, "Title Page" means
the text near the most prominent appearance of the work's title,
preceding the beginning of the body of the text.

The "publisher" means any person or entity that distributes copies of
the Document to the public.

A section "Entitled XYZ" means a named subunit of the Document whose
title either is precisely XYZ or contains XYZ in parentheses following
text that translates XYZ in another language. (Here XYZ stands for a
specific section name mentioned below, such as "Acknowledgements",
"Dedications", "Endorsements", or "History".) To "Preserve the Title"
of such a section when you modify the Document means that it remains a
section "Entitled XYZ" according to this definition.

The Document may include Warranty Disclaimers next to the notice which
states that this License applies to the Document. These Warranty
Disclaimers are considered to be included by reference in this
License, but only as regards disclaiming warranties: any other
implication that these Warranty Disclaimers may have is void and has
no effect on the meaning of this License.

## 2. VERBATIM COPYING

You may copy and distribute the Document in any medium, either
commercially or noncommercially, provided that this License, the
copyright notices, and the license notice saying this License applies
to the Document are reproduced in all copies, and that you add no
other conditions whatsoever to those of this License. You may not use
technical measures to obstruct or control the reading or further
copying of the copies you make or distribute. However, you may accept
compensation in exchange for copies. If you distribute a large enough
number of copies you must also follow the conditions in section 3.

You may also lend copies, under the same conditions stated above, and
you may publicly display copies.

## 3. COPYING IN QUANTITY

If you publish printed copies (or copies in media that commonly have
printed covers) of the Document, numbering more than 100, and the
Document's license notice requires Cover Texts, you must enclose the
copies in covers that carry, clearly and legibly, all these Cover
Texts: Front-Cover Texts on the front cover, and Back-Cover Texts on
the back cover. Both covers must also clearly and legibly identify you
as the publisher of these copies. The front cover must present the
full title with all words of the title equally prominent and visible.
You may add other material on the covers in addition. Copying with
changes limited to the covers, as long as they preserve the title of
the Document and satisfy these conditions, can be treated as verbatim
copying in other respects.

If the required texts for either cover are too voluminous to fit
legibly, you should put the first ones listed (as many as fit
reasonably) on the actual cover, and continue the rest onto adjacent
pages.

If you publish or distribute Opaque copies of the Document numbering
more than 100, you must either include a machine-readable Transparent
copy along with each Opaque copy, or state in or with each Opaque copy
a computer-network location from which the general network-using
public has access to download using public-standard network protocols
a complete Transparent copy of the Document, free of added material.
If you use the latter option, you must take reasonably prudent steps,
when you begin distribution of Opaque copies in quantity, to ensure
that this Transparent copy will remain thus accessible at the stated
location until at least one year after the last time you distribute an
Opaque copy (directly or through your agents or retailers) of that
edition to the public.

It is requested, but not required, that you contact the authors of the
Document well before redistributing any large number of copies, to
give them a chance to provide you with an updated version of the
Document.

## 4. MODIFICATIONS

You may copy and distribute a Modified Version of the Document under
the conditions of sections 2 and 3 above, provided that you release
the Modified Version under precisely this License, with the Modified
Version filling the role of the Document, thus licensing distribution
and modification of the Modified Version to whoever possesses a copy
of it. In addition, you must do these things in the Modified Version:

-   A. Use in the Title Page (and on the covers, if any) a title
    distinct from that of the Document, and from those of previous
    versions (which should, if there were any, be listed in the
    History section of the Document). You may use the same title as a
    previous version if the original publisher of that version
    gives permission.
-   B. List on the Title Page, as authors, one or more persons or
    entities responsible for authorship of the modifications in the
    Modified Version, together with at least five of the principal
    authors of the Document (all of its principal authors, if it has
    fewer than five), unless they release you from this requirement.
-   C. State on the Title page the name of the publisher of the
    Modified Version, as the publisher.
-   D. Preserve all the copyright notices of the Document.
-   E. Add an appropriate copyright notice for your modifications
    adjacent to the other copyright notices.
-   F. Include, immediately after the copyright notices, a license
    notice giving the public permission to use the Modified Version
    under the terms of this License, in the form shown in the
    Addendum below.
-   G. Preserve in that license notice the full lists of Invariant
    Sections and required Cover Texts given in the Document's
    license notice.
-   H. Include an unaltered copy of this License.
-   I. Preserve the section Entitled "History", Preserve its Title,
    and add to it an item stating at least the title, year, new
    authors, and publisher of the Modified Version as given on the
    Title Page. If there is no section Entitled "History" in the
    Document, create one stating the title, year, authors, and
    publisher of the Document as given on its Title Page, then add an
    item describing the Modified Version as stated in the
    previous sentence.
-   J. Preserve the network location, if any, given in the Document
    for public access to a Transparent copy of the Document, and
    likewise the network locations given in the Document for previous
    versions it was based on. These may be placed in the "History"
    section. You may omit a network location for a work that was
    published at least four years before the Document itself, or if
    the original publisher of the version it refers to
    gives permission.
-   K. For any section Entitled "Acknowledgements" or "Dedications",
    Preserve the Title of the section, and preserve in the section all
    the substance and tone of each of the contributor acknowledgements
    and/or dedications given therein.
-   L. Preserve all the Invariant Sections of the Document, unaltered
    in their text and in their titles. Section numbers or the
    equivalent are not considered part of the section titles.
-   M. Delete any section Entitled "Endorsements". Such a section may
    not be included in the Modified Version.
-   N. Do not retitle any existing section to be Entitled
    "Endorsements" or to conflict in title with any Invariant Section.
-   O. Preserve any Warranty Disclaimers.

If the Modified Version includes new front-matter sections or
appendices that qualify as Secondary Sections and contain no material
copied from the Document, you may at your option designate some or all
of these sections as invariant. To do this, add their titles to the
list of Invariant Sections in the Modified Version's license notice.
These titles must be distinct from any other section titles.

You may add a section Entitled "Endorsements", provided it contains
nothing but endorsements of your Modified Version by various
parties—for example, statements of peer review or that the text has
been approved by an organization as the authoritative definition of a
standard.

You may add a passage of up to five words as a Front-Cover Text, and a
passage of up to 25 words as a Back-Cover Text, to the end of the list
of Cover Texts in the Modified Version. Only one passage of
Front-Cover Text and one of Back-Cover Text may be added by (or
through arrangements made by) any one entity. If the Document already
includes a cover text for the same cover, previously added by you or
by arrangement made by the same entity you are acting on behalf of,
you may not add another; but you may replace the old one, on explicit
permission from the previous publisher that added the old one.

The author(s) and publisher(s) of the Document do not by this License
give permission to use their names for publicity for or to assert or
imply endorsement of any Modified Version.

## 5. COMBINING DOCUMENTS

You may combine the Document with other documents released under this
License, under the terms defined in section 4 above for modified
versions, provided that you include in the combination all of the
Invariant Sections of all of the original documents, unmodified, and
list them all as Invariant Sections of your combined work in its
license notice, and that you preserve all their Warranty Disclaimers.

The combined work need only contain one copy of this License, and
multiple identical Invariant Sections may be replaced with a single
copy. If there are multiple Invariant Sections with the same name but
different contents, make the title of each such section unique by
adding at the end of it, in parentheses, the name of the original
author or publisher of that section if known, or else a unique number.
Make the same adjustment to the section titles in the list of
Invariant Sections in the license notice of the combined work.

In the combination, you must combine any sections Entitled "History"
in the various original documents, forming one section Entitled
"History"; likewise combine any sections Entitled "Acknowledgements",
and any sections Entitled "Dedications". You must delete all sections
Entitled "Endorsements".

## 6. COLLECTIONS OF DOCUMENTS

You may make a collection consisting of the Document and other
documents released under this License, and replace the individual
copies of this License in the various documents with a single copy
that is included in the collection, provided that you follow the rules
of this License for verbatim copying of each of the documents in all
other respects.

You may extract a single document from such a collection, and
distribute it individually under this License, provided you insert a
copy of this License into the extracted document, and follow this
License in all other respects regarding verbatim copying of that
document.

## 7. AGGREGATION WITH INDEPENDENT WORKS

A compilation of the Document or its derivatives with other separate
and independent documents or works, in or on a volume of a storage or
distribution medium, is called an "aggregate" if the copyright
resulting from the compilation is not used to limit the legal rights
of the compilation's users beyond what the individual works permit.
When the Document is included in an aggregate, this License does not
apply to the other works in the aggregate which are not themselves
derivative works of the Document.

If the Cover Text requirement of section 3 is applicable to these
copies of the Document, then if the Document is less than one half of
the entire aggregate, the Document's Cover Texts may be placed on
covers that bracket the Document within the aggregate, or the
electronic equivalent of covers if the Document is in electronic form.
Otherwise they must appear on printed covers that bracket the whole
aggregate.

## 8. TRANSLATION

Translation is considered a kind of modification, so you may
distribute translations of the Document under the terms of section 4.
Replacing Invariant Sections with translations requires special
permission from their copyright holders, but you may include
translations of some or all Invariant Sections in addition to the
original versions of these Invariant Sections. You may include a
translation of this License, and all the license notices in the
Document, and any Warranty Disclaimers, provided that you also include
the original English version of this License and the original versions
of those notices and disclaimers. In case of a disagreement between
the translation and the original version of this License or a notice
or disclaimer, the original version will prevail.

If a section in the Document is Entitled "Acknowledgements",
"Dedications", or "History", the requirement (section 4) to Preserve
its Title (section 1) will typically require changing the actual
title.

## 9. TERMINATION

You may not copy, modify, sublicense, or distribute the Document
except as expressly provided under this License. Any attempt otherwise
to copy, modify, sublicense, or distribute it is void, and will
automatically terminate your rights under this License.

However, if you cease all violation of this License, then your license
from a particular copyright holder is reinstated (a) provisionally,
unless and until the copyright holder explicitly and finally
terminates your license, and (b) permanently, if the copyright holder
fails to notify you of the violation by some reasonable means prior to
60 days after the cessation.

Moreover, your license from a particular copyright holder is
reinstated permanently if the copyright holder notifies you of the
violation by some reasonable means, this is the first time you have
received notice of violation of this License (for any work) from that
copyright holder, and you cure the violation prior to 30 days after
your receipt of the notice.

Termination of your rights under this section does not terminate the
licenses of parties who have received copies or rights from you under
this License. If your rights have been terminated and not permanently
reinstated, receipt of a copy of some or all of the same material does
not give you any rights to use it.

## 10. FUTURE REVISIONS OF THIS LICENSE

The Free Software Foundation may publish new, revised versions of the
GNU Free Documentation License from time to time. Such new versions
will be similar in spirit to the present version, but may differ in
detail to address new problems or concerns. See
<https://www.gnu.org/licenses/>.

Each version of the License is given a distinguishing version number.
If the Document specifies that a particular numbered version of this
License "or any later version" applies to it, you have the option of
following the terms and conditions either of that specified version or
of any later version that has been published (not as a draft) by the
Free Software Foundation. If the Document does not specify a version
number of this License, you may choose any version ever published (not
as a draft) by the Free Software Foundation. If the Document specifies
that a proxy can decide which future versions of this License can be
used, that proxy's public statement of acceptance of a version
permanently authorizes you to choose that version for the Document.

## 11. RELICENSING

"Massive Multiauthor Collaboration Site" (or "MMC Site") means any
World Wide Web server that publishes copyrightable works and also
provides prominent facilities for anybody to edit those works. A
public wiki that anybody can edit is an example of such a server. A
"Massive Multiauthor Collaboration" (or "MMC") contained in the site
means any set of copyrightable works thus published on the MMC site.

"CC-BY-SA" means the Creative Commons Attribution-Share Alike 3.0
license published by Creative Commons Corporation, a not-for-profit
corporation with a principal place of business in San Francisco,
California, as well as future copyleft versions of that license
published by that same organization.

"Incorporate" means to publish or republish a Document, in whole or in
part, as part of another Document.

An MMC is "eligible for relicensing" if it is licensed under this
License, and if all works that were first published under this License
somewhere other than this MMC, and subsequently incorporated in whole
or in part into the MMC, (1) had no cover texts or invariant sections,
and (2) were thus incorporated prior to November 1, 2008.

The operator of an MMC Site may republish an MMC contained in the site
under CC-BY-SA on the same site at any time before August 1, 2009,
provided the MMC is eligible for relicensing.

## ADDENDUM: How to use this License for your documents

To use this License in a document you have written, include a copy of
the License in the document and put the following copyright and
license notices just after the title page:

        Copyright (C)  YEAR  YOUR NAME.
        Permission is granted to copy, distribute and/or modify this document
        under the terms of the GNU Free Documentation License, Version 1.3
        or any later version published by the Free Software Foundation;
        with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
        A copy of the license is included in the section entitled "GNU
        Free Documentation License".

If you have Invariant Sections, Front-Cover Texts and Back-Cover
Texts, replace the "with … Texts." line with this:

        with the Invariant Sections being LIST THEIR TITLES, with the
        Front-Cover Texts being LIST, and with the Back-Cover Texts being LIST.

If you have Invariant Sections without Cover Texts, or some other
combination of the three, merge those two alternatives to suit the
situation.

If your document contains nontrivial examples of program code, we
recommend releasing these examples in parallel under your choice of
free software license, such as the GNU General Public License, to
permit their use in free software.
