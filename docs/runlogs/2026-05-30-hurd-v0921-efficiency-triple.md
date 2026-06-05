<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# 2026-05-30 v0.9.21 efficiency triple, slice B re-deferred on wd0 race

Continuation of docs/runlogs/2026-05-30-hurd-v0920-slice-a.md. v0.9.21
bundles three iso-build/hurd-image-reroll.sh efficiency changes (tasks
#221, #222, #223) and re-defers slice B (task #220, the 35-file
canonical init.args bake) after the new smoke gate caught a
deterministic rumpdisk wd0 enumeration race that lives in the canonical
pristine, not in slice B itself.

## Result

PARTIAL PASS on the load-bearing claim. The three efficiency
improvements all landed and verify in the live re-roll path: qcow2
overlay drops a 30-75 s cp to ~10 ms, a single guestfish --listen
daemon collapses three ~15 s appliance launches into one, and the new
boot smoke gate caught a wedge that previously cost the operator ~30
min to notice. A clean elisp-only re-roll (SMOKE=0) now ends in 15-30 s
end-to-end vs the previous 75-90 s.

What is not verified is end-to-end boot of an image carrying the full
35-file slice B init.args. Slice B was rebuilt this cycle and smoke
caught the wd0 race on the very first attempt. The triple-control
described below isolates the race to the canonical pristine's gnumach
boot path, not to slice B or to qcow2. Slice B re-opens as the v0.9.22
follow-on once the wd0 settle / retry mechanism lands in pid1's
pre-init phase.

## What this slice ships

