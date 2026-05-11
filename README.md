<p align="center">
  <img src="docs/img/logo.png" alt="GNU/Emacs Operating System (GEOS), editor on silicon" width="217" height="256">
</p>

# GNU/Emacs Operating System (GEOS)

Maintainer: Borja Tarraso &lt;borja.tarraso@member.fsf.org&gt;

An operating system where Emacs is the userland and Emacs is PID 1.
Short name is GEOS, full name is GNU/Emacs Operating System; the rest
of this document uses GEOS.

There is no shell other than eshell. There is no Shepherd. There is no
systemd. The first userspace process the kernel starts is a small C
program that becomes Emacs and then loads itself back as an Emacs
dynamic module, so the supervisor lives inside the supervised process.
Every system concept (`top`, `ip a`, `journalctl`, `df`, `apt`) is a
buffer with a major mode and a refresh timer.

This is v0.3.1. It runs. I use it.

## try it

```
./iso-build/dev-vm.sh
```

That builds the host-side binaries (`pid1/`, `shstub/`), then runs
`guix time-machine` against the pinned channel to produce a qcow2,
then boots it under QEMU/KVM. First build is large (~8 GB into
`/gnu/store`); subsequent ones are seconds.

For a headless smoke pass:

```
./iso-build/smoke-test.sh
```

You need a Linux host with KVM and Guix installed. Boot to a
usable EXWM frame takes about eleven seconds. Full instructions
in [docs/INSTALL.md](docs/INSTALL.md). The why is in
[docs/MANIFESTO.md](docs/MANIFESTO.md), and the manifesto is the
document I would actually rather you read first.

## what works

  - PID 1 is a C binary that execs Emacs and exposes the reaper, mount
    helper, hostname, reboot and signal handlers as Elisp functions
    via a dynamic module.
  - The panic buffer catches every uncaught error and refuses to let
    Emacs die.
  - `/bin/sh` is a 50-line C stub that forwards into eshell. No bash,
    no dash, no busybox.
  - EXWM brings up real Xorg with the modesetting driver against
    virtio_gpu's KMS device. Keyboard and mouse work in QEMU. X11
    windows are buffers.
  - `eshell/uname` reads `GEOS lambda <release> ... GNU/Emacs (Linux)`,
    so the user-facing kernel string says what GEOS actually is and
    keeps the real kernel name visible at the end.
  - `M-x geos-poweroff` and `M-x geos-reboot` go through `reboot(2)`
    via the pid1 module. No `/sbin/poweroff`, no socket, no sudo.
  - `*processes*`, `*network*`, `*journal*`, `*services*`, `*disks*`,
    `*packages*`, `*users*`, `*audio*` are all live buffers with
    sensible keybindings.
  - `/etc/hostname` is read and applied at boot via `pid1-set-hostname`
    (no Shepherd hostname service to depend on).
  - GRUB picks the boot mode from `geos.mode=`; `ui` is the default,
    `geos.mode=console` lands on a raw `/dev/console` Emacs without
    Xorg, `geos.mode=recovery` does the same and also skips the
    userland load chain via `early-init.el`.
  - Persistent state under `/var/emacs/`: pid1 mounts an ext4 partition
    labelled `geos-var` if present, falls back to tmpfs otherwise.
    Crash-safe `state-write` (rename + parent fsync via `pid1-fsync-dir`).
    See [docs/STATE_LAYOUT.md](docs/STATE_LAYOUT.md).
  - Static IPv4 from `*network*`: `s` prompts for address and gateway
    and goes through `pid1-set-address` + `pid1-set-route-default`
    ioctls. No `ip` binary involved.
  - Package install and remove from `*packages*`, driven by
    `guix package` via `make-process` with the build log streamed
    into the buffer.
  - User accounts: `passwd.el` store under `/var/emacs/users/` and a
    `*users*` buffer. The login flow itself is v0.5; right now this is
    the account store and the UI on top of it.
  - Suspend to RAM via `M-x geos-suspend`. pid1 writes `mem` to
    `/sys/power/state` after the supervisor quiesces timers.
  - Audio (preview): `*audio*` buffer wraps `amixer` and `aplay`
    through `make-process`. No pid1-side audio module yet.
  - `iso-build/freeze-tests.el` is an in-VM abuse suite that asserts
    the panic buffer survives runaway loops, catastrophic regex, slow
    network, bad tramp, `kill-emacs`, and a state-write round trip.
  - `iso-build/smoke-test.sh` boots a headless qcow2 and gates on
    PID 1, userland, `/var` mount, and state-mode markers.
  - The whole image builds reproducibly from a pinned Guix channel.

## what does not work yet

The Hurd variant. Real hardware (only QEMU is exercised). The login
flow (account store is in, per-user emacs split is not). Bluetooth.
Wayland. DHCP and DNS UI (static IPv4 lands packets but the resolver
side is manual). Disk encryption at boot. A bare-metal install
wizard (the `*reconfigure*` buffer covers in-place generation
changes; first-install partitioning is the next piece). The list
lives in [docs/ROADMAP.md](docs/ROADMAP.md), with the detailed v0.4
plan in [docs/v04-plan.md](docs/v04-plan.md).

## the failure mode I have accepted

Emacs is single threaded. A stuck regex stalls the OS. A slow network
call stalls the OS. The panic buffer mitigates this for errors raised
through `condition-case`, but it does not save you from a tight loop
in C-level code. This is a documented design constraint, not a bug. I
lose maybe one session a week to it. If that ratio is unacceptable to
you, this is not your OS, and I will not be offended.

## status

  - v0.1: tagged, ISO is 1.57 GB, boots in QEMU. Xvfb only.
  - v0.2: tagged. Real Xorg, working input, poweroff, hostname. Same
    ISO build flow.
  - v0.3.1: tagged. Round-5 hardening across the pid1 ABI, the
    supervision throttle, and the buffer renderers. Long-standing
    fullscreen-pre-WM hang in `exwm-config.el` fixed (was making
    headless smoke-tests time out). Freeze-test suite, AUTHORS,
    contributor docs, user guide.
  - v0.4: in flight. Eight of eleven items shipped: persistent state,
    `core/supervise.el`, static IPv4, `*packages*`, suspend/resume,
    `passwd.el` + `*users*`, audio preview, and the three-way GRUB
    boot menu (ui / console / recovery). Remaining: the real
    installer, the login flow (deferred to v0.5), LUKS at boot, and
    the Hurd spike. Plan in [docs/v04-plan.md](docs/v04-plan.md).

I am the only contributor. If you want to send a patch, read the
manifesto first so you know what you are signing up for.

## license

GPLv3 or later, same as Emacs and Guix. See `COPYING`.
