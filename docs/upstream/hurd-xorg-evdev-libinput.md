<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

<!-- upstream deferral, drafted 2026-05-30, covers HURD_PORT.md lines 90-112 -->

# hurd-amd64 ships no evdev / libinput driver; native Xorg blocked on keyboard init

## summary

native Xorg does not come up on Debian GNU/Hurd 0.9 today.  it walks
through dummy-driver init, GLX / DRISWRAST init, all 23 extension
inits, and mouse input init, then dies in `kbd_drv.so` with

    [295.288] (EE) Cannot set event mode on keyboard (Bad file descriptor)

`kbd_drv.so` issues a Linux-style "set event mode" ioctl against
`/dev/cons/kbd`, which is a `/hurd/chrdev 156 33685736` translator,
and the chrdev returns EBADF because the gnumach console translator
does not implement the ioctl.  the natural fallbacks
`evdev_drv.so` and `libinput_drv.so` are not present on hurd-amd64:
`/usr/lib/xorg/modules/input/` carries only `inputtest_drv.so`,
`kbd_drv.so`, `mouse_drv.so`, `synaptics_drv.so`, and there are no
`xserver-xorg-input-evdev` or `xserver-xorg-input-libinput` binary
packages on hurd-amd64 (only `-dev` / `-doc` shadow lines appear).

GEOS unblocks itself today by spawning Xvfb on Hurd instead of real
Xorg: pid1 spawns `/usr/bin/Xvfb :99 -screen 0 1024x768x24` and
EXWM 0.33 + xelb 0.20 on emacs-lucid 30.2 attach to it unchanged
from the Linux path.  this gets the editor-as-WM story live on
Hurd without waiting on the input-driver gap.  it does not get us
hardware-attached display.

i am the GEOS author.  this file is my upstream-ready writeup of
the gap and two remediation paths.

## ground truth (probe receipt)

receipt: `docs/runlogs/2026-05-21-hurd-xorg-probe.md`, probes E3,
E4, and I.

probe E3 (Xorg launch with `Driver "dummy"`):

    [295.286] (II) Using input driver 'mouse' for '<default pointer>'
    [295.286] (II) <default pointer>: Setting Device option to "/dev/mouse"
    [295.286] (II) XINPUT: Adding extended input device "<default pointer>" (type: MOUSE, id 6)
    [295.287] (II) Using input driver 'kbd' for '<default keyboard>'
    [295.287] (II) XINPUT: Adding extended input device "<default keyboard>" (type: KEYBOARD, id 7)
    [295.287] (EE)
    Fatal server error:
    [295.288] (EE) Cannot set event mode on keyboard (Bad file descriptor)

`Xwrapper.config` is `allowed_users=anybody`, so this is not a
permissions failure.  the chrdev rejects the ioctl because it has
no handler.

probe E4 (driver inventory):

    /usr/lib/xorg/modules/input/
      inputtest_drv.so
      kbd_drv.so
      mouse_drv.so
      synaptics_drv.so

no `evdev_drv.so`, no `libinput_drv.so`.

    apt-cache search '^xserver-xorg-input'
      xserver-xorg-input-{all,kbd,mouse,synaptics,elographics,mutouch}
      (no -evdev or -libinput binary packages on hurd-amd64)

probe I (input-device tree):

    /dev/input        not present
    /dev/kbd          /hurd/symlink cons/kbd
    /dev/mouse        /hurd/symlink cons/mouse
    /dev/cons/kbd     /hurd/chrdev 156 33685736
    /dev/cons/mouse   /hurd/chrdev 156 33685736

no `/dev/input/event*` tree.  this is exactly why no `evdev_drv.so`
ships: evdev's entire model is `read()` of `struct input_event`
records out of `/dev/input/eventN`, and that surface does not exist
on Hurd.  keyboard and mouse instead surface through gnumach's
console translator under `/dev/cons/`.

## remediation path (a): port evdev to hurd-amd64

shorter-term realistic fix.  Debian packaging task.

scope sketch:

  - `xserver-xorg-input-evdev` is arch-restricted in
    `debian/control` to architectures that ship `/dev/input/eventN`;
    a hurd-amd64 build needs the Linux-specific code paths either
    ported or stubbed, then a one-line arch-list addition plus a
    buildd run.
  - the load-bearing dependency is the `/dev/input/eventN` +
    `struct input_event` surface.  the lower-effort variant is a
    shim translator that exposes `/dev/input/event0` on top of
    the existing `/dev/cons/kbd` and `/dev/cons/mouse`,
    marshalling chrdev events into `struct input_event` records
    on each read().  evdev itself stays unchanged.  the alternative
    is patching evdev with a `#ifdef __GNU__` codepath that talks
    `/dev/cons/*` directly and does the scancode-to-keysym
    translation in-driver.  more work, fewer translators.
  - libinput is a strict superset of evdev (multi-touch, gestures).
    evdev alone is enough to unblock the GEOS EXWM-on-real-Xorg
    story for the first cut.

