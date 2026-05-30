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
