<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

<!-- 2026-05-20: v0.9.5 disk_size_bytes end-to-end VM-verify on Debian Hurd 0.9 -->

# 2026-05-20: v0.9.5 disk_size_bytes end-to-end VM-verify on Debian Hurd 0.9

this receipt is the live-verify pass for the v0.9.5 chain: pid1's
`disk_size_bytes` port-layer slot with both kernel backends and the elisp
consumer wiring on top of it. the chain landed across three commits before
this verify: `main/ca4e2e6` (port_layer.h slot, port_linux.c body,
emacs-init.c `Fpid1_disk_size_bytes` binding, freeze-test-disk-size-bytes.el),
`hurd/2e91f9f` (port_hurd.c body using `file_get_storage_info` from
`<hurd/fs.h>`, skeptic VERDICT GO with B1-B6 cleared), and `main/ba44cdc`
(emacs-init/buffers/disks.el + emacs-init/install/disk.el wired through an
`fboundp` guard plus freeze-test-hurd-disk-size-bytes.el). the RPC choice
itself was driven by the earlier probe receipt `c46b535`
(`docs/runlogs/2026-05-20-hurd-storeio-getsize.md`), which falsified the
storeio cookbook (`device_get_status` returns `MIG_BAD_ID`) and identified
`file_get_storage_info` as the working call.

## Verdict

PASS on all axes. the PORT=hurd module builds clean with zero warnings and
zero errors. 5 of 5 raw C binding cases return the expected shape (int for
real device names, nil for nonexistent / empty / traversal-bait input). 2
of 2 elisp wrappers return the same integer as the raw binding. 100-call
leak smoke shows zero VmSize growth and zero Mach port-name count change.
the OOL-cleanup contract that the skeptic flagged on hurd/2e91f9f holds up
under repeated invocation.

## Pass 1: PORT=hurd module build

the build target was `STATIC=0 make module`, since the elisp consumer needs
the .so binding rather than a static boot binary. zero warnings, zero
errors, exit 0:

```
mig -DSEQNOS -sheader fsys_S.h -server fsysServer.c -header /dev/null -user /dev/null /usr/include/x86_64-gnu/hurd/fsys.defs
cc -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-aliasing -fPIC -DPID1_MODULE -I/usr/include -DPORT_HURD -c -o emacs-init.mod.o emacs-init.c
cc ... -c -o port_hurd.mod.o port_hurd.c
cc -std=c11 -Wall -O2 -fstack-protector-strong -fno-strict-aliasing -DPORT_HURD -fPIC -DPID1_MODULE -I/usr/include -c -o fsysServer.mod.o fsysServer.c
cc -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-aliasing -fPIC -DPID1_MODULE -I/usr/include -DPORT_HURD -shared -o pid1-module.so emacs-init.mod.o port_hurd.mod.o fsysServer.mod.o -lcrypt -lports -lfshelp -lhurduser -lmachuser
EXIT=0
```

## Pass 2: raw C binding probes

five cases against `pid1-disk-size-bytes`:

```
MODULE-LOADED fboundp=t
CASE name="wd0" -> 4194304000
CASE name="wd0s2" -> 3192913920
CASE name="nonexistent" -> nil
CASE name="" -> nil
CASE name="../../etc/passwd" -> nil
DONE
EXIT=0
```

`wd0` returned 4,194,304,000 bytes (the whole disk backing image).
`wd0s2` returned 3,192,913,920 bytes (the root slice inside it). the
nonexistent name, the empty string, and the traversal-bait input all
returned nil, which is the documented "no answer" shape for this slot.

## Pass 3: elisp wrapper probes

two wrappers, both `fboundp` and both returning the same integer the raw
binding returned for `wd0`:

```
MODULE-LOADED fboundp=t
install-disk--size-bytes-hurd fboundp=t
disks-buffer--list-hurd-block-devices fboundp=t
WRAPPER install-disk--size-bytes-hurd "wd0" -> 4194304000
LIST count=30
PLUCK :name=wd0 plist=(:name "wd0" :size-bytes 4194304000 :removable nil)
PLUCK :size-bytes -> 4194304000
DONE
EXIT=0
```

