<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# 2026-06-01: apt-image flavor re-rolls clean with pre-apt /var detach

Closure receipt for task #233. The v1.x apt-image flavor produced by
`iso-build/hurd-image-reroll.sh FLAVOR=apt-image` baked clean once at
commit 127b753 (receipt
`docs/runlogs/2026-05-23-hurd-v1x-apt-image-flavor-live-verify.md`),
then regressed when fb91016 moved the canonical-/var detach into the
boot path via `services/hurd-essentials.el`. The revert at 5e19fd9
captured the root cause: state.el load-time mkdir against the tmpfs
view of `/var/emacs/*` loses its writes when the detach fires at boot,
and heavy writes against the underlying ext2fs trip the pager.c:455
assertion I just filed upstream as
`docs/upstream/emails/08-ext2fs-pager-blk-assertion.txt`. This slice
moves the detach into the bake's own ssh session pre-apt and into the
verify path's pre-P1 step, then re-bakes and re-verifies.

## Result

PASS on the load-bearing claim. The bake completes end-to-end with the
pre-apt `settrans -fg /var` in step 8a, apt-install pulls all five
flavor packages without the pager assertion firing, the shutdown path
returns within the new 15s timeout wrapper, and the resulting image at
`/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0922-apt.img`
(390725632 bytes, sha256 `f09ffdbc0c8eadad15740a801338aece71f256ff14383715d4d5702a48e3bb1e`)
passes all five probes under `iso-build/apt-image-verify.sh`.

What this does not do is widen the apt-install manifest. The five
packages happen to land under the ext2fs pager wedge threshold;
upstream email 08 is still the load-bearing blocker for anything
larger. The boot-time detach path stays out per 5e19fd9 and is not
revisited in this slice.

## What this slice ships

Per-commit, in the order they landed.

- commit 5e19fd9 (earlier session): revert "hurd-essentials: detach
  canonical /var /hurd/tmpfs at boot" from fb91016. Message captures
  the state.el-mkdir-disappears-on-detach failure mode in full so the
  next person who proposes the boot-time detach finds the prior
  attempt.
- commit 3f72960 (earlier session): adds pre-P1 step to
  `iso-build/apt-image-verify.sh` that runs
  `ssh ... 'showtrans /var; settrans -fg /var 2>&1; echo settrans=$?'`
  before P1. Drafts `docs/upstream/emails/08-ext2fs-pager-blk-assertion.txt`
  and updates `docs/upstream/STATUS.md` to add section 08 and bump the
  filing count to eight emails.
- commit 24b555b (this session):
  `iso-build/hurd-image-reroll.sh` step 8a now runs
  `settrans -fg /var` in the bake's own ssh session before apt-install.
  Inline comment block enumerates the state.el-mkdir failure mode and
  cross-references email 08 for the ext2fs pager risk so future readers
  do not move the detach back to boot.
- uncommitted in working tree at receipt-write time, will commit with
  this receipt:
  - `iso-build/hurd-image-reroll.sh`: `SSH_OPTS` gains
    `-o ServerAliveInterval=5 -o ServerAliveCountMax=2` so any single
    ssh call has a bounded blocking window, and every
    `ssh ... 'shutdown -h now'` is wrapped in `timeout 15` so step 8e
    cannot block forever on Hurd not sending FIN. Same shape that
    landed in `apt-image-verify.sh` at daeb500.
  - `docs/upstream/emails/08-ext2fs-pager-blk-assertion.txt`: body
    trimmed from 105 lines to roughly 55, every downstream project
    reference removed per filing policy. Body is now one sentence of
    problem, a three-step reproducer, one paragraph of context
    (rootfs size + pager.c reading around line 455), three asks, a
    short offer to test patches, sign-off.
  - `docs/upstream/emails/08-SEND.txt`: new operator-only send
    instructions. NEW filing on bug-hurd, not a reply. Carries
    To/Subject/body source, step-by-step gmail UI, post-send
    STATUS.md update path, and an explicit warning that the
    operator-notes section must not be pasted into the outgoing mail.

## Build matrix

Linux dev host: `iso-build/hurd-image-reroll.sh FLAVOR=apt-image`,
second attempt PASS after the OUT_DIR/timeout fixes; 390725632-byte
qcow2 written to `/home/overdrive/hurd-vm/`.