estimation: weeks for the shim variant, longer for the in-driver
port.  the packaging task goes on `debian-hurd@lists.debian.org`
where the people who would land it are.

## remediation path (b): teach gnumach the evdev interface

longer-term, more invasive, lives in gnumach.  two variants: extend
the console translator at `/dev/cons/*` to implement the Linux-style
"set event mode" ioctl that `kbd_drv.so` issues plus the
`KDGKBMODE` / `KDSKBMODE` family (smallest change, existing
`kbd_drv.so` works unmodified), or add a Hurd-native `/dev/input/`
surface exposing `event0` with `struct input_event` records (what
evdev expects across Linux and BSD).  either touches the gnumach
console driver where the `chrdev 156 33685736` major / minor pair
lives.  estimation: months, because gnumach driver changes affect
every booting Hurd VM.

## suggested upstream destinations

path (a) goes on `debian-hurd@lists.debian.org` for the packaging
discussion, then a salsa MR against `xserver-xorg-input-evdev`
once the upstream evdev change lands; optionally
`xorg-devel@lists.x.org` if the evdev change is non-trivial enough
to want upstream X.org buy-in.  path (b) goes on `bug-hurd@gnu.org`
for the gnumach console translator extension.  i would prefer (a)
first as the unblock and (b) later as the cleaner fix; (a) alone
is enough to retire the Xvfb workaround.

## status in GEOS

pid1 spawns Xvfb on Hurd (v0.9.8) instead of real Xorg, reusing the
Linux dev-host spawn path.  EXWM 0.33 + xelb 0.20 on emacs-lucid
30.2 attach to it unchanged (v0.9.10 live-verified on canonical
Debian Hurd 0.9: `_NET_SUPPORTING_WM_CHECK` points at the EXWM
identity window, xterm and xclock appear under the EXWM container
hierarchy with WM_CLASS and `_NET_WM_PID` set).  the four apt
prereqs (`xvfb`, `emacs-lucid`, `elpa-exwm`, `elpa-xelb`) are not
in the canonical image; a future v1.x apt-image flavor bundles
them.  native-Xorg-on-Hurd work is blocked on upstream paths (a)
and (b); no GEOS-side change buys us a fix.

HURD_PORT.md lines 90-112 carry the current verdict with pointers
to the xorg probe receipt above.

## To file (debian-hurd, packaging path a)

- destination: `debian-hurd@lists.debian.org` (the Debian Hurd
  porters list; this is the packaging discussion that has to
  happen before any salsa MR against `xserver-xorg-input-evdev`).
- subject line: `[debian-hurd] no evdev / libinput on hurd-amd64; native Xorg blocked on kbd_drv.so + /dev/cons ioctl gap`
- body header:

  on Debian GNU/Hurd 0.9 (xserver-xorg-core 2:21.1.11-1, hurd
  1:0.9.git20230520-7, gnumach 1.8+git20230410-1), native Xorg
  cannot start: it walks dummy-driver init, GLX / DRISWRAST init,
  all 23 extension inits, mouse input init, then dies in
  `kbd_drv.so` with
  `Cannot set event mode on keyboard (Bad file descriptor)`.
  `kbd_drv.so` issues a Linux-style set-event-mode ioctl against
  `/dev/cons/kbd` (a `/hurd/chrdev 156 33685736` translator) and
  the chrdev returns EBADF.  the fallbacks evdev and libinput are
  not packaged for hurd-amd64: `/usr/lib/xorg/modules/input/`
  carries only `inputtest_drv.so`, `kbd_drv.so`, `mouse_drv.so`,
  `synaptics_drv.so`; `apt-cache search '^xserver-xorg-input'`
  lists no `-evdev` and no `-libinput` binary packages.  user
  impact: no native X session on real hardware (GEOS runs Xvfb
  as a workaround, EXWM attaches and works, but there is no
  hardware-attached display).  the packaging ask is to either
  port evdev to hurd-amd64 (a shim translator that maps
  `/dev/cons/*` events into `struct input_event` records is the
  lower-effort variant; an in-driver `__GNU__` codepath is the
  alternative) or pick up an existing port if one exists on the
  debian-hurd side.

## Patch sketch (not yet a working diff)

