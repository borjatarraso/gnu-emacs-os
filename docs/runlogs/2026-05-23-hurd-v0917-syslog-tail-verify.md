<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

## 2026-05-23: v0.9.17 syslog tail second-arm live-verify on Debian Hurd 0.9

this verifies the v0.9.17 ship that replaces the reverted v0.9.15 slice
A. v0.9.15 slice A tried to fix user-side `logger -p kern.info` not
appearing in *journal* by editing /etc/inetutils-syslog.conf and
SIGHUPing syslogd; the v0.9.16 cold-boot receipt at
docs/runlogs/2026-05-23-hurd-v0916-cold-boot-verify.md proved that
approach unfixable on two axes (wrong conf file on canonical, and
LOG_KERN -> LOG_USER demotion happens at source classification before
routing). v0.9.17 takes the alternate path: tail BOTH /var/log/kern.log
(the v0.9.6 arm) AND /var/log/syslog (the new arm), and retag the
second arm's emitted records' :source plist slot to `syslog-user` so
the renderer's source column visibly distinguishes user-origin from
kernel-origin entries. shipped at main/c671132 and hurd/ea1b6fa today;
no HURD_PORT.md row gained, this closes the v0.9.14 follow-on #1.

## Result

PASS on the load-bearing claim. the v0.9.17 syslog tail second arm
correctly catches user-process LOG_KERN messages that syslogd demotes
to LOG_USER on Debian GNU/Hurd 0.9. the user-shell-emitted token
`geos-v0917-1779552479` (and a follow-up `geos-v0917-user-1779552507`)
lands in /var/log/syslog (not kern.log), the supervised
`tail -F /var/log/syslog` picks it up, the new
`journal-tail--filter-syslog-user` retags `:source` to `syslog-user`,
and the *journal* renderer shows it under that source. the kern.log
arm from v0.9.6 still operates unchanged, proven by a forged BSD-format
line written directly to /var/log/kern.log that renders with
`:source = syslog`.

the methodology caveat is real and not softened. this snapshot's
/sbin/init is stock Debian sysv init (45 KiB Debian binary), not pid1.
the new arm was exercised via a self-contained `emacs --batch` probe
against the deployed /root/geos/emacs-init/services/journal-tail.el.
that is a valid functional test of registry membership, the
ensure-helper, the live tail process, the filter, and the render, but
it does not prove the file loads inside the SUPERVISED emacs on next
pid1 respawn. that second loop is the v0.9.17 follow-on against a
re-rolled canonical image with v0.9.12+ pid1 baked in.

## What this slice ships

this receipt does not ship code. the code shipped earlier today at
main/c671132 and hurd/ea1b6fa, two helpers plus one supervise-register
block in services/journal-tail.el, all kernel-gated by
`(geos-kernel-hurd-p)`. this file is the verification receipt for
that ship.

## Build matrix

Linux dev host: not exercised this session, no code shipped in this
slice. the v0.9.17 code ship was build-verified at commit time.

Hurd VM (preserved v0.9.16 snapshot via KVM, host port 2266): probe
via `ssh -p 2266 root@127.0.0.1` against the deployed journal-tail.el;
`emacs --batch -l probe.el` exit 0; supervisor registry contains both
`journal-kmsg` and `journal-syslog`; two `tail -F` PIDs alive
simultaneously without contention.

## Probe run

file sha1 chain across the scp, confirming the deployed file matches
main HEAD:

```
pre-deploy in-VM:  e2a0d769cd373458a3ff528b57170bd44a2cd965  (v0.9.16-era)
post-deploy in-VM: 955c540ec1b1e856100b05f7ad6a183fed2f79f5
host main HEAD:    955c540ec1b1e856100b05f7ad6a183fed2f79f5
```

supervisor registry under `GEOS_KERNEL=hurd` batch probe: both arms
present.

```
(geos-kernel-hurd-p) -> t
(supervise--registry) contains: journal-kmsg journal-syslog
```

ensure-helper probe. /var/log/syslog did not exist before the probe
load; after probe load, /var/log/syslog exists, parent /var/log/ exists,
mtime matches probe load time. this confirms
`journal-tail--ensure-syslog-hurd` ran.

