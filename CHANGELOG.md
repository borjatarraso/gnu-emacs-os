<!-- SPDX-License-Identifier: FSFAP -->

# Changelog

Tagged releases of GEOS, newest first. Dates are commit dates of
the tagged commit. The signed tag for each release carries the
full per-slice commit list; this file is the short version. The
matching GitHub release page mirrors each entry.

## v1.0.0 (2026-06-01)

State declaration.  Emacs as PID 1 on both Linux and canonical
Debian GNU/Hurd 0.9, end-to-end through a multi-user EXWM session.
Every row in `docs/HURD_PORT.md` is YES modulo two upstream
translator-level gaps (native audio translator, pfinet per-iface
counters) documented in-tree as deferred-upstream.  Of the eight
upstream filings under `docs/upstream/emails/`, all eight are
on-list; none blocks GEOS.  The "full Hurd support" claim is
defensible from the matrix alone, no asterisks.  This is the
first GEOS release I am willing to ship under that label.

What this tag captures, by area:

  - **pid1 + port seam**: every Linux-only syscall in `pid1/`
    routes through the `port_caps` function-pointer struct
    (`port_linux.c`, `port_hurd.c`).  the Hurd backend covers
    network ioctls, `host_reboot` via `get_privileged_ports`,
    `MACH_NOTIFY_DEAD_NAME` parent-death watcher,
    `file_get_storage_info` for disk size, `auth_server_authenticate`
    peer-cred handshake, kmsg via `tail -F` on `/var/log/syslog`
    with the syslog-format parser, and a STATIC=1 build that
    inlines `pid1-module.o` into the emacs-init binary
    (`emacs-init` statically linked, zero dynamic deps).  the
    two `port_caps` rows that remain ENOSYS on Hurd are the
    upstream-translator gaps cited above.

  - **multi-user**: peer-cred end-to-end (`v0.8`), supervisor
    RPC over `/run/geos/super.sock` with verbs `ping`,
    `journal-tail`, `services-list`, `reboot`, `poweroff`,
    concurrent session allocation with isolation tests
    (`v0.6`), login audit + throttle + lockout + last-login
    footer (`v0.6` item 5), `*users*` buffer +
    `passwd-create-user-and-home` (`v0.6` item 4).

  - **EXWM-on-Xvfb on Hurd**: live-verified at `v0.9.10`.
    EXWM 0.33 + xelb 0.20 on emacs-lucid 30.2 is the EWMH
    WM over a `v0.9.8`-spawned Xvfb.  apt prereqs (xvfb,
    emacs-lucid, elpa-exwm, elpa-xelb) bundled by the
    `FLAVOR=apt-image` knob in `iso-build/hurd-image-reroll.sh`
    (`v0.9.24`).

  - **end-to-end SSH on Hurd**: `v0.9.12`.  twelve-slice
    cycle landed `remount_root_rw` via `fsys_set_options`,
    a native-comp opt-out for the boot-time trampoline build,
    breadcrumbs to supervise `/dev/console`, and static
    eth0 via `settrans pfinet` with the full SLIRP shape
    inline.  `host ssh -p 2266 root@127.0.0.1` opens an
    interactive session.

  - **journal-kmsg on Hurd**: `v0.9.13` arc (`afd1f3f`,
    `7e4fc42`, `211aeee`); also closes the emacs-respawn
    case from task #171.

  - **install wizard on Hurd**: `v0.9.23` live-verified.
    `install-mkfs-ext4` and `install-grub-install` end-to-end
    PASS through the elisp wrappers on canonical Hurd; fresh
    ext4 mounts, GRUB MBR + `i386-pc/core.img` written.

  - **iso-build/hurd-image-reroll.sh**: qcow2 backing-chain
    over a read-only pristine, single `guestfish --listen`
    daemon, smoke gate that fails fast on `No such device or
    address` or `Kernel panic`, IDE + e1000 device flags
    (Hurd's rumpdisk has no virtio-blk and netdde has no
    virtio-net), `FLAVOR=apt-image` derivative for the
    EXWM-on-Xvfb + pulseaudio userland, `GEOS_BYPASS=1`
    escape hatch that produces a canonical Debian image with
    stock /sbin/init.

  - **upstream filings**: `docs/upstream/STATUS.md` tracks
    eight emails on bug-hurd / debian-hurd / bug-gnu-emacs.
    `01` (emacsclient SO_RCVTIMEO) closed by Paul Eggert with
    a broader accept-and-rewrite.  `06` (evdev) closed with
    no engagement.  `08` (ext2fs `file_pager_write_pages`
    `blk` assertion under apt-install) sent 2026-06-01.
    none of the on-list reactions force a present-day GEOS
    code change.

  - **bash console escape hatch**: `GEOS_BYPASS=1
    ./iso-build/hurd-image-reroll.sh` keeps stock
    `/sbin/init` (no swap), skips the GEOS overlay steps,
    reroutes the output to `BYPASS_OUTPUT_IMG`, and leaves
    the bake-time conveniences (serial console patch, root
    `authorized_keys`, pre-generated sshd host keys) in
    place.  documented in `docs/HURD_BOOT.md`.

