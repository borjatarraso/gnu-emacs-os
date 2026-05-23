# 2026-05-23: v0.9.17 in-VM STATIC=1 link verify on Debian GNU/Hurd 0.9

this is the live-verify slice that closes the v0.9.16 follow-on #2:
PORT=hurd STATIC=1 links cleanly on a real Hurd toolchain. the v0.9.16
cycle shipped the Makefile diff (--start-group / --end-group wrap of
the Hurd subset) with host-side parse clean and the dynamic-link path
proved inert, but the link itself had never run against a real Hurd
toolchain because /usr/include/x86_64-gnu/hurd/fsys.defs only exists
on a Hurd VM. this receipt does that link, in-VM, and flips
docs/HURD_PORT.md row 291 ("STATIC=1 link cleanliness on Hurd") from
PENDING to YES at main/c671132 and hurd/ea1b6fa. prior receipt is
docs/runlogs/2026-05-23-hurd-v0916-cold-boot-verify.md.

## Result

PASS on the load-bearing claim. `PORT=hurd STATIC=1 make -C pid1`
completed with exit 0 inside the v0.9.16 work snapshot, produced a
1,552,824-byte ELF that `file` reports as "statically linked ... for
GNU/Hurd 0.0.0", `ldd` reports as "not a dynamic executable", and
`readelf -d` reports as "no dynamic section in this file". the same
toolchain in the same VM produced a 51,592-byte STATIC=0 reference
binary whose `ldd` resolved the full six Hurd .so chain
(libports/libfshelp/libihash/libshouldbeinlibc/libhurduser/libmachuser)
plus libpthread, libc, and ld. the 30.1x size delta is the expected
shape when all six Hurd archives + libpthread + libc fold inline.

what is not verified by this receipt: a runtime `--self-test` of the
STATIC=1 binary. pid1 has no `--self-test` mode and the SSH-invoked
attempt hung the channel because the binary fell through to the PID-1
startup path. I substituted `file` + `readelf -d` + the STATIC=0 vs
STATIC=1 size delta per the recipe's documented fallback. follow-on #1
is the real `--self-test` mode for future cycles.

## What this slice ships

- main/c671132 and hurd/ea1b6fa: docs/HURD_PORT.md row 291 flipped from PENDING to YES with this receipt as the citation
- docs/runlogs/2026-05-23-hurd-v0917-static-in-vm-verify.md (this file, main only; the hurd-side HURD_PORT.md edit was cherry-picked separately)

no pid1 source change. no Makefile change. the v0.9.16 hurd/5a2acec
Makefile diff is what got verified here.

## Build matrix

Linux dev host: unchanged from v0.9.16. `make PORT=linux -C pid1`
builds clean to emacs-init; `PORT=hurd STATIC=1 make -C pid1 -n`
parses the recipe clean; the host stops at `No rule to make target
'/usr/include/x86_64-gnu/hurd/fsys.defs'` because the Hurd toolchain
is not installed on this host. this is the exact gap that motivated
this slice.

Hurd VM (KVM, work.img snapshot from v0.9.16 verify cycle):
`PORT=hurd STATIC=1 make -C pid1` exit 0; binary 1,552,824 bytes,
statically linked, no dynamic section, no .so chain. preserved
snapshot at /tmp/geos-hurd-vm-v0916-work-1779546177.qcow2, QEMU pid
1586142 still up on host port 2266 at the time of writing. KVM accel
only; TCG wedges Hurd at SeaBIOS on this host per the v0.9.16 cold-boot
recipe.

## VM access notes

