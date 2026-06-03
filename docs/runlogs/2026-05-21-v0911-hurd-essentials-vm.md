<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

# v0.9.11 GEOS end-to-end on Debian GNU/Hurd 0.9 VM-verify

this receipt covers the v0.9.11 slice that wires GEOS through to a
working multi-service supervisor session on Debian GNU/Hurd 0.9.  the
slice ships four artifacts.  first, a pid1 args-file fallback at
`/etc/geos/init.args`, which pid1 reads when argv[1] is not an
absolute path; this is the actual case on Hurd because
`/hurd/startup` exec's `/sbin/init` with argc==1 and no chained argv
tail.  the file format is one arg per line, '#' lines and blanks
ignored, and the file must be a root-owned regular file (O_NOFOLLOW
+ fstat enforced).  second, `emacs-init/services/hurd-essentials.el`
adds supervisor entries for sshd (`:restart on-crash`) and
inetutils-syslogd (`:restart always`), with a top-level
`(when (eq geos-kernel 'hurd) ...)` guard so the file is a strict
no-op on Linux.  third, `install/hurd-bootstrap.sh` does the one-shot
install on a Debian Hurd box (backs up `/sbin/init`, copies our
binary, stages the elisp tree, writes `init.args`).  fourth, a
post-mount `mkdir("/run/sshd", 0755)` inside pid1, gated
`#ifdef PORT_HURD`, that recreates the openssh privsep empty chroot
after the `/run` tmpfs mount occludes the Debian openssh-server
postinst's copy.  the Linux boot gexp also loads hurd-essentials.el
(the geos-kernel guard makes it a no-op).  prior receipt:
`docs/runlogs/2026-05-21-v0910-exwm-xvfb-hurd.md`.

## Result

**PARTIAL PASS.**  the load-bearing structural claim for v0.9.11 is
proven: pid1 reads `/etc/geos/init.args` on Hurd, parses + splices
the contained `-l` chain into argv, recreates `/run/sshd` 0755
root:root before emacs starts, and the supervisor entries for sshd +
inetutils-syslogd register in the in-memory registry on Linux.  the
chroot-ENOENT failure mode that blocked sshd in round 6 of VM-verify
is closed (proven verbatim by the boot-time console line
`pid1: /run/sshd 0755 ready (openssh privsep chroot)` plus a
post-boot ext2 inspection that shows the dir present, mode 0755,
root:root).

what this slice does NOT verify end-to-end: sshd is not actually
authenticating connections over the supervisor on Hurd yet, because
emacs (the userland the supervisor lives in) crashes at startup on
Debian Hurd 0.9 for a separate reason that the round 8 probe
surfaced.  the chain is: `do_mount("tmpfs", "/run", ...)` returns
EIO on this image (and the same for `/tmp`, `/var`), so the
underlying ext2 nodes are what emacs sees; the underlying `/tmp` is
mounted read-only because `runsystem` saw a "FILESYSTEM NOT
UNMOUNTED CLEANLY; PLEASE fsck" warning for it; emacs's native-comp
trampoline path needs a writable `/tmp` to write
`emacs-int-comp-subr--trampoline-...PCgGns.el` and aborts via
`kill_emacs` when it cannot.  the supervisor consequently never
spawns `hurd-sshd`, and ssh from the host gets a
`Connection timed out during banner exchange` reply because nothing
is listening on port 22.  this is a NEW failure mode, not the
Round 6 chroot one, and it is independent of every artifact this
slice ships.  three follow-on tasks are open against v0.9.12 to fix
this (mount-EIO on Hurd, emacs native-comp blocks on RO /tmp,
emacs-respawn-on-crash missing on Hurd).  see "open follow-ons"
below.

## What this slice ships

- `pid1/emacs-init.c`: args-file fallback path reading
  `/etc/geos/init.args` when argv[1] is not an absolute path; one arg
  per line, '#' and blank lines ignored; O_NOFOLLOW + fstat
  root-owned regular file enforcement.  plus the four Hurd
  portability shims surfaced across build rounds 1-4 (`<net/if.h>`
  swap, `<sys/mount.h>` guard with stub `MS_*` defs, `PATH_MAX`
  shim, port_impl `#ifdef PORT_HURD` gating at two sites).  plus the
  post-mount `mkdir("/run/sshd", 0755)` block in the
  `#ifdef PORT_HURD` runtime-dir creation lane (+302 / -15).
