<!-- SPDX-License-Identifier: FSFAP -->
# 2026-05-17 hurd ifname normalization verified

## Milestone

`port->set_address` and `port->set_route_default` work on real
GNU/Hurd with bare Linux-shaped ifnames.  pfinet on a stock Debian
Hurd install keys hardware interfaces by the devnode translator
path passed to `/hurd/pfinet` at settrans time (`/dev/eth0`), not
the bare `eth0` name the Linux backend uses.  the supervisor
speaks Linux-shaped ifnames, so the translation belongs in the
backend, not in elisp.

Fix on the hurd branch at `b031db5`: added `hurd_normalize_ifname`
in `pid1/port_hurd.c`.  rule: prepend `/dev/` unless the name
starts with `/` (already an absolute devnode path) or is literally
`"lo"` (pfinet special-cases loopback regardless of devnode
configuration).  applied at the seam in `hurd_set_address` and
`hurd_set_route_default`.  `bring_up_lo` uses literal `"lo"` and
is unaffected.

## Environment

Same as 2026-05-17-hurd-mount-fix.md.  module rebuilt with
`make PORT=hurd STATIC=0 module` after the patch.

## Before the fix

```
peculiar error: "pid1: set-address: No such device"
```

This is `ENODEV` surfacing from pfinet because `"eth0"` does not
match any interface pfinet knows about; pfinet only has
`"/dev/eth0"` in its internal table.  passing `"/dev/eth0"`
explicitly worked, but that forces every elisp caller to know
about a kernel-specific naming convention.

## After the fix

```elisp
(module-load "/root/geos/pid1/pid1-module.so")
(princ (format "set-address bare eth0: %S\n"
               (pid1-set-address "eth0" "10.0.2.15" 24)))
```

Output:

```
module loaded
set-address bare eth0: t
```

`ifconfig /dev/eth0` after the call:

```
/dev/eth0 (2):
  inet address  10.0.2.15
  netmask       255.255.255.0
  broadcast     10.0.2.255
  flags         UP BROADCAST RUNNING ALLMULTI MULTICAST
```

`ping -c 1 10.0.2.2` (QEMU NAT gateway):

```
PING 10.0.2.2 (10.0.2.2): 56 data bytes
64 bytes from 10.0.2.2: icmp_seq=0 ttl=255 time=0.518 ms
```

Default route via the same normalization:

```elisp
(princ (format "set-route-default 10.0.2.2 eth0: %S\n"
               (pid1-set-route-default "10.0.2.2" "eth0")))
```

Output:

```
set-route-default 10.0.2.2 eth0: t
```

(arg order is gateway-first, then ifname; verified by reading
`Fpid1_set_route_default` at `pid1/emacs-init.c:1822`.)

## Why this matters

The point of the port-layer seam is that elisp callers stay
kernel-agnostic.  before this fix, `core/network.el` would have
needed a `(if (eq geos-kernel 'hurd) (concat "/dev/" iface)
iface)` shim at every call site.  putting the translation in
`port_hurd.c` keeps the elisp side identical across kernels and
puts the kernel-specific knowledge in exactly one place.

## References

  - hurd branch commit: `b031db5`
  - main docs update: `fc08c4d` (HURD_PORT.md matrix promotion)

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