live tail PIDs captured during the verify window:

```
pid 2165: tail -F --lines=+1 /var/log/kern.log    (v0.9.6 arm)
pid 2166: tail -F --lines=+1 /var/log/syslog      (new v0.9.17 arm)
```

empirical confirmation of the v0.9.17 thesis (this is the
load-bearing measurement). from a user shell:

```
logger -p kern.info "geos-v0917-1779552479"
```

/var/log/kern.log: empty after multiple repeats. /var/log/syslog: grew
by the line, /var/log/user.log mirrors it. this is exactly the
LOG_KERN -> LOG_USER demotion that v0.9.15 slice A tried and failed
to bypass via syslog.conf.

the token `geos-v0917-1779552479` appears in *journal* with `:source`
rendered as `syslog-user`. a follow-up token
`geos-v0917-user-1779552507` also renders with
`:source = syslog-user`. the new filter
`journal-tail--filter-syslog-user` correctly re-tagged via
`(plist-put rec :source 'syslog-user)`.

negative check, proves no accidental rewire of the kern.log arm. a
forged BSD-format line was written directly to /var/log/kern.log and
rendered with `:source = syslog`, not `syslog-user`. side-by-side
verbatim from the *journal* render:

```
17:08:27 syslog      info  kernel: geos-v0917-kern-1779552507
17:08:27 syslog-user info  root:   geos-v0917-user-1779552507
```

two arms, two distinct source labels, both rendered in the same
*journal* buffer in the same second.

## Methodology caveat

this snapshot's /sbin/init is stock Debian sysv init (45 KiB Debian
binary), NOT pid1. consequence: I could not exercise the v0.9.13
emacs-respawn-on-crash path. the verify ran the new file via a
self-contained `emacs --batch -l probe.el` against the deployed
/root/geos/emacs-init/services/journal-tail.el. that is a valid
functional test of the new arm (registry membership, ensure-helper,
tail process, filter, render). it does not prove the file loads inside
the SUPERVISED emacs on next pid1 respawn (because pid1 is not the init
on this snapshot). that second loop should be exercised on the
v0.9.17 task-tracked re-rolled canonical image with v0.9.12+ pid1
baked in.

the emacsclient AF_UNIX setsockopt gap carried forward from v0.9.15
slice D was not exercised in this verify because no running supervisor
was probed; the batch emacs probe end-to-end is self-contained. the gap
may matter again on the re-rolled image.

## Preserved artifacts

```
/tmp/geos_v0917_probe.el                          (probe script)
/tmp/geos_v0917_neg.el                            (negative-check script)
/tmp/v0917_probe.out                              (first probe run, syslogd stuck pre-SIGHUP)
/tmp/v0917_probe2.out                             (clean probe run with hits)
/tmp/v0917_neg.out                                (negative-check output, both sources)
/tmp/geos-hurd-vm-v0916-work-1779546177.qcow2     (VM snapshot preserved)
/tmp/geos-hurd-vm-v0916-cold-boot-serial.log     (serial transcript)
```

QEMU pid 1586142, KVM accel, host port 2266, key /tmp/hurd_vm_key.

## Open follow-ons (do NOT block this receipt's commit)

1. re-roll the canonical Debian Hurd 0.9 image with v0.9.12+ pid1
   baked in (already a v0.9.17 candidate per the v0.9.16 receipt) so
   future verify cycles can exercise the in-supervisor-respawn path
   end-to-end without a per-cycle init swap. next step: drive the
   re-roll on the v0.9.17 starter task and re-run this probe under
   the supervised emacs rather than batch.

2. the emacsclient AF_UNIX setsockopt gap on Hurd remains as recorded
   in v0.9.15 slice D; not exercised in this batch verify but will
   matter when verifying on the re-rolled image. next step: re-probe
   emacsclient against a live supervisor socket once item 1 lands.

## Files touched on the main branch

- docs/runlogs/2026-05-23-hurd-v0917-syslog-tail-verify.md (+this file)

the next time anything in journal-tail.el's syslog path on Hurd
changes, 2026-05-23 is the bisect waypoint that says the syslog-user
filter ran clean here.