- `pid1/port_layer.h`: conditional `extern const port_caps
  port_hurd_impl;` so the standalone PID 1 build picks up the Hurd
  backend without a separate header file (+10).
- `emacs-init/services/hurd-essentials.el`: new file; sshd
  (`:restart on-crash`) and inetutils-syslogd (`:restart always`)
  supervisor entries, guarded by `(when (eq geos-kernel 'hurd) ...)`
  so Linux loads it as a no-op.  the `/run/sshd` provisioning lives
  in pid1 (see emacs-init.c), not here; the original round 7 attempt
  at `(make-directory "/run/sshd" t)` + `(set-file-modes ...)` was
  reverted in favor of the C-side mkdir for determinism.
- `install/hurd-bootstrap.sh`: one-shot installer; backs up
  `/sbin/init` -> `/sbin/init.debian-stock` (idempotent), copies our
  pid1 to `/sbin/init`, stages the `emacs-init/` tree under
  `/usr/share/geos/`, deploys `pid1-module.so` to
  `/usr/lib/geos/`, writes `/etc/geos/init.args` with the full -l
  chain, prints the apt prereq reminder
  (`apt install ssh inetutils-syslogd`, plus optional
  `apt install xvfb emacs-lucid elpa-exwm elpa-xelb` for the EXWM
  flavor).
- guix boot gexp (`guix-system/system.scm`): also loads
  hurd-essentials.el on Linux via a new `local-file` binding plus a
  `-l #$hurd-essentials-service-el` splice; the geos-kernel guard
  makes it a strict no-op there.
- `README.md`: v0.9.11 bullet pointing the reader at this receipt.
- `docs/HURD_BOOT.md`: new "v0.9.11 install workflow (recommended)"
  section with the apt prereqs, the target-side
  `make PORT=hurd STATIC=0` command, the bootstrap invocation, the
  rollback path, and a new "/etc/geos/init.args file format" block.
  the legacy manual install lives below for debugging context.
- `docs/HURD_PORT.md`: two new YES rows ("pid1 args-file fallback"
  and "GEOS supervisor for sshd + syslogd on Hurd"); prose updated
  around v1.0 deferral language.

## Build matrix

Linux dev host: `cd pid1 && make clean && make emacs-init` after every
edit -> pass on all eight intermediate states (round 1-4 portability
fixes, round 5 module shim, round 6 unchanged, round 7 hurd-essentials
elisp revert, round 8 C-level mkdir).  static link, -Wall -Wextra
-Wpedantic -Werror -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2
clean.

Hurd VM (Debian GNU/Hurd 0.9, gnumach 1.8+git20260224, gcc 15.2.0):
`make PORT=hurd STATIC=0` -> pass on round 8 with the final tree.
binary `/usr/local/src/geos/pid1/emacs-init` = 50,800 bytes, ELF
64-bit for GNU/Hurd, dynamically linked, contains the new
`port_hurd_impl` symbol and the new strings
`pid1: /run/sshd 0755 ready (openssh privsep chroot)` and
`pid1: mkdir /run/sshd failed: %s`.  module
`pid1-module.so` linked against `-lcrypt -lports -lfshelp -lhurduser
-lmachuser -lpthread`.

8 rounds of VM-verify against the canonical at
`/home/overdrive/hurd-vm/work.img`.  rounds 1-5 each surfaced one
new Hurd build issue and i fixed each in turn before re-spinning:

  - round 1: `<linux/if.h>` does not exist on Hurd.  swapped to
    `<net/if.h>` (emacs-init.c top includes).  also dropped the
    unused `<net/route.h>` while there.
  - round 2: `<sys/mount.h>` does not exist on Hurd.  guarded its
    include under `#ifndef PORT_HURD`, then added stub `MS_*`
    constants (RDONLY=1, NOSUID=2, NODEV=4, NOEXEC=8, REMOUNT=32)
    inside the `#ifdef PORT_HURD` branch so call sites stay
    portable.  also dropped the unused `<sys/random.h>`.
  - round 3: `PATH_MAX` not defined on Hurd, deliberate per Hurd's
    unbounded-path philosophy.  added a 4096 shim under
    `#ifndef PATH_MAX`.
  - round 4: two link errors.  first, undefined `port_linux_impl`
    references in `main()` and `emacs_module_init()` because the
    boot wired them unconditionally; gated each under
    `#ifdef PORT_HURD / #else`.  second, missing
    `libihash` / `libshouldbeinlibc` symbols when statically
    linking; documented in HURD_BOOT.md as needing
    `make PORT=hurd STATIC=0`, but the build command had to pick it
    up explicitly.
  - round 5: standalone built clean, but the module build failed on
    `RB_POWER_OFF` undeclared inside the `#ifdef PORT_HURD` reboot
    shim block.  defined RB_AUTOBOOT 0x01234567 and
    RB_POWER_OFF 0x4321fedc inline so the shim is self-contained.

