<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Booting GEOS on GNU/Hurd

GEOS runs on canonical Debian GNU/Hurd 0.9 as of v1.0.0.  Emacs is
PID 1, the full supervisor tree comes up, the multi-user EXWM
session lands, end-to-end SSH works (`v0.9.12`), and the install
wizard formats + GRUB-installs onto a second disk (`v0.9.23`).
Every row of [HURD_PORT.md](HURD_PORT.md) is YES modulo two
deferred-upstream rows (real-hardware audio and pfinet per-iface
counters); see [docs/upstream/](upstream/) for the on-list
filings.

This document is the operator runbook.  There are two paths:

  - **Image re-roll (recommended)**: run
    `iso-build/hurd-image-reroll.sh` on a Linux host against the
    canonical Debian GNU/Hurd 0.9 image.  Out comes a derivative
    image with the static `pid1`, the supervisor tree, serial GRUB,
    and SSH authorized_keys baked in.  Boot it under QEMU and `ssh
    -p 2266 root@127.0.0.1`.  See
    [iso-build/hurd-image-reroll.sh](../iso-build/hurd-image-reroll.sh)
    for the flags; `FLAVOR=apt-image` adds EXWM-on-Xvfb plus
    pulseaudio userland on top, `GEOS_BYPASS=1` re-routes to a
    stock canonical image with `/sbin/init` + bash for comparison
    work.
  - **Manual bootstrap (for the curious or for porting work)**:
    boot a fresh canonical Debian GNU/Hurd 0.9 install, run
    `install/hurd-bootstrap.sh` as root, reboot.  The recipe below
    walks through the apt prereqs, the build, the init.args
    contract, the rollback path, and what a healthy console
    transcript looks like.

The `pid1/port_hurd.c` source still lives only on the `hurd` side
branch (rebased onto main weekly per the side-branch contract).
`port_layer.h` and `port_linux.c` live on main.  The static
`pid1` and the supervisor tree that ship in the re-rolled image
are built from the `hurd` branch.

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

`STATIC=0` is the default Debian Hurd path: the static
`libfshelp.a` shipped by libhurd-dev references
`__assert_fail_backtrace`, a glibc-debug symbol the static glibc
archive does not export.  A dynamic link picks it up fine.  The
downside is DT_NEEDED entries on libfshelp / libhurduser /
libmachuser; those are provided by libhurd-dev and ship under
/lib on the Debian Hurd rootfs, so the dynamic linker resolves
them at boot.

`STATIC=1` works too as of v0.9.17 (the supervisor primitives are
inlined and the binary has zero dynamic deps, about 1.5 MiB).
The image re-roll script uses `STATIC=1` for the binary it bakes
into the canonical image so the rootfs's runtime libs are not on
the boot critical path.

Expected output: `pid1/emacs-init` (and `pid1/pid1-module.so` if
you also `make module`), linked against `-lfshelp -lhurduser
-lmachuser`.  The historical `-lhurd` / `-lmach` standalone .so
files are gone on a modern Debian Hurd toolchain (folded into
glibc); the Makefile reflects this.

**Things that can still surprise you** (the recipe below is
what works on canonical Debian GNU/Hurd 0.9; if you have a
different snapshot expect breakage in any of):

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

### v0.9.12 install workflow (recommended)

As of v0.9.12 the install is one script and the booted image opens
an interactive ssh session from the host without any post-install
manual steps.  Prerequisite is a fresh Debian GNU/Hurd 0.9 image
with a working network and root login.  Get an apt mirror reachable
first, then:

```
# inside the Hurd VM, as root
apt install ssh inetutils-syslogd
# optional, only if you want EXWM under Xvfb (v0.9.10 path):
apt install xvfb emacs-lucid elpa-exwm elpa-xelb
```

sshd + inetutils-syslogd are not optional: the `hurd-essentials`
supervisor expects both binaries to exist on disk, and v0.9.6's
journal-kmsg source on Hurd tails `/var/log/kern.log` which only
grows because syslogd is draining `/dev/klog` into it.

By default the supervisor configures eth0 statically against the
QEMU SLIRP defaults (10.0.2.15/24, gw 10.0.2.2).  For a bare-metal
deployment with real DHCP, set `geos-hurd-static-eth0` to `nil`
under `/var/emacs/init.el` after the first boot; the settrans
pre-step still runs so an apt-installed dhcp client has a live
pfinet to bind to.

Copy the GEOS source tree to the target under `/usr/local/src/geos/`
(rsync, scp, git clone, whatever fits your workflow), then build
pid1 and the dynamic module on the target itself:

```
cd /usr/local/src/geos/pid1
make PORT=hurd STATIC=0
make pid1-module.so PORT=hurd STATIC=0
```

`STATIC=0` is required on Debian Hurd; see Step 3 above for the
reason.  If you are unsure which targets the Makefile actually
exposes, read `pid1/Makefile`; the PORT=hurd branch is the source
of truth.

Then run the bootstrap:

```
/usr/local/src/geos/install/hurd-bootstrap.sh
```

The script is idempotent.  It refuses to run unless `uname` says
`GNU` and euid is 0, backs up `/sbin/init` to
`/sbin/init.debian-stock` (only on the first run, never overwrites
itself on re-runs), copies the freshly-built pid1 binary into
`/sbin/init`, stages the elisp tree under
`/usr/share/geos/emacs-init/`, drops the dynamic module at
`/usr/lib/geos/pid1-module.so`, and writes the boot chain to
`/etc/geos/init.args`.  Reboot and the next boot lands in Emacs
PID 1 mode.

