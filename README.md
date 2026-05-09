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

This is v0.2. It runs. I use it.

## try it

```
cd iso-build
guix time-machine -C channels.scm -- \
    system image -L .. build.scm
./qemu-harness.sh /gnu/store/...-image.iso
```

You need a Linux host with KVM, Guix installed, and about 8 GB free
in `/gnu/store`. Boot takes around eleven seconds. Full instructions
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
    `*packages*` are all live buffers with sensible keybindings.
  - The whole image builds reproducibly from a pinned Guix channel
    (commit `230aa373f315f247852ee07dff34146e9b480aec`).

## what does not work yet

The Hurd variant. Real hardware (only QEMU is exercised). Multi-user.
Audio. Bluetooth. Wayland. Real networking beyond `lo`. The list lives
in [docs/ROADMAP.md](docs/ROADMAP.md); v0.3 is where it gets shorter.
v0.2 is about "I can boot it, type into it, see the screen, and shut
it down without a host kill", which works.

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
  - v0.3: scoped, not started. See [docs/ROADMAP.md](docs/ROADMAP.md).

I am the only contributor. If you want to send a patch, read the
manifesto first so you know what you are signing up for.

## license

GPLv3 or later, same as Emacs and Guix. See `COPYING`.