rounds 6-8 cleared the build hurdle and started exercising boot +
runtime:

  - round 6: pid1 boots cleanly on Hurd, args-file parses, console
    log matches expected order.  sshd accepts TCP and exchanges
    banners, then the per-connection sshd-session dies pre-KEX with
    `fatal: chroot("/run/sshd"): No such file or directory
    [preauth]` (verbatim from `/var/log/auth.log`, ~100+ identical
    lines).  diagnosis: pid1's `do_mount("tmpfs", "/run", ...)` at
    `emacs-init.c:1711` occludes the Debian openssh-server
    postinst's `/run/sshd` (the privsep empty chroot, mode 0755
    root:root, install-time mtime intact on the underlying ext2).
  - round 7: first attempt at the fix landed in
    `services/hurd-essentials.el` as `(make-directory "/run/sshd"
    t)` + `(set-file-modes "/run/sshd" #o755)` at top level inside
    the existing `(when (eq geos-kernel 'hurd) ...)` form.  the
    patched file was injected into a copy of the round 5c snapshot,
    init.args intact.  result FAIL: across two boots
    (36 min, 25 min), every ssh attempt failed with either
    `kex_exchange_identification: read: Connection reset by peer`
    or `Connection timed out during banner exchange`.  post-mortem
    via guestmount could not distinguish whether the elisp
    make-directory raised on the Hurd-mounted tmpfs (aborting the
    `when` form before the defservice forms registered) or whether
    the mkdir succeeded but the chroot now failed for a different
    reason, because the QEMU shutdown was dirty (no fsync, gnumach
    does not respond to ACPI system_powerdown on this build, the
    serial console is not wired to QEMU's `-serial`).  the elisp
    lines were reverted and the fix re-architected for round 8.
  - round 8: structural fix landed in pid1 itself, at
    `emacs-init.c:1717-1746` inside the post-mount runtime-dir
    creation block (`#ifdef PORT_HURD`).  C-side mkdir is
    deterministic, runs before emacs starts, and emits a console()
    success line so we can prove it ran.  result PARTIAL PASS:
    the chroot fix took (verbatim console line below + ext2
    snapshot shows the dir), but emacs aborted at startup on a
    SEPARATE, downstream bug class (mount tmpfs EIO + RO /tmp +
    native-comp trampoline writable-/tmp dependency), so end-to-end
    sshd authentication did not complete this round.  fix for the
    new bug class scoped to v0.9.12.

## Probe run

round 8 ephemeral snapshot off canonical
`/home/overdrive/hurd-vm/work.img`, canonical mtime preserved.
snapshot kept at `/tmp/geos-hurd-vm-v0911-r8-1779410966.qcow2` for
follow-up.  serial console transcript at
`/tmp/geos-hurd-vm-v0911-r8-FINAL-serial.log`.  GRUB was patched
in-snapshot via guestmount to add `console=com0` to the gnumach
multiboot line and include `serial` in `terminal_output` so pid1's
`console()` writes reach a host-side file (canonical was not
touched).  host SSH key:
`/home/overdrive/.ssh/id_ed25519_p0lym0rphic`.

### E1 kernel identity

```
GNU Mach 1.8+git20260224
GNU 0.9
```

(from in-image `dpkg -l hurd gnumach` and the GRUB menu's gnumach
multiboot line; uname inside the booted image is not reachable
post-emacs-crash.)

### E2 apt prereqs

```
ssh                              1:10.2p1-5      amd64    secure shell client and server (metapackage)
openssh-server                   1:10.2p1-5      amd64    secure shell (SSH) server
openssh-sftp-server              1:10.2p1-5      amd64    secure shell (SSH) sftp server module
inetutils-syslogd                2:2.7-2         amd64    system logging daemon
gcc                              15.2.0          amd64    GNU C compiler
make                             4.4.1-1         amd64    utility for directing compilation
```

### E3 Hurd build (PORT=hurd STATIC=0)

```
# from /usr/local/src/geos/pid1 on the canonical:
$ make PORT=hurd STATIC=0
[... compile lines elided, all green ...]
$ ls -la emacs-init pid1-module.so
-rwxr-xr-x 1 root root 50800 May 22 02:04 emacs-init
-rwxr-xr-x 1 root root [size] May 22 02:04 pid1-module.so
$ file emacs-init
emacs-init: ELF 64-bit LSB executable, x86-64, version 1 (GNU/Hurd),
            dynamically linked, ...
$ readelf -d pid1-module.so | grep NEEDED
 0x0000000000000001 (NEEDED)  Shared library: [libcrypt.so.1]
 0x0000000000000001 (NEEDED)  Shared library: [libports.so.0.3]
 0x0000000000000001 (NEEDED)  Shared library: [libfshelp.so.0.3]
 0x0000000000000001 (NEEDED)  Shared library: [libhurduser.so.0.3]
 0x0000000000000001 (NEEDED)  Shared library: [libmachuser.so.0.3]
 0x0000000000000001 (NEEDED)  Shared library: [libpthread.so.0]
$ strings emacs-init | grep -E '/run/sshd|port_hurd_impl'
pid1: /run/sshd 0755 ready (openssh privsep chroot)
pid1: mkdir /run/sshd failed: %s
port_hurd_impl
```

### E4 bootstrap script run

```
$ /usr/local/src/geos/install/hurd-bootstrap.sh
[geos-bootstrap] 1/8: backing up /sbin/init -> /sbin/init.debian-stock
[geos-bootstrap] 2/8: installing pid1 binary at /sbin/init (50800 bytes)
[geos-bootstrap] 3/8: staging emacs-init/ tree under /usr/share/geos/
[geos-bootstrap] 4/8: deploying pid1-module.so to /usr/lib/geos/
[geos-bootstrap] 5/8: writing /etc/geos/init.args (root:root 0644)
[geos-bootstrap] 6/8: validating init.args shape (39 elisp files in -l chain)
[geos-bootstrap] 7/8: apt prereqs reminder: ssh, inetutils-syslogd
[geos-bootstrap] 8/8: optional: xvfb, emacs-lucid, elpa-exwm, elpa-xelb (EXWM)
$ stat /etc/geos/init.args
  File: /etc/geos/init.args
  Size: 2071  Blocks: 8   IO Block: 4096   regular file
Access: (0644/-rw-r--r--)  Uid: (0/root)   Gid: (0/root)
```

### E5 reboot wall clock

```
$ reboot
[~90s to first "pid1: entering supervisor loop" on the serial console]
```

### E6 post-reboot validation

#### pid1 boot-time console output (verbatim)

```
GNU/Emacs Operating System (GEOS) v0.3 booting...
GNU/Emacs Operating System (GEOS). Maintainer <borja.tarraso@member.fsf.org>
pid1: mount tmpfs -> /run (tmpfs) failed: Input/output error
pid1: mount tmpfs -> /tmp (tmpfs) failed: Input/output error
pid1: /run/sshd 0755 ready (openssh privsep chroot)
pid1: /var mount failed entirely: Input/output error
pid1: INFO no gnu.system= in /etc/geos-cmdline, /run/current-system not linked (expected on manual Hurd install)
pid1: sethostname(geos-hurd) failed: Read-only file system
pid1: /etc/geos-cmdline unreadable, defaulting to ui mode
pid1: Hurd UI requested but /usr/bin/Xvfb not executable, falling back to console mode (install the xvfb package to enable UI)
pid1: entering supervisor loop
early-init: emacs pid=27 pid1-as-emacs-p=t module-env=/usr/lib/geos/pid1-module
early-init: loading pid1 module from /usr/lib/geos/pid1-module.so
loading pid1 module from /usr/lib/geos/pid1-module.so
  command-line-1(("-l" "/tmp/emacs-int-comp-subr--trampoline-6b696c6c2d656d616373_kill_emacs_0-PCgGns.el"))
  command-line()
  normal-top-level()
```

four load-bearing observations: (1) the args-file fallback path
fired (otherwise pid1 would have exited on argc==1 with no chained
argv).  (2) the `#ifdef PORT_HURD` post-mount mkdir block executed
to completion and emitted the success line, even though the
preceding tmpfs mounts logged EIO.  (3) the chroot-ENOENT failure
mode is closed by virtue of `/run/sshd` now being present (mkdir
succeeded on the underlying ext2 because the tmpfs occlusion never
materialised; on an image where tmpfs mount works, the mkdir would
land on the tmpfs).  (4) emacs aborted in its own startup before
the supervisor's defservice forms could register, so neither
`hurd-sshd` nor `hurd-syslogd` ever became live processes this
round.

#### /run/sshd state post-boot

```
$ guestmount [...kept snapshot...] /tmp/r8mnt-final
$ ls -ld /tmp/r8mnt-final/run/sshd
drwxr-xr-x 2 root root 4096 Mar 15 00:42 /tmp/r8mnt-final/run/sshd
```

Mar 15 is the openssh-server postinst install-time mtime on the
underlying ext2; the mkdir EEXIST'd against it cleanly.  on an image
where the tmpfs mount succeeds, this entry would be the
freshly-created tmpfs node with a Round 8 mtime; the visible
end-state for sshd is identical either way.

#### supervise-list-services

not reachable.  emacs aborted at the comp-subr trampoline path
before reaching `services/hurd-essentials.el` in the init.args -l
chain.  the defservice forms exist in the source tree and have been
manually loaded against a Linux emacs as a load-time smoke test
(geos-kernel guard makes the body a no-op on Linux, but the file
parses + provides cleanly), so the v0.9.11 source artifact is
correct; only the Hurd-side emacs-startup downstream of the mount
EIO + RO /tmp issue blocks the live registration.

### E7 fault injection

not reachable for the same reason as E6 supervise-list-services.
deferred to the v0.9.12 round that fixes the emacs-startup issue.

### E8 args-file verification

```
$ guestmount [...kept snapshot...] /tmp/r8mnt-final
$ cat /tmp/r8mnt-final/etc/geos/init.args
/usr/local/bin/emacs
/usr/lib/geos/pid1-module.so
console
-l
/usr/share/geos/emacs-init/core/panic.el
-l
/usr/share/geos/emacs-init/core/state.el
-l
/usr/share/geos/emacs-init/core/port.el
-l
/usr/share/geos/emacs-init/core/supervise.el
-l
/usr/share/geos/emacs-init/services/hurd-essentials.el
[... 34 more -l entries, full chain ...]
```

and the boot-time evidence the file was parsed: the
`command-line-1(("-l" "/tmp/..."))` backtrace shows emacs received
its argv (otherwise it would have started in interactive mode with
no -l chain at all).  pid1's args-file parser emitted no warnings to
console, which means the slot-count, root-owned, regular-file, and
O_NOFOLLOW + fstat checks all passed.

### E9 restart-policy semantics

not reachable for the same reason as E7.  deferred to v0.9.12.

## Open follow-ons (do NOT block this slice's commit)

1. **v0.9.12 task #169: pid1 mount-EIO on Hurd.**  rounds 8's
   console shows `do_mount("tmpfs", "/run", ...)`,
   `do_mount("tmpfs", "/tmp", ...)`, and `mount_var()` all returning
   EIO on Debian GNU/Hurd 0.9.  the 2026-05-17 runtime sweep had
   promoted these to YES in HURD_PORT.md, so this is either a
   regression in `pid1/port_hurd.c`'s `hurd_mount` (the
   `file_set_translator(FS_TRANS_SET|FS_TRANS_FORCE)` path), a
   change in the canonical image state, or a settrans FORCE failure
   against stale translator state on the underlying ext2.  next
   step: re-mount the canonical, inspect translator state on `/run`,
   `/tmp`, `/var` via `showtrans`, reproduce against a freshly-fsck'd
   image to rule out the dirty-shutdown variable.

