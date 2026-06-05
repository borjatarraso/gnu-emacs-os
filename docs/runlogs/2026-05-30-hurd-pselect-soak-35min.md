<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

## 2026-05-30: v0.9.24 extended pselect soak, 35 min / 1383 evals, non-reproduced

Follow-on to docs/runlogs/2026-05-30-hurd-v0923-pselect-soak.md. That
prior receipt closed task #213 structurally on a 5-minute / 60-eval
window. This run upgrades the verdict to 35 minutes / 1383 evals on
the same v0.9.22 image, with the same crash markers and the same
non-reproduction. Verification only, no GEOS code change in this slice.

## Result

PASS. The v0.9.18-era SIGSEGV chain (pselect -> setauth helper at
libc+0x5b3c0 -> __mach_msg -> +0x2a) stayed non-reproducible on the
v0.9.22 image across a 35-minute / 1383-eval soak. 1153 driver
iterations (1038 sequential + 115 bursts of 3) landed 1383 emacsclient
evals against the supervised emacs over ssh -p 2266, all PASS, zero
FAIL. Supervised emacs PID stable at 30 across 63 thirty-second
side-polls, no mid-soak respawn, no CPU runaway. CPU time delta on the
emacs process: 0:49 to 2:25, about 96 CPU-seconds for 1383 evals,
~70 ms/eval.

What is not verified: anything past 35 minutes of wall-clock or past
this exercise pattern (server-socket pselect under emacsclient eval
with bursts of 3). The v0.9.18 image is still the historical
reproducer for the original chain and is not retested here.

## Image under test

Canonical Debian Hurd 0.9 with pid1 STATIC=1, GRUB serial patch, ssh
authorized_keys, and the minimal-to-SSH supervisor tree baked in by
iso-build/hurd-image-reroll.sh. The on-disk image was never modified;
the soak ran against a qcow2 overlay snapshot.

## What this slice ships

No code. One receipt that upgrades task #213's verdict from "5-min /
60-eval non-reproduction" to "35-min / 1383-eval non-reproduction" on
the v0.9.22 image.

## Build matrix

Linux dev host: no build in this slice.
Hurd VM: no build in this slice, soak ran against the pre-baked v0.9.22 image.

## Harness run

Driver was `/tmp/v0924-soak.sh` running sequential emacsclient evals
of `(length (buffer-list))` at ~0.6 s SSH RTT plus a 1 s host sleep,
with a parallel burst of 3 every ~9 iterations. SSH ControlMaster mux
kept connection cost flat across the full 35-minute window. Side-poll
`/tmp/v0924-pid-side-poll.sh` snapped `ps -A` for the supervised emacs
process every 30 s.

```
counts:
  PASS                  : 1383
  FAIL                  : 0
  mid-soak respawns     : 0
  PID drift             : 0   (initial=30, final=30, all 63 side-polls=30)
  driver iterations     : 1153   (1038 sequential + 115 bursts of 3)
  burst evals           : 345
  sequential evals      : 1038
  total evals           : 1383

crash-grep across full serial log:
  SIGSEGV               : 0
  Mach exception        : 0
  __mach_msg            : 0
  "pid1: emacs exited"  : 0
  kill_emacs            : 0
in-soak 60s periodic polls: 34, every poll crash_marker_lines=0

ps line, pre-soak:
  root  30  1  co  0:49.06  /usr/bin/emacs --no-site-lisp --no-site-file
                            --no-splash -l /usr/share/geos/emacs-init/core/panic.el ...

ps line, post-soak (pre-shutdown):
  root  30  1  co  2:25.63  /usr/bin/emacs --no-site-lisp --no-site-file
                            --no-splash -l /usr/share/geos/emacs-init/core/panic.el ...

same PID, same PPID 1, same argv. CPU delta ~96 s across 1383 evals.

timing:
  wall-clock            : 2100 s (target 2100 s)
  iter cadence          : ~0.55 iter/s   (target 1/s)
  eval cadence          : ~0.66 eval/s
  total evals           : 1383   (target ~2100)
  burst count           : 115    (target ~210)

cadence below target because each iter is SSH-mux RTT (~0.6 s) +
sleep-for 0.1 s + 1 s host sleep, so ~1.7-1.9 s/iter. throughput was
flat from minute 1 to minute 35, no degradation.

serial log: 648 lines total. lines 535-619 contain a second
`supervise: autostart` block with `pid1: /var mount failed entirely:
Input/output error` and fresh pids 3421-3424. that block is the
shutdown path, fired by the closing `shutdown -h now`: pid1 has no
/run/initctl, the supervised emacs exits, pid1's supervisor loop
tries to bring everything back up. the 63 side-polls confirm PID 30
was alive for the full 35-minute soak window, so this is not a
mid-soak respawn.

dmesg surface on canonical Debian Hurd 0.9:
  /var/log/dmesg        : absent
  /dev/kmsg             : absent
  /dev/klog             : present, raw
  /var/log/kern.log     : 0 bytes at soak end
  /var/log/syslog       : 4 lines, "-- MARK --" only
  /var/log/messages     : 4 lines, "-- MARK --" only
  /var/log/auth.log     : 7638 bytes, sshd PAM noise only, no denials
gnumach emitted no kernel trace during the soak.

VM clock note: guest reports 10:41 to 11:39, host reports 12:41 to
13:16. ~2 h skew that does not affect any soak finding.
```

## Open follow-ons (do NOT block this slice's commit)

1. Soak past 35 minutes or past this exercise pattern is not covered.
   The current verdict says "non-reproducible at this exercise level".
   If a future v1.x slice needs a stronger statement, the driver can
   run with no host sleep and with bursts of 10 against a multi-tenant
   sshd workload. Next-step hint: add a v1.x stress profile in
   iso-build/ that targets ~10000 evals over the same image.

2. The shutdown-path autostart block at serial lines 535-619 is
   cosmetic on a `shutdown -h now`, but the underlying `/var mount
   failed entirely: Input/output error` line is the v0.9.20 deferred
   /var-translator-detach item resurfacing on the shutdown side. Not
   a soak finding, recorded for the next /var slice. Next-step hint:
   fold a `pid1: shutting down` early-exit into the supervisor loop
   so the shutdown path does not re-run autostart.

## Files touched on the main branch

- docs/runlogs/2026-05-30-hurd-pselect-soak-35min.md (new file, +135 lines)

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
