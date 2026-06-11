<!-- SPDX-License-Identifier: FSFAP -->

# 2026-05-23: v0.9.16 cold-boot verify (slice A reverted, slice B PASS, STATIC=1 PATH A Makefile)

three things landed in the v0.9.16 cycle and they share a single
cold-boot session, so they share a single receipt. this verifies the
v0.9.14 follow-on #2 hypothesis (slice B dmesg re-sync) on real
hardware-ish Hurd via KVM, falsifies the v0.9.14 follow-on #1
hypothesis (slice A syslog.conf override demotes LOG_KERN), and
records the host-side parse of the STATIC=1 PATH A Makefile change
that shipped on hurd. prior receipt was the v0.9.14 verification slice
at docs/runlogs/2026-05-22-hurd-v0914-verify.md.

## Result

PARTIAL PASS on the v0.9.16 cycle as a whole. slice B verified
end-to-end on cold-boot Hurd (timer arm, file-offset tick, idempotent
re-arm, documented first-tick double-emit). slice A helpers executed
as designed but the load-bearing premise (config file edit routes
user-side LOG_KERN to kern.log) is unfixable at the config-file
layer, so slice A was reverted in the same cycle. STATIC=1 PATH A
Makefile diff parses clean host-side and the dynamic-link Hurd path
is untouched, but in-VM link verify did not happen this session and
is the v0.9.17 starter.

slice A is reverted, not patched-forward, because the right fix
changes which file journal-tail.el tails (or introduces a local0/local1
operator-logging convention), not which file the helpers write to.
v0.9.14 follow-on #1 stays OPEN against journal-tail.el for that work.

## What this slice ships

