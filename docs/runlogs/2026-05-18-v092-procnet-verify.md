<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

# v0.9.2 procnet scoping verify on Debian GNU/Hurd 0.9

Date: 2026-05-18
Host: long-running Hurd 0.9 VM, ssh on 127.0.0.1:2222 as root.
Mode: read-only probe. No code changes, no commits, no matrix edits.
Purpose: decide the data source the *network* buffer's Hurd backend
should read in v0.9.2, since the Linux backend parses
/proc/net/dev + /proc/net/route.

## Step results

1. `ls -l /proc/net/`
   FAIL. `ls: cannot access '/proc/net/': No such file or directory`.
   The Hurd procfs translator does not expose a `/proc/net/`
   subdirectory at all.

2. `cat /proc/net/dev`
   FAIL. `No such file or directory`. Absent.

3. `cat /proc/net/route`
   FAIL. `No such file or directory`. Absent at the Linux path.
   But: `/proc/route` (no `net/` prefix) DOES exist on Hurd procfs
   and uses the Linux 11-column format:

       Iface       Destination  Gateway   Flags RefCnt Use Metric Mask         MTU Window IRTT
       /dev/eth0   10.0.2.0     0.0.0.0   0001  0      0   0      255.255.255.0 0   0      0
       /dev/eth0   0.0.0.0      10.0.2.2  0003  0      0   0      0.0.0.0       0   0      0
       /dev/eth0   0.0.0.0      0.0.0.0   0001  0      0   0      0.0.0.0       0   0      0

   Iface column carries the full Mach device path (`/dev/eth0`),
   not a short name like `eth0`. Numbers are decimal-dotted, not
   the Linux hex little-endian. The Linux-side
   `/proc/net/route` parser is therefore not reusable as-is.

4. `ls -l /servers/socket/`
   OK. Entries `1`, `2`, `26` plus symlinks `local -> 1`,
   `inet -> 2`, `inet6 -> 26`. So pfinet IPv4 is at
   `/servers/socket/2`, IPv6 at `/servers/socket/26`, pflocal at
   `/servers/socket/1`.

5. `fsysopts /servers/socket/2`
   OK. Returns the live pfinet argv:
   `/hurd/pfinet --interface=/dev/eth0 --address=10.0.2.15
    --netmask=255.255.255.0 --gateway=10.0.2.2 ...`.
   This is enough on its own to render the interface address, mask,
   and default gateway in *network* without any RPC: a string parse
   of `fsysopts` output covers the same surface as a `route -n` for
   the single-interface case.

6. `ifconfig -a`
   OK. Two interfaces: `/dev/eth0 (2)` with 10.0.2.15/24, broadcast
   10.0.2.255, MAC 52:54:00:12:34:56, UP BROADCAST RUNNING; and
   `lo (1)` with 127.0.0.1/8. Both routable.

7. `netstat -rn`
   FAIL. `netstat: command not found`. Also no `route`, no `ip`
   on stock Debian Hurd 0.9 base. Tool surface is thinner than
   Linux. `/proc/route` is the only kernel-side text source.

8. `cat /proc/uptime`
   OK. `10113.04 9548.49`. Linux-format two-float line. Reusable
   as-is.

9. `cat /proc/meminfo`
   OK. Linux-format key/value with `kB` suffix. MemTotal,
   MemFree, Buffers, Cached, Active, Inactive, Mlocked,
   SwapTotal, SwapFree visible. Reusable as-is.

## Verdicts

- `/proc/net/dev`: ABSENT. Hurd procfs has no `net/` subtree.
  The interface-stats surface has to come from somewhere else.
  Available options: parse `ifconfig` output (depends on a
  user binary, not great), or `io_stat`/pfinet RPC against
  `/servers/socket/2`, or `fsysopts /servers/socket/2` for
  address+mask+gateway only (no byte/packet counters).
- `/proc/net/route`: ABSENT at the Linux path. Present at
  `/proc/route` with the same 11-column header but
  decimal-dotted addresses and full `/dev/<iface>` Mach paths
  in the Iface column. A separate Hurd parser is needed; the
  Linux parser will not accept it.
- `/proc/uptime`, `/proc/meminfo`: PRESENT, Linux-format,
  reusable without a port branch.

## Recommendation for v0.9.2 scoping

Two tiers of work, in order:

Tier A, cheap, text-only, ships first:
  - Add a Hurd branch in `core/network.el` that, when
    `geos-kernel` is `hurd`, parses `/proc/route` (note: no
    `net/` prefix, decimal addrs, `/dev/<iface>` names) for
    the route table, and runs `fsysopts /servers/socket/2`
    (and `/servers/socket/26` for v6 later) to read
    address/netmask/gateway. Interface list comes from a
    `ls /servers/socket/` walk plus the fsysopts parse. No
    byte/packet counters in this tier (the *network* buffer
    can show `-` for those columns on Hurd).
  - Add a Hurd branch in any future system-info display that
    wants uptime or memory; both Linux paths work as-is, so
    the branch is a no-op pass-through and only documents the
    kernel check for the port_seam audit.

Tier B, later, only if counters are wanted in *network*:
  - pfinet RPC against `/servers/socket/2` for per-iface
    stats. This is real Mach RPC work (`io_stat` or a pfinet
    op), belongs in `port_hurd.c`, not in elisp. Out of
    v0.9.2 scope.

No `port_caps` additions are needed for Tier A: the Hurd
backend is pure elisp reading a text file and shelling
`fsysopts` (which is a Hurd CLI, not a shell, allowed). If
Tier B happens later, that's where a new `port_caps` slot
(`iface_stats`?) would be the right conversation with
pid1-engineer.

## Out of scope

- IPv6 surface (`/servers/socket/26`) deferred to v0.9.3+.
- Per-interface byte/packet counters deferred (Tier B).
- Any change to the Linux backend.
- Any code change at all. This is a scoping receipt.
