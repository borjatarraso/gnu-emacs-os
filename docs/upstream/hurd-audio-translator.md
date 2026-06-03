<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

<!-- upstream deferral, drafted 2026-05-30, covers HURD_PORT.md row 280 -->

# Debian GNU/Hurd 0.9 ships no native audio translator

## summary

GEOS has a `*audio*` buffer that lists sound cards, sinks, sources,
and current volume.  on Linux it parses `/proc/asound/` and shells
out to pactl when pulseaudio is up.  on Debian GNU/Hurd 0.9 the
buffer correctly reports "no cards visible" because there is no
audio surface to read.  the gap is in upstream Hurd, not in GEOS.

specifically:

  - `/hurd/` ships 74 translator binaries.  zero match
    `audio|snd|dsp|sound|mixer|oss|alsa` under any case fold.
  - `/dev/` has no audio nodes.  `/dev/dsp`, `/dev/audio`,
    `/dev/mixer`, `/dev/snd`, `/dev/sound` are all ENOENT.
  - `/servers/` has 13 entries (acpi, bus, crash, crash-dump-core,
    crash-kill, crash-suspend, default-pager, exec, geos-auth,
    password, shutdown, socket, startup).  no audio server.
  - `/proc/` has no audio entry, no `asound` analogue.
  - gnumach boot transcript is silent on audio: `dmesg`,
    `/var/log/dmesg`, `/var/log/syslog` match zero hits for
    `audio|snd|sound|dsp|oss|alsa`.  no audio hardware enumerated.
  - `dpkg -L hurd` matches zero files with audio names.  the
    Debian `hurd` source package, which ships every translator in
    `/hurd/`, contains no audio code path at all.

i am the GEOS author.  this file is my upstream-ready writeup
documenting the gap and three increasing-effort paths forward.

## ground truth (probe receipt)

receipt: `docs/runlogs/2026-05-21-hurd-audio-probe.md`.  H1, H2, H3,
H4 all falsified end-to-end.  H5 partially confirmed: ALSA on
hurd-amd64 is config-only (alsa-topology-conf, alsa-ucm-conf,
alsa-ucm-conf-asahi) and OSS is shim-only (oss-compat, oss-preserve);
no libasound2, no alsa-utils, no oss4-base.  H6 confirmed:
pulseaudio 17.0+dfsg1-2.1 and sndio are both installable from
debian-ports sid/main on hurd-amd64.

## three levels of remediation

### level (a): apt-installed pulseaudio path

shipped today, lives in GEOS userland.  v0.7 already promoted audio
to the userland layer; `user/userland/audio.el` drives pactl when
pulseaudio is up.  on Hurd the user runs `apt install pulseaudio`,
starts the daemon, and the same elisp arm works.  there is no
hardware on the canonical QEMU stdvga image, so the path exercises
pulseaudio's null-sink and module-pipe-source rather than real
playback.

no upstream change needed.  this is the pragmatic best-available
path today.  a future v1.x apt-image flavor bundles pulseaudio so
the user does not have to install it by hand.

### level (b): native /hurd/audio translator

v2.x scope.  requires a real device driver layer underneath gnumach
since today's gnumach enumerates no audio hardware at boot.

scope sketch, written for a hurd hacker:

  - shape: a new `/hurd/audio` translator binary, structurally
    parallel to `/hurd/pfinet` and `/hurd/streamio`.  attaches to
    `/dev/dsp` (and friends) via settrans; client opens the device
    node and reads/writes PCM with ioctls for format / rate /
    channel selection.
  - OSS API is the lowest-common-denominator target.  Linux's
    OSS-style ioctl set (SNDCTL_DSP_*) is well-documented and
    matches the file-IO + ioctl shape the Hurd device interface
    already serves for other translators.
  - the hard part is the driver layer.  gnumach has no AC97 /
    HDA / SB16 driver enumeration today.  options:
      - port a NetBSD audio driver via the rumpkernel path
        (rumpdisk / rumpnet are the precedent on hurd-amd64; a
        rumpaudio translator would be a natural sibling).
      - write a native gnumach driver against the QEMU
        intel-hda or ac97 device first to get a known-good
        target before any real-hardware bring-up.
  - userland: libpulse, libcanberra, sndio are useful comparison
    points for the API surface a translator should expose; sndio
    in particular is small enough to inform the IPC shape.
  - integration: settrans `/dev/dsp /hurd/audio` at boot, exposed
    through `/servers/socket/audio` (or similar) for daemon-style
    clients.  GEOS would gain a port_caps slot
    `port->audio_enumerate` and `port->audio_set_volume`; the
    elisp arm in `user/userland/audio.el` already has the buffer
    contract.

estimation: large.  this is full new-translator work plus a
new gnumach driver subsystem.  multi-month even with the rumpkernel
shortcut.

### level (c): Mach-RPC sound server

v2.x+ scope.  parallel to pulseaudio's daemon model: a Hurd-native
sound server holds the device, clients talk to it over Mach RPC for
volume / sink switching / per-app routing.  benefits over level (b)
are the same as pulseaudio's over raw OSS: per-application volume,
device routing, format conversion, network audio.  builds on top of
level (b)'s translator.

i would not recommend starting at (c).  the level (b) translator
is the prerequisite, and pulseaudio (level a) already covers the
multi-client / per-app-volume use case once installed.

## suggested upstream destination

  - discussion on `bug-hurd@gnu.org` before any patch attempt.
    the level (b) scope is large enough that the design wants
    consensus first: rumpaudio vs native gnumach driver, OSS vs
    ALSA-style API, settrans path under `/dev/` vs `/servers/`.

