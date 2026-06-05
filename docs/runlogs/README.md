<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
# runlogs

<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->
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