- /tmp/geos-hurd-vm-v0916-work-1779546177.qcow2 is the working snapshot from the v0.9.16 cold-boot verify cycle, carried forward unchanged into this session
- QEMU pid 1586142 up, KVM accel, host SSH on 127.0.0.1:2266, key at /tmp/hurd_vm_key, root login
- toolchain on the VM: gcc 15.2.0, binutils 2.46, mig at /usr/bin/mig; zero apt installs needed
- dpkg DB returned empty in this snapshot (anomaly worth recording; both the binaries and the /usr/include/x86_64-gnu/hurd/*.defs headers were intact, so the build path did not need the dpkg DB)

## Probe run

build log /tmp/static-build.log:

```
rm -f emacs-init pid1-module.so *.o fsysServer.c fsys_S.h
---BUILD-START---
mig -DSEQNOS \
    -sheader fsys_S.h \
    -server fsysServer.c \
    -header /dev/null \
    -user /dev/null \
    /usr/include/x86_64-gnu/hurd/fsys.defs
cc -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-aliasing -DPORT_HURD -c -o emacs-init.boot.o emacs-init.c
cc -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-aliasing -DPORT_HURD -c -o port_hurd.boot.o port_hurd.c
cc -std=c11 -Wall -O2 -fstack-protector-strong -fno-strict-aliasing -DPORT_HURD -c -o fsysServer.boot.o fsysServer.c
cc -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-aliasing -DPORT_HURD -static -o emacs-init emacs-init.boot.o port_hurd.boot.o fsysServer.boot.o  -Wl,--start-group -lports -lfshelp -lihash -lshouldbeinlibc -lhurduser -lmachuser -lpthread -Wl,--end-group
/usr/bin/ld: warning: pt-hurd-cond-timedwait.o: requires executable stack (because the .note.GNU-stack section is executable)
---BUILD-EXIT=0---
```

exit 0. one benign link warning, quoted verbatim:

```
/usr/bin/ld: warning: pt-hurd-cond-timedwait.o: requires executable stack (because the .note.GNU-stack section is executable)
```

this comes from libpthread.a in the Hurd toolchain (glibc's hurd port
upstream), fires for any STATIC link that pulls libpthread.a, and is
not in pid1 source. follow-on #3 covers filing it upstream.

ldd ./emacs-init (STATIC=1):

```
	not a dynamic executable
LDD-EXIT=1
```

readelf -d ./emacs-init:

```
There is no dynamic section in this file.
```

file ./emacs-init:

```
./emacs-init: ELF 64-bit LSB executable, x86-64, version 1 (GNU/Linux), statically linked, BuildID[sha1]=56280a2fd1b622082e008352e69e4f94adbccf9e, for GNU/Hurd 0.0.0, not stripped
```

ls -l ./emacs-init (STATIC=1):

```
-rwxr-xr-x 1 root root 1552824 May 23 16:55 ./emacs-init
```

size ./emacs-init (STATIC=1):

```
   text	   data	    bss	    dec	    hex	filename
1378972	  32184	  92584	1503740	 16f1fc	./emacs-init
```

three pieces of evidence converge: (a) `file` says statically linked
for GNU/Hurd 0.0.0, (b) `ldd` says not a dynamic executable, (c)
`readelf -d` says no dynamic section. those three together are
sufficient to claim the binary has zero runtime .so dependencies.

## STATIC=0 reference build for size delta

built in the same VM in the same session as a control:

- ls -l ./emacs-init.dynamic = 51,592 bytes
- STATIC=1 / STATIC=0 ratio = 1,552,824 / 51,592 = 30.1x
- ldd of the STATIC=0 binary resolved libports.so, libfshelp.so, libihash.so, libshouldbeinlibc.so, libhurduser.so, libmachuser.so, libpthread.so, libc.so, and ld dynamically

the 30.1x growth is the expected shape when all six Hurd archives plus
libpthread plus libc fold inline. nothing about the static binary
suggests something the dynamic binary did not also pull, and the
six-library set inside --start-group / --end-group is exactly what
PORT_MODULE_LIBS advertised at the Makefile layer in v0.9.16.

## Self-test substitution note

pid1 has no `--self-test` flag in v0.9.17. when I tried to exec the
STATIC=1 binary over SSH to "see it run and exit", the binary fell
through to the PID-1 startup path and hung the SSH channel (it was not
PID 1 in that context, but the startup path does not gate on `getpid()
== 1` before opening /dev/console). I killed the SSH process and fell
back to `file` + `readelf -d` + the STATIC=0 size delta per the
recipe's documented fallback. follow-on #1 is the real fix: a
`--self-test` mode that exits 0 after printing build metadata, so
future STATIC verify cycles do not need the substitute.

the substitute is rigorous in the sense that the three commands
together cannot be satisfied by a binary that secretly retained a .so
dependency. it does not prove the binary runs to main() and exits
cleanly, which is what `--self-test` would prove.

## Preserved artifacts

- /tmp/geos-hurd-vm-v0916-work-1779546177.qcow2 (working snapshot, 11 MiB after build, preserved)
- QEMU pid 1586142, host port 2266, key /tmp/hurd_vm_key (still up at the time of writing)
- /root/pid1/emacs-init on the VM (STATIC=1, 1,552,824 B)
- /root/pid1/emacs-init.dynamic on the VM (STATIC=0, 51,592 B, kept for future diffs)
- /tmp/v0917-pid1-hurd-tree/pid1/ host-side staging tree (hurd HEAD b070767c)
- /tmp/static-build.log (full build log including the mig invocation and the one benign warning)
- /tmp/static-vs-dynamic.log (STATIC=0 vs STATIC=1 size comparison)

## Open follow-ons (do NOT block this slice's commit)

1. pid1 has no `--self-test` mode. ship one so future STATIC verify cycles do not have to fall back to `file` + `readelf -d`. low priority; the substitute evidence is rigorous, just less direct than `./emacs-init --self-test; echo $?`. next step: a one-flag branch in main() that prints PORT / STATIC / build-id and exits 0 before the PID-1 startup path opens /dev/console.
2. the verified snapshot is a v0.9.16 work image with v0.9.12 pid1 baked in. the load-bearing claim should hold for any canonical Debian Hurd 0.9 with hurd-dev installed, but a clean-room reproduction once would be reassuring (and would also exercise the apt path for the toolchain, which I skipped here because the binaries were already present). next step: cold-boot a fresh canonical image, `apt install hurd-dev gcc binutils mig` from scratch, repeat the build, repeat the three smoke commands.
3. file the `pt-hurd-cond-timedwait.o` `.note.GNU-stack` warning upstream against glibc's hurd port (libpthread.a). cosmetic; the warning is benign and predates this work by years. next step: minimal repro against vanilla libpthread.a, file against the Hurd glibc tracker.

## Closing

v0.9.17 closes the v0.9.16 follow-on #2: PORT=hurd STATIC=1 builds and
links on real Debian GNU/Hurd 0.9, produces a binary with zero
dynamic dependencies, and folds the full Hurd archive set inline via
--start-group / --end-group exactly as the Makefile diff at hurd/5a2acec
advertised. HURD_PORT.md row 291 is YES. the next time anything in the
Hurd STATIC link path changes, 2026-05-23 is the bisect waypoint that
says STATIC=1 linked clean here.

## Files touched on the main branch

- docs/HURD_PORT.md (row 291 PENDING -> YES, citation flipped to this receipt, at c671132)
- docs/runlogs/2026-05-23-hurd-v0917-static-in-vm-verify.md (+this file)
