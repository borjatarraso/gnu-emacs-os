<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

<!-- 2026-05-20: pfinet per-iface counter source probe, H1 confirmed -->

# 2026-05-20: pfinet per-interface counter probe falsifies H2 and H3, H1 confirmed

this slice is the read-only RPC-discovery probe i ran on the canonical
Debian GNU/Hurd 0.9 VM before adding any port_layer slot for per-iface
byte/packet counters. it follows the v0.9.2 receipt at
docs/runlogs/2026-05-18-v092-procnet-verify.md which left
`network--read-proc-net-dev-hurd` returning eight zeros with the note
"stub-zero pending pfinet RPC in port_hurd.c". this probe answers
what RPC, and the answer is: none. probe-first is again the whole
point. if i had landed a `geos_port_iface_counters` slot on the
prediction that pfinet exposes a `pfinet_getstats` RPC or honours
`SIOCGIFSTATS`, every call would have returned ENOTTY or MIG_BAD_ID
and the v0.9.6 chain would have been a wasted commit.

## Result

PROBE PASS. negative finding is a successful probe outcome. the load
bearing claim is that pfinet on Debian GNU/Hurd 0.9 does not expose
per-interface byte or packet counters via any ioctl, any Mach RPC, or
any procfs file. H1 (no surface exists) is confirmed. H2 (a
`pfinet_getstats` RPC in subsystem 37000) is falsified by the
canonical `.defs` and by a binary string scan. H3 (an aggregate at
`/proc/net/snmp` or `/proc/net/dev`) is falsified by the procfs walk:
`/proc/net/` does not exist on this image.

what is verified: the entire ioctl surface pfinet implements (from
`iioctl.defs`), the entire Mach RPC surface pfinet implements (from
`pfinet.defs`), the runtime dispatch behaviour of `SIOCGIFSTATS`
against the live pfinet at `/servers/socket/2`, and the procfs
top-level listing. what is not verified: anything about a future
upstream pfinet patch (out of scope, FSF/GNU territory), the kmsg or
audio translator slots (separate probes), and the HURD_PORT.md row
192 edit (separate doc commit).

## What this slice ships

- docs/runlogs/2026-05-20-hurd-pfinet-counters-probe.md: this
  receipt. no code, no header touches, no matrix edits. the receipt
  is the deliverable so the v0.9.6 chain plan can pivot off the
  falsification before any port_layer slot gets proposed.

## Build matrix

Linux dev host: not applicable, the probe is a Hurd-only C file
compiled inside the VM, plus header / strings / showtrans / fsysopts
queries that only mean anything on Hurd.

Hurd VM: `gcc -Wall -Wextra -Werror` on a 30-line probe-pfinet-stats.c
that opens an `AF_INET` `SOCK_DGRAM` socket and runs the standard
ioctl menu. clean build first try. no libhurduser / libmachuser
needed for the ioctl probe; the falsification reaches pfinet through
the libc socket layer.

## Probe run

evidence chain, six findings, in increasing order of authority.

1. header inventory rules out the cookbook ioctl set.
   `/usr/include/x86_64-gnu/bits/ioctls.h` defines SIOC* constants
   for ADDR / DSTADDR / FLAGS / BRDADDR / CONF / NETMASK / METRIC /
   ARP / MTU / INDEX / NAME / HWADDR only. no `SIOCGIFSTATS`, no
   `SIOCGIFMIB`, no `SIOCGIFDATA`, no `SIOCGIFCOUNTERS` macro
   anywhere under `/usr/include`. `/usr/include/sys/sockio.h` does
   not exist.

2. pfinet's canonical Mach subsystem spec at
   `/usr/include/x86_64-gnu/hurd/pfinet.defs` declares the complete
   `pfinet` subsystem (number 37000) as exactly two routines:
   `pfinet_siocgifconf` and `pfinet_getroutes`. that is the whole
   RPC surface. the MIG-generated `/usr/include/hurd/pfinet.h`
   matches.

3. the per-interface ioctl subsystem at
   `/usr/include/x86_64-gnu/hurd/iioctl.defs` (subsystem 112000)
   enumerates every per-iface ioctl pfinet implements: SIOCSIFADDR,
   SIOCSIFDSTADDR, SIOCSIFFLAGS, SIOCGIFFLAGS, SIOCSIFBRDADDR,
   SIOCSIFNETMASK, SIOCGIFMETRIC, SIOCSIFMETRIC, SIOCDIFADDR,
   SIOCGIFADDR, SIOCGIFDSTADDR, SIOCGIFBRDADDR, SIOCGIFNETMASK,
   SIOCGIFHWADDR, SIOCGIFMTU, SIOCSIFMTU, SIOCGIFINDEX, SIOCGIFNAME.
   slots 0-11, 13, 15, 18, 20-21, 26-32, 36 (SIOCGIFCONF in libc),
   38 (SIOCGARP "Not implemented yet"), 40-50, 53-89 are all marked
   `skip`. no stats RPC is reserved, not even as unimplemented.

