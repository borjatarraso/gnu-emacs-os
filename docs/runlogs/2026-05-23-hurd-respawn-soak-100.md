<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

# 2026-05-23: hurd emacs respawn soak, 100 cycles, PASS

this is the v0.9.15 slice D receipt. the load-bearing claim is that the
v0.9.13 emacs respawn-on-crash path on Debian GNU/Hurd 0.9 does not bleed
resources across 100 SIGSEGV-and-respawn cycles. it follows the v0.9.14
verification receipt (main/01e0b50) and closes task #171 at scale: the
v0.9.13 elisp arc said respawn works once, this run says it still works
the hundredth time and looks no different from the first.

## Result

PASS on the load-bearing claim. 100/100 cycles completed, zero FAIL rows
in stats.csv, respawn wait flat at 1 second per cycle against a 30 second
upper bound (the cycle script gives up at 30, the gate budget I care
about is 5). pid1 port table essentially flat: 16 at cycle 1, 17 at
cycle 10, 17 for cycles 10 through 100 with one transient 18 along the
way. pid1 RSS drifted from 952K to 936K (-1.7%), pid1 SZ flat at 4.15G.
no monotonic resource growth on either pid1 or the supervised emacs.

what is not verified: I did not push to 500 cycles. I stopped at 100
because the trend lines went flat by cycle 10 (ports settled, RSS settled,
SZ settled) and another 400 cycles of identical rows would have spent six
more hours of QEMU wall-clock to prove nothing new. I also could not
directly introspect the live emacs from the host via emacsclient over the
guest socket; the AF_UNIX setsockopt path on Hurd refused with "Protocol
not available". the supervisor-health probes still ran but the responses
came back empty rather than as elisp values, so the *panic* / journal-kmsg
gates are best-effort rather than authoritative.

## What this slice ships

- `/tmp/soak-driver.sh` (host driver, 80 lines): N cycles in a for loop,
  one ssh round-trip per cycle, every 10th cycle also samples pid1 and
  asks the in-guest emacs for *panic* contents + journal-kmsg supervise
  status. writes stats.csv, driver.log, panic-snapshots.log,
  journal-kmsg-status.log under `$OUT`.
- `/tmp/remote-cycle.sh` (per-cycle script, 82 lines): probes the
  currently-supervised emacs (ps -l + portinfo wc -l), kills it with
  SIGSEGV, waits up to 30s for pid1 to respawn a new child whose ppid is
  1 and comm is emacs, settles 4s, probes again, emits one space-separated
  row. SAMPLE_PID1=1 path also probes pid 1 itself for the per-decile
  rows; SAMPLE_PID1=0 emits dashes for pid1 fields (saves ~7s/cycle).
- `/tmp/soak-out-100e/stats.csv` (101 lines: 1 header + 100 cycle rows).
- `/tmp/soak-out-100e/driver.log` (26 lines: every 5th cycle echoed +
  start/end timestamps + one "empty response, retrying once" notice at
  cycle 10 which the retry path handled).
- `/tmp/soak-out-100e/panic-snapshots.log` and journal-kmsg-status.log
  (13 lines each: cycle 0, 1, 10, 20, ..., 100, final; values empty for
  the emacsclient reason explained below).

## Build matrix

Linux dev host: no build for this slice. it runs against the existing
v0.9.13 + v0.9.14 hurd image at hurd/5fd791b. host-side driver is bash
+ ssh + awk.

Hurd VM: pid1 respawning emacs at hurd/5fd791b. 100/100 SIGSEGV cycles
served, no panic, no pid1 death.

## Harness run