CI: `.github/workflows/checks.yml` runs attribution +
no-shell gates on every push.  `.github/workflows/hurd-smoke.yml`
plus `docs/CI_HURD_RUNNER.md` carry the self-hosted KVM
boot-smoke gate; goes live the day a runner labelled
`hurd-kvm` registers.

## v0.8 through v0.9.24

This range covers the full Hurd port arc from the peer-cred
end-to-end land (`v0.8`) to the upstream-drafts + apt-image
flavor + CI scaffolding (`v0.9.24`).  The per-slice commit
list lives on each signed tag; the signed `v1.0.0` tag carries
the summary above.  Notable intermediate markers:

  - `v0.8` (2026-05-18): peer-cred end-to-end multi-user on
    both kernels.
  - `v0.8.1` (2026-05-18): `poll(POLLOUT)` gate + retry-loop
    drain on the supervisor RPC path.
  - `v0.8.2` (2026-05-20): 64 KiB stack frame for the
    multi-user code path.
  - `v0.9` (2026-05-20): every v0.9 elisp arm flipped YES on
    Hurd.
  - `v0.9.5` (2026-05-20) through `v0.9.7` (2026-05-21): the
    remaining `port_hurd.c` slots (disk size, kmsg, audio)
    land or are confirmed deferred-upstream.
  - `v0.9.8` (2026-05-21) + `v0.9.9` (2026-05-21):
    `arm_parent_death` watcher on Hurd, with the
    `err_hurd`-not-`err_kern` ground-truth lesson recorded.
  - `v0.9.12` (2026-05-22): end-to-end SSH on Hurd.
  - `v0.9.18` (2026-05-23): canonical Hurd image re-roll
    script (`iso-build/hurd-image-reroll.sh`).
  - `v0.9.19` (2026-05-24): trampoline-wedge closed; full
    35-file init.args boots to `*scratch*`.
  - `v0.9.22` (2026-05-30): IDE + e1000 flip; SSH-able
    supervised emacs first-try on every bake.
  - `v0.9.23` (2026-05-30): install wizard slice C
    live-verified on Hurd.
  - `v0.9.24` (2026-05-30): four parallel slices (upstream
    drafts, `FLAVOR=apt-image`, CI hurd-smoke draft,
    35-min pselect soak).

## v0.7.1 (2026-05-17)