Hurd VM: booted under QEMU by `iso-build/apt-image-verify.sh` against
the new image, supervisor came up clean, all five probes executed over
ssh.

## Bake run

First attempt with commit 24b555b alone failed two ways. Step 8a
referenced `$OUT_DIR`, which apt-image-verify.sh defines but the
reroll script does not, so the redirect into `${OUT_DIR}/...` aborted
under `set -u`:

```
iso-build/hurd-image-reroll.sh: line ...: OUT_DIR: unbound variable
```

Patched to `PREAPT_LOG="${PREAPT_LOG:-/tmp/hurd-image-reroll-preapt-var-detach.log}"`
and the apt-install step then hit the same lock-frontend ENOENT path
the pre-detach bake hit (no detach yet had actually run because of the
set -u abort). Step 8e then hung indefinitely on the shutdown ssh
because Hurd never sent FIN on the channel.

Second attempt added `SSH_OPTS` keepalive and the `timeout 15` wrapper
on every shutdown ssh; passed end-to-end:

```
settrans=0
apt-install: 5 packages installed
  xvfb
  emacs-lucid
  elpa-exwm
  elpa-xelb
  pulseaudio
step 8e: shutdown ssh returned within 15s wrapper
step 8e: 60s qemu-halt wait expired (Hurd shutdown is slow)
step 8e: SIGTERM sent, qemu cleaned up
```

The ext2fs pager.c:455 assertion did not fire during apt-install. The
five-package manifest sits under the wedge threshold on this image
size; email 08 is the load-bearing follow-on for any larger manifest.

Final artifact:

```
path:   /home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0922-apt.img
size:   390725632
sha256: f09ffdbc0c8eadad15740a801338aece71f256ff14383715d4d5702a48e3bb1e
```

## Verify run

`iso-build/apt-image-verify.sh` against the new image. Snapshot booted
at `/tmp/apt-image-verify-20260601-121328.qcow2`, ssh came up, pre-P1
`settrans -fg /var` fired (exit=0), all five probes PASS.

| Probe | What it covers                                | Result |
|-------|-----------------------------------------------|--------|
| pre-P1 | `showtrans /var; settrans -fg /var`          | settrans=0 |
| P1    | `dpkg-query` of the five baked packages       | PASS (5/5 `ii`) |
| P2    | `Xvfb :99` + `xdpyinfo`                       | PASS |
| P3    | emacs-lucid + xelb + exwm headless            | PASS |
| P4    | `pulseaudio --version` + `pactl --version`    | PASS |
| P5    | full chain `DISPLAY=:99` + `exwm-init` bound  | PASS |

Per-probe logs at `/tmp/apt-image-verify-20260601-121328/`. Serial log
at `/tmp/apt-image-verify-20260601-121328.serial.log`. Snapshot
retained at `/tmp/apt-image-verify-20260601-121328.qcow2` for
forensics.

## Open follow-ons (do NOT block this slice's commit)

1. Upstream email 08 (ext2fs pager.c:455 `Assertion 'blk' failed.`)
   stays the load-bearing blocker for any apt manifest larger than the
   current five-package set. The reroll script's pre-apt detach plus
   the verify path's pre-P1 detach make the current manifest safely
   re-rollable, but the next time the manifest grows the bake is one
   heavy write away from tripping the assertion again. Next step: send
   email 08 per `docs/upstream/emails/08-SEND.txt` and wait for an
   upstream pager.c fix before widening the manifest.

## Files touched on the main branch

- `iso-build/hurd-image-reroll.sh` (+SSH_OPTS keepalive, +timeout 15
  on shutdown ssh; commit 24b555b already landed the pre-apt
  `settrans -fg /var` in step 8a with the cross-reference comment).
- `docs/upstream/emails/08-ext2fs-pager-blk-assertion.txt` (-50 lines;
  scrubbed of every downstream reference, now ~55 lines).
- `docs/upstream/emails/08-SEND.txt` (new file; operator-only send
  instructions, explicit do-not-paste warning on the notes section).
- `docs/runlogs/2026-06-01-hurd-apt-image-pre-apt-detach.md` (this
  receipt).

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