```pseudo-diff
/* lower-effort variant: a shim translator that exposes
   /dev/input/event0 on top of the existing /dev/cons/kbd and
   /dev/cons/mouse, marshalling chrdev events into
   struct input_event records on each read().  evdev itself stays
   unchanged.  */

--- hurd/evdev-shim/main.c  (new)
+++ hurd/evdev-shim/main.c
@@
+/* evdev shim translator.  attached via:
+     settrans -c /dev/input/event0 /hurd/evdev-shim --source /dev/cons/kbd
+     settrans -c /dev/input/event1 /hurd/evdev-shim --source /dev/cons/mouse
+   each read() returns struct input_event records (see
+   <linux/input.h>), marshalled from the underlying chrdev's
+   scancode / button stream.  */

--- debian/control (xserver-xorg-input-evdev)
+++ debian/control (xserver-xorg-input-evdev)
@@
-Architecture: linux-any kfreebsd-any
+Architecture: linux-any kfreebsd-any hurd-amd64
```

- reproduction steps (canonical Debian GNU/Hurd 0.9, native QEMU
  console, not Xvfb):

  1. boot the canonical image to a text console.
  2. `apt install xserver-xorg-core xserver-xorg-input-kbd
      xserver-xorg-input-mouse xinit`
  3. write a one-line xorg.conf with `Driver "dummy"` for the
     screen and the default keyboard / mouse stanzas.
  4. `startx 2>&1 | tee /tmp/xorg.log`
  5. observe the log ends with
     `Fatal server error: Cannot set event mode on keyboard
     (Bad file descriptor)` after `Adding extended input device
     "<default keyboard>"`.
  6. `ls /usr/lib/xorg/modules/input/` returns exactly
     `inputtest_drv.so kbd_drv.so mouse_drv.so synaptics_drv.so`.
  7. `ls /dev/input/` returns ENOENT.

- GEOS runlog: `docs/runlogs/2026-05-21-hurd-xorg-probe.md`
  (probes E3, E4, I).

filed-by: Borja Tarraso <borja.tarraso@member.fsf.org>

## To file (bug-hurd, gnumach console route path b)

- destination: `bug-hurd@gnu.org` (or the Savannah `hurd` tracker
  at https://savannah.gnu.org/bugs/?group=hurd; gnumach lives in
  the same tree).
- subject line: `[gnumach] /dev/cons/kbd rejects kbd_drv.so set-event-mode ioctl with EBADF; please implement KDSKBMODE or expose /dev/input/event*`
- body header:

  on Debian GNU/Hurd 0.9 (gnumach 1.8+git20230410-1, hurd
  1:0.9.git20230520-7), Xorg's `kbd_drv.so` cannot bring up the
  console keyboard because the gnumach console translator at
  `/dev/cons/kbd` (`/hurd/chrdev 156 33685736`) returns EBADF
  for the Linux-style set-event-mode ioctl that `kbd_drv.so`
  issues.  user impact: no native Xorg on real hardware, even
  with the `kbd` input driver that hurd-amd64 does package
  (since evdev / libinput are not packaged for hurd-amd64,
  `kbd_drv.so` is the only path).  request: either teach the
  gnumach console translator to honour the `KDGKBMODE` /
  `KDSKBMODE` ioctl family that `kbd_drv.so` issues (smallest
  change, existing `kbd_drv.so` works unmodified), or expose a
  Hurd-native `/dev/input/event0` surface so evdev can be ported
  unchanged.  the debian-hurd packaging side of the same issue
  is filed at debian-hurd@lists.debian.org (subject above) so the
  two threads stay linked.

## Patch sketch (not yet a working diff)

```pseudo-diff
--- gnumach: i386/i386at/kd.c  (console keyboard driver)
+++ gnumach: i386/i386at/kd.c
@@ kd_ioctl (...)
+    case KDGKBMODE:
+      *(int *)data = current_kb_mode;  /* K_RAW | K_XLATE | K_MEDIUMRAW | K_UNICODE */
+      return 0;
+    case KDSKBMODE:
+      if (*(int *)data not in { K_RAW, K_XLATE, K_MEDIUMRAW, K_UNICODE })
+        return EINVAL;
+      current_kb_mode = *(int *)data;
+      /* tell the rest of the driver to stop translating scancodes
+         when K_RAW / K_MEDIUMRAW is selected, which is what
+         kbd_drv.so wants so X.org can do its own keymap.  */
+      return 0;
```

- reproduction steps: same as the debian-hurd filing above (steps
  1 through 5 reproduce the EBADF; step 6 confirms the driver
  inventory; step 7 confirms the absent `/dev/input/` tree).
- GEOS runlog: `docs/runlogs/2026-05-21-hurd-xorg-probe.md`
  (probes E3, E4, I).

filed-by: Borja Tarraso <borja.tarraso@member.fsf.org>