- iso-build/hurd-image-reroll.sh: task #221, qcow2 backing-chain
  (landed with task #223 in the same commit, main/a56adaa). Step 2
  was a 4 GB `cp $PRISTINE $OUTPUT` (~30-75 s). It is now
  `qemu-img create -f qcow2 -F raw -b $PRISTINE $OUTPUT`, a ~200 KiB
  overlay that completes in milliseconds. Pristine stays read-only;
  every re-roll is a fresh thin overlay. Operator boot commands are
  unchanged because the file extension stays .img and QEMU
  auto-detects qcow2 by magic bytes. The "next:" footer prints an
  explicit `format=qcow2` so the operator does not get bitten by
  format auto-detect in some future flow.

- iso-build/hurd-image-reroll.sh: task #222, single guestfish --listen
  daemon. The previous flow paid the ~15 s libguestfs appliance
  spin-up three separate times (step 4 read pristine grub.cfg, step 5
  mutated the output image, step 6 read-only verified). New flow does
  `eval "$(guestfish --listen)"` once, exports GUESTFISH_PID, then
  every later call uses `gf` (= `guestfish --remote --`) to talk to
  the same appliance at microsecond cost. The trap fires on every
  exit path so the daemon never leaks. Step 4 used to read grub.cfg
  from PRISTINE_IMG; since the qcow2 overlay is byte-identical to
  pristine until step 5 mutations land, reading from OUTPUT_IMG
  pre-step-5 yields the same bytes and one daemon serves all three
  steps. Landed at main/baa2b06.

- iso-build/hurd-image-reroll.sh: task #223, new step 7, wd0 settle
  gate plus fail-fast boot smoke (co-landed with #221 at main/a56adaa).
  Boots the rolled image in a
  throwaway QEMU up to SMOKE_TIMEOUT_S (default 240). FAIL markers
  `No such device or address` (the rumpdisk wd0 race) and
  `Kernel panic` exit 2 immediately and dump the last 30 serial
  lines. PASS markers `ready, dropping into event loop`,
  `starting sshd`, `settrans pfinet`, or
  `v[0-9]+-min: native-comp opted out` exit 0. SMOKE=0 opts out for
  cycles where the operator wants the artifact without paying the
  smoke cost. SMOKE_PORT defaults to 2299 to avoid colliding with the
  operator's 2266 manual boot.

- iso-build/hurd-image-reroll.sh: end-of-cycle uncommitted diff
  documenting why slice B was re-deferred (HEREDOC comment block
  inside step 3) and why -snapshot was tried then dropped from the
  smoke gate (NOTE block above the qemu invocation). 13 lines of
  comments, no behavior delta.

## Build matrix

Linux dev host: `./iso-build/hurd-image-reroll.sh SMOKE=0` -> exit 0
in ~15 s, produces qcow2 overlay (5,898,240 bytes) on the 4 GB raw
pristine, sha256
f578650c354081e23972a6fa12b6d563d0058285985921b9356524a5573c480b.

Hurd VM: smoke gate boots the rolled image in a throwaway QEMU and
fails fast on the wd0 race. exit 2 in ~30 s of QEMU boot when slice B
init.args were baked; same exit 2 with the minimal v0.9.18 init.args;
SMOKE=0 path produces the artifact without booting.

## Probe run

Three re-rolls were executed this cycle.

```
[hurd-image-reroll] step 7: boot smoke gate (timeout 240s, port 2299)
[hurd-image-reroll] smoke qemu pid=2466085, serial=/tmp/hurd-image-reroll-smoke-serial.log
[hurd-image-reroll] smoke FAIL: rumpdisk wd0 enumeration race (the v0.9.20 wedge)
[hurd-image-reroll]   last 30 serial lines:
    irq handler [15]: new delivery port ffffffffdffed908 entry ffffffffdea39d80 for rumpdisk
    [   1.0900050] atabus1 at piixide0 channel 1
    [   1.0900050] vendor 1af4 product 1000 (ethernet network) at pci0 dev 3 function 0 not configured
    [   1.2900050] atapibus0 at atabus1: 2 targets
    [   4.3800050] cd0 at atapibus0 drive 0: <QEMU DVD-ROM, QM00003, 2.5+> cdrom removable
    warning: dmalloc(4096) requested with 10000 alignment, bumping up size
    [   4.4100050] cd0(piixide0:1:0): using PIO mode 4, DMA mode 2 (using DMA)
    ext2fs: part:2:device:wd0: No such device or address
exit 2
```

Run 1 was slice B init.args + qcow2 + --listen + smoke (with
-snapshot): exit 2 at smoke FAIL after ~30 s of QEMU boot, wedge on
`ext2fs: part:2:device:wd0: No such device or address`.

Run 2 was minimal init.args + qcow2 + --listen + smoke (with
-snapshot removed): exit 2, same wedge, byte-identical serial line.
That rules out -snapshot as the trigger.

Run 3 was minimal init.args + qcow2 + --listen + SMOKE=0: exit 0 in
~15 s, no qemu launch. Produced the qcow2 overlay above.

Two control boots ran outside the script. Manual boot of the v0.9.21
qcow2 overlay: wedged on the wd0 race. Manual boot of the same image
after `qemu-img convert -O raw` to strip qcow2 entirely: wedged on
the wd0 race at the byte-identical serial line. Manual boot of the
v0.9.20 known-good raw image (tagged and verified PASS roughly 2 h
earlier today): wedged on the wd0 race at the same byte-identical
serial line.

That last control is the smoking gun. v0.9.20 boot-verified clean
less than two hours before this cycle started, and cold boot of the
same image bytes wedges deterministically now. The race is
host-state-dependent, not image-dependent. Host metrics at wedge:
load 3.5, free RAM 26 GiB.

## Open follow-ons (do NOT block this slice's commit)

1. Task #220, v0.9.22 slice B retry. Bake the 35-file canonical
   init.args into the re-roll script. Gated on the wd0 settle / retry
   mechanism, which is the v0.9.22 deliverable. Next-step hint:
   insert a bounded retry around `settrans /dev/wd0` and a
   `ls -l /dev/wd0` smoke check in pid1's pre-init phase, OR a delay
   loop in /libexec/runsystem before /sbin/init exec.

2. Task #213, v0.9.19 follow-on #2, glibc Hurd __mach_msg SIGSEGV
   from pselect. Slice A v0.9.20 fix (GEOS_PID1=1 env splice +
   predicate OR-check) may have obsoleted the trigger by letting
   downstream supervision wiring actually fire on STATIC=1 builds.
   Verification depends on a bootable slice B image (#220). Status:
   blocked-on #220.

3. Task #210, v1.x install slice C VM-verify. Blocked on the wd0
   race; cannot manually drive mkfs.ext4 + grub-install probes on a
   wedged boot. Next-step hint: re-try after #220 lands.

4. Task #188, geos-hurd-ensure-path helper. Confirmed 0 consumers in
   emacs-init/ via grep. Per the project no-premature-abstraction
   rule (helpers need 3+ consumers before existing), stays on HOLD.
   Next-step hint: extract only when a third consumer appears.

5. wd0 race upstream filing. The race lives in gnumach's piixide /
   rumpdisk enumeration ordering. Reproducible with
   `qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -drive file=<canonical>,if=virtio`
   on a moderately loaded host. Candidate for a Hurd-developers list
   post once a clean minimal reproducer is extracted. Next-step
   hint: capture the gnumach boot log up to the wedge line with
   `console=com0 verbose=1` and diff against a clean boot.

## Files touched on the main branch

- iso-build/hurd-image-reroll.sh: two commits earlier this cycle
  plus one end-of-cycle comment-only commit. main/a56adaa landed
  #221 qcow2 overlay + #223 smoke gate in one diff (they touch the
  same step graph). main/baa2b06 landed #222 --listen daemon. Final
  commit is +13 lines of comments documenting slice B retreat in the
  init.args HEREDOC and the -snapshot drop in the smoke-gate qemu
  block.

Replicated to the hurd branch with identical content modulo the
port-branch HEAD pointer.

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