Hurd port seam complete on main; CI tightened; identity
propagated through to per-user emacs.

  - pid1 port-layer abstraction (`3f90c87`, hardened at
    `8dae17b`): every Linux-only syscall in `pid1/` now goes
    through a `port_caps` function-pointer struct. `port_linux.c`
    holds the bodies; `port_require_or_abort()` is the loud
    backstop for a missed backend assignment.
  - elisp port seam (`df7fb92`): `emacs-init/core/port.el`
    defines `geos-kernel` and the `geos-port-unimplemented`
    error. Adapters at every data-source site (`core/network.el`,
    `core/state.el`, `buffers/disks.el`, `install/disk.el`)
    dispatch by kernel.
  - consumer adapters extended: uname (`94063a3`), journal kmsg
    follower (`87d5880`), uname honesty markers (`a6053e0`),
    audio surface (`a16d031`).
  - `get_peer_cred` port slot (`3a8797b`): SO_PEERCRED, the last
    Linux-only kernel-syscall surface in `pid1/`, now routes
    through the port layer. Hurd backend returns ENOSYS; the
    supervisor RPC poll special-cases the errno so the 200ms
    timer keeps ticking instead of panicking forever.
  - GEOS_KERNEL env propagation (`a53304b`): new `kernel_name`
    slot in `port_caps` carries the backend identity. pid1
    `main()` snprintf's `GEOS_KERNEL=<name>` into the supervisor
    execve envp; `session.el` forwards it through to every
    per-user emacs spawn so `geos-kernel` resolves to the right
    symbol on every kernel instead of defaulting to `'linux`.
  - skip-class freeze-test discipline (`a673679`) so CI can tell
    a real Hurd-arm regression from a dev-host module gap.
  - CI: `no-shell-check` regex word-bounded (`\bsystem\(`,
    `\bpopen\(`) and elisp call patterns now require an opening
    paren prefix (`b8b21d5`), so legitimate identifiers like
    `link_current_system(` and comments mentioning
    `shell-command` no longer fail the gate.
  - `docs/HURD_PORT.md` rewritten (`ddbaa1a`), refreshed at
    `4f9be94`, `16b918b`, and again here.

`hurd` side branch is rebased onto this tag; it carries
`port_hurd.c`, `system-hurd.scm`, `hurd-smoke-test.sh`, and the
matching `.kernel_name = "hurd"` initializer on
`port_hurd_impl`. Boot to multi-user on Hurd is pending the
v0.8 self-hosted runner with a Hurd cross-toolchain.

## v0.7 (2026-05-12)

user-side surfaces, input methods, audio, RPC views, CI gate.

  - EXWM release-display protocol: `session.el` releases the
    display on logout and reclaims it on the next login.
  - input methods: chooser dispatcher with the quail builtin,
    per-user persistence under
    `/var/emacs/users/NAME/input-method`, real IBus launcher,
    pid1 `ibus-daemon` respawn with inline crashloop cap.
  - `*audio*` lifted user-side. The pcm stream parser takes an
    optional path arg so user emacs walks `/proc/asound`
    without supervisor mediation.
  - supervisor views over RPC: new `services-list` verb,
    `services-client.el` and `journal-client.el` under
    `user/userland/`, both 3s-tick with an RPC-down fallback
    that pins the last-good rows. `*processes*` lifted user-
    side without RPC because `/proc` is world-readable.
  - host-side CI gate: `.github/workflows/checks.yml` runs
    `attribution-scan` and `no-shell-check` on push to `main`
    and to the `hurd` side branch and on PRs. KVM-gated boot
    smoke is deferred to v0.8.
  - `docs/HURD_PORT.md` summarises the port status: spike
    closed, port lives on a side branch with weekly rebase.

## v0.6 (2026-05-12)

multi-user, RPC, workspace-split.

  - phase A: per-user dotfiles under `/var/emacs/users/NAME/`
    (0700, chowned), supervisor RPC over AF_UNIX
    `/run/geos/super.sock` with verbs `ping`, `journal-tail`,
    `reboot`, `poweroff`.
  - phase B: `*users*` buffer adds, deletes, and sets
    passwords via a single `passwd-create-user-and-home`
    bundle. Login hardening: per-user lockout writing
    `/var/emacs/lockouts/NAME` with 15min expiry, global cap
    5-in-60s, last-login footer on the username prompt, audit
    log as sexp-per-line under `/var/emacs/journal/auth.log`.
    Concurrent sessions: `:workspace` slot on `geos-session`,
    multi-session UI on `*login*` (`n` adds another login,
    `s` switches), allocator in `session.el` authoritative,
    capped at 3.
  - phase C deferred to v0.7: full userland-into-user-emacs
    handover, IBus / quail proper, audio promotion.
  - phase D: Hurd remains on its own side branch.

