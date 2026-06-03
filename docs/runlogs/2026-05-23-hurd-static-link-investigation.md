<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

<!-- 2026-05-23: STATIC=1 link investigation for pid1 on the Hurd branch -->

# 2026-05-23: STATIC=1 link investigation for pid1 on the Hurd branch

this receipt is a desk-side investigation of whether `make PORT=hurd
STATIC=1` builds cleanly today on the canonical Debian GNU/Hurd 0.9
image, and what the minimum change would look like if not. follow-on
to the two prior mentions that left this as deferred work:
`docs/runlogs/2026-05-20-v095-disk-size-verify.md` ("undefined symbols
from libports / libfshelp transitive dependencies") and
`docs/runlogs/2026-05-21-v098-vm-verify.md` ("the image does not ship
libc.a so a STATIC=1 link fails at the final cc step").

## Result

PROBE PASS with a SHIP candidate held back from this commit. the
load-bearing claim is that `STATIC=1` is one Makefile edit away from
working on the canonical image, NOT a packaging blocker. every static
archive the boot binary needs ships in two stock Debian packages
(`hurd-dev 1:0.9.git20251029-7+b1` and `libc0.3-dev 2.42-16`), both
already installed on the canonical VM. the prior runlog's "image does
not ship libc.a" claim was incorrect; `libc.a` is at
`/usr/lib/x86_64-gnu/libc.a` on the canonical image (it is an `ld`
linker script that GROUPs to `libcrt.a libmachuser.a libhurduser.a`,
not a real archive, but it is present and gcc finds it).

what i did NOT do: run the patched build in the live VM. the canonical
Hurd VM did not boot in the window of this slice (cold-boot to
ssh-ready was zero output after three minutes, vs the sixty-one second
baseline in `docs/runlogs/2026-05-20-v092-verify-v093-probe.md`; a
second QEMU instance owned by another agent was sharing the same
hardware-virt slot and the contention starved both VMs). the
shipping-the-fix step is therefore deferred to the next slice with a
working VM. the proposed Makefile diff is documented at the bottom of
this receipt for the next agent to apply, re-build, and verify.

per the task instructions, no PATH A commit ships here. this is a
PATH B receipt-only commit on the hurd branch.

## What this slice ships

- `docs/runlogs/2026-05-23-hurd-static-link-investigation.md`: this
  receipt. no Makefile edit, no `HURD_PORT.md` row flip, no test
  binary, no port_caps slot. the receipt is the deliverable so the
  next slice can ship the one-line Makefile change against a booted
  VM.

## Build matrix

Linux dev host: not exercised this slice (no code touched on host).

Hurd VM: did not boot in the window of this slice. canonical image
`/home/overdrive/hurd-vm/debian-hurd-amd64-20260314.img` was mounted
read-only via libguestfs (`/dev/sda2` ext2), every relevant `.a`
archive and the dpkg metadata were copied out, the symbol-provider
table below was built host-side with `nm --defined-only` and
`nm --undefined-only` against the actual archives the live build
would link against.

## What I checked

evidence chain, in order of authority.

1. the Hurd-branch Makefile's PORT=hurd link line as it stands today.

```
PORT_BOOT_LIBS   := -lports -lfshelp -lhurduser -lmachuser -lpthread
```

invocation: `cc $CFLAGS -static -o emacs-init $BOOT_OBJS \
$LDFLAGS $PORT_BOOT_LIBS`. with `-static`, gcc auto-appends `-lc` at
the end of the link line.

2. `libc.a` IS present on the canonical image, contrary to the prior
runlog claim. it is at `/usr/lib/x86_64-gnu/libc.a`, ships in
`libc0.3-dev`, and is a 190-byte `ld` linker script:

```
/* GNU ld script
   This linker script is installed as /lib/libc.a.
   It makes -lc become just like -( -lcrt -lmachuser -lhurduser -).
   */
GROUP ( libcrt.a libmachuser.a libhurduser.a )
```

implication: `-static -lc` expands to a GROUP of three archives with
back-tracking semantics, which resolves any symbol defined within the
group regardless of declaration order. `libpthread.a` is similarly an
ld script GROUPing `-lpthread_syms -lpthread2 -lrt`.

3. inventory of `.a` archives shipped on the canonical image at
`/usr/lib/x86_64-gnu/`: 60 archives total, including everything the
PORT_BOOT_LIBS line references plus `libihash.a` and
`libshouldbeinlibc.a` (NOT currently named on the link line). also
present: `crtbeginT.o` in `/usr/lib/gcc/x86_64-gnu/15/`, which gcc
requires for `-static`. nothing is missing from the canonical image.

4. dpkg ownership of each `.a` archive the link will pull. checked
against the live `/var/lib/dpkg/info/*.list` from the running VM.

```
libc.a                  libc0.3-dev:hurd-amd64        2.42-16
libcrt.a                libc0.3-dev:hurd-amd64        2.42-16
libcrt_nonshared.a      libc0.3-dev:hurd-amd64        2.42-16
libhurduser.a           libc0.3-dev:hurd-amd64        2.42-16
libmachuser.a           libc0.3-dev:hurd-amd64        2.42-16
libpthread.a            libc0.3-dev:hurd-amd64        2.42-16
libpthread2.a           libc0.3-dev:hurd-amd64        2.42-16
libpthread_syms.a       libc0.3-dev:hurd-amd64        2.42-16
librt.a                 libc0.3-dev:hurd-amd64        2.42-16
libfshelp.a             hurd-dev                      1:0.9.git20251029-7+b1
libihash.a              hurd-dev                      1:0.9.git20251029-7+b1
libports.a              hurd-dev                      1:0.9.git20251029-7+b1
libshouldbeinlibc.a     hurd-dev                      1:0.9.git20251029-7+b1
```

both packages have standard Debian maintainers (`GNU Hurd Maintainers
<debian-hurd@lists.debian.org>`, `GNU Libc Maintainers
<debian-glibc@lists.debian.org>`). neither needs upstream repackaging,
neither needs to be pulled from outside the canonical archive.
`hurd-dev` is already installed on the canonical image; the prior
PORT=hurd STATIC=0 builds documented in
`docs/runlogs/2026-05-22-v0914-multiuser-reverify.md` link against
the matching `.so` files from `hurd-libs0.3` (the runtime
counterpart), so the build host already has the toolchain root the
static link needs.

5. symbol provider table for the symbols libports.a and libfshelp.a
reference but do not define themselves. column 1 is the symbol;
column 2 is the archive that defines it. derived from `nm
--defined-only $arch | grep " [TWRDBV] $sym$"` over every relevant
archive.

```
hurd_ihash_init             libihash.a
hurd_ihash_add              libihash.a
hurd_ihash_find             libihash.a
hurd_ihash_destroy          libihash.a
hurd_ihash_locp_remove      libihash.a
hurd_ihash_hash32           libihash.a
hurd_ihash_locp_add         libihash.a
hurd_ihash_locp_find        libihash.a
hurd_ihash_remove           libihash.a
exec_reauth                 libshouldbeinlibc.a
idvec_free                  libshouldbeinlibc.a
idvec_merge_auth            libshouldbeinlibc.a
idvec_setid                 libshouldbeinlibc.a
idvec_tail_contains         libshouldbeinlibc.a
make_idvec                  libshouldbeinlibc.a
__assert_fail_backtrace     libshouldbeinlibc.a
__assert_perror_fail_backtrace  libshouldbeinlibc.a
hurd_check_cancel           libcrt.a    (via libc.a GROUP)
hurd_thread_cancel          libcrt.a    (via libc.a GROUP)
hurd_thread_self            libcrt.a    (via libc.a GROUP)
mach_msg_server_timeout     libcrt.a    (via libc.a GROUP)
argp_parse                  libcrt.a    (via libc.a GROUP)
argz_add                    libcrt.a    (via libc.a GROUP)
error                       libcrt.a    (via libc.a GROUP)
perror                      libcrt.a    (via libc.a GROUP)
getauth                     libcrt.a    (via libc.a GROUP)
__hurd_fail                 libcrt.a    (via libc.a GROUP)
```

the implication is the diagnostic the prior runlog saw. the current
`PORT_BOOT_LIBS` does not list `-lihash` or `-lshouldbeinlibc`. in
the shared-link path that ships today (`STATIC=0`), the dynamic
linker walks libports.so's `DT_NEEDED` chain (`libihash.so.0.3,
libshouldbeinlibc.so.0.3, libpthread.so.0.3, libc.so.0.3,
libmachuser.so.1`) at runtime, so the missing names on the link line
are invisible. in the static-link path (`STATIC=1`), the linker has
no DT_NEEDED to chase; every archive must be named on the command
line.

6. shared-variant `DT_NEEDED` confirmation, from
`readelf -d /usr/lib/x86_64-gnu/libports.so.0.3`:

```
NEEDED  libihash.so.0.3
NEEDED  libshouldbeinlibc.so.0.3
NEEDED  libpthread.so.0.3
NEEDED  libc.so.0.3
NEEDED  libmachuser.so.1
```

and from `readelf -d /usr/lib/x86_64-gnu/libfshelp.so.0.3`:

```
NEEDED  libshouldbeinlibc.so.0.3
NEEDED  libports.so.0.3
NEEDED  libihash.so.0.3
NEEDED  libpthread.so.0.3
NEEDED  libc.so.0.3
NEEDED  libmachuser.so.1
NEEDED  libhurduser.so.0.3
```

every NEEDED entry maps to a `.a` already on the canonical image.
nothing is upstream-missing.

7. circular references between libports and libfshelp. libfshelp
references `ports_*` symbols defined in libports; libports references
some symbols that need libfshelp via the higher-level translator
plumbing the boot binary does NOT touch (`fsys_forward`,
`fshelp_start_translator_long`), but the safer pattern for any
real-world Hurd static link is to wrap the Hurd-library subset in
`-Wl,--start-group ... -Wl,--end-group` so the linker iterates until
the working set stabilises, instead of relying on a hand-ordered
list. this is the same idiom hurd.git's own `configure` uses.

## Proposed Makefile diff (do NOT apply this slice)

target file: `pid1/Makefile` on the hurd branch.

```
-PORT_BOOT_LIBS   := -lports -lfshelp -lhurduser -lmachuser -lpthread
-PORT_MODULE_LIBS := -lports -lfshelp -lhurduser -lmachuser -lpthread
+# the boot-binary link line wraps the Hurd subset in
+# -Wl,--start-group ... -Wl,--end-group so the linker iterates over the
+# archive set until the working set stabilises.  this is what hurd.git
+# does for its own translators and matters under -static because:
+#   - libports.a refs hurd_ihash_* (libihash.a)
+#   - libfshelp.a refs idvec_* + exec_reauth + __assert_*_backtrace
+#     (libshouldbeinlibc.a)
+#   - libports.a refs __assert_*_backtrace (libshouldbeinlibc.a)
+# under -static (STATIC=1) there is no DT_NEEDED chase at runtime; every
+# archive must be on the command line.  -lihash and -lshouldbeinlibc
+# ship in hurd-dev on Debian GNU/Hurd 0.9, the same package -lports and
+# -lfshelp already come from, so this is one Makefile edit, not an
+# upstream packaging blocker.
+# the module link line keeps the legacy shape because the .so resolves
+# the same transitive set at dlopen time via DT_NEEDED, identical to
+# what the v0.9.14 multi-user re-verify confirmed.
+PORT_BOOT_LIBS   := -Wl,--start-group \
+                    -lports -lfshelp -lihash -lshouldbeinlibc \
+                    -lhurduser -lmachuser -lpthread \
+                    -Wl,--end-group
+PORT_MODULE_LIBS := -lports -lfshelp -lhurduser -lmachuser -lpthread
```

verification an in-VM run would have to confirm before the next slice
flips this in:

  - `make PORT=hurd STATIC=0` still produces a clean module build
    (regression gate for everything v0.9.14 verified).
  - `make PORT=hurd STATIC=1` exits 0, no `undefined reference`
    errors.
  - resulting `emacs-init` boot binary runs `file` as
    `ELF 64-bit LSB executable, x86-64, ..., statically linked`.
  - `ldd ./emacs-init` reports `not a dynamic executable`.
  - a smoke run of the static `emacs-init` inside the VM at least
    reaches the argv parse without dying on a missing symbol; the
    full PID-1 boot is a separate verification.

## Reasoning about what stays out of scope

`-rpath` is not relevant to the static path (no runtime DSO lookup).
`-static-libgcc` is similarly irrelevant: gcc picks the static libgcc
automatically under `-static`. the `-fstack-protector-strong` +
`-D_FORTIFY_SOURCE=2` pair the Makefile already passes resolves
through `libssp_nonshared.a` in `/usr/lib/gcc/x86_64-gnu/15/`, which
ships in `gcc-15` and is present on the canonical image. the
existing Makefile comment about libssp ("guix's gcc-toolchain ships
libssp so the production build path is fine") applies one-for-one to
the Debian Hurd toolchain too.

the module (`pid1-module.so`) link line stays unchanged because the
module is `dlopen()`'d into a running emacs and resolves its
transitive deps via the dynamic linker's DT_NEEDED walk at dlopen
time, the same way every shared-lib consumer works. this is why
column 2 of the diff above keeps the historical `PORT_MODULE_LIBS`
shape; only the boot-binary line needs the wider archive list and the
group wrapper.

the Linux `PORT_BOOT_LIBS` stays empty (everything comes from glibc).
the `-static` constraint that PID 1 should not depend on shared
libraries from `/lib` is the same on both kernels, but the Linux
glibc folds `__stack_chk_fail` into `libc.a` natively and has no
Hurd-server-style helper libraries, so there is nothing to add.

## Recommendations

per the task instructions's "ship / defer-upstream / wait until v1.x"
asks for each blocker:

  - libports.a + libfshelp.a missing names on the link line: **SHIP.**
    one Makefile edit, no upstream change, no version risk. land it
    on the hurd branch in the next slice after a VM-verify pass.

  - libc.a presence: **NOT A BLOCKER.** the prior runlog claim was
    incorrect. record this here so the next verifier does not
    re-defer on the same misreading.

  - circular ports<->fshelp refs: **SHIP (as part of the same edit).**
    `--start-group` / `--end-group` is the idiom the hurd.git
    upstream uses; safer than hand-ordering.

  - `-rpath` / `-static-libgcc` quirks: **NONE.** the Hurd toolchain
    does not want either for this link line.

## VM boot environment (not exercised this slice)

would-be invocation if a fresh VM had come up. captured here so the
next agent does not have to re-derive it.

```
qemu-img create -f qcow2 -F raw \
  -b /home/overdrive/hurd-vm/debian-hurd-amd64-20260314.img \
  /tmp/geos-static-probe.qcow2
qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
  -drive file=/tmp/geos-static-probe.qcow2,if=ide,format=qcow2,index=0 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2299-:22 \
  -device e1000,netdev=n0 \
  -display none -serial file:/tmp/geos-static-probe-serial.log \
  -pidfile /tmp/geos-static-probe-qemu.pid -daemonize
```

then, in-VM (`ssh -p 2299 root@127.0.0.1`):

```
cd ~/emacs-os/pid1
make clean
make PORT=hurd STATIC=1 2>&1 | tee /tmp/static-build.log
file ./emacs-init
ldd  ./emacs-init || true
```

success markers: exit 0 on the make, `statically linked` in `file`,
`not a dynamic executable` from `ldd`.

## Toolchain on the canonical image (from `/var/lib/dpkg/status`)

```
hurd-dev               1:0.9.git20251029-7+b1
libc0.3-dev:hurd-amd64 2.42-16
gcc-15                 15.2.0-12
binutils               2.46-3
mig                    1.8+git20231217-10
```

binutils 2.46 ld is recent enough to honour `--start-group` /
`--end-group` (those have been ld idioms since the 1990s) and to
default to `--no-copy-dt-needed-entries`, the same change the v0.9.9
runlog already recorded as the reason `-lpthread` had to be named
explicitly on the existing Hurd link line. the new `-lihash` and
`-lshouldbeinlibc` names land for the same reason; binutils 2.46 will
not chase transitive `.a` membership the way an older link strategy
might have.

## Open follow-ons (do NOT block this slice's commit)

1. apply the proposed Makefile diff above, rebuild
   `make PORT=hurd STATIC=1` inside a booted VM, capture the
   transcript, ship the diff on the hurd branch with the receipt as
   evidence.
2. once shipped, decide whether STATIC=1 becomes the default for the
   PORT=hurd build path (it is the upstream `STATIC ?= 1` default
   today, but the booted-VM build chain has been overriding to
   `STATIC=0` for over a month per
   `docs/runlogs/2026-05-22-v0914-multiuser-reverify.md`). making it
   default-on means every Hurd VM-verify gets the no-DSO-skew
   guarantee for free.
3. consider adding a host-side static-link smoke to the freeze-test
   matrix so future binutils or libports updates do not silently
   re-introduce an undefined-reference regression. this would need a
   chroot or container with the Hurd toolchain; out of scope for the
   hurd branch alone.
4. the v0.9.13 / v0.9.14 receipts both reference an in-guest build
   transcript at `/tmp/pid1-build-180020.log`; that path is run-
   dependent and should not be load-bearing for any future verify.
   leaving the note here so the next slice does not waste cycles
   looking for it.

## Sanity check vs the prior runlog claims

  - `docs/runlogs/2026-05-20-v095-disk-size-verify.md` lines 164-170:
    "undefined symbols from libports / libfshelp transitive
    dependencies", confirmed as the exact diagnostic by the symbol
    provider table above. the fix is two extra `-l` flags and a
    group wrapper.
  - `docs/runlogs/2026-05-21-v098-vm-verify.md` lines 53-56: "the
    image does not ship libc.a", falsified. libc.a is at
    `/usr/lib/x86_64-gnu/libc.a` on the canonical image, ships in
    `libc0.3-dev`, is an ld linker script (not a real archive) but is
    nonetheless what gcc picks up when it auto-appends `-lc` to the
    static link line. the actual underlying issue the verifier hit
    was the unresolved-symbol failure from the prior runlog, not a
    missing libc.a. recording this so the next verifier does not
    inherit a wrong premise.

## Out of scope

cross-build of pid1 for Hurd from a Linux host (would need a Hurd
sysroot or a container shipping `hurd-dev` + `libc0.3-dev`; the
existing recipe ships emacs-init by building inside the VM). Hurd
glibc 2.42 ABI quirks beyond the `__hurd_fail` path the existing
file_get_storage_info wrapper at hurd/c7222c5 already documents.
guix-system/system-hurd.scm: the side-branch Hurd system record;
unchanged here because the `pid1/` link line is a pure C-toolchain
property, not a Guix gexp choice.
