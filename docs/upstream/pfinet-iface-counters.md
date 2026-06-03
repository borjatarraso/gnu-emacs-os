<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

<!-- upstream deferral, drafted 2026-05-30, covers HURD_PORT.md row 273 -->

# pfinet exposes no per-interface byte / packet counter RPC

## summary

GEOS renders a `*network*` buffer that lists every interface with its
address, flags, and rx/tx byte and packet counters.  on Linux the
counters come from `/proc/net/dev`.  on Debian GNU/Hurd 0.9 the
counters are stub-zero for every interface, including lo and eth0
under live traffic.  the gap is not in the GEOS elisp arm.  pfinet,
the Hurd translator that backs AF_INET sockets and owns the
per-interface state, does not expose byte or packet counters via any
ioctl, any Mach RPC, or any procfs file.

i am the GEOS author.  this file is my upstream-ready writeup of the
finding and a sketch of what an upstream patch would look like.
adding the surface is out of scope for the GEOS repo.

## ground truth (how i confirmed the absence)

receipt: `docs/runlogs/2026-05-20-hurd-pfinet-counters-probe.md`.

seven independent findings, in increasing order of authority:

  1. `/usr/include/x86_64-gnu/bits/ioctls.h` defines SIOC* constants
     for ADDR / DSTADDR / FLAGS / BRDADDR / CONF / NETMASK / METRIC /
     ARP / MTU / INDEX / NAME / HWADDR only.  no `SIOCGIFSTATS`, no
     `SIOCGIFMIB`, no `SIOCGIFDATA`, no `SIOCGIFCOUNTERS` macro
     anywhere under `/usr/include`.

  2. `pfinet.defs` (subsystem 37000) at
     `/usr/include/x86_64-gnu/hurd/pfinet.defs` declares the complete
     pfinet RPC surface as exactly two routines: `pfinet_siocgifconf`
     and `pfinet_getroutes`.  the MIG-generated `pfinet.h` matches.

  3. `iioctl.defs` (subsystem 112000) enumerates every per-iface
     ioctl pfinet implements.  no stats routine is reserved, not even
     as an unimplemented slot.  slots 0-11, 13, 15, 18, 20-21, 26-32,
     36, 38, 40-50, 53-89 are all marked `skip`.

  4. a runtime SIOCGIFSTATS probe (30-line C, `socket(AF_INET,
     SOCK_DGRAM, 0)` then the standard ioctl menu against lo and
     /dev/eth0) returns `errno=1073741849 "Inappropriate ioctl for
     device"`.  that errno value is the Hurd-encoded ENOTTY.  the
     baseline ioctls (SIOCGIFCONF, SIOCGIFFLAGS) round-trip cleanly,
     so the socket is genuinely talking to pfinet.

  5. a binary symbol scan of `/hurd/pfinet` finds exactly one
     `_get_stats` match: `tunnel_get_stats`, which is a Linux-net
     tunnel-device internal callback, not an RPC entry.  no
     `pfinet_getstats`, no `inet_stats`, no `siocgifstats` strings
     anywhere in the binary.

  6. procfs walk: `/proc/net/` does not exist on this image.  the
     top-level `/proc/` namespace contains `cmdline cpuinfo
     filesystems hostinfo loadavg meminfo mounts route self slabinfo
     stat swaps uptime version vmstat` and per-pid dirs.  no `snmp`,
     no `netstat`, no `dev`.  `/proc/route` exists at the top level
     (not under net/) and carries the routing table, but its `Use`
     and `RefCnt` columns are always 0.

  7. translator identity: `showtrans /servers/socket/2` returns
     `/hurd/pfinet -6 /servers/socket/26`.  `fsysopts
     /servers/socket/2` returns the live pfinet command line with
     all configured v4 / v6 addresses.  so the AF_INET socket the
     probe used in finding 4 is definitely talking to pfinet, not a
     stub.

verdict: no per-iface counter surface exists today.  the GEOS elisp
arm correctly returns the eight-zero tuple via
`network--read-proc-net-dev-hurd`.

## remediation: pfinet learns an iioctl stats routine

scope sketch, written for a hurd hacker:

  - add a new `iioctl` routine.  the obvious shape is
    `iioctl_get_stats (port_t iface) -> (struct net_device_stats
    stats)`, returning a fixed-width record:

        struct iioctl_net_device_stats {
          uint64_t rx_bytes;
          uint64_t tx_bytes;
          uint64_t rx_packets;
          uint64_t tx_packets;
          uint64_t rx_errors;
          uint64_t tx_errors;
          uint64_t rx_dropped;
          uint64_t tx_dropped;
        };

    the Linux glue layer pfinet already wraps maintains these
    counters internally (the `linux/net/core/dev.c` equivalent
    increments them on every recv and xmit).  the patch needs the
    RPC surface and a getter, not a new accounting layer.

  - alternative shape: extend `pfinet.defs` (subsystem 37000) with
    a third routine `pfinet_get_iface_stats (port_t port, string_t
    ifname) -> (...)`.  i prefer the `iioctl` form because it
    parallels the existing per-iface getters (SIOCGIFFLAGS,
    SIOCGIFADDR, ...) and reuses the same per-iface port the
    caller already holds.

  - one of the reserved `iioctl.defs` slots (0-11, 13, 15, 18,
    20-21, 26-32, 36, 38, 40-50, 53-89 are all `skip` today) is
    the right home.  pick the next free slot and reserve it.

  - libc-side: add a `SIOCGIFSTATS` ioctl macro and a thin glibc
    shim that issues the new MIG routine.  programs that already
    expect SIOCGIFSTATS on other Unixes will then work unchanged
    on Hurd.

