<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

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

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".

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
