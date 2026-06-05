<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!--
SPDX-License-Identifier: GFDL-1.3-or-later
Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Permission is granted to copy, distribute and/or modify this
document under the terms of the GNU Free Documentation License,
Version 1.3 or any later version published by the Free Software
Foundation; with no Invariant Sections, no Front-Cover Texts, and
no Back-Cover Texts.  A copy of the license is included in the
file COPYING.DOC at the top of this distribution.

Paste-ready text for the Savannah non-GNU project registration
form at https://savannah.nongnu.org/register/.  Each section
header below maps to a labelled field on that page.  Submit at
member.fsf.org login `borjatarraso` (or whatever your active
Savannah login is); the form requires no attachments.

After submission, expect 1-2 weeks for a Savannah admin to
review and approve.  Once approved you get an SSH-only git
remote at `git.savannah.nongnu.org:/srv/git/<unix-name>.git`.
-->

# Savannah non-GNU project registration

## Full Name

GNU/Emacs Operating System

## Project Unix Name (first preference)

geos

If `geos` is already taken on Savannah, fall back in this order:

  1. `gnu-emacs-os`
  2. `emacs-os`
  3. `emacs-as-pid1`

## Project Description (Short, one paragraph)

GEOS is an operating system where GNU Emacs is the userland and
GNU Emacs is PID 1.  The first userspace process the kernel
starts is a small C program that immediately becomes Emacs and
then loads itself back into that Emacs as a dynamic module, so
the supervisor lives inside the supervised process.  There is
no shell other than eshell; `/bin/sh` is a 50-line C stub that
forwards to eshell via emacsclient.  Shepherd is removed
entirely; service supervision is Elisp.  Every system concept
(`top`, `ip a`, `journalctl`, `df`, `apt`) is a buffer with a
major mode.  GEOS runs end-to-end as PID 1 on both Linux and
canonical Debian GNU/Hurd 0.9, multi-user, with EXWM.

## Project Description (Long)

GEOS turns Emacs into the OS rather than an editor that runs on
the OS.  v1.0.0 boots Emacs as PID 1 on two kernels: Linux (Guix
host) and canonical Debian GNU/Hurd 0.9, both end-to-end through
a multi-user EXWM session.

Architecture in three layers:

  - kernel: Linux or Hurd (Mach + translators).  Provides
    hardware abstraction and nothing more.
  - PID 1: a small C binary (`pid1`) and its companion Emacs
    dynamic module (`pid1-module.so`).  The C side does the
    fork/exec/wait reaping, signal forwarding, mount syscalls,
    reboot syscalls, and the supervised Emacs spawn.  The
    dynamic module exposes those primitives as Elisp functions
    (`pid1-mount`, `pid1-reboot`, `pid1-spawn-as-uid`, etc.).
  - Emacs userland: every system concept is a buffer.  `*top*`
    is `*processes*`, `ip a` is `*network*`, `journalctl` is
    `*journal*`, `df` is `*disks*`, `apt` is `*packages*`, and
    so on.  Each buffer has a major mode, a refresh timer, and
    keyboard bindings that drive the underlying capability
    directly (no shell-out).

The port seam is a function-pointer struct (`port_caps` in
`pid1/port_layer.h`) with `port_linux.c` and `port_hurd.c`
backends.  Every Linux-only syscall in `pid1/` routes through
this struct.  A `STATIC=1` build inlines the supervisor
primitives into a statically linked `emacs-init` binary
(verified at v0.9.17: ~1.5 MiB, zero dynamic deps).

A 50-line `/bin/sh` stub forwards `sh -c` into eshell via
`emacsclient`; no other shell exists in the image.  EXWM brings
up real Xorg against virtio_gpu's KMS device.  The supervisor
exposes an `AF_UNIX` RPC channel at `/run/geos/super.sock` with
`SO_PEERCRED` gating on Linux and `auth_server_authenticate` on
Hurd.