## status in GEOS

  - `user/userland/audio.el` Linux arm: shipped (v0.7).
  - `user/userland/audio.el` Hurd arm: routes through
    `geos-port-unimplemented`, returns nil, `*audio*` renders
    "no cards visible".  shipped at v0.9.4 doc-flip.
  - v1.x apt-image flavor: deferred, bundles pulseaudio so the
    pactl path comes up zero-config.
  - level (b) and (c) work: deferred to v2.x, lives upstream.

HURD_PORT.md row 280 carries the "deferred at translator level"
verdict with a pointer to the audio probe receipt above.

## To file (bug-hurd, design discussion)

- destination: `bug-hurd@gnu.org` (the canonical inbox; also
  reachable as the Savannah `hurd` tracker at
  https://savannah.gnu.org/bugs/?group=hurd if a tracker entry is
  preferred over a list post).
- subject line: `[RFC] no native audio translator on Debian GNU/Hurd 0.9; design discussion for /hurd/audio`
- body header:

  on Debian GNU/Hurd 0.9 (hurd 1:0.9.git20230520-7, gnumach
  1.8+git20230410-1), there is no native audio surface.  `/hurd/`
  ships 74 translator binaries and none match
  `audio|snd|dsp|sound|mixer|oss|alsa`; `/dev/` has no audio
  nodes; `/servers/` enumerates 13 entries and none are audio;
  gnumach boot enumerates no audio hardware in dmesg.  the user
  impact: no application that opens an audio device works
  (everything from `aplay` through pulseaudio's real-hardware
  sinks).  the pragmatic workaround is `apt install pulseaudio`,
  which installs cleanly on hurd-amd64 and exercises null sinks /
  module-pipe-source paths, but cannot reach hardware.  this RFC
  asks for design feedback on three remediation levels: apt-image
  bundling of pulseaudio (no upstream change), a native
  `/hurd/audio` translator (large), and a Mach-RPC sound server
  (larger).

## Patch sketch (not yet a working diff)

```pseudo-diff
/* new translator binary, structurally parallel to /hurd/pfinet
   and /hurd/streamio.  attaches to /dev/dsp (and friends) via
   settrans; client opens the device node and reads/writes PCM
   with ioctls for format / rate / channel selection.  */

--- hurd/audio/main.c  (new)
+++ hurd/audio/main.c
@@
+/* audio translator: serves /dev/dsp and friends.  OSS
+   SNDCTL_DSP_* ioctls for format / rate / channel; read/write
+   for PCM; attaches via settrans /dev/dsp /hurd/audio.  */
+int
+main (int argc, char **argv)
+{
+  /* parse args (device backend: rumpaudio vs native gnumach
+     driver), bind the translator control port, enter the
+     server loop.  */
+}

--- gnumach: device/audio.c  (new, driver layer)
+++ gnumach: device/audio.c
@@
+/* either: port a NetBSD audio driver via the rumpkernel path
+   (rumpdisk / rumpnet are the precedent on hurd-amd64; rumpaudio
+   is the natural sibling); or write a native gnumach driver
+   against the QEMU intel-hda / ac97 device first to get a
+   known-good target before any real-hardware bring-up.  */
```

- reproduction steps (canonical Debian GNU/Hurd 0.9):

  1. boot the canonical image.
  2. `ls /hurd/ | grep -iE 'audio|snd|dsp|sound|mixer|oss|alsa'`
     prints nothing.
  3. `ls /dev/dsp /dev/audio /dev/mixer /dev/snd /dev/sound`
     returns ENOENT on every path.
  4. `ls /servers/` lists 13 names; none are audio.
  5. `dmesg | grep -iE 'audio|snd|sound|dsp|oss|alsa'` returns
     no matches.
  6. `dpkg -L hurd | grep -iE 'audio|snd|sound|dsp|oss|alsa'`
     returns no matches.
  7. for the pulseaudio workaround:
     `apt install pulseaudio && pulseaudio --start && pactl list short sinks`
     succeeds with a null sink; no hardware is reachable.

- GEOS runlog: `docs/runlogs/2026-05-21-hurd-audio-probe.md`
  (H1 / H2 / H3 / H4 falsified end-to-end; H5 partial; H6
  confirmed for pulseaudio 17.0+dfsg1-2.1 and sndio).

filed-by: Borja Tarraso <borja.tarraso@member.fsf.org>

## To file (debian-hurd, packaging side)

- destination: `debian-hurd@lists.debian.org` (the Debian Hurd
  porters list; the maintainers who would land an apt-image
  flavor with pulseaudio bundled live here).
- subject line: `[debian-hurd] no native audio translator on hurd-amd64; suggesting pulseaudio in the live-image task`
- body header:

  on Debian GNU/Hurd 0.9 there is no audio surface in the base
  install (no `/hurd/audio*`, no `/dev/dsp`, no `/servers/audio`,
  no gnumach driver enumeration).  pulseaudio 17.0+dfsg1-2.1 from
  debian-ports sid/main is installable on hurd-amd64 and works
  for null-sink / module-pipe-source paths; the gap is purely
  that it is not bundled in the canonical image.  the proposal
  is to add pulseaudio (and the userland that goes with it) to a
  future hurd-amd64 live-image flavor so audio-aware userland
  comes up zero-config.  the deeper translator / driver work is
  filed separately on `bug-hurd@gnu.org`.

- reproduction steps and probe pointer: same as the bug-hurd
  filing above; GEOS runlog
  `docs/runlogs/2026-05-21-hurd-audio-probe.md`.

filed-by: Borja Tarraso <borja.tarraso@member.fsf.org>
