<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

# 2026-05-31 v1.x apt-image flavor first live-verify on Hurd

First in-VM exercise of the apt-image flavor produced by
`iso-build/hurd-image-reroll.sh FLAVOR=apt-image`. This follows
docs/runlogs/2026-05-30-hurd-v0923-install-slice-c-verify.md and is
the gate the v1.x release-engineering plan called "apt-image flavor
live-tested": prove that Xvfb, xelb, exwm, and pulseaudio are all
present and functional on a freshly baked apt-flavor image so the
v0.9.10 EXWM-on-Xvfb path can be reproduced on canonical Hurd without
a real display.

## Result

PASS on the load-bearing functional claim. Xvfb 21.1.22 starts and
serves :99, xdpyinfo talks to it, emacs-lucid loads xelb 0.20 and
exwm 0.33 against that Xvfb, and pulseaudio + pactl both report
17.0. The closest reproduction of v0.9.10's EXWM-on-Xvfb-on-Hurd
chain that does not require a real display works on this image.

What this verify did NOT prove is in-VM apt operability. The dpkg
admin database is absent from the baked image, so `dpkg-query` and
`dpkg --list` return zero rows even though every binary is physically
on disk. The bake produces a usable runtime image but not a usable
apt host, and that gap is a v1.0 blocker. Two operator-side probe
bugs (load-path under `-Q`, EXWM 0.33 dropping the `exwm-version`
defvar) also surfaced and are recorded so the next verify cycle does
not re-discover them.

## What this slice ships

No code change in this receipt. The image under test is the artifact
itself, produced ahead of this verify:

- `/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0922-apt.img`, a
  391 MB qcow2 overlay baked from the v0.9.22 pristine via
  `iso-build/hurd-image-reroll.sh FLAVOR=apt-image`. Contains the
  four flavor packages physically installed under `/usr/bin/` and
  `/usr/share/emacs/site-lisp/elpa/` (xvfb, emacs-lucid,
  elpa-exwm 0.33, elpa-xelb 0.20) plus pulseaudio 17.0.

The retained snapshot at `/tmp/geos-hurd-vm-20260531-215131.qcow2` is
the overlay used for this verify; it is kept around so the dpkg gap
can be inspected without re-baking.

## Build matrix

Linux dev host: `iso-build/hurd-image-reroll.sh FLAVOR=apt-image`,
391 MB qcow2 written under `/home/overdrive/hurd-vm/`.

Hurd VM: booted under QEMU with SSH on host port 2298, supervisor
came up clean, all five probes executed over that SSH channel.

## Operator hygiene flag, recorded up front

Before the new VM could start, a stale qemu process was already
holding port 2298 against the canonical apt.img with no overlay
snapshot. PID 744996, 1d05h elapsed, sshd inside it wedged. The
previous session had skipped the snapshot-first rule, so any state
that process accumulated was on the pristine. The driver terminated
that qemu and took a fresh snapshot before booting the verify VM.
Note for future sessions: snapshot first, always, even on flavor
images.

## Probe run

### Probe 1: dpkg-query of the five baked packages (FAIL, bake bug)

Command shape:

```
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
  xvfb emacs-lucid elpa-exwm elpa-xelb pulseaudio
```

stderr (all five lines, exit=1):

```
dpkg-query: no packages found matching xvfb
dpkg-query: no packages found matching emacs-lucid
dpkg-query: no packages found matching elpa-exwm
dpkg-query: no packages found matching elpa-xelb
dpkg-query: no packages found matching pulseaudio
```

Root cause: `/var/lib/dpkg/` is absent on the running image. A
bare `dpkg --list` returns zero rows total, not just zero for these
five package names. The dpkg admin database was either wiped during
the bake or never installed into the flavor overlay. The packages
themselves are present at the filesystem level: `/usr/bin/Xvfb`,
`/usr/bin/emacs-lucid`, `/usr/bin/emacs`, `/usr/bin/pulseaudio`,
`/usr/bin/pactl`, `/usr/bin/xdpyinfo` all exist, and the elpa elisp
trees are at `/usr/share/emacs/site-lisp/elpa/xelb-0.20/` and
`/usr/share/emacs/site-lisp/elpa/exwm-0.33/`. So the image is
functionally apt-flavored, it is just not queryable through dpkg.
This is the v1.0 blocker.

### Probe 2: Xvfb spawn + xdpyinfo (PASS)

```
$ Xvfb :99 -screen 0 1024x768x24 &
$ DISPLAY=:99 xdpyinfo | head -5
name of display:    :99
version number:    11.0
vendor string:    The X.Org Foundation
vendor release number:    12101022
X.Org version: 21.1.22
```

Xvfb stays up and answers protocol requests. This is the minimum
display-server precondition for everything downstream.

### Probe 3: emacs-lucid + xelb + exwm headless (PASS after two corrections)

Worth preserving in full because the progression is the diagnostic
story for future verifies.

3a, the operator's first cut (exit nonzero):

```
emacs-lucid -Q --batch \
  --eval "(require 'xelb)" \
  --eval "(require 'exwm)" \
  --eval "(message \"exwm-version: %s\" exwm-version)"
```