Rollback path: boot into the GRUB rescue / maintenance shell, then
`mv /sbin/init.debian-stock /sbin/init`.  Reboot once more and you
are back on stock Debian sysvinit.

### bash console option (GEOS_BYPASS, build-time)

Some operators want the canonical Debian GNU/Hurd 0.9 userland
(bash + sysvinit + getty) instead of the Emacs PID 1, but still
want the bake-time conveniences the reroll script provides (serial
console patch on every GRUB multiboot line, root authorized_keys
in place, pre-generated sshd host keys).  Set `GEOS_BYPASS=1` on
the reroll invocation:

```
GEOS_BYPASS=1 ./iso-build/hurd-image-reroll.sh
```

Under bypass the script keeps `/sbin/init` as the stock Debian
binary (no `/sbin/init.debian-stock` backup is created because no
swap happens), and skips the `init.args` + supervisor tree +
`early-init.el` overlays.  The rerolled image lands at
`BYPASS_OUTPUT_IMG` (default
`/home/overdrive/hurd-vm/debian-hurd-amd64-canonical.img`) so the
operator's GEOS image is not clobbered.  The boot smoke gate is
also skipped under bypass because its PASS markers are
GEOS-specific; boot manually and ssh in to verify.

`GEOS_BYPASS=1 FLAVOR=apt-image` is rejected by the script: the
apt-image overlay needs the GEOS supervisor running during the
apt pass, so the combination is not coherent.

### legacy manual install (pre-v0.9.12)

The hand-rolled version of the same steps, kept here because it
documents what the bootstrap script does under the hood and is
sometimes useful when debugging a half-bricked image.

```
# inside the Hurd VM, as root
cp /sbin/init /sbin/init.debian-orig
cp pid1/emacs-init /sbin/init
cp pid1/emacs-init /usr/sbin/init     # sysvinit keeps both in sync
mkdir -p /etc /var/log /run
echo "geos-hurd" > /etc/hostname
sync
```

### /etc/geos/init.args file format

pid1 reads `/etc/geos/init.args` only when `argv[1]` is not an
absolute path.  That is the Hurd case: `/hurd/startup` execs
`/sbin/init` with `argc==1` (or with a sysvinit-style runlevel
token like `"6"` in `argv[1]`, which is also not absolute).  On
Linux the Guix gexp passes an absolute store path in `argv[1]`
(`/gnu/store/.../emacs`), so the file is never opened.

The file is one argv slot per line.  `#` lines and blank lines are
stripped.  pid1 walks the file in order: slot 1 is the emacs
binary, slot 2 is the pid1 dynamic module, slot 3 is the Xorg spec
(empty path field disables X spawn on Hurd), slot 4+ are forwarded
into emacs's own argv as the `-l` chain.  Example (trimmed from
what `hurd-bootstrap.sh` writes; see the script for the full
canonical load order):

```
# /etc/geos/init.args -- v0.9.11 Hurd boot chain
/usr/bin/emacs
/usr/lib/geos/pid1-module.so
:
-Q
-l
/usr/share/geos/emacs-init/early-init.el
-l
/usr/share/geos/emacs-init/core/panic.el
```

The file must be a root-owned regular file.  pid1 opens it with
`O_NOFOLLOW` and rejects symlinks; an `fstat` after open confirms
`S_ISREG` and `st_uid == 0` before any line is parsed.  Failure
modes (open errno, non-regular, non-root, short read, empty file,
file larger than 8 KiB, more args than the slot cap) all fall
through to the default argv and log a one-line diagnostic to
`/dev/console`.  See the `parse_init_args` docstring at
`pid1/emacs-init.c` for the full contract.

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

## What "verified" means in v1.0.0

Every row in [HURD_PORT.md](HURD_PORT.md) is YES modulo two
deferred-upstream rows.  Concretely, on canonical Debian GNU/Hurd
0.9 the expected steady-state is:

  - pid1 boots to a Hurd prompt without panicking.
  - `geos-kernel` is `'hurd` in `*scratch*`.
  - `(geos-port-call 'reboot 'halt)` reboots the VM cleanly via
    `host_reboot` through `get_privileged_ports`.
  - `*processes*` lists pid1, the emacs supervisor, and any
    `defservice` children that have spawned.
  - `*network*` shows the pfinet interface and the routing table
    (counters render as zeros, the deferred-upstream gap).
  - `*disks*` shows the storeio nodes and mount table.
  - `*audio*` renders the not-on-this-kernel banner; the v1.x
    apt-image flavor instead surfaces pulseaudio via `pactl`.
  - SSH to the supervised emacs works on `:2266` (see v0.9.12).
  - Multi-user `*login*` flow + concurrent per-user EXWM sessions
    work on the apt-image flavor (Xvfb + EXWM 0.33).
  - `M-x install` end-to-end onto a second disk: mkfs.ext4 +
    pid1-mount + cp -a + grub-install (see v0.9.23).

## After verification

For routine re-verification:

  - `iso-build/hurd-image-reroll.sh` re-bakes the image from
    current `hurd` branch HEAD; the in-script smoke gate boots
    the result and waits for the supervised emacs to come up.
  - any deltas to `port_hurd.c` land on the `hurd` branch and
    rebase forward onto main during the weekly side-branch
    rebase.
  - per-milestone receipts live under `docs/runlogs/`; the
    convention is one file per verified slice with the raw
    serial / VM transcripts that prove the slice landed.