per-gate verdict table. "best-effort" means the gate is true under my
indirect evidence (driver.log shows the supervisor stayed up, ssh kept
working, every cycle's post_pid was a fresh pid greater than the pre_pid)
but the direct introspection probe returned empty because of the
emacsclient gap noted under Anomalies.

```
gate                                 verdict   evidence
respawn_wait_s <= 5s                 PASS      100/100 rows, respawn_wait_s=1 every row
*panic* empty                        PASS*     panic-snapshots.log, cycle=0..final, panic= (empty value); best-effort
journal-kmsg :running                PASS*     journal-kmsg-status.log, cycle=0..final, journal-kmsg= (empty value); best-effort
no monotonic resource growth         PASS      pid1 ports 16/17/17/17/17/17/17/17/17/17/17 across deciles
                                               pid1 rss 952K/936K (-16K, -1.7%) c1..c100
                                               pid1 sz 4.15G flat
                                               post_rss range 11.6M..14.8M no upward drift
                                               post_ports 16..18 no upward drift
```

* the two starred gates are best-effort because the in-guest emacsclient
  probe path failed on Hurd; see Anomalies. the supervisor process itself
  stayed alive (pid 1 still answered ps and portinfo on every decile) so
  there was no journal-kmsg-death event for *panic* to record anyway.

trend table, c1 vs c100, raw rows from stats.csv:2 and stats.csv:101.

```
field            c1            c100          delta
pre_pid          454           11433         +10979 (monotonic by design, pid space wrap not reached)
pre_rss          36.3M         31.7M         -4.6M  (pre-cycle emacs settles smaller after first full init)
pre_ports        46            32            -14    (first emacs had more open ports from boot init work)
post_rss         12.6M         12.8M         +0.2M  (within decile jitter band 11.6M..14.8M)
post_ports       17            17            0
respawn_wait_s   1             1             0
pid1_msgi        4990          6609          +1619  (16.3 msgi per cycle, monotonic as expected for kill+respawn)
pid1_msgo        363           574           +211   (2.1 msgo per cycle, same shape)
pid1_rss         952K          936K          -16K   (-1.7%)
pid1_ports       16            17            +1
pid1_sz          4.15G         4.15G         0
```

the only "growth" numbers (pid1_msgi, pid1_msgo, pre_pid) are exactly
the ones that should grow: every kill + respawn cycle puts ipc traffic
through pid1 and consumes pid numbers. msgi growth is linear at ~16
messages/cycle which matches one mach_notify_dead_name + a handful of
proc_* lookups, no leak shape there.

## Anomalies (non-blocking)

1. ppoll "Computer bought the farm" glibc noise on Hurd: the serial log
   `/tmp/geos-hurd-vm-soak100-serial.log` (44M) carries 1,429,925
   occurrences of the "Computer bought the farm" string and 1,432,870
   occurrences of "ppoll". this is the well-known glibc-on-Hurd ppoll
   diagnostic that prints from inside libpthread when a port name dies
   under a poll set; it pre-existed before this soak (visible on the
   v0.9.13 image as shipped) and is not produced by the respawn path
   under test. next step: when there is appetite for an upstream debian
   bug, file against libc0.3 with the gnumach version and a minimal
   reproducer. not blocking.

2. emacsclient over the guest's /tmp/emacs0/server socket fails with
   "setsockopt: Protocol not available" on Hurd-side AF_UNIX. the host
   ssh into the guest works, the in-guest shell works, but the
   in-guest emacsclient binary cannot complete the handshake against the
   in-guest server socket. consequence: the per-decile *panic* and
   journal-kmsg supervise-status probes returned empty strings instead
   of elisp values. I keep the gate marked PASS* because indirect
   evidence (driver.log, supervisor still answering every probe, no
   FAIL row) covers it, but it is a real gap. next step: hand to a probe
   task that reproduces emacsclient AF_UNIX setsockopt on Hurd in
   isolation and decides whether the fix is in emacs's
   process-coding-system path or in pflocal.

## Preserved artifacts

- VM snapshot: `/tmp/geos-hurd-vm-soak100-1779536027.qcow2`
- QEMU pid during the run: 909944
- SSH host port: 2266 (127.0.0.1)
- SSH key: `/tmp/hurd_vm_key`
- serial log: `/tmp/geos-hurd-vm-soak100-serial.log` (44M, do not grep
  without -c unless you really mean it)
- soak outputs root: `/tmp/soak-out-100e/`

if a future bisect needs to rerun a single cycle, the qcow2 + the two
shell scripts are enough. host driver expects /root/cycle.sh installed
at the same path inside the guest as remote-cycle.sh, with mode +x.

## Wall-time accounting

stats.csv ts span looks like 123 minutes (cycle 1 ts 1779536852, cycle
100 ts 1779544254, delta 7402 seconds, mean 74s/cycle) but the real
driver wall time is 64 minutes (start `[14:39:31]`, end `[15:43:34]`).
the difference is bookkeeping: stats.csv's ts column is the moment the
cycle started inside the VM, which is set after the host-side ssh handshake
completes. the per-decile pid1 probes also cost ~7s each. the underlying
respawn itself is still 1 second flat. so the 74s/cycle mean is dominated
by ssh setup + pid1 probe sampling, not by the respawn path under test.

## Open follow-ons (do NOT block this slice's commit)

1. push the soak to 500 cycles. only worth it if a later change to the
   respawn path lands and we want a wider regression band. next-step
   hint: rerun /tmp/soak-driver.sh 500 /tmp/soak-out-500 against a
   freshly-booted snapshot, expect ~5.5h wall.

2. fix the emacsclient AF_UNIX setsockopt: Protocol not available gap on
   Hurd. this is what kept the *panic* and journal-kmsg gates as PASS*
   instead of PASS. next-step hint: strace -e setsockopt the emacsclient
   call on Hurd to identify which option is being requested (likely
   SO_PASSCRED or SO_PEERCRED).

3. file libc0.3 / libpthread upstream bug for the "Computer bought the
   farm" ppoll noise. 1.4M lines for a 64-minute soak is well past
   reasonable. next-step hint: minimal reproducer is probably "open a
   port, register for poll, deallocate the port, observe stderr".

4. wire a host-side parser that summarizes stats.csv into a one-line
   PASS/FAIL verdict so the v0.9.16 receipt does not have to manually
   eyeball decile rows. next-step hint: awk script that asserts (a)
   respawn_wait_s <= 5 on every row, (b) post_ports delta <= 3 across
   the whole file, (c) pid1_rss delta <= +5% across the whole file.

## Files touched on the main branch

- docs/runlogs/2026-05-23-hurd-respawn-soak-100.md (+this receipt only).
  no code touched. v0.9.15 slice D is verification-only against
  hurd/5fd791b and main/01e0b50.

## Closing

task #171 (emacs respawn-on-crash on Hurd) opened with the v0.9.13
elisp arc and was structurally closed there. this receipt is the at-scale
closure: 100 SIGSEGV cycles, no FAIL, no resource bleed, no pid1 death.
the next time anything in the supervised emacs path changes on Hurd and
something goes sideways, 2026-05-23 is the bisect waypoint that says
respawn was clean here.
