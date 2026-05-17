<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Changelog

Tagged releases of GEOS, newest first. Dates are commit dates of
the tagged commit. The signed tag for each release carries the
full per-slice commit list; this file is the short version. The
matching GitHub release page mirrors each entry.

## unreleased

(empty — see v0.7.1 for the port-seam slice landed since v0.7.)

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
