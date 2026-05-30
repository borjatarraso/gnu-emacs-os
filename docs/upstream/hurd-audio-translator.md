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
