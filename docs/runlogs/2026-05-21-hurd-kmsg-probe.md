<!-- SPDX-License-Identifier: FSFAP -->

<!-- 2026-05-21: kmsg source probe on Debian Hurd 0.9, H2 + H3 confirm, no port_caps slot -->

# 2026-05-21: kmsg probe lands on /dev/klog + /var/log/kern.log, no port_caps slot needed

this slice is the read-only probe i ran on the canonical Debian
GNU/Hurd 0.9 VM before adding any port_layer slot for the v0.9.6
journal-tail kernel-message source. it follows the pfinet receipt at
docs/runlogs/2026-05-20-hurd-pfinet-counters-probe.md and the
storeio receipt at docs/runlogs/2026-05-20-hurd-storeio-getsize.md.
the goal is to identify what `services/journal-tail.el` can read on
Hurd so the *journal* buffer renders live kernel events instead of
the current `:autostart nil` stub. probe-first is again the whole
point: if i had landed a `geos_port_kmsg_open` slot on the cookbook
prediction that gnumach exposes a `device_open("kmsg")` stream you
just keep `device_read`ing, i would have shipped a wrapper around a
blocking, single-reader Mach port whose semantics already get drained
by inetutils-syslogd into a file the elisp can just tail.

## Result

PROBE PASS. the load-bearing claim is that on Debian GNU/Hurd 0.9
the gnumach `kmsg` device has a real but single-reader-blocking
Mach surface AND a userspace drain (inetutils-syslogd) which puts
the same byte stream into `/var/log/kern.log` and one-shots the boot
transcript into `/var/log/dmesg`. H2 (translator/streamio surface
at `/dev/klog`) and H3 (userspace drain into `/var/log/*`) are both
confirmed. H1 (raw `device_read` on the `kmsg` Mach device as the
only path) is falsified as the sole route but kept as a layered
fallback for the case where syslogd is not running. H4 (no source
exists, ship as stub) is falsified.

slot-shape decision: pure elisp wiring in
`emacs-init/services/journal-tail.el`, no `port_caps` slot, no
`port_hurd.c` code. the Hurd arm reads `/var/log/kern.log` for the
live tail and `/var/log/dmesg` for the boot transcript. that is
the whole change. what is not verified: the rotation race for
kern.log under `savelog`, the behaviour when inetutils-syslogd is
absent (a `dpkg --purge` situation, not the canonical image), and
the audio translator slot (separate probe, queued next).

## Findings

evidence chain, seven findings, in order of authority.

1. `/dev/klog` is a `/hurd/streamio kmsg` translator node, mode 660
   root:root. `showtrans /dev/klog` prints exactly
   `/hurd/streamio kmsg`. the streamio binary lives at
   `/hurd/streamio` (23312 bytes, april 2026 build). the
   passive-translator argument `kmsg` is the gnumach device name
   streamio opens internally. there is no `/dev/kmsg`, no
   `/dev/kernlog`, no `/proc/kmsg`.

2. `/dev/klog` is blocking by default and has no history replay.
   under the streamio shell:

   ```
   dd if=/dev/klog bs=4096 count=4 iflag=nonblock
   dd: error reading '/dev/klog': Resource temporarily unavailable
   0+0 records in
   0 bytes copied
   ```

   blocking `cat /dev/klog` with a 5s timeout returns exit 124 (no
   bytes during the window even though the boot transcript exists).
   so anything that reads `/dev/klog` only sees events that fire
   after the open call. as user `nobody` the read is denied with
   `Permission denied` (the 660 root:root mode is enforced by
   streamio, not just by libc).

3. under the streamio surface, the actual gnumach device is reachable
   via `device_open(master, D_READ, "kmsg")`. the C probe gets the
   master port from `get_privileged_ports` and tries every plausible
   device name with a per-name 5s alarm and `D_NOWAIT`:

   ```
   device_open("kmsg",    D_READ) -> err=0    dev=9
   device_read(D_NOWAIT)          -> err=2501 (would block) count=0
   device_open("klog",    D_READ) -> err=2502 (no such device) dev=0
   device_open("console", D_READ) -> err=0    dev=9
       console: TIMED OUT in device_open/read
   device_open("com0",    D_READ) -> err=0    dev=11
       com0:    TIMED OUT in device_open/read
   device_open("com1",    D_READ) -> err=2502
   device_open("tty0",    D_READ) -> err=2502
   device_open("tty00",   D_READ) -> err=2502
   device_open("vcs",     D_READ) -> err=2502
   device_open("vcsa",    D_READ) -> err=2502
   device_open("kd",      D_READ) -> err=0    dev=9
       kd:      TIMED OUT in device_open/read
   ```

   err 2501 = `D_WOULD_BLOCK` means "device readable, buffer empty
   right now". err 2502 = `D_NO_SUCH_DEVICE` so the device name is
   literally `kmsg` (not `klog`). console / com0 / kd open fine but
   read blocks (those are output devices in gnumach's view, the
   open succeeds even though reading would never return). the
   binary string scan of `/boot/gnumach-1.8-amd64-up.gz` confirms
   `kmsg` is the only kernel-message-style device name string in
   the kernel image.