`(require 'xelb)` raised `file-missing`. Cause: `-Q` skips
site-start, so the elpa `subdirs.el` that injects the elpa subdirs
into `load-path` never runs. The packages are present, the loader
just cannot see them. Probe-script bug, not a packaging bug.

3b, with explicit load-path injection (exit 0 but eval errored on a
void variable):

```elisp
(add-to-list 'load-path "/usr/share/emacs/site-lisp/elpa/xelb-0.20")
(add-to-list 'load-path "/usr/share/emacs/site-lisp/elpa/exwm-0.33")
(require 'xelb)   ; ok
(require 'exwm)   ; ok
exwm-version      ; void
```

Both requires succeed. The `exwm-version` symbol is unbound because
EXWM 0.33 dropped the defvar; version is now only carried in the
`;; Version: 0.33` package header and the package metadata. Second
probe-script bug.

3c, the correct probe shape (PASS):

```
xelb features=t exwm-features=t
exwm-wm-mode bound=nil exwm-init bound=t
```

xelb 0.20 loads, exwm 0.33 loads, `exwm-init` is the callable entry
point, `exwm-wm-mode` is gone in 0.33 and replaced by the
`exwm-init` flow. Two API drift facts to remember when wiring the
real session.el call site.

### Probe 4: pulseaudio + pactl version (PASS)

```
$ pulseaudio --version
pulseaudio 17.0

$ pactl --version
pactl 17.0
Compiled with libpulse 17.0.0
Linked with libpulse 17.0.0
```

Both binaries present, both reporting 17.0, libpulse linkage matches
the binary version. Satisfies the v1.x pulseaudio-on-Hurd scope X
(pactl userland) precondition.

### Probe 5: full chain Xvfb + emacs + exwm (PASS with load-path patch)

```
Xvfb pid=351 alive=yes
display: :99
xelb feat: t exwm feat: t
exwm-init bound: t exwm-wm-mode bound: nil
```

xelb and exwm both load inside emacs-lucid talking to a fresh Xvfb
instance. This is the closest in-VM reproduction of v0.9.10 without
attaching a real display, and it passes.

### Serial log tail, supervisor state during the probes

Relevant marker lines from the supervised emacs while the probes
ran (cosmetic syslog noise stripped):

```
hurd-essentials: settrans pfinet exit=0
supervise: spawn name=hurd-sshd pid=412 OK
supervise: spawn name=journal-kmsg pid=410 OK
supervise: spawn name=journal-syslog pid=411 OK
session: presenting *login* in console mode
```

Three already-known fallback lines also appeared and are not
regressions:

```
hostname: pid1-set-hostname unbound, skipping (no module)
rpc-server: pid1-rpc-listen unbound, RPC disabled
hurd-essentials: eth0 static skipped, pid1-set-address unbound
```

All three are the supervised-emacs-is-not-pid1 path documented in
the v0.9.22 receipt; settrans pfinet had already brought the network
up regardless. A pre-existing baked Xvfb on `:0` was also running
supervised on this image, separate from the `:99` Xvfb the probes
spawned.

System banner for the record:

```
GNU lambda 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9 x86_64 GNU
release: forky/sid
```

## Open follow-ons (do NOT block this slice's commit)

1. Bake bug, release-blocking for v1.0: the apt-image flavor ships
   without `/var/lib/dpkg/`. Every binary is present on disk, but
   `dpkg-query` and `dpkg --list` return zero rows. In-VM
   `apt install`, `apt upgrade`, and `apt list --installed` cannot
   work in this state. Next step: inspect the bake script in
   `iso-build/hurd-image-reroll.sh` under the `FLAVOR=apt-image`
   branch and find the step that omits or wipes the dpkg admin
   directory; the retained snapshot at
   `/tmp/geos-hurd-vm-20260531-215131.qcow2` is the diff target.

2. Probe-script bug, cosmetic: `emacs-lucid -Q --batch` cannot
   `(require 'xelb)` or `(require 'exwm)` because `-Q` skips
   site-start, so the elpa `subdirs.el` `load-path` injection does
   not run. Next step: future apt-image verify scripts should either
   drop `-Q` or prepend the two `add-to-list` lines on
   `/usr/share/emacs/site-lisp/elpa/xelb-0.20` and
   `/usr/share/emacs/site-lisp/elpa/exwm-0.33`.

3. EXWM 0.33 API drift, will bite session.el later: `exwm-version`
   is no longer a bound symbol, and `exwm-wm-mode` is gone,
   replaced by the `exwm-init` flow. Next step: when wiring the
   apt-image flavor into the canonical session, call `exwm-init`
   and stop reading `exwm-version`; pull the version from the
   package metadata if it is needed for the banner.

4. Operator hygiene: the snapshot-first rule was skipped on the
   prior session against this same port, leaving a wedged qemu
   running for 1d05h. Next step: a one-line guard at the top of
   the verify driver that refuses to boot if a qemu is already
   bound to the chosen ssh port would prevent the next instance.

## Files touched on the main branch

None. This is a docs-only receipt; the image is the artifact.
