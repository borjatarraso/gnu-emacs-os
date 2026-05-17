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
apt-get install -y build-essential libhurd-dev libihash-dev \
                   libstore-dev mig pkg-config
```

The libraries we link against (`-lhurduser`, `-lmachuser`,
`-lfshelp`) all come from `libhurd-dev` on a modern Debian Hurd
toolchain.  The historical separate `libhurd-mach-dev` package
is gone; what it used to provide is now folded into glibc and
into the user-side `-luser` stubs.  `mig` generates RPC stubs at
compile time from the `.defs` files the Mach RPC system uses;
the Hurd toolchain ships it.

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
make PORT=hurd STATIC=0
```

`STATIC=0` is required on Debian Hurd: the static `libfshelp.a`
shipped by libhurd-dev references `__assert_fail_backtrace`, a
glibc-debug symbol that the static glibc archive does not export.
A dynamic link picks it up fine.  The downside is that the boot
binary now has DT_NEEDED entries on libfshelp / libhurduser /
libmachuser; those are provided by libhurd-dev and ship under
/lib on the Debian Hurd rootfs, so the dynamic linker resolves
them at boot.  When the v0.8 cross-toolchain runner comes online
we revisit whether a static link is achievable upstream.

Expected output: `pid1/emacs-init` (and `pid1/pid1-module.so` if
you also `make module`), linked against `-lfshelp -lhurduser
-lmachuser`.  The historical `-lhurd` / `-lmach` standalone .so
files are gone on a modern Debian Hurd toolchain (folded into
glibc); the Makefile reflects this.

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
flow today because Guix-on-Hurd is still maturing.

**Hurd does not honor an `init=` kernel cmdline.**  I confirmed
this on a Debian GNU/Hurd 2026-03 snapshot on 2026-05-18: GRUB
hands control to `gnumach`, gnumach starts `/hurd/startup` as
the bootstrap PID 1, and startup execs `/sbin/init`
unconditionally.  There is no `argv[1]=path-to-init` hook.

So the install path is: **replace /sbin/init in place**, after
keeping a backup the maintenance shell can fall back to.

```
# inside the Hurd VM, as root
cp /sbin/init /sbin/init.debian-orig
cp pid1/emacs-init /sbin/init
cp pid1/emacs-init /usr/sbin/init     # sysvinit keeps both in sync
mkdir -p /etc /var/log /run
echo "geos-hurd" > /etc/hostname
sync
```

Then reboot the VM **cleanly** from inside Hurd (`shutdown -r
now`).  Do NOT use QEMU's `system_reset` monitor command for the
swap-in reboot: it is a hard reset, ext2fs has not flushed, and
the next boot drops to a single-user maintenance shell for fsck
before /sbin/init runs.  I learned this the hard way on the
second attempt today.

GRUB does not need editing.  The Debian Hurd installer's default
entry uses the standard sequence below and we change nothing in
it:

```
multiboot /boot/gnumach.gz root=device:hd0s0
module /hurd/ext2fs.static ...
module /lib/ld.so.1 /hurd/exec '$(exec-task=task-create)'
```

`/hurd/startup` will exec `/sbin/init`, which is now the GEOS
supervisor.

## Step 5: expected boot sequence

In the order they appear on /dev/console (transcript of the
2026-05-18 first-boot, see
`docs/runlogs/2026-05-18-hurd-pid1-boot-result.md`):

```
pid1: mkdir /tmp failed: Read-only file system
/hurd/tmpfs: No default pager (memory manager) is running
pid1: mount tmpfs -> /tmp (tmpfs) failed: Input/output error
pid1: mkdir /var failed: Read-only file system
pid1: /var mount failed entirely: Input/output error
pid1: INFO no gnu.system= in /etc/geos-cmdline,
      /run/current-system not linked (expected on manual Hurd install)
pid1: sethostname(geos-hurd) failed: Read-only file system
pid1: entering supervisor loop
pid1: execve failed (<errno>): /usr/bin/emacs    (only if emacs is
      missing OR the exec translator chokes on the binary)
```

The first six lines are diagnostic noise from the bootstrap-order
gap: `/sbin/init` runs BEFORE Debian Hurd's `checkroot.sh` would
remount root rw under sysvinit (we replaced /sbin/init, so that
step is gone).  The supervisor reaches its loop regardless and
attempts to exec emacs.

If emacs is properly installed and spawns, the supervisor falls
silent and the emacs banner takes over the console.  If emacs is
absent or unspawnable, the supervisor crashloops ~10 times and
then enters the holding pattern:

```
pid1: emacs crashloop, entering holding pattern; supervisor will
      reap zombies but not respawn emacs
```

The holding pattern is the documented degraded state.  pid1 stays
alive, reaping zombies, until an operator reboots.

Three bootstrap-order fixes are tracked separately and will reduce
the noise; see the runlog.  They are not blockers for "emacs
spawned at all".

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
