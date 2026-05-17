<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Booting GEOS on GNU/Hurd

The Hurd-side code (`pid1/port_hurd.c`, `guix-system/system-hurd.scm`,
`iso-build/hurd-smoke-test.sh`) is written and skeptic-reviewed but
has never been compiled against real Hurd headers or run on a Hurd
kernel. This document is the recipe for taking it from "written" to
"verified" without further code changes. Every step is something an
operator with a working Hurd environment can do; the work is
infrastructure, not code design.

## Prerequisites

One of:

  - **Debian GNU/Hurd** VM (2024 snapshot or newer). Easiest path:
    https://www.debian.org/ports/hurd/ has installer images. Boot
    qemu with `qemu-system-i386 -m 2G -enable-kvm` against a fresh
    Debian Hurd install.

  - **Guix System** with the Hurd kernel via
    `--target=i586-pc-gnu`. This requires building a Hurd cross-
    toolchain from source unless `ci.guix.gnu.org` happens to have
    substitutes; the full bootstrap on a cold cache is multiple
    hours of CPU on the build host. `guix shell` with
    `hurd-headers`, `gnumach-headers`, and `mig` does NOT work on
    `x86_64-linux` because the Guix package definitions for those
    inputs restrict `supported-systems` to Hurd targets only. The
    cross route is real but slow.

The Debian VM route is recommended for the first verification pass
because it gives you a known-good Hurd glibc and a working `apt`.

## Step 1: install build deps in the Hurd VM

```
apt-get update
apt-get install -y build-essential libhurd-dev libhurd-mach-dev \
                   libihash-dev libstore-dev mig pkg-config
```

The libraries we link against (`-lhurduser`, `-lhurd`, `-lmach`)
come from `libhurd-dev`; the Mach IPC stubs come from
`libhurd-mach-dev`. `mig` generates RPC stubs at compile time from
the `.defs` files the Mach RPC system uses; the Hurd toolchain ships
it.

## Step 2: clone GEOS and check out the hurd branch

```
git clone https://github.com/borjatarraso/gnu-emacs-os.git
cd gnu-emacs-os
git checkout hurd
```

The `hurd` branch tracks `main` and is rebased weekly per the
side-branch contract in `docs/HURD_PORT.md`.

## Step 3: build pid1 with the Hurd backend

```
cd pid1
make clean
make PORT=hurd
```

Expected output: `pid1/emacs-init` and `pid1/pid1-module.so`, both
linked against `-lhurduser -lhurd -lmach`.

**Known unknowns** (this is the first time anyone runs this; expect
breakage in any of):

  - `mig`-generated header includes may need explicit `-I` flags
    that `pkg-config --cflags hurd` should provide. If `make`
    fails on `#include <hurd/fs.h>`, add `pkg-config` integration
    to the Makefile.
  - `file_set_translator()` signature may have evolved since the
    spike review. The current call in `hurd_mount` passes
    `(name, MACH_PORT_NULL, dir_port, 0, FS_TRANS_SET, argz,
    argz_len, FS_TRANS_SET, argz, argz_len, 30000)`; verify
    against `<hurd/fs.h>` in your toolchain.
  - `host_reboot()` is in `<mach.h>`. Hurd has had a couple of
    name changes around reboot semantics over the years. If the
    symbol is missing or renamed, the fix is to swap one Mach RPC
    for another, not to redesign the port slot.
  - Linker order matters: `-lhurduser` must come before `-lhurd`
    on the cc command line. The `Makefile` PORT=hurd branch
    follows this convention.

If any of these break, fix at the file/line level and push a commit
to the `hurd` branch. Do NOT touch `main`; the side-branch contract
keeps Linux green.

## Step 4: install GEOS into the Hurd VM

The Hurd build of GEOS does NOT use Guix's `system reconfigure`
flow today because Guix-on-Hurd is still maturing. The bare-minimum
manual install:

```
install -m 755 pid1/emacs-init /sbin/emacs-init
install -m 644 pid1/pid1-module.so /lib/pid1-module.so
mkdir -p /etc /var/log /run
echo "geos-hurd" > /etc/hostname
```

Boot into the Hurd kernel with `init=/sbin/emacs-init` on the
kernel command line. In GRUB:

```
multiboot /boot/gnumach.gz root=device:hd0s1
module /hurd/ext2fs.static --readonly --multiboot-command-line='${kernel-command-line}' --host-priv-port='${host-port}' --device-master-port='${device-port}' --exec-server-task='${exec-task}' -T typed '${root}' '$(task-create)' '$(task-resume)'
module /lib/ld.so.1 /hurd/exec '$(exec-task=task-create)'
module /sbin/emacs-init
```

The trailing `module /sbin/emacs-init` line is the only GEOS-
specific addition; everything above it is the standard Hurd boot
sequence.

## Step 5: expected boot sequence

In the order they appear on /dev/console:

```
pid1: /etc/hostname applied: geos-hurd
pid1: /var ... (probably "falling through to tmpfs", since
      /dev/disk/by-label/ does not exist on Hurd)
pid1: /run/current-system not linked   (no Guix activation today)
pid1: GEOS_KERNEL splice ... (if this aborts, port->kernel_name
      is NULL — bug in port_hurd.c initializer)
pid1: emacs spawned
```

Then Emacs takes over and prints whatever core/state.el's banner
emits.

## Step 6: smoke test

```
./iso-build/hurd-smoke-test.sh
```

The script boots the VM headless and greps the serial log for the
`geos: emacs userland up` marker. If the marker appears, the boot
went all the way to userland and core/port.el resolved
`geos-kernel` to `'hurd` via the GEOS_KERNEL env propagation.

## What "verified" means

The bar is intentionally modest for the first pass:

  - pid1 boots to a Hurd prompt without panicking.
  - `geos-kernel` is `'hurd` in `*scratch*`.
  - `(geos-port-call 'reboot 'halt)` reboots the VM cleanly.
  - `*processes*` lists at least the pid1 process and the emacs
    supervisor process.
  - `*disks*`, `*network*`, `*audio*` render the
    not-on-this-kernel banner where appropriate (intentional
    degradation, not crash).

Multi-user, EXWM, install wizard, and audio are explicitly OUT OF
SCOPE for the first verification pass. Those are v0.8+ work.

## After verification

Once the smoke test passes:

  - update `docs/HURD_PORT.md` "Verification status" section to
    promote each surface from "untested" to "verified on Hurd
    YYYY-MM-DD".
  - tag a `v0.7.2` on the `hurd` branch (NOT on main) marking
    "first Hurd boot to userland".
  - any deltas to `port_hurd.c` discovered during verification
    stay on the `hurd` branch.

The first verification will surface things that the desk-review
missed. That is the point: the work order's step 6 ("Hurd smoke
test green") is the loop that closes the speculative-code risk in
`port_hurd.c`. Until it runs once, every line in that file is a
hypothesis.
