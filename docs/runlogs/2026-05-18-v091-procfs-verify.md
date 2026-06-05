<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

// 2026-05-18: v0.9.1 procfs assumptions probed on Debian GNU/Hurd 0.9

Read-only verification of the Hurd backends added in main/983f1db
("v0.9.1: state + uname Hurd backends, no more placeholders"). No code
changes, no commits. The image probed is the canonical Debian Hurd
0.9 VM at `/home/overdrive/hurd-vm/debian-hurd-amd64-20260314.img`,
reached over ssh on 127.0.0.1:2222 against a long-running QEMU
already booted on this host. The image identifies itself as
`GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9 x86_64
GNU`.

## Verdict: pure-fallback

Both v0.9.1 backends sit on top of `/proc/sys/kernel/{ostype,
osrelease,version,hostname}`, and on this Debian Hurd image **none
of those four nodes exist**: `/proc/sys/` itself is absent. The
`uname.el` Hurd arm therefore lands on its per-field synthesis path
for all four fields. The `state.el` Hurd arm reads `/proc/mounts`
(which does exist), but `/var` is not listed there at all (no
translator settles it; it is a plain subtree of the root ext2fs),
so the `ext[234]\(?:fs\)?` alternation never gets a chance to fire
and `state--detect-mode-hurd` falls through to the
`(file-writable-p state-root)` writable-probe.

Net: the v0.9.1 matrix flip to "YES on Hurd" is **load-bearing only
in the sense that the fallback paths exist and behave**. The native
procfs reads contribute zero data on stock Debian Hurd 0.9. If the
intent of the matrix entry is "reads procfs natively on Hurd", the
parenthetical should read "via fallback path" or equivalent. If the
intent is "returns sensible values on Hurd without crashing", v0.9.1
delivers, but only because the fallbacks were written.

## Per-question answers

- `/proc/mounts` exists. The `/var` line is **absent**; only `/` and
  `/proc` appear. The root line is
  `/dev/wd0s2 / ext2fs writable,relatime,no-inherit-dir-group,
  store-type=typed 0 0`.
- Of the four `/proc/sys/kernel/*` nodes, **none** exist. `/proc/sys/`
  itself does not exist on this image; the procfs translator on
  Debian Hurd 0.9 does not publish a `sys/` subtree.
- `settrans -p /var` prints nothing (silent success on a node with
  no translator). `showtrans /var` also prints nothing. `/var` is a
  plain directory inside the root ext2fs, not a separately-translated
  mount point.
- The state.el regex `ext[234]\(?:fs\)?` is correct for the case it
  was written for (a `/var` line of type `ext2fs` from a translator
  settling /var), but on this image **no `/var` line exists**, so
  the regex never sees input and the writable-probe branch runs.
- The uname.el per-field reads **all fail** (file-missing). Every
  field falls through to the synthesized default: `:kernel "GNU"`,
  `:release "unknown"`, `:version` the build-time string, `:host`
  `(system-name)`.

## Practical implication

The "v0.9.1 reads procfs on Hurd" claim should be qualified. On the
Debian Hurd 0.9 ISO we ship against, `/proc/sys/kernel/*` is not a
thing. The Hurd `procfs` translator can expose more under the right
mount options (some downstream builds enable `--anonymous-owner`
plus a sysctl emulation layer), but the stock Debian one does not,
and the v0.9.1 fallbacks are what the user actually sees.

If a future slice wants a real native read, the path is either
(a) `host_info` / `vm_statistics` style Mach RPC for kernel
identification, or (b) parsing `/hurd/*` translator banners. Both
are more work than the v0.9.1 ostype-string read and out of scope
for this verification.

## Raw command output

### Step 2: `/proc/mounts`

```
# ls -l /proc/mounts
-r--r--r-- 0 root root 0 Jan  1  1970 /proc/mounts

# cat /proc/mounts
/dev/wd0s2 / ext2fs writable,relatime,no-inherit-dir-group,store-type=typed 0 0
proc /proc /hurd/procfs defaults 0 0
```

### Step 3: `/proc/sys/kernel/`

```
# ls -l /proc/sys/kernel/
ls: cannot access '/proc/sys/kernel/': No such file or directory

# ls /proc/sys/
ls: cannot access '/proc/sys/': No such file or directory
```

### Steps 4-7: per-field `/proc/sys/kernel/*` reads

```
# cat /proc/sys/kernel/ostype
cat: /proc/sys/kernel/ostype: No such file or directory

# cat /proc/sys/kernel/osrelease
cat: /proc/sys/kernel/osrelease: No such file or directory

# cat /proc/sys/kernel/version
cat: /proc/sys/kernel/version: No such file or directory

# cat /proc/sys/kernel/hostname
cat: /proc/sys/kernel/hostname: No such file or directory
```

### Step 8: `/var` listing

```
# ls /var
backups
cache
lib
local
lock
log
mail
opt
run
spool
tmp

# ls -l /var | head -5
total 36
drwxr-xr-x  2 root root 4096 Aug 10  2025 backups
drwxr-xr-x  8 root root 4096 Mar 14 22:43 cache
drwxr-xr-x 27 root root 4096 May 17 21:58 lib
drwxr-xr-x  2 root root 4096 Aug 10  2025 local
```

### Step 9: translator on `/var`

```
# settrans -p /var
(no output, exit 0)

# showtrans /var
(no output, exit 0)

# showtrans /
(no output, exit 0)
```

### Extra cross-checks captured along the way

```
# ls /proc/cmdline /proc/version /proc/uptime /proc/meminfo
/proc/cmdline
/proc/meminfo
/proc/uptime
/proc/version

# cat /proc/version
Linux version 2.6.1 (GNU 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9 x86_64)

# cat /etc/hostname
geos-hurd

# hostname
geos-hurd

# ls /servers
acpi
bus
crash
crash-dump-core
crash-kill
crash-suspend
default-pager
exec
geos-auth
password
shutdown
socket
startup
```

`/proc/version` does exist and carries a usable "GNU 0.9 ... Hurd-0.9"
string; that is a candidate fallback source for a future uname slice
if we want a real kernel-side identifier rather than a synthesized
default, but the v0.9.1 code does not read it.

## VM state on exit

No changes were made. The probed VM was the long-running QEMU
instance already on 127.0.0.1:2222 (PID predates this session). The
snapshot `/tmp/hurd-vm-v091.img` was copied but never booted (port
2222 was held by the existing VM); it can be deleted at leisure.

## license

This document is licensed under the GNU Free Documentation License,
Version 1.3 or any later version published by the Free Software
Foundation; with no Invariant Sections, no Front-Cover Texts, and no
Back-Cover Texts.

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3 or
any later version published by the Free Software Foundation; with no
Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.  A
copy of the license is included in the file `COPYING.DOC` at the top
of this distribution.