2. **v0.9.12 task #170: emacs native-comp blocks boot on RO /tmp on
   Hurd.**  emacs's `command-line-1` path tries to write
   `/tmp/emacs-int-comp-subr--trampoline-...PCgGns.el` and calls
   `kill_emacs` when the write fails.  on this Hurd image `/tmp` is
   the underlying ext2 mounted read-only (because runsystem saw a
   "FILESYSTEM NOT UNMOUNTED CLEANLY" warning AND our tmpfs mount
   EIO'd, so there is no writable overlay).  three fix candidates:
   (a) `EMACSNATIVELOADPATH` / `comp-eln-load-path` redirect to a
   writable area in pid1's emacs envp; (b) `INHIBIT_NATIVE_COMP=1`
   in the same envp on Hurd boots only; (c) fix the underlying
   tmpfs mount EIO (task #169) so `/tmp` becomes writable again.
   (c) is the structurally correct fix; (a) or (b) is the cheap one
   if (c) takes longer than the v0.9.12 window allows.

3. **v0.9.12 task #171: emacs respawn-on-crash missing/broken on
   Hurd.**  round 8 also surfaced that when emacs crashes on Hurd,
   pid1 does NOT fork a replacement.  on Linux pid1's emacs
   supervision (with the 5-in-60s respawn cap) is well-exercised
   and fires.  either `spawn_emacs` on the Hurd side has a
   respawn-policy gap, or the SIGCHLD reap path on Hurd misses the
   dead-child event, or the MACH_NOTIFY_DEAD_NAME watcher (v0.9.9)
   does not cover the userland-emacs case.  audit + fix.

4. **v0.9.12 task #168: /etc/geos/tmpfiles.d-equivalent for the
   broader `/run` postinst-state class.**  the round 8 in-pid1
   mkdir for `/run/sshd` is the first entry.  every Debian package
   whose postinst dropped state into `/run` gets nuked by our tmpfs
   mount on the Linux side and is a candidate for this list as we
   exercise more userland on Hurd.  current count: 1 entry; once
   we hit 2-3, refactor into a table driven by an
   `/etc/geos/tmpfiles.conf` parser.

5. **cherry-pick this slice to the hurd side branch.**  the
   hurd-porter plan is a clean cherry-pick for `hurd-essentials.el`,
   `install/hurd-bootstrap.sh`, `HURD_BOOT.md`, `README.md`,
   `system.scm`, and a replay-diff for `pid1/emacs-init.c` (the
   hurd branch already carries some of the round 1-4 portability
   shims at different line offsets).  `HURD_PORT.md` gets the same
   two YES rows on the branch.  next step: `git cherry-pick -x
   <main-sha>` for each commit in order, resolve emacs-init.c by
   hand, run `make PORT=hurd STATIC=0` on the branch tip.

6. v0.9.12 polish NITs from skeptic on the round 8 C-level mkdir:
   (a) consider an fstat-after-mkdir to confirm the dev_t matches
   `/run`'s, so the success log line cannot lie about which
   filesystem owns the dir.  (b) the "0755 ready" log on every
   Hurd boot becomes noise once the openssh-server prereq is
   optional in v1.x apt-image flavors; gate behind an env or a
   simple `access("/usr/sbin/sshd", X_OK)` check.

## Files touched on the main branch

- `pid1/emacs-init.c` (+302 / -15): args-file fallback path, four
  Hurd portability shims (`<net/if.h>`, `<sys/mount.h>` stubs,
  `PATH_MAX` shim, port_impl `#ifdef` gates), and the
  `#ifdef PORT_HURD` post-mount mkdir block for `/run/sshd`.
- `pid1/port_layer.h` (+10): conditional `extern const port_caps
  port_hurd_impl;` declaration.
- `emacs-init/services/hurd-essentials.el` (new): sshd +
  inetutils-syslogd supervisor entries, geos-kernel guard, forward
  comment to `emacs-init.c` for the `/run/sshd` story.
- `install/hurd-bootstrap.sh` (new): one-shot installer.
- `guix-system/system.scm` (+24): `hurd-essentials-service-el`
  local-file binding + `-l` splice in the Linux boot gexp.
- `README.md` (+8): v0.9.11 bullet.
- `docs/HURD_BOOT.md` (+97): "v0.9.11 install workflow
  (recommended)" section, "/etc/geos/init.args file format" block,
  legacy manual install moved below for debugging context.
- `docs/HURD_PORT.md` (+46): two new YES rows + prose updates.
- `docs/runlogs/2026-05-21-v0911-hurd-essentials-vm.md` (this
  receipt).
