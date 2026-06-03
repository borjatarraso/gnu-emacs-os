<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

# 2026-05-31 v1.x /var tmpfs detach, the apt bake bug that wasn't

Closure receipt for follow-on #1 of
`docs/runlogs/2026-05-31-v1x-apt-image-verify.md`. That verify ran
`dpkg-query` and `dpkg --list` from inside the booted apt-image VM,
got zero rows, and classified the result as a release-blocking bake
bug: the dpkg admin database had been wiped or never installed.
Diagnosis this session proved that read wrong on both counts. The
admin DB was on disk the whole time; canonical Debian GNU/Hurd 0.9
ships `/var` as a `/hurd/tmpfs` translator that masked the populated
underlying ext2fs tree from anything running in the booted VM. The
fix is a `settrans -fg /var` call at the top of the
`(when (eq geos-kernel 'hurd) ...)` block in
`emacs-init/services/hurd-essentials.el`, landed at commit fb91016.

## Result

PASS on the load-bearing claim. The apt-image bake is correct; the
five flavor packages are physically present and their dpkg admin
records are intact. After the elisp fix runs at boot, dpkg-query for
the five baked package names returns five `ii` rows with exit=0, and
`dpkg --list` returns 536 rows (Debian baseline plus the five
flavor adds). The v1.0 release-blocker classification in the prior
receipt is withdrawn.

What this does not do is re-bake the artifact at
`/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0922-apt.img`. That
image still ships the pre-fix supervisor tree under
`/usr/share/geos/emacs-init/`. The next
`iso-build/hurd-image-reroll.sh FLAVOR=apt-image` cycle picks the fix
up automatically because the supervisor tarball is regenerated from
the current main checkout at bake time, so no image-side action is
required; flagging it so the next bake is the verifier.

## What this slice ships

- `emacs-init/services/hurd-essentials.el` (+36): new block at the
  top of the Hurd gate, before the `defservice` entries. Guarded
  with `(file-executable-p "/bin/settrans")` so it stays a strict
  no-op on dev hosts and any non-canonical image. Goes through
  `call-process` with no shell wrapper, wraps the call in
  `condition-case`, and frames it with two `/dev/console`
  breadcrumbs ("settrans -fg /var (detach canonical /hurd/tmpfs)"
  and "settrans -fg /var exit=%S"). Comment block records the
  load-order subtlety: `state.el`'s top-level auto-init has already
  mkdir'd `/var/emacs/{journal,packages,network,users,services,dotfiles,sessions,lockouts}`
  on the tmpfs by the time this block runs, those dirs vanish with
  the tmpfs, and `state-write` re-creates them on the underlying
  ext2fs via `state--ensure-dir` on first write. Nothing has written
  state yet at this load step, so the dir loss is invisible.

## Build matrix

Linux dev host: `emacs -Q --batch --eval "(byte-compile-file
\"emacs-init/services/hurd-essentials.el\")"`, clean.

Hurd VM: fix file scp'd into
`/usr/share/geos/emacs-init/services/hurd-essentials.el` on a fresh
snapshot overlay, VM rebooted, five probes re-run, all PASS.

## Diagnosis chain, the part worth keeping

Two passes, both required.

First, inspected the image directly with guestfish, no boot.
`/var/lib/dpkg/` is present, `status` is 485896 bytes, all five
baked package names appear in `grep '^Package: ' status`. The bake
was fine.

Second, re-booted the apt-image on a fresh snapshot and added a new
probe G: `showtrans /var` returned `/hurd/tmpfs 256M`, `mount`
showed only `typed:part:2:device:wd0 on /` (no `/var` entry), and
`ls /var/lib` from inside the booted VM was essentially empty. The
booted userland was looking at the tmpfs, which canonical's
first-boot scripts populate with only `cache/`, `emacs/`, and
`log/`. Guestfish bypasses live translators and reads the raw
ext2fs underneath; both observations were true.

