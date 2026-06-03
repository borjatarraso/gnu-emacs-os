<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

<!-- 2026-05-21: v0.9.8 Xorg + spawn-surface probe on Debian Hurd 0.9 -->

# 2026-05-21: Xorg probe pins Xvfb-only path and corrects the prctl analogue

this slice is the read-only probe i ran on the canonical Debian
GNU/Hurd 0.9 VM to close the v0.9.8 open-work item "Xorg spawn path
on Hurd (proc_setowner analogue of prctl)". it follows the audio
probe at docs/runlogs/2026-05-21-hurd-audio-probe.md and the v0.9.6
dmesg-prime verify at docs/runlogs/2026-05-21-v096-dmesg-prime-verify.md,
both same date, same series. the goal here is twofold: figure out
whether GEOS can spawn a real X server on hurd-amd64 today, and
verify what primitive replaces Linux's `prctl(PR_SET_PDEATHSIG)` so
pid1 can wire a "die when parent dies" link on a spawned X. the
probe is again the whole point; the v0.9.7 release memory carries a
load-bearing assumption ("proc_setowner is the analogue of prctl")
that turns out to be wrong, and i would rather pin the correction
in a receipt than ship a port_hurd.c slot against the wrong RPC.

## Verdict

PROBE PASS with a sharp split on the load-bearing claim. native
Xorg on hurd-amd64 is blocked on the input side, not the video
side: Xorg with `Driver "dummy"` walks through GLX init, all 23
extension inits, and mouse input init, then dies on `kbd_drv.so`
issuing a Linux-style "set event mode" ioctl against /dev/cons/kbd,
which the gnumach console-translator-backed chrdev returns EBADF
for. there is no `evdev_drv.so` and no `libinput_drv.so` under
/usr/lib/xorg/modules/input/ on this image, and no
xserver-xorg-input-evdev / xserver-xorg-input-libinput binary
package on hurd-amd64 (only *-dev / *-doc shadow lines). EXWM on
Xvfb is unblocked: `Xvfb :99 -screen 0 800x600x24` came up clean,
xdpyinfo against it returns 23 extensions including RANDR /
COMPOSITE / GLX, elpa-exwm 0.33-1 and elpa-xelb 0.20-1 are both
Candidate on hurd-amd64, Emacs 30.2 has `modules-built-in=t`. that
is enough surface to ship EXWM on Hurd against a virtual
framebuffer today.

the PDEATHSIG question lands somewhere different from what the
v0.9.7 open-work note assumed. `prctl.h` is not on this image and
there is no `PR_SET_PDEATHSIG` analogue under any name. the Hurd
primitive that actually carries the same semantic is
`MACH_NOTIFY_DEAD_NAME` requested via `mach_port_request_notification`,
not `proc_setowner` (which is marked **Deprecated** in
/usr/include/x86_64-gnu/hurd/process.defs:127). this receipt
records the correction explicitly so the v0.9.8 slot-shape work
and the HURD_PORT.md row do not carry the wrong primitive
forward.

## Test-harness amendments

two trip-wires the next verifier should not step on.

1. on Debian Hurd 0.9 the Mach + Hurd `.defs` files live under
   `/usr/include/x86_64-gnu/{mach,hurd}/`, not
   `/usr/include/{mach,hurd}/`. probe G initially looked under the
   short path, found nothing, and the false start showed up as a
   one-line empty result before i corrected the path and re-ran.
   recording the canonical path here so the next probe goes
   straight to it.
2. probe E3's trailing `pgrep -af Xorg` returns exit 1 by design.
   it runs after the Xorg under test has already died from the
   kbd_drv ioctl failure; "no process found" is the expected
   outcome, not a probe error.

## VM build environment

```
uname:           GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9 x86_64 GNU
debian_version:  forky/sid
gnumach cmdline: gnumach root=part:2:device:wd0
xorg-server:     2:21.1.22-1 (xserver-xorg-core upgraded mid-probe from 2:21.1.21-1)
xvfb:            2:21.1.22-1 (newly installed)
xinit:           X.Org X Server 1.21.1.22
emacs:           GNU Emacs 30.2, modules-built-in=t
```

