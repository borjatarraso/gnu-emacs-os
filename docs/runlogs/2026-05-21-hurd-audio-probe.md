<!-- SPDX-License-Identifier: FSFAP -->

<!-- 2026-05-21: audio translator surface probe on Debian Hurd 0.9, all native hypotheses falsified, no port_hurd.c slot -->

# 2026-05-21: audio probe finds no native translator surface, closes deferred-upstream

this slice is the read-only probe i ran on the canonical Debian
GNU/Hurd 0.9 VM before adding any port_layer slot for the v0.9.7
audio surface. it follows the kmsg receipt at
docs/runlogs/2026-05-21-hurd-kmsg-probe.md and the pfinet
counters receipt referenced from main/a5486e1 and main/8e5db44.
the goal is to identify what `userland/audio.el` can read on Hurd
so the *audio* buffer renders something other than a Linux-only
`/proc/asound` parse error. probe-first is again the whole point:
the current parser assumes a procfs surface that simply does not
exist on this image, and i wanted to know whether the gap belongs
in `port_hurd.c` (write a new slot) or upstream (close as
deferred-upstream, same pattern pfinet per-iface counters used).

## Result

PROBE PASS. the load-bearing claim is that on Debian GNU/Hurd 0.9
there is no native audio translator surface in `/hurd`, no
audio Mach device exposed by gnumach, no `/dev/dsp` / `/dev/snd`
nodes, and no audio entry under `/servers` or `/proc`. H1 H2 H3
H4 are all falsified. H5 is partially confirmed: alsa and oss
packages exist on hurd-amd64 but are config-only (alsa) and
shim-only (oss) with no runtime driver. H6 is confirmed:
pulseaudio 17.0+dfsg1-2.1 and sndio are both installable from
debian-ports sid/main on hurd-amd64, just not bundled in the
canonical image.

slot-shape decision: no `port_hurd.c` slot ships for v0.9.7. the
"audio translator surface" line in the post-v0.9 slot list closes
deferred-upstream, exactly like pfinet per-iface counters did at
main/8e5db44. `userland/audio.el` stays out of scope for v0.9.7
since its current parser targets `/proc/asound` which has zero
analogue here. what is not verified: pulseaudio runtime behaviour
after `apt install` (the daemon is installable but i did not boot
into a pulseaudio-running image), sndio runtime behaviour on
hurd-amd64, and pipewire core daemon availability (metas listed but
core binary not confirmed at this probe depth).

## Findings

evidence chain, eight findings, in order of authority.

1. `/hurd/` ships 74 translator binaries on this image. zero of
   them match `audio|snd|dsp|sound|mixer|oss|alsa` under any
   case fold. the full A2 inventory is acpi auth console crash
   cvsfs devnode eth-multiplexer exec ext2fs fakeroot fatfs fifo
   filter firmlink ftpfs fwd hello hello-mt hostmux httpfs ifsock
   init iso9660fs lwip mach-defpager magic mboxfs memfs mtab
   netdde new-fifo nfs nsmux null password pci-arbiter pfinet
   pflocal proc procfs proxy-defpager random remap rtc rumpdisk
   rumpnet rumpusbdisk run shutdown smbfs socketio startup
   storeio streamio symlink tarfs term tmpfs usermux xmlfs (plus
   `.static` variants). the only rump translators are rumpdisk,
   rumpnet, rumpusbdisk; no rumpaudio, no rumpsnd.

2. `/dev/` has zero audio nodes. `ls -la /dev/ | grep -iE
   "audio|dsp|snd|sound|mixer"` returns exit 1 with no hits.
   `/dev/snd/` and `/dev/sound/` are both ENOENT.

3. `showtrans` on the canonical OSS / ALSA paths confirms there is
   no passive translator either:

   ```
   == /dev/dsp ==
   showtrans: /dev/dsp: No such file or directory
   == /dev/audio ==
   showtrans: /dev/audio: No such file or directory
   == /dev/mixer ==
   showtrans: /dev/mixer: No such file or directory
   == /dev/snd ==
   showtrans: /dev/snd: No such file or directory
   ```

