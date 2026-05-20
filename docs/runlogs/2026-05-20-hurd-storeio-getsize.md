# 2026-05-20: storeio device_get_status probe falsifies the cookbook, file_get_storage_info wins

this slice is the read-only probe i ran on the canonical Debian
GNU/Hurd 0.9 VM before writing any port_hurd.c code for the disks
buffer's per-device size lookup. it follows the v0.9.3 receipt at
docs/runlogs/2026-05-20-hurd-v093-disks-install.md and is what the
HURD_PORT.md row 195 ("storeio device_get_status") gets re-scoped
against. probe-first is the whole point: if i had skipped this and
landed the cookbook RPC as written, the implementation would have
returned MIG_BAD_ID on every disk and i would have been chasing it
through pid1 instead of in a 30-line C file.

## Result

PROBE PASS. falsification is a successful probe outcome; the goal
was to verify the predicted RPC shape, and verification said no.
the cookbook claim that storeio answers `device_get_status` with
`DEV_GET_SIZE` on a `file_t` port returned by `file_name_lookup`
is wrong on Debian Hurd 0.9: the file_t speaks the filesystem
protocol, not the Mach device protocol, and the call returns -303
(`MIG_BAD_ID`). the replacement RPC `file_get_storage_info` from
`hurd/fs.h` works on the same file_t and returns enough structure
to compute the size cleanly.

what is verified: the RPC shape, the size math for the single-run
case (`block_size * sum(run_lengths)`), and the ENXIO surfacing
behaviour for dead `/dev/*` translator nodes. what is not verified:
multi-run / RAID / LVM offsets[] shapes; the actual port_layer.h
slot addition (out of scope, separate commit chain); and the
HURD_PORT.md row 195 edit (separate doc commit).

## What this slice ships

- docs/runlogs/2026-05-20-hurd-storeio-getsize.md: this receipt.
  no code, no header touches, no matrix edits. the receipt is the
  deliverable so the next slice (port_layer slot + port_hurd.c
  implementation) has the correct RPC shape on paper before any
  build.

## Build matrix

Linux dev host: not applicable, the probe is a Hurd-only C file
compiled inside the VM.

Hurd VM: `gcc -Wall -Wextra -Werror -lhurduser -lmachuser`. first
build of the cookbook probe failed with `'DEV_GET_SIZE_RECORDS'
undeclared (first use in this function); did you mean
'DEV_GET_SIZE_RECORD_SIZE'?`. live header at
`/usr/include/x86_64-gnu/device/device_types.h` spells it
`DEV_GET_SIZE_RECORD_SIZE` (the trailing S is "size", not a
plural). after rename, clean build. the replacement probe with
`file_get_storage_info` from `hurd/fs.h` built clean first try.

## Probe run

original hypothesis (device_get_status DEV_GET_SIZE on file_t):

```
/tmp/hurd-storeio-getsize /dev/wd0
device_get_status: -303
EXIT=1

/tmp/hurd-storeio-getsize /dev/wd0s2
device_get_status: -303
EXIT=1

/tmp/hurd-storeio-getsize /dev/hd0
file_name_lookup: No such device or address
EXIT=1

/tmp/hurd-storeio-getsize /dev/cd0
file_name_lookup: No such device or address
EXIT=1

/tmp/hurd-storeio-getsize /nope
file_name_lookup: No such file or directory
EXIT=1
```

-303 decodes via `/usr/include/x86_64-gnu/mach/mig_errors.h` as
`MIG_BAD_ID`, "bad request message ID". the file_t returned by
`file_name_lookup` does not speak the Mach device protocol; it
speaks the filesystem file_t / io_t protocol. settrans args
confirm the wd0 / wd0s2 nodes are storeio front-ends, not raw
device ports:

```
/dev/wd0     -> /hurd/storeio --writable @/dev/disk:wd0
/dev/wd0s2   -> /hurd/storeio --writable --store-type=typed part:2:device:@/dev/disk:wd0
```

the `@/dev/disk:wd0` store-spec defers actual device acquisition
to the rumpdisk translator at `/dev/disk`. so even if i had a
raw device port, it would not be on these nodes.

replacement hypothesis (file_get_storage_info from hurd/fs.h):

```
/tmp/hurd-file-storage-info /dev/wd0
OK /dev/wd0 portsCnt=1 intsCnt=6 offsetsCnt=2 dataCnt=15
  ints: [0]=1 [1]=8192 [2]=512 [3]=1 [4]=15 [5]=0
  offsets (pairs are start,length in store blocks): [0]=0 [1]=8192000
  data (15 bytes):@/dev/disk:wd0 |
EXIT=0

/tmp/hurd-file-storage-info /dev/wd0s2
OK /dev/wd0s2 portsCnt=1 intsCnt=6 offsetsCnt=2 dataCnt=15
  ints: [0]=1 [1]=0 [2]=512 [3]=1 [4]=15 [5]=0
  offsets (pairs are start,length in store blocks): [0]=1953792 [1]=6236160
  data (15 bytes):@/dev/disk:wd0 |
EXIT=0
```

decoded:

- wd0: `block_size` (ints[2]) = 512, single run of 8,192,000 blocks
  = 4,194,304,000 bytes = exactly 4 GB (the image size).