Build is reproducible from a pinned Guix channel
(`guix-system/channels.scm`).  `iso-build/dev-vm.sh` builds the
host-side binaries, runs `guix time-machine` against the pinned
channel to produce a qcow2, then boots it under QEMU/KVM.  Boot
to a usable EXWM frame takes about eleven seconds on a
contemporary laptop.

For Hurd: a fresh Debian GNU/Hurd 0.9 image plus
`install/hurd-bootstrap.sh` plus reboot.  The bake script
`iso-build/hurd-image-reroll.sh` produces a derivative image
with the static `pid1` + the supervisor tree + serial GRUB +
SSH authorized_keys pre-baked.

The project ships an in-VM abuse suite (`iso-build/freeze-tests.el`)
that asserts the Emacs single-thread reality (a stuck regex
would stall the OS) does not actually freeze the supervisor
under runaway loops, catastrophic regex, slow network, or
bad tramp; the panic buffer catches every uncaught error.

## Other Software Required

Build host:

  - GNU Make
  - GCC (or any C11 compiler)
  - Guix (host package manager, used as the build orchestrator)
  - QEMU + KVM (for the dev VM)

Runtime:

  - Linux kernel (>= 5.x) or GNU/Hurd 0.9 (Mach)
  - GNU Emacs 30.2 (lucid build) with dynamic-module support
  - Xorg + EXWM 0.33 + xelb 0.20 (for the graphical session)
  - OpenSSH (for the `*ssh*` userland)
  - dhcpcd (for DHCP from `*network*`)

The full Guix channel pin is in `guix-system/channels.scm`
and produces a deterministic closure.

## License

Choose: GNU General Public License v3.0 or later
(plus GNU Free Documentation License v1.3 or later for manuals)

  - Source code (every .el, .c, .h, .scm, .sh, .yml, .py, .conf, .mk
    and every `Makefile`): GPL-3.0-or-later.  Full text in COPYING.
    Each source file carries an `SPDX-License-Identifier` header
    AND the complete GPL notice paragraph in its own comment style,
    per the gnu.org/licenses/gpl-howto recommendation.

  - Documentation (every .md file in the tree, plus AUTHORS):
    GFDL-1.3-or-later, with no Invariant Sections, no Front-Cover
    Texts, and no Back-Cover Texts.  Full text in COPYING.DOC.
    Each .md file carries a visible `## license` section at the
    end with the complete GFDL notice paragraph, per the
    gnu.org/licenses/fdl-howto recommendation.

`AUTHORS` lists the maintainer, the GPG signing key fingerprint, and
the per-file-category breakdown of which license applies to which
file.  `docs/upstream/STATUS.md` documents the directory-level
license for `docs/upstream/emails/*.txt` and
`docs/upstream/patches/*.patch` (where a per-file header would break
the email or patch format).  `docs/MEDIA.md` inventories every
binary asset with origin and license.

## Other Public Domain / GPL-Compatible Licenses

None.  All in-tree code is GPL-3.0-or-later; all in-tree
documentation is GFDL-1.3-or-later.  The vendored Emacs package
pins are upstream packages under their own GPL-compatible licenses
(use-package, etc.), not redistributed here.

## Group Type

Software

## Existing Git Hosting

The current public mirror is on GitHub:

  https://github.com/borjatarraso/gnu-emacs-os

The Savannah git repository will be the primary upstream after
approval.  GitHub will continue as a read-only mirror, with the
maintainer pushing to both via `remote.origin.pushurl` in the
local `.git/config` (see `docs/HACKING.md` for the mirror setup).

## Maintainer

Borja Tarraso <borja.tarraso@member.fsf.org>

Tags are signed with GPG key fingerprint
`4491 8A01 3087 BBF8 4D41  C229 4FD9 DE40 1BD9 C40C` (rsa4096).

## Why Savannah (rather than another forge)

Free-software hosting that the FSF can endorse, plus a path
toward GNU project status if the GNU evaluation committee
accepts the submission separately filed at
`gnu-prospective-projects@gnu.org` (see
`docs/savannah/GNU_EVALUATION_SUBMISSION.md`).

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