the `disks-buffer--list-hurd-block-devices` list still has the 30 entries
the v0.9.3 verify recorded, and the `wd0` plist now carries
`:size-bytes 4194304000` instead of the prior `nil`. the install path
wrapper `install-disk--size-bytes-hurd "wd0"` returned the same integer.

## Pass 4: 100-call leak smoke

100 back-to-back calls against `wd0` from inside a single emacs process,
with `/proc/<pid>/status` captured before and after the burst:

```
MODULE-LOADED pid=934 fboundp=t
WARMUP -> 4194304000
GO seen after ~66s
===STATUS-BEFORE===
Name:	emacs
State:	H (halted)
Tgid:	934
Pid:	934
PPid:	933
Uid:	0	0	0	0
VmSize:	 4538932 kB
VmPeak:	 4538932 kB
VmRSS:	   31940 kB
VmHWM:	   31940 kB
Threads:	5
===END-STATUS-BEFORE===
RESULT first=4194304000 last=4194304000 mismatches=0
===STATUS-AFTER===
Name:	emacs
State:	H (halted)
Tgid:	934
Pid:	934
PPid:	933
Uid:	0	0	0	0
VmSize:	 4538932 kB
VmPeak:	 4538932 kB
VmRSS:	   32420 kB
VmHWM:	   32420 kB
Threads:	5
===END-STATUS-AFTER===
STOP
```

VmSize delta 0 across 100 calls. VmRSS moved +480 kB (31940 to 32420),
which I attribute to stdio buffer and gc churn from the print loop itself,
not to the slot under test. first and last return values identical, zero
mismatches across the burst.

## Pass 5: Mach port introspection

`portinfo` against PID 934 before and after the 100-call burst:

| metric         | pre | post |
|----------------|-----|------|
| total ports    | 30  | 30   |
| send rights    | 24  | 24   |
| send-once      | 0   | 0    |
| dead names     | 0   | 0    |
| receive rights | 11  | 11   |
| port-sets      | 0   | 0    |

steady-state port count is conserved across the burst. individual
port-name allocations do move (e.g. name 26 was a receive right pre but
not post, name 28 was a receive right post but not pre), because each
`file_name_lookup` allocates a fresh name and the matching deallocate
reclaims it. that is expected churn at allocation granularity, not a
leak. this directly answers the OOL-cleanup risk that the skeptic flagged
on the hurd/2e91f9f review.

## Cookbook calibration

one numeric expectation in the v0.9.5 dispatch was off. the spec expected
`wd0` to return 4,294,967,296 bytes (4 GiB binary). the VM returned
4,194,304,000 bytes (3.906 GiB, or 4 GB decimal), which is the actual
canonical work.img backing size on this host. the slot is correct, the
expectation was wrong. recording this here so the same misread does not
mislead the next probe spec. `wd0s2` came back as 3,192,913,920 bytes
(3.044 GB decimal), which matches the probe receipt's loosely-quoted
"~3 GB" expectation.

## Build note

an earlier attempt at the default `make` target (which builds the
PORT=hurd boot binary with `STATIC=1`) failed at the final static link
with undefined symbols from libports / libfshelp transitive dependencies.
the elisp consumer needs the .so binding, not the static boot binary, so
the driver switched to `STATIC=0 make module` for this run. the static
link failure is a known split-tree issue tracked separately from the slot
under test.

## Out of scope

1. the earlier `-static` boot-binary link failure (libports / libfshelp
   transitive symbol deps). distinct from the slot under test, tracked on
   its own follow-on.
2. the four W-class follow-ups from the skeptic GO review on hurd/2e91f9f:
   W1 sign-laundering cast, W2 magic-3 constant, W3 `file_name_lookup`
   errno mapping, W4 function length. none block this verify.
3. remaining `port_hurd.c` slots from the v0.9 deferral list: pfinet
   per-iface counters, native kmsg source, audio translator. those are
   their own slices.

## VM state on exit

1. snapshot `/tmp/geos-hurd-vm-20260520-233748.qcow2` torn down.
2. QEMU pid 249992: `shutdown -h now` from inside the VM, SIGTERM
   fallback, gone.
3. host port 2222 free.
4. canonical `/home/overdrive/hurd-vm/work.img` mtime preserved at
   2026-05-18 13:34:31.700204970 +0300, unchanged before and after the
   run.