estimation: small patch by absolute size (one MIG entry, one
getter, one libc shim).  the risk is in agreeing the record
shape upstream so it does not have to change later.

## status in GEOS

no in-repo code change.  `core/network.el`'s
`network--read-proc-net-dev-hurd` returns the eight-zero tuple
honestly and documents the gap inline.  HURD_PORT.md row 273
carries the "deferred at translator level" verdict with a pointer
to the probe receipt above.

## suggested upstream destination

  - `bug-hurd@gnu.org` for the feature request and any patch
    submission.  pfinet is FSF / GNU territory; there is no Debian
    packaging side to this one beyond rebuilding once upstream
    lands.

## To file

- destination: `bug-hurd@gnu.org` (or the Savannah `hurd` tracker
  at https://savannah.gnu.org/bugs/?group=hurd if a tracker entry
  is preferred over a list post; either reaches the same set of
  maintainers).
- subject line: `[pfinet] no per-interface byte / packet counter RPC; please add SIOCGIFSTATS or equivalent`
- body header:

  on Debian GNU/Hurd 0.9 (pfinet as shipped in the `hurd` source
  package, `pfinet.defs` subsystem 37000, `iioctl.defs` subsystem
  112000), there is no RPC, no ioctl, and no procfs file that
  returns per-interface byte / packet counters.  `/proc/net/dev`
  does not exist; the per-iface ioctl menu covers ADDR / DSTADDR /
  FLAGS / BRDADDR / CONF / NETMASK / METRIC / ARP / MTU / INDEX /
  NAME / HWADDR and no stats slot; `pfinet.defs` exposes exactly
  two routines, `pfinet_siocgifconf` and `pfinet_getroutes`; the
  `/hurd/pfinet` binary carries no `*_get_stats` entry beyond
  `tunnel_get_stats` (a Linux-net internal callback, not an RPC).
  user impact: every tool that reads `/proc/net/dev` (ifconfig
  byte counts, bmon, vnstat, prometheus node_exporter, GEOS's
  `*network*` buffer, anything else) reports zero traffic on
  every interface regardless of actual load.  request: add a
  per-iface stats getter so the counters pfinet already maintains
  internally (via its Linux-net glue layer) become readable.

## Patch sketch (not yet a working diff)

```pseudo-diff
--- include/hurd/iioctl.defs
+++ include/hurd/iioctl.defs
@@
+/* slot N (pick the next free slot from the existing skip list:
+   0-11, 13, 15, 18, 20-21, 26-32, 36, 38, 40-50, 53-89). */
+routine iioctl_siocgifstats (
+        iface : io_t;
+        out stats : iioctl_net_device_stats_t);

--- include/hurd/iioctl_types.defs
+++ include/hurd/iioctl_types.defs
@@
+type iioctl_net_device_stats_t = struct {
+    uint64_t rx_bytes;
+    uint64_t tx_bytes;
+    uint64_t rx_packets;
+    uint64_t tx_packets;
+    uint64_t rx_errors;
+    uint64_t tx_errors;
+    uint64_t rx_dropped;
+    uint64_t tx_dropped;
+};

--- pfinet/iioctl-ops.c
+++ pfinet/iioctl-ops.c
@@
+kern_return_t
+S_iioctl_siocgifstats (struct iouser *user, ifname_t name,
+                       iioctl_net_device_stats_t *stats)
+{
+  /* look up the device by ifname; copy the in-kernel net_device_stats
+     struct that the Linux net glue maintains on every recv/xmit out
+     to the caller; map missing iface to ENODEV.  */
+}

--- glibc: sysdeps/mach/hurd/bits/ioctls.h
+++ glibc: sysdeps/mach/hurd/bits/ioctls.h
@@
+#define SIOCGIFSTATS  _IOWR ('i', N, struct iioctl_net_device_stats)
```

- reproduction steps (canonical Debian GNU/Hurd 0.9):

  1. boot the canonical image, log in, generate traffic on lo:
     `ping -c 100 127.0.0.1 >/dev/null`.
  2. observe `cat /proc/net/dev` returns `No such file or directory`.
  3. observe `ifconfig lo` reports `RX bytes:0` and `TX bytes:0`
     under live traffic.
  4. for the ioctl confirmation, compile and run the 30-line
     SIOCGIFSTATS probe from finding 4 in the runlog; observe
     `errno=1073741849 "Inappropriate ioctl for device"`
     (Hurd-encoded ENOTTY).
  5. for the binary scan: `nm /hurd/pfinet | grep _get_stats`
     returns exactly one hit, `tunnel_get_stats`, which is a
     Linux-net internal callback and not exported as a Mach RPC.

- GEOS runlog: `docs/runlogs/2026-05-20-hurd-pfinet-counters-probe.md`.

filed-by: Borja Tarraso <borja.tarraso@member.fsf.org>