Prior art exists. This exact symptom was filed as anomaly #2 in
`docs/runlogs/2026-05-24-hurd-v0919-image-reroll-fullchain.md`, with
the one-liner remediation `settrans -fg /var` already documented.
The v1.x apt-image verify hit it independently and mis-classified
it as a bake bug because the verify ran from inside the booted VM
and never compared against an out-of-band view of the same filesystem.

## Probe run

Verify ran against snapshot
`/tmp/geos-hurd-vm-vartmpfs-fix-20260531-222426.qcow2`, an overlay
over the apt-image.

Probe 1, settrans breadcrumbs in the post-fix serial log
(`grep -aE 'settrans -fg /var'`):

```
hurd-essentials: settrans -fg /var (detach canonical /hurd/tmpfs)
hurd-essentials: settrans -fg /var exit=0
```

Probe 2, mount + showtrans state after the fix:

```
$ mount
typed:part:2:device:wd0 on /
$ showtrans /var
$
```

The tmpfs translator is gone. The underlying ext2fs `/var` is what
every subsequent path resolution sees.

Probe 3, /var/lib/dpkg/ visibility from inside the booted VM:

```
$ ls /var/lib/dpkg/
alternatives  info  parts  status  status-old  triggers  updates  ...
$ stat -c%s /var/lib/dpkg/status
485896
```

Same 485896 bytes guestfish reported out-of-band, now visible to the
booted userland.

Probe 4, the originally-failing reprobe:

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
    xvfb emacs-lucid elpa-exwm elpa-xelb pulseaudio
ii xvfb 2:21.1.22-1
ii emacs-lucid 1:30.2+1-1
ii elpa-exwm 0.33-1
ii elpa-xelb 0.20-1
ii pulseaudio 17.0+dfsg1-2
$ echo $?
0
```

Five `ii` rows, one per baked package, exit=0. This is the inverse
of the prior receipt's probe 1.

Probe 5, dpkg --list count:

```
$ dpkg --list | wc -l
536
```

Canonical Debian baseline plus the five apt-bake packages, which
matches a hand-count of the baseline plus the flavor adds.

## Mechanics note worth preserving

`reboot(8)` on canonical Debian GNU/Hurd 0.9 wedges with
`/run/initctl: No such file or directory` and does not cycle the
kernel. To re-trigger boot-time elisp during this kind of fix-test
loop, kill the qemu pid and re-boot from the same qcow2 overlay;
scp'd files survive because writes land in the overlay. The next
boot picks them up. Recording this so the next session does not
spend twenty minutes wondering why `reboot` returned silently and
the elisp file under test never re-loaded.

## Open follow-ons (do NOT block this slice's commit)

1. Probe-script bug, still open from the parent receipt:
   `emacs-lucid -Q --batch` cannot `(require 'xelb)` or
   `(require 'exwm)` because `-Q` skips site-start, so the elpa
   `subdirs.el` load-path injection never runs. Next step: future
   apt-image verify scripts drop `-Q` or prepend the two
   `add-to-list` lines explicitly.

2. EXWM 0.33 API drift, still open from the parent receipt:
   `exwm-version` is no longer a bound symbol and `exwm-wm-mode`
   is gone, replaced by the `exwm-init` flow. Next step: when
   wiring the apt-image flavor into the canonical session, call
   `exwm-init` and read version from package metadata.

3. Operator hygiene, still open from the parent receipt: the
   snapshot-first rule was skipped on a prior session against the
   same port and left a wedged qemu running for 1d05h. Next step:
   a one-line port-bind guard in the verify driver that refuses to
   boot if qemu is already on the chosen ssh port.

4. Image artifact not re-baked. The current
   `/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0922-apt.img`
   still ships the pre-fix supervisor tree under
   `/usr/share/geos/emacs-init/`. The next
   `iso-build/hurd-image-reroll.sh FLAVOR=apt-image` cycle is the
   verifier; the bake regenerates the supervisor tarball from the
   current main checkout, so picking the fix up is automatic. Next
   step: when v1.x ships, the release-engineering bake is the
   confirmation, not a separate test.

## Files touched on the main branch

- `emacs-init/services/hurd-essentials.el` (+36)
