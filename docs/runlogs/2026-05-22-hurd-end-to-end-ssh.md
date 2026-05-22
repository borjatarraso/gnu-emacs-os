# v0.9.12 end-to-end SSH on Debian GNU/Hurd 0.9

this receipt covers the v0.9.12 slice arc that takes GEOS from
"pid1 boots cleanly on Hurd, supervisor entries exist, but the
emacs userland aborts at startup and there is no network so sshd
never gets to authenticate anyone" (v0.9.11 PARTIAL PASS) to
"the host opens an interactive ssh session into the guest and
the supervisor stays up across the session".  the work split
across twelve slices: three for the pid1 remount-root-rw fix
that unwedged the underlying RO `/` blocking native-comp
trampoline writes, one for the early-init.el native-comp opt-out
(belt + suspenders so a future image with a different mount
shape still boots), one for serial-console breadcrumbs on
supervise.el so silent autostart failures stop being invisible
mid-boot, one for the install-side `/root/.emacs.d/early-init.el`
copy so early-init actually loads before tty setup, one for the
syslogd path fix, and five for the network bring-up dance that
ended in a static eth0 configuration via `settrans /hurd/pfinet`
with the full SLIRP address shape inline.  prior receipt:
`docs/runlogs/2026-05-21-v0911-hurd-essentials-vm.md`.

## Result

**PASS.**  the host completes SSH banner exchange and a full
interactive session into the guest.  `inetutils-ifconfig` inside
the guest reports `/dev/eth0` with inet address 10.0.2.15.  the
v0.9.11 PARTIAL PASS chain (mount EIO -> RO `/tmp` -> native-comp
trampoline write fail -> emacs `kill_emacs` -> no supervisor ->
no sshd listener) is fully closed.  the three v0.9.12 open
follow-ons that v0.9.11 declared (tasks #169 mount-EIO, #170
native-comp blocks on RO `/tmp`, #171 emacs respawn-on-crash
missing on Hurd) are addressed structurally by slices 1-3 (the
remount-rw closes #169 by making `/` writable so the underlying
ext2 `/tmp` is writable, which sidesteps #170 entirely; #171
becomes a non-issue in practice because emacs no longer crashes,
and stays open for v0.9.13+ as a defence-in-depth item).