4. there is no `host_kernel_log` / `console_log` / `kmsg_*` RPC in
   any subsystem the headers ship. enumerating routine /
   simpleroutine across `mach_debug.defs`, `gnumach.defs`,
   `mach_host.defs`, `mach4.defs`, `experimental.defs` finds
   exactly one matching-shape RPC, `host_kernel_version`, and it
   returns a single static string, not a log stream. no kmsg RPC
   is reserved, not even as unimplemented. `grep -r kmsg
   /usr/include/x86_64-gnu` finds zero hits in `defs` or `h`
   files. the gnumach `kmsg` device is a real Mach device, not an
   RPC subsystem, and the only Mach interface to it is `device.defs`
   `device_open` + `device_read`.

5. inetutils-syslogd is shipped, enabled at runlevels 2/3/4/5, and
   running (`/usr/sbin/syslogd --no-forward`, PID 602 on the probe
   image). the binary strings `/dev/klog`, `no-klog`, and
   `do not listen to kernel log device /dev/klog` confirm it reads
   `/dev/klog` directly. `/etc/syslog.conf` routes `kern.*` to
   `/var/log/kern.log` and `*.*` (with auth excluded) to
   `/var/log/syslog`, both 644 root:root and readable by non-root.

6. `/var/log/dmesg` is the one-shot boot transcript. populated by
   `/etc/init.d/bootlogs`, runlevel S02, with this recipe:

   ```
   if which dmesg >/dev/null 2>&1; then
       dmesg -s 524288 >/var/log/dmesg
   elif [ -c /dev/klog ]; then
       dd if=/dev/klog of=/var/log/dmesg &
       sleep 1
       kill $!
   fi
   ```

   the `dd | sleep 1 | kill` recipe exists precisely because
   `/dev/klog` blocks; there is no dmesg(8) on Hurd so the elif
   branch always fires. the resulting file is 640 root:adm,
   rotated through `dmesg.0` / `dmesg.1.gz` / etc. content is the
   rump kernel boot transcript (NetBSD 10.99.12 RUMP-ROAST,
   piixide, wd0 sizing, cd0 partition errors).

7. live events do land in `/var/log/kern.log` after boot. while the
   probe was running, the kernel emitted `cd0: dos partition I/O
   error` and `irq handler [9]: new delivery port ... for
   /hurd/acpi` events, both visible in `kern.log` and in `syslog`
   with the same `vmunix:` tag and timestamp prefix. stopping
   syslogd and re-running the device probe shows the same
   `D_WOULD_BLOCK` on `kmsg`: the Mach device is one-reader (the
   typical "one-Mach-device port = one reader" gnumach rule), and
   while syslogd holds it, other readers cannot drain it; but
   while syslogd is stopped, the new-events-only semantics still
   hold, so the elisp does not gain anything by going around
   syslogd.

procfs adds nothing. `/proc` lists `cmdline cpuinfo filesystems
hostinfo loadavg meminfo mounts route self slabinfo stat swaps
uptime version vmstat` plus per-pid dirs, no `kmsg`, no
`kern.log`, no `dmesg`, no `printk`, no `console`. same shape as
the pfinet probe found.

## Slot shape

decision matrix for `services/journal-tail.el` Hurd arm:

- live tail: `auto-revert-tail-mode` on `/var/log/kern.log`. file is
  644 root:root, readable as the geos user without privilege.
  syslogd already drains `/dev/klog` so the elisp is a pure file
  reader. format is `<timestamp> <hostname> vmunix: <message>`,
  one line per kernel event. rotation is via `savelog`, which
  renames in place, so `auto-revert-tail-mode` recovers on next
  poll cycle.

