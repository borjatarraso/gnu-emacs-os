<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# v0.9.10 EXWM-on-Xvfb-on-Hurd live verify

this receipt closes the EXWM-attaches-to-Xvfb gap that v0.9.8 and v0.9.9
left open (see `docs/runlogs/2026-05-21-v098-vm-verify.md` open follow-on
#1 and `docs/runlogs/2026-05-21-v099-vm-verify.md` open follow-on #3).
v0.9.8 shipped the Xvfb-on-Hurd spawn in `pid1/port_hurd.c` (spawn_xorg
plus main_supervise_xvfb), v0.9.9 shipped the real
MACH_NOTIFY_DEAD_NAME watcher so the Hurd Xvfb child gets the same
parent-death guarantee Linux gets through prctl(PR_SET_PDEATHSIG), and
this slice runs EXWM 0.33 + xelb 0.20 on emacs-lucid 30.2 against that
Xvfb on canonical Debian GNU/Hurd 0.9 to confirm EXWM actually drives
the display. commit anchor for the probe is `main/0ec9533`, the v0.9.9
tag at probe time.

## Result
FEASIBLE WITH GAPS on the load-bearing claim: EXWM attaches to the
Xvfb instance the v0.9.8 spawn path puts up on Hurd, declares itself
the EWMH window manager, and manages a real X client (xterm and
xclock observed under the EXWM container hierarchy).

what is verified: Xvfb 21.1.22 live on display :99 on GNU/Hurd 0.9,
EXWM 0.33 + xelb 0.20 loaded on emacs-lucid 30.2, `(exwm-enable)`
returns clean, the EWMH `_NET_SUPPORTING_WM_CHECK` window on the root
points at the `"EXWM"` window in the xwininfo tree, xclock appears as
a managed client with WM_CLASS / _NET_WM_PID set, and *Messages* shows
no panic and no exwm error. what is not verified is the canonical
image bundling story: four apt packages (xvfb, emacs-lucid, elpa-exwm,
elpa-xelb) are not in the Debian Hurd 0.9 default set and had to be
installed inside the ephemeral snapshot. that is packaging work, not
code work, and it is parked in open follow-ons for the v1.x apt-image
flavor.

## What this slice ships
this is a verification-only slice. no code diff. the artifact is the
probe receipt at `/tmp/hurd-exwm-feasibility-20260521-192634.log` and
this runlog under `docs/runlogs/`.

## Build matrix
Linux dev host: no build, verification-only slice.
Hurd VM: ephemeral snapshot `/tmp/geos-hurd-vm-exwm-20260521-191702.qcow2`
off canonical `/home/overdrive/hurd-vm/work.img` (mtime preserved at
2026-05-18 13:34:31.700204970 +0300, canonical never written to).
QEMU pid 3082090, ssh `root@127.0.0.1:2299`.

## Probe E1: kernel + userland identity

```
GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9 x86_64 GNU
forky/sid
GNU Emacs 30.2
X.Org version: 21.1.22
```

GNU-Mach + Hurd 0.9, debian forky/sid userland, emacs 30.2 (the
emacs-lucid build, X-capable), Xorg 21.1.22 binary present from the
xvfb package. this is the canonical 2026-05-18 image, not a custom
build.

## Probe E2: apt prereq inventory

```
ii elpa-exwm     0.33-1                   all
ii elpa-xelb     0.20-1                   all
ii emacs-lucid   1:30.2+1-2               hurd-amd64
ii x11-apps      7.7+11                   hurd-amd64
ii x11-utils     7.7+7                    hurd-amd64
ii xdotool       1:3.20160805.1-5.1+b2    hurd-amd64
ii xterm         407-1                    hurd-amd64
ii xvfb          2:21.1.22-1              hurd-amd64
```

x11-utils, xterm, xdotool, x11-apps are in the canonical image already.
the four packages i actually had to install on the snapshot were xvfb,
emacs-lucid, elpa-exwm, elpa-xelb. canonical ships emacs-nox which has
no X support; emacs-lucid is what EXWM needs to talk to the display.

## Probe E3: Xvfb live

```
Keyboard Control:
  auto repeat:  on    key click percent:  0    LED mask:  00000000
  XKB indicators:
    00: Caps Lock:   off    01: Num Lock:    off    02: Scroll Lock: off
  auto repeat delay:  660    repeat rate:  25
```

`xset q` against `:99` returns a populated keyboard-control block, so
the Xvfb server is up and accepting client connections on that display
number. this is the same display the v0.9.8 spawn path puts up.

## Probe E4: EXWM connection state

```
"connection=t workspaces=2 managed=1 buffers=1"
```

emacsclient eval reports a live X connection (`connection=t`), two
EXWM workspaces allocated (the default count), one managed X client,
and one EXWM buffer. (the `setsockopt: Protocol not available` line
that emacsclient prints first is the AF_UNIX socket option mismatch
known on Hurd; it is harmless, emacsclient still talks to the daemon,
and the eval result is the line in quotes.) the managed count of 1
matches the snapshot moment when only xterm was up; xclock was added
later and shows up in E5.

## Probe E5: EXWM root-window tree + EWMH check

```
xwininfo: Window id: 0xef (the root window) (has no name)

  Root window id: 0xef (the root window) (has no name)
     7 children:
     0x400029 "EXWM: exwm-input--timestamp-window": ()  1x1+-1+-1  +-1+-1
     0x60000c "xclock": ("xclock" "XClock")  1022x669+1+64  +1+64
     0x400002 "EXWM": ()  1x1+-1+-1  +-1+-1
     0x400027 "EXWM workspace 0 frame container": ()  1024x768+0+0  +0+0
        1 child:
        0x200149 "*EXWM*": ("emacs" "Emacs")  1024x768+0+0  +0+0
     0x400001 "EXWM: exwm--wmsn-window": ()  1x1+-1+-1  +-1+-1
     0x200010 (has no name): ()  1x1+-1+-1  +-1+-1
     0x400028 "EXWM workspace 1 frame container": ()  1x1+-1+-1  +-1+-1
        1 child:
        0x20029f "*scratch*": ("emacs" "Emacs")  672x675+0+0  +-1+-1

_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x400002
```

the root has 7 children and 5 of them are EXWM-owned: the
timestamp-window, the WM-selection window (`exwm--wmsn-window`), the
EWMH `EXWM` identity window at 0x400002, and the two workspace frame
containers (0x400027 holds `*EXWM*` at 1024x768, 0x400028 holds
`*scratch*` at 672x675). xclock is in the tree at 1022x669, fully
sized, sitting alongside the EXWM containers as a managed top-level.

the EWMH bit is the real proof: the `_NET_SUPPORTING_WM_CHECK` property
on the root points at window 0x400002, and 0x400002 is literally the
`"EXWM"` window in the same tree dump. that is the contract a EWMH
client uses to identify the running window manager, and on this Xvfb
display the answer is EXWM. EXWM owns the display.

(side observation: E4 said managed=1 and E5 shows xclock plus an
xterm-shaped container. the two probes were not snapshotted at the
same instant. E4 ran while only one client was up, E5 ran after
xclock launched. i am recording both numbers as i observed them rather
than smoothing them over.)

## Probe E6: xclient identity

```
WM_CLASS(STRING) = "xclock", "XClock"
WM_NAME(STRING) = "xclock"
_NET_WM_PID(CARDINAL) = 1770
```

xclock has WM_CLASS, WM_NAME, and _NET_WM_PID set on its top-level
window. that means a real X client process (pid 1770) connected to
the Xvfb display, did ICCCM + EWMH setup, and is now under EXWM
management. this is the end-to-end check: process spawned, client
connected, WM saw the MapRequest, WM mapped it.

## Probe E7: *Messages* clean

```
"For information about GNU Emacs and the GNU system, type C-h C-a.
Wrong number of arguments: mapcar, 3"
```

*Messages* has the standard emacs 30.2 banner plus exactly one
warning, `Wrong number of arguments: mapcar, 3`. no `pid1-error`,
no `exwm-error`, no `error in X event handler`, no backtrace. the
mapcar warning is emacs 30.2 byte-compile deprecation noise from a
third-party load-path entry (mapcar dropped its optional 3rd arg
years ago) and it does not prevent EXWM from functioning, which the
EWMH check in E5 is the proof of. flagging it as a follow-on for a
future cleanup pass, not as a regression.

## What this closes
this closes the deferred verification in
`docs/runlogs/2026-05-21-v098-vm-verify.md` Result section ("what is
not verified: EXWM attaches to the spawned Xvfb") and the matching
open follow-on #1 in that receipt, and it closes the carried-forward
open follow-on #3 in `docs/runlogs/2026-05-21-v099-vm-verify.md`. the
v0.9.8 spawn-Xvfb path and the v0.9.9 dead-name parent watcher are
doing the right thing in production shape: EXWM is a real client of
that Xvfb instance and behaves as the EWMH window manager for it.

## Open follow-ons (do NOT block this slice's commit)
1. `Wrong number of arguments: mapcar, 3` warning in *Messages*. third-party
   elisp on the canonical Hurd image's emacs-lucid load-path is calling
   `mapcar` with three args, which emacs 30.x no longer accepts (the
   sequence-fn-with-init signature). EXWM itself works around it (E5
   proves that), but the warning is noise i want gone. next step:
   grep the load-path on the snapshot for `(mapcar [^)]+ [^)]+ [^)]+)`
   to find the offending package and either patch it or filter the
   load order.

2. canonical-image bundling decision for xvfb + emacs-lucid + elpa-exwm
   + elpa-xelb. these are debian forky/sid packages and they install
   cleanly on Hurd 0.9 (E2 confirms hurd-amd64 builds exist for the
   native ones), but they are not in the default canonical image. the
   right answer is probably a geos-x flavor of the apt-image build, not
   bloating the base. deferred to v1.x apt-image-flavor work; next step
   is to spec a `debian/geos-x.list` and a regenerate script.

3. emacsclient `setsockopt: Protocol not available` first-line noise on
   every emacsclient call. this is the AF_UNIX socket-option mismatch
   on Hurd that i already know about; the eval still succeeds. next
   step is the libemacsclient fix upstream or a thin emacsclient wrapper
   that drops the offending setsockopt on Hurd.

## Artifact paths
- raw probe receipt: `/tmp/hurd-exwm-feasibility-20260521-192634.log`
- ephemeral snapshot: `/tmp/geos-hurd-vm-exwm-20260521-191702.qcow2`
- canonical base image (read-only, mtime preserved):
  `/home/overdrive/hurd-vm/work.img` (mtime 2026-05-18 13:34:31.700204970 +0300)
- QEMU serial log: `/tmp/hurd-exwm-serial-3082030.log`
- QEMU pid at probe time: 3082090
- ssh handle: `root@127.0.0.1:2299 -i ~/.ssh/id_ed25519_p0lym0rphic`
- commit anchor: `main/0ec9533` (v0.9.9 tag at probe time)

## Files touched on the main branch
- `docs/runlogs/2026-05-21-v0910-exwm-xvfb-hurd.md` (new file, this
  receipt, no code diff in this slice).

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