canonical image at `/home/overdrive/hurd-vm/work.img` mtime
preserved at `2026-05-18 13:34:31.700204970 +0300` across the run
(verified before and after, byte-identical). qemu pid 380884 was
SIGTERMed at teardown, down after 2s, host port 2222 free, no
qemu process left behind. snapshot
`/tmp/geos-hurd-xorg-probe-1779346658.qcow2` and serial log
`/tmp/geos-hurd-xorg-probe-1779346658.serial` retained on disk per
default. ssh handshake usable 69s into the boot (11th poll at 4s
intervals).

## Probe A: X server + EXWM package availability

`apt-cache search '^xserver-xorg'` lists xserver-xorg-core,
xserver-xorg-input-{all,kbd,mouse,synaptics,elographics,mutouch},
xserver-xorg-video-{all,dummy,fbdev,cirrus,mach64,mga,neomagic,r128,savage,geode},
and xserver-xorg-legacy. there is NO xserver-xorg-input-evdev and
NO xserver-xorg-input-libinput binary package on hurd-amd64; only
the `-dev` / `-doc` shadow lines appear. xserver-xorg-core
Installed 2:21.1.21-1, Candidate 2:21.1.22-1 from
debian-ports sid hurd-amd64. xserver-xorg Installed 1:7.7+26.
xvfb Candidate 2:21.1.22-1 (not installed at probe start).
xserver-xorg-video-dummy Candidate 1:0.4.0-1 (not installed).
emacs 1:30.2+1-2 installed, Candidate 1:30.2+1-3. emacs-nox
1:30.2+1-2 installed. exwm Candidate 0.3 (hurd-amd64). dpkg -l
confirms xorg, xserver-xorg, xserver-xorg-core 2:21.1.21-1,
xserver-xorg-input-{all,kbd,mouse,synaptics}, xserver-xorg-legacy
2:21.1.21-1, xserver-xorg-video-{all,fbdev,vesa},
x11-{apps,utils,session-utils,xkb-utils,xserver-utils} are
already installed in the canonical image.

## Probe B: X11 client libs

libx11-dev 2:1.8.13-1, libxcb1-dev 1.15-1+b1, libxext-dev
2:1.3.4-1+b4, libxrandr-dev 2:1.5.4-1+b4, libxinerama-dev
2:1.1.4-3+b5 all installable on hurd-amd64. none installed by
default. enough to compile xelb's protocol bindings if needed,
though elpa-xelb 0.20-1 already ships pre-compiled on hurd-amd64
(see probe K).

## Probe C: install Xvfb

`apt-get install -y --no-install-recommends xvfb xauth` fetched
xvfb 2:21.1.22-1 from debian-ports sid/main hurd-amd64.
xserver-common and xserver-xorg-legacy upgraded
2:21.1.21-1 -> 2:21.1.22-1 as side effects (mismatch with the
installed xserver-xorg-core would have been flagged otherwise).
/usr/bin/Xvfb present after install. `Xvfb -version` is not a
recognized flag in 21.1.22 (banner reports the version anyway).
/usr/bin/xauth version 1.1.2.

## Probe D: Xvfb up + xdpyinfo against it

`Xvfb :99 -screen 0 800x600x24 &` returned bg pid 920. xvfb.out
and xvfb.err both empty. `pgrep -af Xvfb` confirmed alive after
5s. `DISPLAY=:99 xdpyinfo | head -40` returned exit 0 with:

```
name of display: :99
version number: 11.0
vendor string: The X.Org Foundation
vendor release number: 12101022
X.Org version: 21.1.22
maximum request size: 16777212 bytes
number of extensions: 23
BIG-REQUESTS Composite DAMAGE DOUBLE-BUFFER GLX
Generic-Event-Extension MIT-SCREEN-SAVER MIT-SHM Present
RANDR RECORD RENDER SECURITY SHAPE SYNC X-Resource XC-MISC
XFIXES XINERAMA XInputExtension ...
```

clean Xvfb up. RANDR and COMPOSITE present, which is the set EXWM
needs at minimum. teardown via `pkill Xvfb` followed by
`pgrep -af Xvfb` returning empty.

## Probe E: real Xorg install + launch with dummy driver

