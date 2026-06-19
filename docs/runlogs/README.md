<!-- SPDX-License-Identifier: FSFAP -->
# runlogs

<!-- voice: first person singular, lowercase, no em-dashes. -->

Verification logs from real hardware or real-kernel VM runs.  one
file per milestone, named `YYYY-MM-DD-<short-tag>.md`.

The runlogs are sanitized at write time: no credentials, no SSH
passwords, no host paths that point at my dev machine, no IPs that
reveal infra (QEMU's 10.0.2.x NAT defaults are fine, they are
public).  the commands shown here are what someone reproducing the
verification would run; the output is verbatim from the run.

These logs exist because the verification matrix in
`docs/HURD_PORT.md` claims things and a public log either backs
that up or shows where the claim was actually weaker than the
matrix suggested.  the matrix is a summary; the runlog is the
receipt.

If a future commit reverses or invalidates a runlog claim, add a
new runlog dated to the day of the regression instead of editing
the historical one.  the runlogs are append-only.

## images in this directory

This directory also holds serial-console screenshots captured from
QEMU sessions of GEOS itself.  A PNG cannot carry a license notice
inside the file, so the copyright and license for these images are
stated here, in the same directory as the files, and again in the
inventory at `docs/MEDIA.md`.

  - `2026-05-18-hurd-pid1-boot-screen.png`
  - `2026-05-18-hurd-pid1-emacs-spawn-screen.png`
  - `2026-05-18-hurd-pid1-reboot-rpc-screen.png`
  - `2026-05-18-hurd-pid1-reboot-aftertype-screen.png`

I captured every one of them from QEMU running an image I built;
every pixel originates from that image or from the GRUB and Hurd
boot output it displays.

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of these images, with or without
modification, are permitted in any medium without royalty provided
the copyright notice and this notice are preserved.  These images
are offered as-is, without any warranty.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
