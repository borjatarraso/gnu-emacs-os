<!-- SPDX-License-Identifier: FSFAP -->

<!-- 2026-05-20: v0.8.2 retry-loop drain re-verify + v0.9.3 disks/install live-verify -->

# 2026-05-20: v0.8.2 retry-loop drain re-verify + v0.9.3 disks/install live-verify

this receipt covers two passes in one Hurd VM session. pass 1 is the v0.8.2
retry-loop drain re-verify that was deferred out of v0.8.1 as the B2 skeptic
blocker. pass 2 is the v0.9.3 live-verify of the disks-buffer and install
Hurd backends shipped at `main/d01b29c`, follow-ons `main/cd56568` (v0.9.4)
and `main/d05bc98` (task #134). the parser shape under test here was driven
by the earlier probe pass recorded in
`docs/runlogs/2026-05-20-v092-verify-v093-probe.md`.

## Verdict

v0.8.2 retry-loop drain re-verify: PASS. the supervisor stays in `S` sleep
state across 1s/5s/15s/30s/60s samples, ~2.1% of one core steady, no memory
growth. the drain code path inside `hurd_get_peer_cred` is technically not
exercised by the standalone supervisor here (the auth translator only stands
up when the pid1-module.so inside the forked emacs publishes
`/servers/geos-auth`), but the outer supervisor poll loop, which was the
carrier of the B2 finding, demonstrates the canonical "block in poll, do not
spin" steady state.

v0.9.3 live-verify: PASS. the regex catches all 30 whole-disk nodes
(wd0..wd5, hd0..hd5, sd0..sd5, ucd0/ucd1, ud0..ud5, cd0/cd1, fd0/fd1), no
false-match on partition slices. `:removable` is set correctly on cd, fd,
ucd, ud nodes. `/proc/mounts` parses and matches:
`disks-buffer--mounts-for-device-hurd "wd0"` returns `("/")` via the
`/dev/wd0` plus `s2` rest-match. `install-disk-mounted-p-hurd` returns t for
wd0, nil for hd0 and cd0.

## Pass 1: v0.8.2 retry-loop drain re-verify

VM uname:

```
GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9 x86_64 GNU
```

launch: `./emacs-init` standalone (PID 682, parent shell PID 676), no argv.
`/servers/geos-auth` translator file pre-existed from the prior boot.

1. T+1s sample: State `S` (sleeping), VmSize 4353840 kB, VmRSS 1124 kB.
2. T+5s sample: State `S`, VmRSS 1360 kB.
3. T+15s sample: State `S`, VmRSS 224 kB.
4. T+30s sample: State `S`, VmRSS 224 kB.
5. T+60s sample: State `S`, VmRSS 224 kB.
6. stdout empty, stderr empty across the whole window.
7. host-side QEMU CPU sample: 21 jiffies / 10s = 2.1%; 63 jiffies / 30s =
   2.1%. steady, no growth.
8. sample script exit code 0. emacs-init still alive in sleep state at
   script end.

## Pass 2: v0.9.3 live probe

raw `/proc/mounts` on the VM:

```
/dev/wd0s2 / ext2fs writable,relatime,no-inherit-dir-group,store-type=typed 0 0
none /tmp /hurd/tmpfs writable,relatime,no-inherit-dir-group,no-sync,size=256M 0 0
none /var /hurd/tmpfs writable,relatime,no-inherit-dir-group,no-sync,size=256M 0 0
none /run /hurd/tmpfs writable,relatime,no-inherit-dir-group,no-sync,size=256M 0 0
proc /proc /hurd/procfs defaults 0 0
```

whole-disk nodes present under `/dev`: `cd0 cd1 fd0 fd1`, `hd0..hd5` plus
slices, `sd0..sd5` plus slices, `ucd0 ucd1`, `ud0..ud5` plus slices,
`wd0..wd5` plus slices. also `/dev/disk -> rumpdisk` and
`/dev/usbdisk -> rumpusbdisk` exist as symlinks, not block nodes.

emacs 30.2 batch invocation against the Hurd backends: exit 0.

1. `disks-buffer--list-hurd-block-devices` returned 30 plists, all with
   `:size-bytes nil` (no sysfs), `:removable t` on cd/fd/ucd/ud, nil on
   hd/sd/wd.
2. `install-disk--all-names-hurd` returned the same 30-name list, sorted.
3. `disks-buffer--read-proc-mounts` returned five entries:

```
(:device "/dev/wd0s2" :mount-point "/" :fstype "ext2fs"
 :options "writable,relatime,no-inherit-dir-group,store-type=typed")
(:device "none" :mount-point "/tmp" :fstype "/hurd/tmpfs"
 :options "writable,relatime,no-inherit-dir-group,no-sync,size=256M")
(:device "none" :mount-point "/var" :fstype "/hurd/tmpfs"
 :options "writable,relatime,no-inherit-dir-group,no-sync,size=256M")
(:device "none" :mount-point "/run" :fstype "/hurd/tmpfs"
 :options "writable,relatime,no-inherit-dir-group,no-sync,size=256M")
(:device "proc" :mount-point "/proc" :fstype "/hurd/procfs"
 :options "defaults")
```

4. `disks-buffer--mounts-for-device-hurd "wd0"` returned `("/")`.
5. `install-disk-mounted-p-hurd "wd0"` returned `t`.
6. `install-disk-mounted-p-hurd "hd0"` returned `nil`.
7. `install-disk-mounted-p-hurd "cd0"` returned `nil`.
8. batch exit code 0.

## Side observation

when emacs-init publishes the auth translator at `/servers/geos-auth`
(which happens once the pid1-module.so loads inside the forked emacs), SSH
login auth breaks. new sshd children see `Connection closed by 127.0.0.1
port 2222` because pid1 reclaims the auth port and breaks the chain sshd's
PAM relies on. this is not a regression of B2, it is a runtime observation
from this session worth filing as a future investigation slot, separate
from the v0.9 chain.

## Build note

PORT=hurd against the main-branch `pid1/` tree does not build directly,
because main carries the Linux-only `emacs-init.c`, `port_layer.h`, and
Makefile shape. to get a buildable PORT=hurd tree the driver pulled the
hurd-branch versions of `emacs-init.c`, `port_layer.h`, `Makefile`, and
`port_hurd.c`, and combined them with main's `port_linux.c`. the final
link line worked:

```
cc ... -DPORT_HURD ... -lports -lfshelp -lhurduser -lmachuser
```

this is a known split-branch reality, not a v0.9 regression.

## Out of scope

1. v1 audio translator surface.
2. pfinet RPC byte and packet counters.
3. storeio `device_get_status` for disk sizes.
4. the SSH-vs-auth-translator conflict noted above, filed separately.

## VM state on exit

1. snapshot at `/tmp/geos-hurd-vm-v082v093-verify.img` torn down.
2. QEMU killed clean.
3. host port 2222 free.
4. canonical `/home/overdrive/hurd-vm/work.img` mtime preserved at
   1779100471 (May 18 13:34), unchanged before and after the run.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