4. `/servers/` contains 13 entries: acpi, bus, crash,
   crash-dump-core, crash-kill, crash-suspend, default-pager,
   exec, geos-auth, password, shutdown, socket, startup.
   `/servers/socket/` is the AF family tree (1 2 26 inet inet6
   local). no audio-named server. `find /servers -maxdepth 3
   \( -iname "*sound*" -o -iname "*audio*" \)` finds nothing
   (modulo the `find: '/servers/acpi': Not a directory` noise
   which is the acpi server node failing to recurse, unrelated).

5. `/proc/devices` is ENOENT (Linux-ism, expected). `find /proc
   -maxdepth 2 \( -iname "*sound*" -o -iname "*asound*"
   -o -iname "*audio*" \)` matches zero. there is no procfs
   audio surface on this image, full stop.

6. kernel boot transcript and runtime logs are silent on audio.
   `dmesg`, `/var/log/dmesg`, and `/var/log/syslog` all return
   zero hits for `audio|snd|sound|dsp|oss|alsa`. gnumach
   enumerates no audio hardware at boot.

7. `strings /boot/gnumach*` matches zero on
   `audio|sound|sb16|snd|ac97|hda`. CAVEAT: the file is gzipped
   (`gnumach-1.8-amd64-up.gz`), so `strings` ran over compressed
   bytes and the absence-of-match is a soft signal not a hard
   one. gunzip-then-strings would tighten this but the other
   six findings are already independently dispositive.

8. `dpkg -L hurd` matches zero files with audio names. the
   Debian `hurd` source package, which ships every translator
   in `/hurd/`, contains no audio code path. this rules out
   the "translator exists but is namespaced oddly" theory.

debian package surface (probe F-row):

- alsa is CONFIG-ONLY on hurd-amd64. `apt-cache search "^alsa-"`
  returns exactly alsa-topology-conf, alsa-ucm-conf,
  alsa-ucm-conf-asahi. no alsa-utils, no libasound2, no
  alsa-base.
- oss is SHIM-ONLY on hurd-amd64. `apt-cache search "^oss-"`
  returns oss-compat, oss-preserve, oss-preserve-dbgsym. no
  oss4-base, no oss4-dkms.
- sndio is FULLY AVAILABLE. libsndio7.0, libsndio-dev,
  sndio-tools, sndiod, baresip all package-listed.
- pulseaudio is AVAILABLE. `apt-cache policy pulseaudio` reports
  Candidate 17.0+dfsg1-2.1 from
  `http://deb.debian.org/debian-ports sid/main hurd-amd64`.
- pipewire metas (pipewire-audio, pipewire-doc, pipewire-libcamera,
  pipewire-module-xrdp, pipewire-system-services,
  pipewire-audio-client-libraries) appear in search; core
  pipewire daemon binary not confirmed at this depth.
- `apt-cache policy alsa-utils oss4-base sndio pulseaudio`
  confirms: alsa-utils Candidate (none), oss4-base Candidate
  (none), sndio policy hit (listed), pulseaudio Candidate
  17.0+dfsg1-2.1.

image identity: `forky/sid` on
`GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9
x86_64 GNU`, dpkg arch hurd-amd64, `/proc/cmdline` is
`gnumach root=part:2:device:wd0`, `/boot/` contains
`gnumach-1.8-amd64-up.gz grub servers.boot` (no separate audio
boot modules).

## Slot shape

decision matrix for the v0.9.7 audio surface on Hurd:

- no `port_layer.h` slot (no `geos_port_audio_open`, no
  `geos_port_audio_play`, no `geos_port_audio_mixer_*`).
- no `pid1/port_hurd.c` code.
- no header probing under `device.defs` / `mach_host` etc., since
  finding 6 already shows gnumach enumerates no audio hardware
  at boot and finding 8 shows the Debian `hurd` source ships no
  audio translator.
- `userland/audio.el` stays as-is for v0.9.7. its `/proc/asound`
  parser remains correct on Linux and inert on Hurd. wiring it
  to a Hurd path is a future v1.x slice (see open follow-on 1).
- HURD_PORT.md "audio translator surface" row flips to
  deferred-upstream with a footnote pointing here, same shape
  as pfinet per-iface counters at main/8e5db44.

## H-table