E1: `apt-get install -y --no-install-recommends xserver-xorg-core
xserver-xorg-video-dummy xinit` installed
xserver-xorg-video-dummy 1:0.4.0-1 and upgraded
xserver-xorg-core to 2:21.1.22-1. E2: /usr/bin/Xorg present,
banner reports `X.Org X Server 1.21.1.22`, X Protocol Version 11
Revision 0, Current Operating System matches the VM uname.
/usr/bin/xinit version banner same.

E3: wrote `/etc/X11/xorg.conf.dummy` with `Driver "dummy"`, ran
`Xorg :55 -config /etc/X11/xorg.conf.dummy -logfile /tmp/xorg.log
-noreset &`, slept 6s, inspected the logfile. the decisive
fragment:

```
[295.286] (II) Using input driver 'mouse' for '<default pointer>'
[295.286] (II) <default pointer>: Setting Device option to "/dev/mouse"
[295.286] (II) XINPUT: Adding extended input device "<default pointer>" (type: MOUSE, id 6)
[295.287] (II) Using input driver 'kbd' for '<default keyboard>'
[295.287] (II) XINPUT: Adding extended input device "<default keyboard>" (type: KEYBOARD, id 7)
[295.287] (EE)
Fatal server error:
[295.288] (EE) Cannot set event mode on keyboard (Bad file descriptor)
[295.288] (EE)
[295.290] (EE) Server terminated with error (1). Closing log file.
```

Xorg makes it through dummy-driver init, GLX/DRISWRAST init, all
23 extension inits, mouse input driver init, then dies on
`kbd_drv.so` attempting an ioctl ("set event mode") against
/dev/kbd, which resolves to /dev/cons/kbd, which is a `/hurd/chrdev
156 33685736` translator returning EBADF for the Linux-style
kbd-event-mode ioctl. Xwrapper.config is `allowed_users=anybody`,
so this is not a permissions failure, it is a missing
ioctl-handler in the gnumach console translator. trailing
`pgrep -af Xorg` returns 1 (expected; Xorg already dead).

E4: `ls /usr/lib/xorg/modules/input/` shows only
inputtest_drv.so, kbd_drv.so, mouse_drv.so, synaptics_drv.so. NO
evdev_drv.so, NO libinput_drv.so. `showtrans /dev/cons/kbd`
returns `/hurd/chrdev 156 33685736`, confirming the chrdev
translator is what kbd_drv is talking to.

## Probe F: prctl / PDEATHSIG surface (Linux side)

F1: `cat /usr/include/sys/prctl.h` returns "No such file or
directory". `find /usr/include -name prctl.h` returns empty.
`grep -lrE 'PR_SET_PDEATHSIG|PDEATHSIG' /usr/include` returns
empty. `apropos pdeath` returns "nothing appropriate". FALSIFIED.
there is no `prctl`-shaped header on hurd-amd64.

F2: the Mach / Hurd-side surface that is relevant:

```
/usr/include/x86_64-gnu/mach/mach.defs:79
  routine task_terminate(...)
/usr/include/x86_64-gnu/mach/mach.defs:455
  routine task_set_special_port(task, which_port, special_port)
/usr/include/x86_64-gnu/mach/notify.defs:106
  MACH_NOTIFY_DEAD_NAME (0110)
  simpleroutine mach_notify_dead_name(...)
/usr/include/x86_64-gnu/mach/notify.defs:90
  MACH_NOTIFY_NO_SENDERS (0106)
  simpleroutine mach_notify_no_senders(...)
/usr/include/x86_64-gnu/mach/mach_port.defs:247
  routine mach_port_request_notification(...)
/usr/include/x86_64-gnu/hurd/process.defs:127
  routine proc_setowner (...)              // marked "Deprecated"
/usr/include/x86_64-gnu/hurd/process.defs:216
  routine proc_mark_exec (...)             // exec tracking, not death
```