- boot transcript: read `/var/log/dmesg` once on buffer creation,
  prepend with a separator line. file is 640 root:adm so the geos
  user needs to be in group `adm` (the install wizard already adds
  the bootstrap user there). if not in `adm`, fall back to skipping
  the prepend with a one-line "boot transcript unreadable, add user
  to group adm" notice.

- RPC-bypass fallback (not shipped, documented): if a future GEOS
  image stops shipping inetutils-syslogd, the elisp arm reads
  `/dev/klog` directly through a subprocess (`cat /dev/klog`), since
  `device_open("kmsg")` + `device_read` would still block exactly
  the same way and would need a real C wrapper. this branch is the
  reason H1 is kept as a layered fallback in the H-table below.

what does NOT need to ship:

- no `port_layer.h` slot (no `geos_port_kmsg_open`,
  no `geos_port_kmsg_read`).
- no `pid1/port_hurd.c` code.
- no header probing under `mach_debug` / `gnumach` / `mach_host`.
- no `auth_server_authenticate` dance, the file is world-readable.

## H-table

| H  | claim                                                | outcome    | evidence                                                                 |
|----|------------------------------------------------------|------------|--------------------------------------------------------------------------|
| H1 | `device_open("kmsg") + device_read` is the only path | FALSIFIED  | step4e: works but blocks; step5: same after syslogd stop; kept as fallback for non-syslogd images |
| H2 | `/dev/klog` `/hurd/streamio kmsg` translator surface | CONFIRMED  | step1: showtrans output; step2: blocking + non-blocking dd; step2b: streamio --help shape |
| H3 | userspace drain into `/var/log/{kern.log,dmesg}`     | CONFIRMED  | step2b/2c: syslog.conf + kern.log content; step2d: bootlogs dd recipe; step6: live cd0 events landing in kern.log |
| H4 | no source exists, ship as stub on Hurd               | FALSIFIED  | H2 and H3 both confirmed                                                 |

## VM state at exit

1. QEMU child killed clean (SIGTERM, ~3s exit from canonical shape).
2. snapshot retained (probe-only, no image mutation).
3. host port 2222 free.
4. canonical `/home/overdrive/hurd-vm/work.img` mtime preserved at
   2026-05-18 13:34:31 +0300 (unchanged from prior probes).
5. qemu serial transcript at the boot-only stage; serial was not the
   active console for this image so the runtime events only show in
   the in-VM logs.

## Out of scope

1. audio translator slot. queued as the next port_hurd.c-or-elisp
   decision after this slice ships. probably another "syslog-style
   userspace drain plus rpc-blocked Mach device" finding, but a
   separate probe confirms.
2. Xorg spawn path on Hurd. not in the v0.9.6 chain.
3. GEOS-side service supervisor replacement for inetutils-syslogd.
   v0.x territory; current image relies on Debian's syslogd to do
   the drain. if i ever replace it i need to handle the
   single-reader rule for the `kmsg` Mach device.
4. multi-host journal aggregation. nothing in v0.9.6.

## Open follow-ons (do NOT block this slice's commit)

1. wire the Hurd arm of `services/journal-tail.el` to
   `/var/log/kern.log` with `auto-revert-tail-mode` and to
   `/var/log/dmesg` for the boot prepend. flip `:autostart` to t on
   the Hurd arm. next step: single-file elisp commit on main with a
   docstring footnote pointing at this receipt.

2. install wizard already adds the bootstrap user to `adm` (for
   `auth.log` access); confirm during v0.9.6 verification that the
   group is actually inherited at login. next step: ssh into the
   canonical VM as the bootstrap user and `id -Gn` to confirm
   `adm` is in the supplementary groups.

3. document the rotation behaviour of `savelog` in the
   `journal-tail.el` docstring so future-me does not assume
   `auto-revert-tail-mode` survives an inode swap; it does, because
   `savelog` renames then truncates, but the docstring should say
   so. next step: comment-only edit during the wire-up commit.

4. HURD_PORT.md row for "kernel message source" needs to flip from
   RED (or "deferred") to GREEN with a footnote pointing here. next
   step: single-file doc commit after the elisp commit lands.

5. audio translator probe. same shape as pfinet / kmsg: three
   hypotheses, falsify until one stands. queued as v0.9.7 starter.
   next step: write the audio probe SPEC for the next session.

## Files touched on the main branch

- docs/runlogs/2026-05-21-hurd-kmsg-probe.md (+ this file).

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
