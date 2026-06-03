# runlogs

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
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