4. runtime SIOCGIFSTATS probe confirms the dispatch layer rejects
   the request. the 30-line C program opens
   `socket(AF_INET, SOCK_DGRAM, 0)` and runs the standard ioctl menu
   on both `lo` and `/dev/eth0`:

   ```
   SIOCGIFCONF ok (2 ifreq entries)
   SIOCGIFFLAGS ok (lo=0x49, /dev/eth0=0x1243)
   SIOCGIFSTATS errno=1073741849 "Inappropriate ioctl for device"
   ```

   errno 1073741849 is the Hurd-encoded `ENOTTY`. baseline ioctls
   round-trip cleanly so the iface-name format is right and the
   socket is the right pfinet port. the stats ioctl reaches pfinet
   and gets rejected because pfinet has no handler.

5. binary symbol search on `/hurd/pfinet`. the translator is
   stripped so objdump / nm are empty for local symbols. the strings
   probe finds exactly one `_get_stats` symbol name:
   `tunnel_get_stats`, which is a Linux-net tunnel-device internal
   callback, not an RPC entry point. no `pfinet_getstats`, no
   `inet_stats`, no `siocgifstats` strings anywhere in the binary.

6. procfs walk kills H3 cleanly. `/proc/net/` does not exist at all
   on this image (`ENOENT`). the full top-level `/proc/` namespace
   contains `cmdline cpuinfo filesystems hostinfo loadavg meminfo
   mounts route self slabinfo stat swaps uptime version vmstat`
   plus per-pid dirs. there is no `snmp`, no `netstat`, no `dev`.
   `/proc/route` exists at the top level (not under `net/`) and is
   the routing table; its `Use` and `RefCnt` columns are always 0
   here, so even that does not carry per-iface byte / packet
   counters.

7. translator confirmation. `showtrans /servers/socket/2` returns
   `/hurd/pfinet -6 /servers/socket/26`. `fsysopts /servers/socket/2`
   returns the live pfinet command line with all configured v4 / v6
   addresses. so `socket(AF_INET, SOCK_DGRAM, 0)` in the C probe is
   definitely talking to pfinet, not some stub.

## Implication

the H1-confirmed branch fires. v0.9.6 should:

- close the per-iface byte / packet counter caveat in
  `docs/HURD_PORT.md` row 192 as "deferred at translator level:
  pfinet does not expose per-iface counters via ioctl, Mach RPC, or
  procfs; counters remain stub-zero", with a footnote pointing at
  this run.

- NOT add a port_caps slot for SIOCGIFSTATS, NOT add a
  `geos_port_iface_counters` RPC. there is no surface to bind to.

- pivot to the next port_hurd.c slot (kmsg or audio).

if counters ever need to be real on Hurd, the only path is a patch
to upstream pfinet that adds either an `iioctl` slot at one of the
reserved numbers or a third `pfinet_*` routine in `pfinet.defs`.
that is FSF / GNU territory and explicitly out of scope.

## Out of scope

1. patching upstream pfinet to add a stats RPC.
2. the native kmsg source slot (next probe).
3. the audio translator slot (probe after kmsg).
4. SNMP-aggregate (no per-iface granularity, would not satisfy the
   slot contract).

## Open follow-ons (do NOT block this slice's commit)

1. edit HURD_PORT.md row 192 to record the deferred-at-translator
   verdict and the footnote pointing at this receipt. flip the cell
   accordingly (yellow / "deferred", not red, since the elisp arm is
   correctly returning the zero tuple already). next step:
   single-file doc commit on main.

2. drop the "pending pfinet RPC in port_hurd.c" wording from the
   `network--read-proc-net-dev-hurd` docstring in
   `emacs-init/core/network.el` and replace with the upstream-only
   note. no behaviour change, just truth in the comment. next step:
   single-file elisp commit on main.

3. queue the kmsg probe spec. /dev/klog vs `device_open("kmsg")` vs
   gnumach console buffer: same shape as this probe, three
   hypotheses, falsify until one stands. next step: write the kmsg
   probe SPEC for the next session.

4. after kmsg, the audio translator slot. probably hits the same
   "no Hurd surface, ship as stub" wall but the probe is what
   confirms it. next step: queue after kmsg lands.

## Files touched on the main branch

- docs/runlogs/2026-05-20-hurd-pfinet-counters-probe.md (+ this file).

VM state on exit:

1. QEMU child (PID 284037) killed clean (SIGTERM, 3s exit).
2. snapshot `/tmp/geos-hurd-vm-v096probe-1779310781.qcow2` deleted.
3. host port 2222 free.
4. canonical `/home/overdrive/hurd-vm/work.img` mtime preserved at
   1779100471 / 2026-05-18 13:34:31.700204970 +0300.