this is the load-bearing correction for the v0.9.8 slot shape.
`proc_setowner` is **Deprecated** at the .defs level; it is not a
viable target for new pid1 code. `proc_mark_exec` is exec
tracking (parent learns the child exec'd a new image), not parent
death. the right primitive for "die when parent dies" on Hurd is:
pid1 holds a notify port, hands the child a send-right on it; the
child calls `mach_port_request_notification` against pid1's task
port with `MACH_NOTIFY_DEAD_NAME`; when pid1 dies the dead-name
notification fires into the child, which then self-terminates via
`task_terminate` on its own task port. clean Mach idiom, no Hurd
process server involvement needed.

## Probe G: proc / process Mach RPC surface

first pass false-started on the wrong include path (see
test-harness amendment 1). re-run under
`/usr/include/x86_64-gnu/` returned:

```
process.defs:127         routine        proc_setowner       (Deprecated)
process.defs:216         routine        proc_mark_exec
process_request.defs:129 simpleroutine  proc_setowner_request
process_request.defs:217 simpleroutine  proc_mark_exec_request
mach.defs:79             routine        task_terminate
mach.defs:455            routine        task_set_special_port
```

the first 80 routines of hurd/process.defs also include
`proc_set_init_task`, `proc_mark_important`,
`proc_make_task_namespace`, `proc_reassign`, `proc_pid2task`,
`proc_task2pid`. all addressable from pid1 if a future slot
needs them. nothing in this set replaces the dead-name notify
path for the PDEATHSIG semantic; it stays at
`mach_port_request_notification` + `MACH_NOTIFY_DEAD_NAME`.

## Probe H: IO permission / framebuffer

```
/dev/mem        crw-rw---- 0,0 (/hurd/storeio --no-cache mem)
/dev/fb*        not present
/dev/vga        not present
mach/x86_64/mach_i386.defs
  i386_io_perm_create + i386_io_perm_modify present
  i386_io_port_{add,remove,list} marked skip (removed)
```

combined with `task_set_special_port`, the i386_io_perm pair is
the only path Xorg has to do raw VGA/PCI MMIO on Hurd. the
absence of /dev/fb0 means vesa and fbdev drivers have nothing to
attach to under gnumach. storeio-wrapped /dev/mem is not the
Linux /dev/mem semantics Xorg's xf86OSLib paths expect. video
side is not the load-bearing block today (probe E proved
`Driver "dummy"` walks through to input init), but it is the
block that has to be cleared if a future v1.x slice wants real
hardware Xorg with cirrus / vesa.

## Probe I: input devices

```
/dev/input        not present
/dev/kbd          /hurd/symlink cons/kbd
/dev/mouse        /hurd/symlink cons/mouse
/dev/cons/kbd     /hurd/chrdev 156 33685736
/dev/cons/mouse   /hurd/chrdev 156 33685736
/dev/console      /hurd/term /dev/console device console
/dev/cons/vcs     -> /dev/vcs/1
```

no `/dev/input/event*` tree, which is why no `evdev_drv.so` ships
on hurd-amd64 (no kernel surface to read from). keyboard and
mouse are gnumach console-driver-backed chrdevs surfaced via
`/dev/cons`. this is exactly the surface `kbd_drv.so` cannot
drive (see probe E3). there are two ways to close this in
upstream:

- port `xf86-input-evdev` or `xf86-input-libinput` to Hurd with a
  /dev/cons backend, OR
- teach the gnumach console translator the Linux-style "set event
  mode" ioctl that `kbd_drv.so` issues.

neither is in scope for v0.9.8.

## Probe J: gnumach hardware enumeration

```
[1.0000050] pci0 at mainbus0 bus 0
[4.1600050] vendor 1234 product 1111 (VGA display, revision 0x02)
            at pci0 dev 2 function 0 not configured
[4.1600050] vendor 8086 product 100e (ethernet network, revision 0x03)
            at pci0 dev 3 function 0 not configured

lspci: 00:02.0 VGA compatible controller:
       Device 1234:1111 (rev 02)            # QEMU stdvga / bochs-dispi
/proc/bus/pci: not present
/servers/bus/pci/: present
  0000/ is the canonical pci-arbiter mount
ps: /hurd/pci-arbiter (pid 1184) running
```

PCI is reachable via the Hurd pci-arbiter translator under
`/servers/bus/pci`, not via the Linux `/proc/bus/pci` tree.
libpciaccess on Debian Hurd already targets `/servers/bus/pci`, so
the path is wired correctly for any future video-driver work; the
block at probe H is the framebuffer node, not the bus.

## Probe K: Emacs + EXWM / xelb surface

```
emacs version:       GNU Emacs 30.2
modules-built-in:    t
custom themes count: 23                     # batch elisp confirmed working
/usr/share/emacs:    no exwm, no xelb (only repo-local copies under /root/geos*/)
elpa-exwm:           Candidate 0.33-1 (hurd-amd64)
elpa-xelb:           Candidate 0.20-1 (hurd-amd64)
exwm metapackage:    Candidate 0.3 (hurd-amd64)
```

H6 confirmed in the strongest form: plain
`apt-get install elpa-exwm elpa-xelb` is sufficient on
hurd-amd64. dynamic-module loader is built in, so pid1-module.so
loads the same way it does on Linux (see
project_pid1_module_build memory for the build wrapper).

## Probe L: image identity reconfirm

```
GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9 x86_64 GNU
forky/sid
gnumach root=part:2:device:wd0
```

same image identity as the audio probe earlier today.

## Hypothesis verdicts

| H  | claim                                                                                       | outcome              | evidence                                                                 |
|----|---------------------------------------------------------------------------------------------|----------------------|--------------------------------------------------------------------------|
| H1 | a real Xorg binary is installable and launches on hurd-amd64                                | PARTIALLY CONFIRMED  | E1/E2: Xorg 1.21.1.22 installs and runs; E3: dies at kbd_drv "set event mode" EBADF; reaches GLX + all 23 ext inits + mouse init first |
| H2 | a video driver attaches under gnumach                                                       | CONFIRMED for dummy  | E3: dummy driver init completes cleanly; H: no /dev/fb0 so vesa/fbdev have nothing to attach to |
| H3 | an input driver attaches under gnumach                                                      | FALSIFIED for real HW | E3: kbd_drv ioctl EBADF on /dev/cons/kbd; E4: no evdev_drv.so / libinput_drv.so on disk; A: no -input-evdev / -input-libinput package on hurd-amd64; I: no /dev/input/event* tree |
| H4 | Xvfb is installable and launches cleanly                                                    | CONFIRMED            | C: xvfb 2:21.1.22-1 installs; D: Xvfb :99 up clean, xdpyinfo exit 0, 23 extensions including RANDR/COMPOSITE/GLX |
| H5 | `prctl(PR_SET_PDEATHSIG)` or any direct analogue header exists on hurd-amd64                | FALSIFIED            | F1: no sys/prctl.h, no PR_SET_PDEATHSIG match, no apropos hit            |
| H6 | `proc_setowner` is the correct Hurd analogue of PR_SET_PDEATHSIG                            | FALSIFIED            | F2/G: process.defs:127 marks proc_setowner Deprecated; proc_mark_exec is exec tracking, not death; correct primitive is MACH_NOTIFY_DEAD_NAME via mach_port_request_notification at mach_port.defs:247 + notify.defs:106 |
| H7 | EXWM + xelb are installable as Debian packages on hurd-amd64                                | CONFIRMED            | K: elpa-exwm 0.33-1 + elpa-xelb 0.20-1 + exwm 0.3 metapackage all Candidate; emacs 30.2 modules-built-in=t |
| H8 | the PCI bus is reachable from userspace for a future hardware video driver                  | CONFIRMED            | J: pci-arbiter pid 1184 running, /servers/bus/pci/0000/ mounted, libpciaccess uses this path on Debian Hurd |

## Decision-relevant points / slot shape

decision matrix for the v0.9.8 Xorg + spawn surface:

- **ship the Xvfb spawn slot in v0.9.8.** `port_hurd.c` gets a
  partial slot that does two things: spawn `/usr/bin/Xvfb :0
  -screen 0 1024x768x24` as a supervised child, and wire the
  child's death-link to pid1 via `MACH_NOTIFY_DEAD_NAME` requested
  through `mach_port_request_notification` against pid1's task
  port. on Linux the same seam is the existing
  `prctl(PR_SET_PDEATHSIG, SIGTERM)` call; the port_layer slot
  abstracts both. shape is a hybrid of v0.9.5 (shipped slot,
  small) and v0.9.6 / v0.9.7 (deferred-upstream on the
  unblockable parts).
- **defer native Xorg to v1.x as deferred-upstream.** the block
  is the input driver gap (probe E3 / E4 / I), not the video
  side. two upstream fix paths exist (evdev / libinput port, OR
  gnumach cons-translator ioctl); neither is in scope for v0.9.8
  and neither is on GEOS's hot path. HURD_PORT.md gets a new row
  pointing to this receipt, same shape as pfinet per-iface
  counters (main/8e5db44) and the audio row from earlier today.
- **correct the v0.9.7 release memory.** the open-work note that
  called the PDEATHSIG analogue "proc_setowner" is wrong (see H6
  + probe F2 evidence). the slot-shape doc and HURD_PORT.md row
  must reference `MACH_NOTIFY_DEAD_NAME` +
  `mach_port_request_notification`, not `proc_setowner`. this is
  the load-bearing correction this receipt is here to pin.
- **EXWM ships on Xvfb today, real-screen EXWM ships in v1.x.**
  user-visible behavior on Hurd in v0.9.8 is: pid1 spawns Xvfb,
  emacs connects DISPLAY=:0, exwm-enable runs, EXWM hosts emacs
  the same way it does on Linux except the X is virtual. that is
  the same "EXWM lives, video is virtual" shape Xvfb has on
  Linux dev hosts, so the userland code does not branch on
  kernel.

## Cleanup

```
qemu pid 380884    SIGTERMed, down after 2s
host port 2222     free (nc -z failed cleanly)
qemu processes     pgrep clean, none left
canonical image    /home/overdrive/hurd-vm/work.img
                   mtime 2026-05-18 13:34:31 preserved, byte-identical
snapshot           /tmp/geos-hurd-xorg-probe-1779346658.qcow2 retained
serial log         /tmp/geos-hurd-xorg-probe-1779346658.serial retained
raw probe outputs  /tmp/geos-hurd-xorg-probe-out/{A1..L}.{stdout,stderr}
                   retained
```

no canonical image mutation. snapshot + serial log + per-probe
outputs kept on disk per default for any follow-up.

## Paths

- canonical image: `/home/overdrive/hurd-vm/work.img`
- snapshot: `/tmp/geos-hurd-xorg-probe-1779346658.qcow2`
- serial log: `/tmp/geos-hurd-xorg-probe-1779346658.serial`
- env file: `/tmp/geos-hurd-xorg-probe.env`
- raw probe outputs: `/tmp/geos-hurd-xorg-probe-out/{A1..L}.{stdout,stderr}`

## Open follow-ons (do NOT block this slice's commit)

1. native Xorg on hurd-amd64 is gated by the input-driver gap.
   `kbd_drv.so` issues a Linux-style "set event mode" ioctl
   against /dev/cons/kbd which the gnumach console translator
   returns EBADF for; there is no `evdev_drv.so` or
   `libinput_drv.so` on hurd-amd64 to fall back to. two upstream
   fix paths: port `xf86-input-evdev` or `xf86-input-libinput` to
   Hurd with a /dev/cons backend, OR teach the gnumach cons
   translator the Linux-style kbd-event-mode ioctl. neither in
   scope for v0.9.8. next step: track upstream Debian Hurd
   input-driver work; queue a v1.x probe once one of the two
   paths lands.

2. v0.9.8 ships the Xvfb + DEAD_NAME path only. real Xorg with a
   real framebuffer is structurally possible on hurd-amd64
   (cirrus / vesa over `/servers/bus/pci` via libpciaccess, see
   probe J) but blocked on input (see follow-on 1) and on the
   absence of `/dev/fb0` (see probe H). recorded for v1.x. next
   step: when follow-on 1 unblocks, run a second probe targeting
   cirrus + libpciaccess + i386_io_perm to confirm the video side
   still walks.

3. the v0.9.7 release memory and any open-work note referencing
   "proc_setowner analogue of prctl" is wrong. the primitive is
   `MACH_NOTIFY_DEAD_NAME` requested via
   `mach_port_request_notification`, not `proc_setowner` (which
   is **Deprecated** at /usr/include/x86_64-gnu/hurd/process.defs:127).
   this receipt records the correction. next step: when v0.9.8
   ships, update HURD_PORT.md and the relevant memory file to
   point at the dead-name notify primitive and footnote this
   receipt's H6 row.