## v0.5.1 (2026-05-12)

per-user session polish.

  - passwd salt read from `/dev/urandom` (no shadow of the BEG
    header).
  - session boot-rehydrate moved to `emacs-startup-hook` so it
    runs after boot, not at load.
  - workspace routing and login re-prompt land after teardown.
  - `user-init.el` and the `/usr/bin/emacs` symlink laid down
    from the boot gexp so the activation gap is closed at
    first boot.
  - `exwm-manage-finish-hook` installed after `(require 'exwm)`
    so the hook actually attaches; the previous top-level
    `boundp` guard meant the hook silently never fired.

## v0.5 (2026-05-11)

multi-user login.

  - per-user emacs sessions spawned from the root supervisor
    via `pid1-spawn-as-uid` (the twelfth bound module
    function).
  - `*login*` buffer presents at boot when no session is
    running, throttles 3-in-30s, and renders a structured
    error from the session layer on failure.
  - `session-spawn` rejects a bad HOME before allocating or
    persisting any state; the C-side `chdir` fallback to `/`
    remains as defense-in-depth.

## v0.4 (2026-05-11)

bare-metal install, multi-user account store, audio preview.

  - all eleven plan items closed.
  - `*install*` wizard: `M-x install` walks disk-pick,
    partition-pick, `mkfs.ext4`, `pid1-mount`, `cp -a` of the
    system closure, `grub-install`. MVP assumes a pre-
    partitioned target; partition-from-scratch is v0.4.1.
  - persistent state under `/var/emacs/`, `core/supervise.el`
    with `defservice` macro and rolling 60s respawn cap,
    network UI (static IPv4 + DHCP), `*packages*`,
    suspend/resume, `passwd.el` + `*users*`, `*audio*`
    preview, three-way GRUB boot menu (ui / console /
    recovery), LUKS-rooted boot as a documented config-edit
    path, Hurd feasibility spike.
  - login flow deferred to v0.5.

## v0.3.1 (2026-05-11)

round-5 hardening, smoke-test unblock, contributor docs.

  - swept the pid1 emacs module ABI: `copy_string_contents`
    two-call pattern, `pid1_signal_errno` discipline.
  - tightened the rolling crashloop window for Xorg and emacs
    respawns.
  - `wait_for_x_socket` reaps a fast-failing Xorg with
    `WNOHANG`.
  - buffer renderers corrected: `*processes*` pid cap,
    `*services*` `make-symbol`, `*journal*` O(1) line counter.
  - exwm-config fullscreen-pre-WM hang deferred to
    `exwm-init-hook` so the headless smoke-test stops timing
    out.
  - new: `iso-build/freeze-tests.el`, `AUTHORS`,
    `docs/CONTRIBUTING.md`, `docs/USER_GUIDE.md`.

## v0.2 (2026-05-09)

real X server, poweroff, hostname, rebrand.

  - Xorg with the modesetting driver against virtio_gpu's KMS
    device. Working keyboard and mouse in QEMU.
  - `M-x geos-poweroff` and `M-x geos-reboot` go through
    `reboot(2)` via the pid1 module.
  - eshell `uname -a` reads
    `GEOS lambda <release> ... GNU/Emacs (Linux)`.
  - `/etc/hostname` applied at boot via `pid1-set-hostname`.
    Default host is `lambda`.
  - GPLv3-or-later with SPDX headers everywhere.

## v0.1 (2026-05-09)

thesis proven.

  - emacs is PID 1; the init binary is also an Emacs dynamic
    module.
  - `/bin/sh` is a 50-line C stub that forwards into eshell.
  - system-concept buffers live: `*processes*`, `*network*`,
    `*journal*`, `*services*`, `*disks*`, `*packages*`.
  - the ISO builds reproducibly from a pinned channel and
    cold-boots in QEMU.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