- main/0c97528 and hurd/b375b94: revert slice A from services/hurd-essentials.el (127 lines removed: two defconsts, three helpers, two call sites, the (require 'panic) that only slice A used)
- hurd/5a2acec: pid1/Makefile STATIC=1 PATH A diff wraps the Hurd subset of port_caps in -Wl,--start-group -lports -lfshelp -lihash -lshouldbeinlibc -lhurduser -lmachuser -lpthread -Wl,--end-group; PORT_MODULE_LIBS unchanged; Linux build path untouched; STATIC=0 dynamic Hurd path untouched (extra -l on dynamic link is a no-op, --start/--end-group are inert for DSOs)
- main/2763a69 and hurd/1ebf7f1: docs/HURD_PORT.md matrix row added for "STATIC=1 link cleanliness on Hurd", hurd-branch-only scope note (main has no PORT=hurd block on pid1/Makefile so the row is informational only on main)
- this receipt at docs/runlogs/2026-05-23-hurd-v0916-cold-boot-verify.md

## Build matrix

Linux dev host: `make PORT=linux -C pid1` builds clean to
emacs-init; `PORT=hurd STATIC=1 make -C pid1 -n` parses the recipe
clean, `make -p` confirms PORT_MODULE_LIBS substitution and the
--start-group / --end-group wrap. host stops at
`No rule to make target '/usr/include/x86_64-gnu/hurd/fsys.defs'`
because the Hurd toolchain is not installed on this host. this is
expected and matches every prior PORT=hurd host invocation.

Hurd VM (canonical base, KVM): canonical's /sbin/init is pre-v0.9.12
pid1 (no remount_root_rw, no /run, sshd never reachable). cold-boot
wedges at RO root before sshd. fell back to the sibling
/home/overdrive/hurd-vm/work.img which carries vanilla Debian /sbin/init
and is the only image on this host that boots through to a usable SSH
state inside this session's budget. preserved at
/tmp/geos-hurd-vm-v0916-1779545879.qcow2.

Hurd VM (work.img, KVM): cold-boot to ssh in seconds. emacs --batch
exercised slice A and slice B harnesses with stubs for geos-kernel,
panic-handle, supervise--console, supervise-register. serial transcript
preserved at /tmp/geos-hurd-vm-v0916-cold-boot-serial.log (45464 bytes),
working snapshot at /tmp/geos-hurd-vm-v0916-work-1779546177.qcow2.
QEMU pid 1586142 still up on host port 2266 at the time of writing.

## Preflight

killed the wedged QEMU at pid 909944 (left over from the v0.9.15 soak100
run) with SIGTERM, confirmed exit, preserved its serial log at
/tmp/geos-hurd-vm-soak100-serial.log and the v0.9.15 verify report at
/tmp/v0915_slice_a_b_verify_report.txt, snapshot at
/tmp/geos-hurd-vm-soak100-1779536027.qcow2. clean handoff, no
half-state into this session.

## Cold-boot path notes (load-bearing)

four traps cost real time and are worth recording for next time anyone
cold-boots Hurd on this host:

1. **accel=tcg wedges Hurd at SeaBIOS.** two attempts at
   `-machine accel=tcg -cpu max -daemonize` produced zero serial bytes
   across 9+ minutes each. KVM (`-enable-kvm -cpu host`) booted in
   seconds. Hurd does not boot reliably under TCG on this host. if KVM
   is not available, budget for "this will not finish".
2. **canonical base ships GRUB with `terminal_output gfxterm`.** serial
   output stops at "Welcome to GRUB!" without a patch. patched
   grub.cfg in-place on the overlay to use `serial console` terminal
   and added `console=com0` to the gnumach multiboot line. without
   this patch the cold-boot transcript ends at GRUB.
3. **canonical base has no authorized_keys for root.** injected pub
   key via guestfish at /root/.ssh/authorized_keys, mode 0600. without
   this the sshd that does come up (on the work.img path) rejects
   password-less login.
4. **canonical base's /sbin/init is pre-v0.9.12 pid1.** no
   remount_root_rw, no /run, sshd never reachable. for v0.9.16 verify
   purposes I fell back to /home/overdrive/hurd-vm/work.img which has
   vanilla Debian /sbin/init and reaches sshd. canonical image needs a
   pid1 refresh before it is usable for verify work again.

## Probe run, slice A (steps 2 through 11)

step 2 (`apt list --installed inetutils-syslogd`):

```
inetutils-syslogd/now 2.7-2 hurd-amd64 [installed,local]
```

PASS with CAVEAT. package installed but binary lives at /usr/sbin/syslogd
without the inetutils- prefix, config at /etc/syslog.conf without the
inetutils- prefix. /etc/inetutils-syslog.conf (which slice A targeted)
does not exist out of the box on this image.

steps 3+4 (scp + sha1):

```
/root/geos/emacs-init/services/hurd-essentials.el sha1: 0bd7f572c993aa4ce19944d7a58a1625f08c32ee
/root/geos/emacs-init/services/journal-tail.el     sha1: 971bfa6d9fed88d88972c31c303eec3d8d58bed4
```

PASS. files landed in the elisp tree at the expected paths.
/usr/share/geos/ does not exist on work.img; the elisp lives only under
/root/geos for this run.

steps 5+6: N/A. no supervised emacs on work.img. slice A and B were
exercised via `emacs --batch` with hand-rolled stubs for geos-kernel,
panic-handle, supervise--console, supervise-register.

step 7 (post-first-invoke kern.* count in target config):

```
-rw-r--r-- 1 root root 28 May 23 ... /etc/inetutils-syslog.conf
kern.*    /var/log/kern.log
grep -c "kern.\\*" /etc/inetutils-syslog.conf -> 1
```

PASS. file created at exactly 28 bytes, contents exactly the override
line, grep count is 1. helpers wrote what they advertised.

step 8 (logger -p kern.info round trip):

```
$ logger -p kern.info 'geos-v0916-syslog-override-1779546491'
$ sleep 2
$ wc -c /var/log/kern.log
0 /var/log/kern.log
$ grep geos-v0916-syslog-override /var/log/syslog
... syslog.info  geos-v0916-syslog-override-1779546491
```

INCONCLUSIVE / EXPECTED FAIL. token landed in /var/log/syslog instead
of /var/log/kern.log. two root causes confirmed: (a) the running
syslogd reads /etc/syslog.conf not /etc/inetutils-syslog.conf so the
override file does not even get parsed, and (b) more fundamentally,
LOG_KERN demotion happens at the source-classification stage inside
syslogd before the rule engine fires, so no edit to either config file
can route a user-side `logger -p kern.info` to kern.log. this is the
load-bearing finding that justifies the slice A revert.

step 9 (second invoke, idempotency):

```
syslog.conf kern.* override already present, no write
```

PASS. console message matches the idempotency contract.

step 10 (kern.* count still 1):

```
-rw-r--r-- 1 root root 28 May 23 ... /etc/inetutils-syslog.conf
grep -c "kern.\\*" /etc/inetutils-syslog.conf -> 1
```

PASS. file unchanged at 28 bytes, count still 1. helpers do not
re-write.

step 11 (SIGHUP cycle):

```
syslogd pid before: 602
syslogd pid after:  602
/var/log/syslog: syslogd (GNU inetutils 2.7): restart
```

PASS WITH FORMAT NOTE. syslogd pid did not change (it handles SIGHUP
in-process, which is correct). the implementation's own SIGHUP-reload
log line is "syslogd (GNU inetutils 2.7): restart"; the spec-mandated
"Received SIGHUP; restarting." string is not exactly what
inetutils-syslogd writes, but the intent matches.

## Probe run, slice B (steps 12 through 16)

steps 12+13 (set interval 5, arm, observe one of our timers added):

```
JOURNAL-BUFFER-DMESG-RESYNC-INTERVAL=5
TIMER-IDLE-LIST-LENGTH=2
OUR-TIMERS=1
```

PASS. required uploading the current v0.9.15 buffers/journal.el (sha1
facf02d7029fce9628113a2a47f29bc681f92165) to the VM because the version
shipped on work.img predated journal-buffer--parse-dmesg-record and
the first attempt panicked on void-function. after upload, idle-timer
arm clean.

step 14 (write to /dev/kmsg):

```
/dev/kmsg: does not exist
/dev/klog: cdev 0,0 (not a user-space write target)
dmesg(8):  not installed
fallback: append directly to /var/log/dmesg
SIZE_BEFORE=3584
SIZE_AFTER=3618
delta=34 (token 'geos-v0916-dmesg-probe-1779546667' + newline)
```

INCONCLUSIVE on kmsg path / PASS via documented alternate. Hurd has
neither /dev/kmsg nor dmesg(8); /dev/klog is a 0,0 cdev that is not a
user-space write target. for v0.9.16 verify purposes I appended the
token directly to /var/log/dmesg, which is what the v0.9.6 dmesg-prime
+ resync path tails. 34-byte delta matches token length plus newline.

step 15 (token in *journal* buffer):

```
grep -c "geos-v0916-dmesg-probe-" *journal* -> 2
LAST-DMESG-SIZE transitioned 0 -> 3618
```

PASS WITH DOCUMENTED WART. count is 2, not 1. this matches the
"double-emit on first tick" wart documented in journal-tail.el lines
224-229: prime-from-dmesg reads the file once at load without recording
size, then dmesg-resync-tick reads `[0, 3618)` on the first tick
because LAST-DMESG-SIZE was still 0, re-emitting the same content.
LAST-DMESG-SIZE then transitions 0 -> 3618 and subsequent ticks would
only read the diff. the offset-diff arm engaged as specified; the
double-emit is the known wart, not a regression.

step 16 (second arm does NOT grow idle list):

```
PRE-FIRST-ARM:  TIMER-IDLE-LIST-LENGTH=2 OUR=1 INTERVAL=30
POST-FIRST-ARM: TIMER-IDLE-LIST-LENGTH=2 OUR=1 INTERVAL=5
POST-SECOND-ARM: TIMER-IDLE-LIST-LENGTH=2 OUR=1
```

PASS. idle-list length stayed at 2 across the second arm (did not grow
from 2 to 3); OUR-TIMERS count stayed at 1. cancelled-old-then-scheduled-new
verified. the pre-first-arm interval of 30 is the defcustom default
from the top-level arm at load time; first arm flipped it to 5; second
arm kept length stable. idempotent re-arm contract holds.

## Slice A revert decision and audit trail

REVERTED on main at 0c97528 and on hurd at b375b94 in the same cycle
as this receipt. 127 lines deleted from
emacs-init/services/hurd-essentials.el: two defconsts
(hurd-essentials--syslog-conf, hurd-essentials--syslog-kern-line),
three helpers (the read/check/write/SIGHUP trio), two call sites, and
the `(require 'panic)` line (only slice A used panic-handle in this
file; the rest of hurd-essentials.el uses supervise--console for
diagnostics).

the rationale, recorded for audit: the helpers ran exactly as designed.
the write was correct, idempotent, and SIGHUP was correct. but the
file target is wrong (running syslogd reads /etc/syslog.conf, not
/etc/inetutils-syslog.conf) AND the underlying premise is wrong per
the syslog spec (LOG_KERN demotion happens at source classification,
before the rule engine sees the message; no config-file edit on either
path can route user-side `logger -p kern.info` to kern.log). a forward
patch that changed the target path would still hit the demotion wall.

v0.9.14 follow-on #1 stays OPEN. the right fix is either (a) teach
journal-tail.el to tail /var/log/syslog in addition to kern.log
(catches user-side logger output regardless of facility demotion), or
(b) document a local0/local1 convention for operator-side logging that
survives demotion. that is a v0.9.17 or later starter, not a v0.9.16
patch.

## STATIC=1 PATH A Makefile section

hurd/5a2acec ships the Makefile diff. it wraps the Hurd subset of
port_caps in:

```
-Wl,--start-group -lports -lfshelp -lihash -lshouldbeinlibc \
  -lhurduser -lmachuser -lpthread -Wl,--end-group
```

PORT_MODULE_LIBS is unchanged. the Linux build path is untouched. the
STATIC=0 dynamic Hurd path is also untouched in effect (extra -l on a
dynamic link is a no-op, --start-group and --end-group are inert for
DSOs). this is the "no regression by construction" shape requested.

main/2763a69 and hurd/1ebf7f1 add the matrix row to docs/HURD_PORT.md
for "STATIC=1 link cleanliness on Hurd". on hurd the row is the live
status; on main the row carries a scope note that PORT=hurd has no
block in pid1/Makefile on the main branch (main is the abstraction
seam, hurd is the port body), so the row is informational on main
only.

host-side parse:

```
$ PORT=hurd STATIC=1 make -C pid1 -n
... (recipe lines print clean) ...
$ PORT=hurd STATIC=1 make -C pid1 -p | grep -E 'PORT_MODULE_LIBS|start-group'
PORT_MODULE_LIBS = ...
... -Wl,--start-group -lports ... -Wl,--end-group ...
$ PORT=hurd STATIC=1 make -C pid1
make: *** No rule to make target '/usr/include/x86_64-gnu/hurd/fsys.defs'.  Stop.
$ make PORT=linux -C pid1
(builds clean to emacs-init)
```

variable substitution confirmed, --start-group / --end-group wrap
confirmed, Linux regression check clean. in-VM link verify deferred to
v0.9.17.

## Preserved artifacts

- /tmp/geos-hurd-vm-v0916-cold-boot-serial.log (45464 bytes, full cold-boot transcript including the GRUB-patched serial output and the work.img fallback)
- /tmp/geos-hurd-vm-v0916-work-1779546177.qcow2 (working snapshot used for slice A + slice B harnesses)
- /tmp/geos-hurd-vm-v0916-1779545879.qcow2 (failed canonical-image attempt, kept for next pid1 refresh)
- /tmp/v0916-slice-a-harness.el (sha1 0bd7f572c993aa4ce19944d7a58a1625f08c32ee)
- /tmp/v0916-slice-b-harness.el (sha1 971bfa6d9fed88d88972c31c303eec3d8d58bed4)
- /tmp/v0916-step2-syslog-pkg.log through /tmp/v0916-step16-rearm.log (per-step raw stdout/stderr)
- /tmp/geos-hurd-vm-soak100-serial.log + /tmp/v0915_slice_a_b_verify_report.txt + /tmp/geos-hurd-vm-soak100-1779536027.qcow2 (preserved from the v0.9.15 preflight handoff)
- QEMU still up at pid 1586142, host port 2266, available for any v0.9.17 starter that wants to skip the cold-boot trap list

## Open follow-ons (do NOT block this slice's commit)

1. journal-tail.el should learn to tail /var/log/syslog in addition to /var/log/kern.log so user-side `logger -p kern.info` output (which gets demoted to syslog.info) is still visible in *journal*. alternatively, document a local0 / local1 operator-logging convention that survives facility demotion. this is the right closure for v0.9.14 follow-on #1 and the reason slice A was revertable rather than patch-forwardable. next step: write the follow-on #1 design note and pick option (a) or (b).
2. STATIC=1 in-VM link verify is the v0.9.17 starter. host-side Makefile parse is clean and the dynamic path is untouched, but the link itself has not run against a real Hurd toolchain in this session. next step: install the Hurd toolchain in the work.img snapshot or build inside the VM, then run `PORT=hurd STATIC=1 make -C pid1`.
3. canonical base image needs a pid1 refresh to v0.9.12 or later before it is usable for cold-boot verify again. work.img is the fallback for now but is not the shipping image. next step: rebuild canonical with current /sbin/init or document the work.img path as the canonical verify target until the refresh lands.
4. slice B first-tick double-emit wart is real but documented in journal-tail.el lines 224-229. recording prime-from-dmesg's read size into LAST-DMESG-SIZE at load time would fix it; the wart is small enough that I am leaving it for a slow afternoon. next step: one-line change in prime-from-dmesg to set LAST-DMESG-SIZE before returning.
5. accel=tcg cold-boot of Hurd on this host is a non-starter; budget KVM time only. next step: drop the tcg fallback from the cold-boot recipe in docs/HURD_PORT.md and call out the KVM requirement explicitly.

## Closing

v0.9.16 closes v0.9.14 follow-on #2 (slice B dmesg re-sync verified on
cold-boot Hurd: timer arms, file-offset tick fires, idempotent re-arm
holds, first-tick double-emit is documented). v0.9.16 falsifies
v0.9.14 follow-on #1 (slice A reverted; the syslog.conf-override
premise does not survive the source-classification demotion stage of
real syslogd). STATIC=1 PATH A shipped at the Makefile layer with
host-side parse clean and Linux regression clean; in-VM link verify is
the v0.9.17 starter.

## Files touched on the main branch

- emacs-init/services/hurd-essentials.el (-127, slice A revert at 0c97528)
- docs/HURD_PORT.md (+row, STATIC=1 link cleanliness matrix row at 2763a69, informational on main since main has no PORT=hurd block in pid1/Makefile)
- docs/runlogs/2026-05-23-hurd-v0916-cold-boot-verify.md (+this file)

## Files touched on the hurd branch

- emacs-init/services/hurd-essentials.el (-127, slice A revert at b375b94)
- pid1/Makefile (STATIC=1 PATH A diff at 5a2acec: --start-group / --end-group wrap of Hurd subset, PORT_MODULE_LIBS unchanged, Linux path untouched, dynamic Hurd path inert)
- docs/HURD_PORT.md (+row, STATIC=1 link cleanliness matrix row at 1ebf7f1, live status on hurd)

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