| H  | claim                                                       | outcome              | evidence                                                                 |
|----|-------------------------------------------------------------|----------------------|--------------------------------------------------------------------------|
| H1 | `/hurd/` ships an audio/snd/dsp translator binary           | FALSIFIED            | A1: zero matches; A2_full: 74 binaries inventoried, none audio; A3_rump: only rumpdisk/rumpnet/rumpusbdisk |
| H2 | an audio translator is settrans-attached under `/dev/`      | FALSIFIED            | B1: zero matches in /dev; B2/B3: /dev/snd and /dev/sound ENOENT; C: showtrans on dsp/audio/mixer/snd all ENOENT |
| H3 | gnumach exposes an audio Mach device discoverable via showtrans | FALSIFIED        | C: all four showtrans probes ENOENT; G1-G3: zero audio hits in dmesg / /var/log/dmesg / /var/log/syslog; H7: zero strings match in gnumach image (soft signal) |
| H4 | a procfs-style audio surface exists (`/proc/asound` analogue, `/proc/sound`, `/servers/*`) | FALSIFIED | D3: /servers has no audio entry; D4: /proc/devices ENOENT; E1: find /proc -iname audio/snd zero hits; E2: find /servers -iname audio zero hits |
| H5 | OSS or ALSA userland exists as installable Debian packages on hurd-amd64 | PARTIALLY CONFIRMED | F1: alsa config-only (topology-conf, ucm-conf, ucm-conf-asahi); F2: oss shim-only (oss-compat, oss-preserve); F6: alsa-utils + oss4-base Candidate (none) |
| H6 | pulseaudio or pipewire is available on hurd-amd64           | CONFIRMED            | F4: pulseaudio listed; F6: pulseaudio Candidate 17.0+dfsg1-2.1 from debian-ports sid/main hurd-amd64; F3: sndio fully available as bonus path |

## VM state at exit

1. QEMU child killed clean. false start at probe-launch (qemu PID
   captured wrong, polled a dead pid, looked like QEMU_DIED while
   the real qemu was alive). re-snapshotted, re-booted,
   re-captured the PID from `pgrep -af | head -1 | awk`. no image
   mutation occurred during the false start.
2. snapshot retained (probe-only, no image mutation).
3. host port 2222 free.
4. canonical image mtime preserved.

## Out of scope

1. pulseaudio runtime behaviour after `apt install pulseaudio` on
   Hurd. the daemon is installable but i did not exercise it. a
   future v1.x probe boots a pulseaudio-installed image and
   verifies whether pulseaudio's null-sink + module-pipe-source
   actually loads on Hurd (the daemon may compile but fail at
   the device-open step because there is no `/dev/dsp` to fall
   back to).
2. sndio runtime behaviour on hurd-amd64.
3. pipewire core daemon availability beyond the meta listing.
4. unpacking `gnumach-1.8-amd64-up.gz` and re-running `strings`
   to tighten H7 from soft to hard. the other five H1-H4
   evidence chains are already independently dispositive.

## Open follow-ons (do NOT block this slice's commit)

1. future v1.x slice: wire `userland/audio.el` to a pulseaudio
   path on Hurd. this is currently the only known route to
   audio on Hurd (pulseaudio 17.0+dfsg1-2.1 is the candidate,
   sndio is the secondary). the path is gated on the user
   installing pulseaudio (or sndio) since neither is in the
   canonical image. next step: write the v1.x audio-userland
   SPEC referencing this receipt's H6 row.

2. HURD_PORT.md "audio translator surface" row needs to flip to
   deferred-upstream with a footnote pointing here. same shape
   as the pfinet per-iface counters flip at main/8e5db44. next
   step: single-file doc commit after this receipt lands.

3. tighten H7 by unpacking `gnumach-1.8-amd64-up.gz` and
   re-running `strings | grep -iE "audio|sound|sb16|snd|ac97|hda"`.
   the current absence-of-match is over compressed bytes so
   the signal is soft. next step: queue a 30-second follow-up
   shell probe (no VM boot needed if i already have the gnumach
   binary on the host).

4. probe pulseaudio install path on a throwaway Hurd VM
   snapshot. `apt install pulseaudio` then `pulseaudio --check`
   then `pactl info`. if it runs, the v1.x slice in follow-on
   1 has a known-good baseline. next step: queue the probe
   under v1.x starters, not v0.9.7.

## Files touched on the main branch

- docs/runlogs/2026-05-21-hurd-audio-probe.md (+ this file).

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
