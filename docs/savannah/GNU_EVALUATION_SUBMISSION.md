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

Paste-ready submission body for the GNU project evaluation
process described at https://www.gnu.org/help/evaluation.html.

Send to: gnu-prospective-projects@gnu.org
Subject: Evaluation request: GNU/Emacs Operating System (GEOS)

The evaluation committee asks for a structured form.  The
section headers below correspond to the items listed in the
"Submitting your package" section of that page.  Expect
multi-week to multi-month turnaround; possible outcomes are
acceptance, conditional acceptance with requested changes,
or rejection.

Before sending, confirm:

  1. FSF copyright assignment paperwork is signed and on file
     for every contributor (currently just the maintainer).
     If not yet on file, request and sign before submission:
     https://www.gnu.org/licenses/why-assign.html
  2. The Savannah non-GNU registration is approved and the
     git repository is live; the evaluation committee will
     ask for a URL.
-->

# GNU project evaluation submission, GEOS

## Maintainer

Borja Tarraso <borja.tarraso@member.fsf.org>

FSF associate member.  Signing key
`4491 8A01 3087 BBF8 4D41 C229 4FD9 DE40 1BD9 C40C` (rsa4096).

## Package name and version

GNU/Emacs Operating System (GEOS), v1.0.0 released
2026-06-01, tag `v1.0.0`.

## Where to download

Public source repository (after Savannah approval):

  https://git.savannah.nongnu.org/cgit/geos.git
  (read-only mirror at https://github.com/borjatarraso/gnu-emacs-os)

Release tarballs are signed by the maintainer key above.

## What it does

GEOS is an operating system in which GNU Emacs is the userland
and GNU Emacs is PID 1.  The kernel (Linux or GNU/Hurd 0.9)
provides hardware abstraction; everything above the kernel is
Emacs and Elisp.

The PID 1 binary is also an Emacs dynamic module, so the
supervision code lives in the Emacs process itself.  There is
no shell other than eshell; `/bin/sh` is a 50-line C stub that
forwards `sh -c` into eshell via `emacsclient`.  Shepherd is
removed entirely; service supervision is Elisp running inside
the supervisor.  Every user-facing system concept is a buffer
with a major mode and a refresh timer (`*processes*`,
`*network*`, `*journal*`, `*services*`, `*disks*`,
`*packages*`, `*users*`, `*audio*`, `*install*`).

GEOS runs end-to-end on both kernels:

  - Linux: Guix-built image, EXWM, multi-user login flow,
    persistent `/var/emacs/` on ext4, supervised user
    sessions with workspace isolation.
  - GNU/Hurd 0.9: same Emacs userland on canonical Debian
    GNU/Hurd 0.9, multi-user, end-to-end SSH, with the
    supervisor's Linux-only syscalls routed through Hurd
    backends (Mach RPC for reboot, pfinet ioctls for the
    `*network*` buffer, etc.).

## Why it should be a GNU package

GEOS is the first project that runs GNU Emacs as PID 1 on
GNU/Hurd, end-to-end through a multi-user X session.  That puts
it directly on the Free Software Foundation's longest-running
research vector: the Hurd.  It also exercises every GNU Emacs
extension surface (dynamic modules, EXWM, eshell, Tramp, native
compilation, native threads where present) as a real userland
rather than a development environment.

The thesis (Emacs as the OS, not an editor on the OS) extends
the existing Emacs-as-environment tradition that has been part
of GNU since 1985.  No part of the design depends on
proprietary software.  Build is reproducible from a pinned
Guix channel.  License is GPL-3.0-or-later, with SPDX headers
on every source file.

The relationship to existing GNU packages:

  - Emacs: the userland.  GEOS does not fork Emacs; it loads
    Emacs as a dynamic module and runs the upstream Emacs
    binary unmodified.
  - Hurd: a first-class supported kernel.  The port seam in
    `pid1/port_layer.h` has Hurd backends that exercise
    real Mach RPC paths (`auth_server_authenticate`,
    `get_privileged_ports`, `host_reboot`, pfinet ioctls,
    libports translators for peer-cred).  Several upstream
    Hurd bugs found during the port have draft patches in
    `docs/upstream/` ready to be filed against the
    bug-hurd / debbugs queues.
  - Guix: the build orchestrator.  GEOS is a Guix-system
    expression with a pinned channel.
  - Shepherd: replaced.  This is a deliberate choice argued
    in `docs/MANIFESTO.md`; it is the one place where GEOS
    intentionally diverges from a sibling GNU project.  The
    rationale (single-process supervision, no PID-1 fork
    bombs from misconfigured service definitions, Elisp as
    the configuration language) is documented openly and is
    discussable.

## Dependencies

  - GNU Emacs 30.2 (lucid build, dynamic-module support, native
    compilation).
  - GNU Make, GCC, glibc (build).
  - GNU Hurd 0.9 with Mach (Hurd target).
  - Linux 5.x+ (Linux target).
  - Xorg, EXWM 0.33, xelb 0.20.
  - Guix (build orchestrator with a pinned channel; produces a
    deterministic closure).

All dependencies are free software.  The Hurd-side runtime adds
no non-free components; the v1.x apt-image flavor uses Debian
GNU/Hurd's main archive, which is free-software-only.

## Documentation

  - `README.md` (project entry point, mirrors this submission).
  - `docs/MANIFESTO.md` (the why).
  - `docs/ARCHITECTURE.md` (three zoom levels: process layout,
    port seam, dual-kernel diagram).
  - `docs/INSTALL.md` (Linux side).
  - `docs/HURD_BOOT.md` (Hurd side, including the apt-image
    flavor).
  - `docs/HURD_PORT.md` (port matrix: every elisp-side feature
    times every backend, with a status cell).
  - `docs/CONTRIBUTING.md` (commit format, attribution-scan and
    no-shell-check gates, freeze-test before phase done).
  - Per-milestone receipts under `docs/runlogs/`.
  - Upstream-draft material under `docs/upstream/`.

## Internationalization

User-facing strings are English-only for now.  i18n is on the
roadmap but not v1.0.  The `input.el` userland supports `quail`
input methods (Pinyin, Anthy, Hangul tested), so non-Latin text
entry works in any buffer.

## Maintainer commitment

I commit to:

  - Continuing as maintainer indefinitely.
  - Filing upstream patches against Hurd / Emacs / Guix as the
    port surface uncovers bugs (current queue: 7 drafts under
    `docs/upstream/`).
  - Cutting signed point releases on a roughly-monthly cadence
    until v1.x stabilizes.
  - Keeping the Hurd matrix green; a regression in any cell of
    `docs/HURD_PORT.md` blocks the next release.
  - Holding to the FSF copyright assignment policy for every
    contributor.

## Free-software hygiene

  - No mentions of any proprietary tooling in the codebase or
    history.  The pre-commit gate `attribution-scan` enforces
    this and is mirrored in the `checks.yml` GitHub Action.
  - No shell-out from supervisor code.  The pre-commit gate
    `no-shell-check` enforces this; eshell is the only
    permitted shell surface for users.
  - Reproducible build from a pinned Guix channel.
  - License: GPL-3.0-or-later, SPDX headers on every source
    file, COPYING at top level, AUTHORS lists the maintainer
    and signing key.

I am happy to amend, split, or otherwise restructure the
submission per the evaluation committee's feedback.

Sincerely,
Borja Tarraso

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
