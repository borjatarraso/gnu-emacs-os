<!-- SPDX-License-Identifier: FSFAP -->
<!--
Paste-ready submission for the GNU package evaluation described at
https://www.gnu.org/help/evaluation.html.

Send to: gnueval@gnu.org  (plain text, per that page)
Subject: Evaluation request: GNU/Emacs Operating System (GEOS)

The body below follows the official questionnaire from that page
(the "Questionnaire for offering software to GNU" section), field for
field.  Send it as plain text and attach the signed release tarball.

Status before sending:

  1. Contributor licensing is settled.  GEOS keeps copyright with the
     maintainer (and contributors over their own work) and takes
     contributions under the Developer Certificate of Origin, not FSF
     copyright assignment.  The evaluation page confirms this is
     allowed: "For a program to be GNU software does not require
     transferring copyright to the FSF."
  2. The Savannah project is approved (task #16779, 2026-06-22) and the
     repository is live.
  3. The granted Savannah unix name is `geos`; every URL below already
     matches it.
-->

# GNU package evaluation submission, GEOS

## General Information

### Do you agree to follow GNU policies?

Yes.  I have read the Information for Maintainers of GNU Software and
the GNU Coding Standards and I agree to follow them as maintainer of
GEOS, including the terminology policy (GNU/Linux, free software) and
the documentation-format policy discussed below.

### Package name and version

GNU/Emacs Operating System (GEOS), v1.0.2, tag `v1.0.2`, released
2026-07-11, signed with the maintainer key.  v1.0.2 is v1.0.1 plus the
conventional configure-and-make build surface and the shell-policy
correction described below; v1.0.1 was v1.0.0 plus the complete
per-file copyright and license notices added during the Savannah
review.

### Author Full Name <Email>

Borja Tarraso <borja.tarraso@member.fsf.org>.  FSF associate member.
Signing key `4491 8A01 3087 BBF8 4D41 C229 4FD9 DE40 1BD9 C40C`
(rsa4096).

### URL to package home page (if any)

https://savannah.nongnu.org/projects/geos (read-only mirror at
https://github.com/borjatarraso/gnu-emacs-os).  If GEOS is accepted,
the home page would move to https://www.gnu.org/software/geos.

### URL to source tarball

A signed release tarball is attached to this message.  The same
sources are at https://git.savannah.nongnu.org/cgit/geos.git, tag
`v1.0.2`.

### Brief description of the package

GEOS is an operating system in which GNU Emacs is PID 1 and GNU Emacs
is the interactive userland.  The kernel (Linux or GNU/Hurd 0.9)
provides hardware abstraction.  The whole interactive and
administrative surface above it is Emacs and Elisp: the login shell is
eshell, the window manager is EXWM, the file manager is dired, and
every system concept a user would reach for is an Emacs buffer with a
major mode and a refresh timer (`*processes*`, `*network*`, `*journal*`,
`*services*`, `*disks*`, `*packages*`, `*users*`, `*audio*`,
`*install*`).  Ordinary command-line programs (GNU coreutils,
findutils and the rest) are present as on any GNU system, and eshell
runs them the way any shell runs external commands; the "Emacs is the
userland" claim is about the interactive surface, not a claim that
Emacs is the only executable on the system.  The PID 1 binary is also
an Emacs dynamic module, so the supervision code runs inside the Emacs
process, and Shepherd is not used: service supervision is Elisp.  A
real POSIX shell is provided as `/bin/sh` so standard packages build
(`./configure`, `make`); eshell is the interactive shell, not the
build shell.

GEOS has two targets, one per kernel, and it runs end to end on both.
On GNU/Linux: a Guix-built image
with EXWM, a multi-user login flow, persistent `/var/emacs` on ext4,
and supervised user sessions with workspace isolation.  On GNU/Hurd
0.9: the same Emacs userland on canonical Debian GNU/Hurd, multi-user,
with end-to-end SSH, the supervisor's Linux-only syscalls routed
through Hurd backends (Mach RPC for reboot, pfinet for the `*network*`
buffer, libports translators for peer credentials).

## Code

### Dependencies

  - GNU Emacs 30.2 (lucid build, dynamic modules, native compilation).
  - GNU Make, GCC, glibc (build).
  - GNU Hurd 0.9 with GNU Mach (Hurd target); Linux 5.x or later
    (Linux target).
  - Xorg, EXWM 0.33, xelb 0.20.
  - Guix (build orchestrator with a pinned channel; deterministic
    closure).

All dependencies are free software.  The Hurd-side runtime adds no
non-free components; the v1.x apt-image flavor uses Debian GNU/Hurd's
main archive, which is free-software-only.

### Configuration, building, installation

The package builds with the conventional
`./configure && make && make install`.  The top-level `configure` is a
hand-written POSIX shell script following the GNU configuration
interface: the standard directory variables, `CC`/`CFLAGS` from the
environment, `--prefix` and the per-directory flags, `--help`,
`--version`, and `config.status --recheck`.  It writes `config.mk`,
which the top-level Makefile includes.  The Makefile follows the GNU
Makefile Conventions: the standard directory variables, `DESTDIR`
staging, and the standard target set (`all`, `install`,
`install-strip`, `uninstall`, `installdirs`, `clean`, `distclean`,
`mostlyclean`, `maintainer-clean`, `check`, `installcheck`, `dist`,
`TAGS`, and the documentation-format targets).  It recurses into the
two C components, the PID 1 binary in `pid1/` and the `/bin/sh` program
in `shstub/`.

This sits alongside the reproducible image path, which is a pinned Guix
channel (a Guix operating-system expression) on GNU/Linux and
`iso-build/hurd-image-reroll.sh` on GNU/Hurd; that path remains the way
the full bootable system is produced.  Two limitations I would rather
state than have you find: `configure` is hand-written rather than
produced by Autoconf (I can migrate it if you prefer Autoconf), and
separate build directories (VPATH) are not yet wired through the
component Makefiles, so the tree builds in place for now.  Both are
noted in the source.

### Documentation

The manuals (architecture, install, internals, Hurd boot, Hurd port,
user guide, manifesto) are written today in Markdown and licensed under
the GNU FDL 1.3 or later, with the full FDL embedded in each.  I
understand the GNU standard documentation format is Texinfo, and I will
provide the manuals in Texinfo, with reference and tutorial material in
one manual, as part of joining GNU.  The content exists today; the
remaining work is the format conversion.

### Internationalization

User-visible strings are English-only today.  I will make them
translatable with GNU Gettext as part of the i18n work already on the
roadmap.  Text entry already works for non-Latin scripts: the
`input.el` userland drives quail input methods (Pinyin, Anthy, Hangul
tested) in any buffer.

### Accessibility

Every system surface is an ordinary Emacs buffer of text, so the whole
UI is reachable through Emacs's existing accessibility paths:
keyboard-only operation, large fonts via the HiDPI path in `fonts.el`,
and screen readers or speech through Emacspeak, which operates on the
same buffers.  There is no custom widget toolkit that would bypass
those paths.  I treat accessibility regressions as release blockers
alongside the Hurd matrix.

### Security

  - Authentication: the multi-user login verifies credentials and, on
    GNU/Hurd, binds sessions to kernel-verified peer credentials over a
    libports translator (the `auth_server_authenticate` path).
  - Hardening: the login flow has audit logging, per-account throttle
    and lockout on repeated failure, and a last-login footer.
  - Privilege: PID 1 runs as root by necessity.  It checks every
    syscall and reports errno to `/dev/console`, does no malloc in hot
    paths, and the RPC supervisor channel
    (AF_UNIX `/run/geos/super.sock`) verifies the peer before honoring
    privileged verbs such as reboot and poweroff.
  - Attack surface: no shell-out from supervisor code, enforced by the
    `no-shell-check` pre-commit gate; the supervisor never invokes a
    shell.  eshell is the interactive shell for users and `/bin/sh` is
    a POSIX shell for scripts and builds; neither sits on a supervisor
    code path.
  - No cryptographic algorithms are implemented in-tree; release
    integrity relies on detached GPG signatures over tags and tarballs.

## Licensing

Code is under the GNU GPL version 3 or later (SPDX headers on every
source file, COPYING at top level).  Manuals are under the GNU FDL 1.3
or later (the full FDL is embedded in each manual, COPYING.DOC at top
level).  Supporting files and media use the all-permissive license
(FSFAP).  All dependencies listed above are free software; none requires
a license that is not on gnu.org/philosophy/license-list.html.

Copyright is held by the maintainer, and by future contributors over
their own work.  Contributions are taken under the Developer
Certificate of Origin (a `Signed-off-by` trailer); `docs/CONTRIBUTING.md`
documents the flow.  Per the evaluation page, keeping the copyright is
allowed; enforcement of the GPL is then mine rather than the FSF's.

## Similar free software projects

I searched the Free Software Directory and the wider free-software
landscape:

  - GNU Guix System uses GNU Shepherd as PID 1 and a Scheme
    operating-system definition.  GEOS deliberately replaces Shepherd
    with in-Emacs Elisp supervision; that is the one place GEOS
    overlaps a sibling GNU project, and the rationale (single-process
    supervision, Elisp as the configuration language, no separate init
    daemon) is argued openly in `docs/MANIFESTO.md` and is open to
    discussion.  GEOS is not a fork of the GNU system or its libraries;
    it is a userland thesis layered on an unmodified Emacs.
  - Emacs-as-environment tools (EXWM as a window manager, eshell,
    Tramp, dired as a file manager) exist as separate packages, but
    none runs Emacs as PID 1 or supervises system services from inside
    Emacs.  GEOS is the integration of those into a bootable system.
  - To my knowledge GEOS is the first project to run GNU Emacs as PID 1
    on GNU/Hurd end to end through a multi-user X session.  That is
    what motivated me to write it: it puts the Emacs userland directly
    on the FSF's longest-running kernel research vector.

## Any other information, comments, or questions

  - Maintainer commitment: I will continue as maintainer indefinitely,
    cut signed point releases on a roughly monthly cadence until v1.x
    stabilizes, keep the Hurd port matrix (`docs/HURD_PORT.md`) green as
    a release gate, and file upstream patches against Hurd, Emacs, and
    Guix as the port uncovers bugs (seven drafts are queued under
    `docs/upstream/`).
  - Free-software hygiene: reproducible build from a pinned Guix
    channel; no recommendation of any non-free program or
    documentation; a pre-commit gate that keeps the tree and history
    free of references to proprietary tooling, mirrored in CI.
  - I am happy to amend, split, or restructure anything per the
    evaluators' feedback.

Sincerely,
Borja Tarraso

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