- wd0s2: block_size = 512, single run starting at block 1,953,792,
  length 6,236,160 blocks = 3,192,913,920 bytes, about 3.0 GB
  (matches the v0.9.3 probe's df output for the root slice).
- data blob (15 bytes): the store-spec name `@/dev/disk:wd0`, same
  for the whole disk and the slice; slice offset lives in
  offsets[0], not in the name.
- ints[0] = store class id (1 for this class); ints[1] differs
  (8192 vs 0), probably flags or children-count, not load-bearing
  for size.

size rule for the single-run case:
`total_bytes = ints[2] * sum(offsets[2k+1] for k = 0 .. offsetsCnt/2-1)`.
block_size is in bytes, run lengths are in store blocks. use a
64-bit accumulator; sum overflows 32-bit on multi-TB disks.

dead nodes under the replacement probe:

```
/tmp/hurd-file-storage-info /dev/cd0
file_name_lookup: No such device or address
EXIT=1

/tmp/hurd-file-storage-info /dev/hd0
file_name_lookup: No such device or address
EXIT=1

/tmp/hurd-file-storage-info /nope
file_name_lookup: No such file or directory
EXIT=1
```

cd0 / hd0 exist as `brw-r----- 0,0` translator-backed nodes but
have no live translator on this image (the install image only
attaches the wd disk). implementation should surface ENXIO cleanly
on this case and let the *disks* buffer render `-` for size rather
than aborting the row.

side data, /dev/ node listing:

```
brw-r----- 1 root root 0, 0 /dev/cd0
brw-r----- 1 root root 0, 0 /dev/hd0
brw-r----- 1 root root 0, 0 /dev/wd0
brw-r----- 1 root root 0, 0 /dev/wd0s2
```

all `brw`, all major/minor 0,0 (translator-backed; the kernel
device-number on a Hurd node is a placeholder, per the v0.9.3
finding).

side data, device header listing from `dpkg -L gnumach-dev`:

```
/usr/include/x86_64-gnu/device/audio_status.h
/usr/include/x86_64-gnu/device/bpf.h
/usr/include/x86_64-gnu/device/device.defs
/usr/include/x86_64-gnu/device/device_reply.defs
/usr/include/x86_64-gnu/device/device_request.defs
/usr/include/x86_64-gnu/device/device_types.defs
/usr/include/x86_64-gnu/device/device_types.h
/usr/include/x86_64-gnu/device/disk_status.h
/usr/include/x86_64-gnu/device/irq_status.h
/usr/include/x86_64-gnu/device/net_status.h
/usr/include/x86_64-gnu/device/notify.defs
/usr/include/x86_64-gnu/device/notify.h
/usr/include/x86_64-gnu/device/tape_status.h
/usr/include/x86_64-gnu/device/tty_status.h
```

`file_get_storage_info` lives in `/usr/include/hurd/fs.h`
(libhurduser), not under `device/`. that's the other shape of the
cookbook drift: the prediction reached for the Mach device tree
when the right RPC is in the Hurd fs tree.

VM session shape:

- image: canonical `/home/overdrive/hurd-vm/work.img`, mtime
  preserved at 2026-05-18 13:34:31 +0300 (unchanged from prior
  runs, qcow2 snapshot path).
- QEMU shape: `-enable-kvm -cpu host -drive if=ide -device e1000`,
  ssh on 127.0.0.1:2222.
- cold boot to sshd banner: 50s.
- clean teardown: SIGTERM, exit in 2s, snapshot deleted, port 2222
  released.
- `uname -a`: `GNU geos-hurd 0.9 GNU-Mach
  1.8+git20260224-up-amd64/Hurd-0.9 x86_64 GNU`.
- package versions: `hurd-dev 1:0.9.git20251029-7+b1`,
  `gnumach-dev 2:1.8+git20260224-8`.

## Open follow-ons (do NOT block this slice's commit)

1. land the port_layer.h slot for the storage-info call (working
   name `geos_port_disk_size`) and the port_hurd.c implementation
   that wraps `file_get_storage_info` on a file_t opened by
   `file_name_lookup`. surface ENXIO from the dead-node path as a
   distinct return so the *disks* buffer can render `-` instead of
   aborting. next step: write the port_caps slot proposal and run
   it past pid1-engineer for the seam.

2. edit HURD_PORT.md row 195 from "storeio device_get_status" to
   "file_get_storage_info (hurd/fs.h)" and flip the cell from RED
   to GREEN. include a one-line footnote pointing at this receipt
   so the matrix carries the falsification trail. next step:
   single-file doc commit on main.

3. multi-run offsets[] shape (RAID / LVM / concat stores) is not
   exercised on this image; the single-run rule covers every
   storeio i can hit on the canonical VM. when a multi-run store
   shows up (probably first on a real install with mdadm or LVM
   under storeio), revisit the sum loop and confirm runs are
   non-overlapping. next step: defer until a multi-run store
   exists on the test matrix, no v0.9.4 work needed.

4. cd0 / hd0 / ucd0 / ud0 / fd0 node creation on the canonical
   VM. those translators were never set up because the install
   image only carries the wd disk. not blocking the disks buffer
   work, but worth a settrans pass on the next VM rebuild so the
   ENXIO branch has a live target to regression-test against.
   next step: add to the VM bring-up checklist for the next image.

## Files touched on the main branch

- docs/runlogs/2026-05-20-hurd-storeio-getsize.md (+ this file).

VM state on exit:

1. QEMU child killed clean (SIGTERM, 2s exit).
2. snapshot `/tmp/geos-hurd-vm-storeio-*.img` deleted.
3. host port 2222 free.
4. canonical `/home/overdrive/hurd-vm/work.img` mtime preserved at
   2026-05-18 13:34:31 +0300.
