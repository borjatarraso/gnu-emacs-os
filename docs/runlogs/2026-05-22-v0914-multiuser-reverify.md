<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

# 2026-05-22: v0.9.14 slice 1 multi-user peer-cred re-verify on Debian Hurd 0.9

Follow-on to `docs/runlogs/2026-05-18-hurd-end-to-end-vm.md` (the v0.8
design-2.2 slice 5 PASS at hurd `aec165f`). Since that receipt twelve
plus slices have shipped touching `pid1/`, `port_hurd.c`,
`supervise.el`, `hurd-essentials.el`, `journal-tail.el`, and
`early-init.el` (v0.9.5 through v0.9.13). This slice 1 re-verify
confirms the load-bearing claim that the multi-user peer-cred surface
still functions against the current stack. No code shipped with this
receipt.

## Result

**PASS.** All nine reference markers from the v0.8 slice-5 harness
fire on the v0.9.13 stack. The harness exits 0 in 2.15s wall, well
under the 8-second budget and far under the harness's own 30-second
internal deadline. `pid1` `PORT=hurd STATIC=0` rebuilds clean in the
guest with `mig` regenerating `fsysServer.c` and `fsys_S.h` and all
three `.boot.o` objects relinking without warning.

The only deltas vs the 2026-05-18 baseline are run-dependent values
(Mach port names and pending_auth fingerprints), neither of which is
the PASS gate. The PASS gates are "lookup returned a non-NULL port"
and "fingerprint changed across the drain", both met.

## What this slice ships

Nothing. This is a verification-only slice. The receipt itself is the
deliverable.

## Build matrix

Linux dev host: not exercised this slice (no code touched).
Hurd VM: `make PORT=hurd STATIC=0` clean (`mig` regenerated
`fsysServer.c` + `fsys_S.h`, three `.boot.o` compiled, link clean);
build transcript at `/tmp/pid1-build-180020.log` in the guest.

## Harness run

Verbatim from the harness stdout (transcript at
`/tmp/harness-run-180020.log` in the guest, serial console at
`/tmp/geos-hurd-vm-v0913-reverify-serial.log`):

```
parent OK publish: idempotency EBUSY-as-expected
child  OK file_name_lookup returned 0xa
child  OK submit_nonce sent
child  OK auth_user_authenticate kr=0x0
child  slice4_handshake_ok=1
parent OK drained submit_nonce; pending_auth fingerprint changed (1469598103934665603 -> 10488948462212568267); drain saw 1 fsys_getroot
parent slice4_handshake_ok=1
parent OK pending_auth row uid=0 gid=0 (real, not sentinel); harness euid=0 egid=0
parent slice5_handshake_ok=1
HARNESS_EXIT=0
WALL_NS=2150080330
```

Harness binary: `tests/hurd-client-handshake.c`, freestanding compile
linked against `../pid1/fsysServer.boot.o` plus `-lports -lfshelp
-lhurduser -lmachuser`. Snapshot kept at
`/tmp/geos-hurd-vm-v0913-reverify-1779459141.qcow2` for follow-on
probes.

## Deltas vs 2026-05-18 baseline

`file_name_lookup` returned `0xa` this run; the 2026-05-18 baseline
saw `0xe`. Mach port name allocation is run-dependent. The PASS gate
is non-NULL plus `auth_user_authenticate` accepting the port, both
confirmed here (`kr=0x0`).

The pending_auth fingerprint after drain is `...8267` here vs `...5329`
in the baseline. The PASS gate is "fingerprint changed across the
drain", not the specific value. The base fingerprint
`1469598103934665603` (empty / sentinel row) is identical in both
runs, which is itself a small structural check that the
`pending_auth[]` initial state has not drifted.

## Open follow-ons (do NOT block this slice's commit)

1. The harness ran as root in the guest, so `row uid=0 gid=0` is the
   "real, not sentinel" gate. A second harness execution under a
   non-root uid would be a stronger check of the
   `auth_server_authenticate` path returning the caller's actual
   creds rather than the publisher's. Next step: add a user to the
   Hurd VM's `/etc/passwd`, su to that uid, re-run the harness, paste
   the markers into a follow-on receipt.

2. The 2.15s wall is dominated by the publish idempotency probe and
   the drain loop, not by the handshake itself. A breakdown of where
   the 2.15s goes would let me set a tighter regression budget. Next
   step: instrument the harness with three `clock_gettime` points
   (publish-done, child-handshake-done, drain-done) and report the
   three deltas in a probe receipt.

## Files touched on the main branch

None. Verification-only slice.
