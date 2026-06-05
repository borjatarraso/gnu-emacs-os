<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# task #171 verification: emacs respawn-on-crash on Hurd

this receipt closes the v0.9.12 follow-on item #171 (emacs
respawn-on-crash missing/broken on Hurd) by direct VM evidence
rather than by writing code.  no source change ships with this
receipt.

## Background

`pid1/emacs-init.c` fork+execs emacs as its first child and
supervises it with a 5-in-60s respawn cap.  the supervisor loop
calls `waitpid(-1, &status, 0)` at line 1987; when the reaped
pid matches the tracked emacs pid the supervisor logs
`pid1: emacs exited, respawning` at line 2011 and re-enters
`spawn_emacs()`.

the v0.9.11 PARTIAL PASS receipt
(`docs/runlogs/2026-05-21-v0911-hurd-essentials-vm.md` lines
404-411) noted that on Hurd, pid1 did NOT fork a replacement
when emacs crashed.  that was when emacs was hitting the
native-comp trampoline failure mode before completing its own
startup; v0.9.12's slice 2 (remount-rw) + slice 4 (native-comp
opt-out) closed the crash itself, so the original observation
could not be reproduced naturally any more.

the audit asked: is the v0.9.11 observation an artifact of
"emacs aborted before completing proc-server registration"
(safe on the post-v0.9.12 boot), or is there a real gnumach
SIGCHLD delivery gap (defence-in-depth still needed)?

## Result

**PASS.**  pid1 reliably respawns the supervisor's emacs child
after a forced `SIGSEGV` on Debian GNU/Hurd 0.9 + gnumach
1.8+git20260224, just as it does on Linux.  the original
observation was the artifact, not a gnumach gap.  the C path,
which is byte-identical between kernels (`port_caps` has no
child-reap slot, `waitpid` is POSIX), functions identically on
Hurd.  task #171 closes by direct evidence; no follow-on code
slice required.

## Probe

ephemeral snapshot off
`/tmp/geos-hurd-vm-v0912-s11-1779448717.qcow2`, ultimately
backed by canonical
`/home/overdrive/hurd-vm/debian-hurd-amd64-20260314.img`
(canonical mtime preserved).  one offline fix before booting:
the snapshot's
`/usr/share/geos/emacs-init/services/hurd-essentials.el` was
overwritten with the v0.9.12-PASS host copy (the snapshot
predated the inline `-a/-m/-g` settrans args) so pfinet would
attach.  serial console transcript at
`/tmp/t171-serial-rw-1779457081.log` (73912 bytes).

### Steps

  1. boot snapshot; confirm GEOS pid1 + `early-init: emacs
     pid=27 pid1-as-emacs-p=t module-env=...`.
  2. ssh -p 2266 root@127.0.0.1: interactive session works
     (v0.9.12 PASS condition).
  3. capture emacs pid via `ps -A` over ssh: 27.
  4. forcibly `kill -SEGV 27` over ssh.
  5. watch serial for `pid1: emacs exited, respawning` and a
     new `early-init: emacs pid=N` with N != 27.
  6. re-attempt ssh -p 2266 root@127.0.0.1 against the
     respawned emacs.
  7. repeat the kill 5 more times for a 6-cycle exercise.

### Evidence

| metric                                        | value                       |
|-----------------------------------------------|-----------------------------|
| initial emacs pid                             | 27                          |
| post-respawn pids (in order)                  | 93, 146, 182, 218, 254, 290 |
| `pid1: emacs exited, respawning` count        | 6                           |
| `early-init: emacs pid=N` count               | 7 (initial + 6 respawns)    |
| `/hurd/crash ... crashed, signal {no:11,...}` | 6 (crash server caught all) |
| respawn latency per cycle                     | ~2-10s                      |
| `pid1: emacs crashloop` (cap tripped)         | 0 (window reset; see below) |

every respawn confirmed `ppid=1` via `ps -A` over the
re-established ssh.  STEP 6 functional gate: ssh re-established
into respawned emacs at pid 93 and again at pid 290, full RPC
channel up, `uname -a` returns
`GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9`.

### Timing note on the 5-in-60s cap

the literal source at `pid1/emacs-init.c:1071` is
`if (emacs_respawns_window > EMACS_RESPAWN_CAP)` with
`EMACS_RESPAWN_CAP=5`, so the hold fires on the 6th respawn
within 60s, not the 5th.  6 kills were run, but each cycle
(kill -> spawn_emacs -> emacs init -> ssh-ready -> next kill)
took ~15-20s, and the window logic in `emacs_note_respawn`
(lines 1062-1068) resets the counter whenever
`now - emacs_window_start > 60` OR
`now - emacs_last_respawn > 60`.  by kill #6 the window had
reset and the cap was never tripped.  to deliberately trip it
would require sub-10s spacing with no ssh-roundtrip between
kills; out of scope for this probe (which was checking respawn
delivery, not cap arithmetic).

## What this closes

  - task #171 (v0.9.12 follow-on): emacs respawn-on-crash on
    Hurd.  the observation was real but its cause was emacs
    aborting before completing dynamic-module hookup, not
    gnumach dropping SIGCHLD.  v0.9.12 closed the cause; this
    probe confirms the respawn path that was always nominally
    in place actually fires.

## Files touched

  - `docs/HURD_PORT.md`: add a new YES row for emacs
    respawn-on-crash on Hurd (no port_caps slot; verifies the
    POSIX `waitpid` path that was always shared between
    kernels).
  - this runlog.

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
