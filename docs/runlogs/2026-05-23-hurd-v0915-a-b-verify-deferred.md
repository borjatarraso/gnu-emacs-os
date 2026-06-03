<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

# 2026-05-23: hurd v0.9.15 slices A and B live-verify, DEFERRED

slice A (`hurd-essentials.el` syslog kern.* override at hurd/9a39f49 and
main/1c0e715) and slice B (`journal-tail.el` periodic dmesg re-sync at
hurd/e8028da and main/4d619f0) were attempted on the preserved snapshot
that slice D's 100-cycle respawn soak ran against
(`/tmp/geos-hurd-vm-soak100-1779536027.qcow2`, qcow2 overlay on
`/tmp/geos-hurd-vm-v0913-reverify-1779459141.qcow2`).  the snapshot was
not viable for the probes I wanted to run, so I am deferring both live
verifies to a v0.9.16 cold-boot cycle and recording what I learned here
so the next session does not lose context.

## Result

DEFERRED.  files scp'd into the running VM with sha1 matching host; the
supervised emacs respawned once against the new code, fired the
"file loaded" and "gate passed" and "registered" breadcrumbs in serial,
then the supervisor wedged before reaching the v0.9.12 settrans pfinet
block.  SSH became unreachable to host probes within 30 s of the new
file landing and never recovered after a 9 minute wait.  none of the
four explicit verify steps for slice A (write-then-read pre/post,
idempotency, `logger -p kern.info` round trip) or the four for slice B
(arm, tick, append, re-arm idempotency) ran.

forensic evidence sits in the preserved serial log and the agent's
report at `/tmp/v0915_slice_a_b_verify_report.txt`.  the wedge is
lexically between the "registered" breadcrumb at line 264 of
`hurd-essentials.el` and the settrans breadcrumb at line 329.  the
slice A helpers are at lines 256 and 257, BEFORE the "registered"
breadcrumb, so the helpers ran to completion.  the wedge sits in the
pre-existing v0.9.12 settrans pfinet block, not in the slice A code.

## Snapshot-specific finding worth recording

the soak snapshot has accreted state away from canonical Debian
GNU/Hurd 0.9.  `dpkg-query` reports NO `inetutils-syslogd` package
installed; the running syslogd is `/usr/sbin/syslogd` from a different
provider and it reads `/etc/syslog.conf`, NOT
`/etc/inetutils-syslog.conf`.  on this snapshot the existing
`/etc/syslog.conf` already routes `kern.* -/var/log/kern.log`, so the
override slice A wants to ship is both unnecessary AND targets the
wrong file.

slice A is still correct for the canonical install path: v0.9.14 slice
2 (`docs/runlogs/2026-05-22-v0914-live-kmsg-probe.md`) verified on a
fresh canonical image that `inetutils-syslogd` was the installed
package and that the user-side LOG_KERN demotion to LOG_USER was real.
the override file slice A writes is exactly the per-spec workaround
for that demotion.  the snapshot drift here is local to this overlay
chain, not a slice A defect.

a v0.9.16 followup should:

  1. cold-boot a fresh `debian-hurd-amd64-20260314.img`,
     `apt install inetutils-syslogd` to match canonical,
  2. lay down slice A by booting GEOS,
  3. confirm `/etc/inetutils-syslog.conf` carries the override line
     exactly once after first boot,
  4. send a `logger -p kern.info "geos-v0916-syslog-override-<ts>"`
     and confirm it lands in `/var/log/kern.log`,
  5. on second boot, confirm idempotency (line still present exactly
     once, no duplicates).

slice B is simpler to live-verify and does not depend on syslogd at
all.  same v0.9.16 cycle should:

  1. set `journal-tail-dmesg-resync-interval` to 5 in a test
     `user-init.el`,
  2. boot, wait 10 s, sample `*journal*` buffer for dmesg content,
  3. write a unique token to `/dev/kmsg`, wait 10 s, sample again,
  4. confirm the token appears in `*journal*` exactly once,
  5. call `(journal-tail--arm-dmesg-resync)` a second time, confirm
     no duplicate timers via `(length timer-idle-list)`.

## Why I stopped the probe

the wedge fingerprint matches v0.9.12 slice 11's known pfinet
attachment ordering: settrans `-fgap /servers/socket/2 /hurd/pfinet`
yanks the live pfinet translator out from under any caller currently
holding a port through `/servers/socket/2`.  the SSH session carrying
the probe goes through that exact path.  the supervised emacs ran 100
respawns before the new files landed; the 101st respawn (the one the
agent's scp triggered) collided the new file load against the SSH
probe attempting to call into the helpers, and pfinet went down with
both legs.

this is not a slice A regression.  it is the same pre-existing fragility
that v0.9.12's settrans pivot accepted as the cost of having a live
network at boot without an rc.d chain.  the right verify cycle for
slices that touch top-level forms in `hurd-essentials.el` is cold-boot
only: load the file at boot time before SSH is up, then SSH in and
inspect side effects.  attempting a load-into-running-image probe was
the design error.

## What is preserved

  - `/tmp/geos-hurd-vm-soak100-1779536027.qcow2` (qcow2 overlay,
    wedged but on-disk intact)
  - `/tmp/geos-hurd-vm-v0913-reverify-1779459141.qcow2` (base, not
    touched)
  - `/tmp/geos-hurd-vm-soak100-serial.log` (94.85 MB serial transcript
    carrying the forensic breadcrumb chain)
  - `/tmp/v0915_slice_a_b_verify_report.txt` (verify agent's full
    report)
  - QEMU pid 909944 left alive per the soak slice's preservation
    contract; the next cycle can either harvest forensics first then
    kill it, or just kill it and cold-boot from the base.

## Task carry-forward

filed as a v0.9.16 task (TBD id) when the next session opens: cold-boot
verify of slices A and B per the recipes above.  this runlog plus the
agent's `/tmp/v0915_slice_a_b_verify_report.txt` are the entry points.