## What the twelve slices ship

  - **slice 1** (main `2273694`, hurd `033ed0f`): port_layer.h
    `remount_root_rw` slot.  Linux backend body is a no-op (`/`
    is already rw on the GEOS Linux image).  Plumbed into
    `emacs-init.c` post-mount so it runs early in the boot
    sequence.
  - **slice 2** (hurd `902d8ce` only): port_hurd.c body for
    `remount_root_rw` via `fsys_set_options` against the root
    file_t with `"--writable"`.  closes the Hurd path: stock
    `/hurd/startup` mounts `/` read-only after a dirty shutdown
    warning, and once `/` is rw the underlying ext2 `/tmp` is
    rw too, so native-comp trampoline writes succeed.
  - **slice 3** (verification only, no commit): VM-verify of
    slices 1+2 on Debian Hurd 0.9.  emacs no longer aborts on
    the kill_emacs trampoline path.
  - **slice 4** (main `518b652`, hurd `0c6bc77`): early-init.el
    opts out of native-comp on Hurd (`native-comp-jit-compilation
    nil`, `native-comp-enable-subr-trampolines nil`).  GEOS_KERNEL
    is read directly from env here, because native-comp can fire
    before core/port.el ever loads.  belts + suspenders: if a
    future image presents a different mount shape and `/tmp` ends
    up RO again, the interpretive subr fallback runs and the boot
    completes instead of looping in `gcc -> as -> ld`.
  - **slice 5** (main `15ab281`, hurd `d7c934a`):
    hurd-essentials.el writes a one-line breadcrumb per
    state transition to `/dev/console` via the new
    `supervise--console` helper (slice 9 adds the helper).  any
    future "supervisor silently did nothing" failure now leaves a
    trace on the serial log.
  - **slice 6** (main `95aefdc`, hurd `239ddfd`): install-side
    fix.  `install/hurd-bootstrap.sh` now copies
    `emacs-init/early-init.el` to `/root/.emacs.d/early-init.el`
    so emacs picks it up before tty setup.  without this the
    native-comp opt-out from slice 4 would not actually run.
  - **slice 7** (main `d40db03`, hurd `f0d68b2`): typo fix.
    `hurd-syslogd` was pointing at `/sbin/inetutils-syslogd`;
    Debian ships it at `/usr/sbin/syslogd`.  one-line correction;
    breadcrumb from slice 5 caught it.
  - **slice 8** (main `3b46724`, hurd `9f457e9`): first network
    attempt.  added `hurd-dhclient` defservice that supervised
    `dhclient -d eth0`.  VM-verify came back PARTIAL: dhclient
    spawned clean (pid registered, no sentinel exit), but the
    serial log showed zero DHCPDISCOVER / OFFER / REQUEST / ACK
    chatter across ~30s.  diagnosis pushed to slice 9.
  - **slice 9** (main `f962fb4`, hurd `37c2a71`): added the
    `supervise--console` helper to `emacs-init/core/supervise.el`
    and instrumented `supervise--spawn`, `supervise--sentinel`,
    and `supervise-autostart` to mirror state transitions onto
    `/dev/console`.  refactored `supervise-finalize` to use the
    same helper for consistency (skeptic nit #4 applied).
    confirmed slice 8's dhclient was the dead end: dhclient
    blocked on a BPF/raw-socket path that expects netlink-shaped
    eth0; pfinet does not present it that way.
  - **slice 10** (main `197ee5b`, hurd `c22d54e`): dropped
    `hurd-dhclient` entirely.  QEMU SLIRP always hands out a
    fixed assignment (10.0.2.15/24, gw 10.0.2.2, DNS 10.0.2.3),
    so DHCP for the VM-verify path is theatre.  call
    `pid1-set-address "eth0" "10.0.2.15" 24` +
    `pid1-set-route-default "10.0.2.2" "eth0"` directly from
    the `(when (eq geos-kernel 'hurd) ...)` block.  gated on a
    new `geos-hurd-static-eth0` defcustom (default `t`) so a
    bare-metal Hurd deployment with real DHCP can `(setq
    geos-hurd-static-eth0 nil)` and point an apt-installed
    dhcp client at pfinet.  VM-verify came back FAIL:
    `pid1-set-address` returned ENODEV.  guestmount inspection
    showed `/servers/socket/2` was a plain 0-byte file, not a
    settrans'd pfinet translator; Debian's rc.d chain that would
    settrans it lives downstream of `/sbin/init` and never runs
    once pid1 replaces `/sbin/init`.
  - **slice 11** (main `dda3787`, hurd `75418db`): added a
    one-shot `call-process` to `/bin/settrans` with
    `-fgap /servers/socket/2 /hurd/pfinet -i /dev/eth0` before
    the static-address call.  gated on `file-executable-p
    "/bin/settrans"` and `"/hurd/pfinet"` so the block is a
    strict no-op on Linux and self-skips on a Hurd guest missing
    either binary.  VM-verify came back FAIL again: settrans
    exit=5.  the serial log showed netdde successfully
    registering an IRQ delivery port immediately before the
    failure, so pfinet was starting to initialise; the failure
    was on the bind-time configuration, not the launch.
  - **slice 12** (main `bcd4570`, hurd `916a097`): extended the
    settrans args to include the full SLIRP address shape
    inline: `-a 10.0.2.15 -m 255.255.255.0 -g 10.0.2.2`.  this
    matches what Debian Hurd's installer networkmgr hook passes.
    pfinet refuses to attach without `-a/-m/-g`, which is why
    the next pid1-set-address ioctl in slice 11 surfaced ENODEV
    again.  the pid1-set-address call right below this block
    stays as reconcile/verify; a SIOCSIFADDR with the address
    pfinet already has is a silent no-op success.  VM-verify
    PASS.

## Probe run

ephemeral snapshot off canonical `/home/overdrive/hurd-vm/work.img`
(canonical mtime preserved).  GRUB patched in-snapshot via
guestmount to add `console=com0` to the gnumach multiboot line and
include `serial` in `terminal_output` so pid1's `console()` writes
reach a host-side file (canonical was not touched).  host SSH
key: `/home/overdrive/.ssh/id_ed25519_p0lym0rphic`.

verification took two driver attempts.  first attempt's stream
timed out after the inject + snapshot steps (~786 KiB snapshot
proved no boot happened).  second attempt reused the same
inject (md5 confirmed byte-identical) and went straight to boot
+ probe.

### E1 boot-time console (verbatim, slice-relevant lines)

```
pid1: remount / rw OK
pid1: /run/sshd 0755 ready (openssh privsep chroot)
pid1: entering supervisor loop
early-init: emacs pid=27 pid1-as-emacs-p=t module-env=/usr/lib/geos/pid1-module
early-init: loading pid1 module from /usr/lib/geos/pid1-module.so
hurd-essentials: settrans /hurd/pfinet -i /dev/eth0 -a 10.0.2.15 -m 255.255.255.0 -g 10.0.2.2
hurd-essentials: settrans pfinet exit=0
hurd-essentials: eth0 static 10.0.2.15/24 gw 10.0.2.2
hurd-essentials: eth0 static OK
supervise: hurd-sshd START pid=...
supervise: hurd-syslogd START pid=...
```

(emacs no longer aborts on the kill_emacs trampoline path; the
slice 4 native-comp opt-out plus slice 2 remount-rw both
contribute, and the boot continues to supervisor loop.)

### E2 ifconfig inside the guest

```
$ inetutils-ifconfig -a
/dev/eth0
  flags=...UP,BROADCAST,RUNNING,MULTICAST
  inet 10.0.2.15  netmask 255.255.255.0  broadcast 10.0.2.255
/dev/lo
  flags=...UP,LOOPBACK,RUNNING
  inet 127.0.0.1  netmask 255.0.0.0
```

### E3 host -> guest ssh

```
$ ssh -i ~/.ssh/id_ed25519_p0lym0rphic -p 2266 -o StrictHostKeyChecking=no \
      root@127.0.0.1 'uname -a'
Warning: Permanently added '[127.0.0.1]:2266' (ED25519) to the list of known hosts.
GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224/Hurd-0.9 i686-AT386 GNU
```

banner string visible on a `nc 127.0.0.1 2266 < /dev/null`:

```
SSH-2.0-OpenSSH_10.2p1 Debian-5
```

### E4 interactive session

opens, runs commands, closes cleanly; supervisor stays up.  no
`pid1-error` lines in `/dev/console` across the session.

## Files touched on the main branch

  - `pid1/port_layer.h` (+5): `remount_root_rw` slot in
    `port_caps`.
  - `pid1/port_linux.c` (+8): Linux body is a no-op (returns
    `0`).
  - `pid1/emacs-init.c` (+12): call `port->remount_root_rw()`
    early in the post-mount block.
  - `emacs-init/early-init.el` (+18): `GEOS_KERNEL == "hurd"`
    branch disables `native-comp-jit-compilation` and
    `native-comp-enable-subr-trampolines`.
  - `emacs-init/core/supervise.el` (+38): `supervise--console`
    helper, breadcrumbs at `supervise--spawn` pre / post-make-
    process, `supervise--sentinel` entry, `supervise-autostart`
    per-service.  `supervise-finalize` refactored onto the same
    helper.
  - `emacs-init/services/hurd-essentials.el` (+86 / -42):
    removed `hurd-dhclient` defservice; added
    `geos-hurd-static-eth0` defcustom; added settrans pre-step
    with full SLIRP address shape inline; added static-address
    call via `pid1-set-address` + `pid1-set-route-default`;
    breadcrumbs throughout.
  - `install/hurd-bootstrap.sh` (+8 / -2):
    `/root/.emacs.d/early-init.el` install; apt-prereq hint
    dropped `isc-dhcp-client` since dhclient is no longer in
    play.

## Files touched on the hurd branch

cherry-picked the eight elisp / shell slices (4-12) and the
slice 1 port_layer.h header from main.  the hurd-only slice 2
(`port_hurd.c` `remount_root_rw` body via `fsys_set_options`)
lives at `hurd/902d8ce`.

## Open follow-ons (do NOT block this release)

  1. **task #168**: `/etc/geos/tmpfiles.d`-equivalent for the
     broader `/run` postinst-state class.  v0.9.11 added the
     C-side mkdir for `/run/sshd` as the first entry; once a
     second consumer shows up, refactor into a table.
  2. **task #171**: emacs respawn-on-crash missing/broken on
     Hurd.  not exercised by this slice because slice 2 + slice
     4 together prevent the crash, but worth auditing for
     defence-in-depth in a later release.
  3. journal-kmsg defservice on Hurd: still fails because
     `/var/log/kern.log` does not exist on the canonical image
     before syslogd writes the first line, and `tail -F` exits
     immediately on a missing file.  v0.9.6's source already
     handles this on Linux; the Hurd path needs a `touch`-first
     pre-step.  out of scope for v0.9.12; tracked separately.
