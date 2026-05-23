<p align="center">
  <img src="docs/img/logo.png" alt="GNU/Emacs Operating System (GEOS), editor on silicon" width="217" height="256">
</p>

# GNU/Emacs Operating System (GEOS)

Maintainer: Borja Tarraso &lt;borja.tarraso@member.fsf.org&gt;

An operating system where Emacs is the userland and Emacs is PID 1.
Short name is GEOS, full name is GNU/Emacs Operating System; the rest
of this document uses GEOS.

There is no shell other than eshell. There is no Shepherd. There is no
systemd. The first userspace process the kernel starts is a small C
program that becomes Emacs and then loads itself back as an Emacs
dynamic module, so the supervisor lives inside the supervised process.
Every system concept (`top`, `ip a`, `journalctl`, `df`, `apt`) is a
buffer with a major mode and a refresh timer.

This is v0.7. It runs. I use it. Per-release notes in
[CHANGELOG.md](CHANGELOG.md).

## try it

```
./iso-build/dev-vm.sh
```

That builds the host-side binaries (`pid1/`, `shstub/`), then runs
`guix time-machine` against the pinned channel to produce a qcow2,
then boots it under QEMU/KVM. First build is large (~8 GB into
`/gnu/store`); subsequent ones are seconds.

For a headless smoke pass:

```
./iso-build/smoke-test.sh
```

You need a Linux host with KVM and Guix installed. Boot to a
usable EXWM frame takes about eleven seconds. Full instructions
in [docs/INSTALL.md](docs/INSTALL.md). The why is in
[docs/MANIFESTO.md](docs/MANIFESTO.md), and the manifesto is the
document I would actually rather you read first. The picture is
in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (three zoom
levels, including the dual-kernel Linux + Hurd seam).

For Hurd: on a fresh Debian GNU/Hurd 0.9 image, run
`install/hurd-bootstrap.sh` as root and reboot. The full recipe
(apt prereqs, build, rollback path, init.args format) is in
[docs/HURD_BOOT.md](docs/HURD_BOOT.md).

## what works

  - PID 1 is a C binary that execs Emacs and exposes the reaper, mount
    helper, hostname, reboot and signal handlers as Elisp functions
    via a dynamic module.
  - The panic buffer catches every uncaught error and refuses to let
    Emacs die.
  - `/bin/sh` is a 50-line C stub that forwards into eshell. No bash,
    no dash, no busybox.
  - EXWM brings up real Xorg with the modesetting driver against
    virtio_gpu's KMS device. Keyboard and mouse work in QEMU. X11
    windows are buffers.
  - `eshell/uname` reads `GEOS lambda <release> ... GNU/Emacs (Linux)`,
    so the user-facing kernel string says what GEOS actually is and
    keeps the real kernel name visible at the end.
  - `M-x geos-poweroff` and `M-x geos-reboot` go through `reboot(2)`
    via the pid1 module. No `/sbin/poweroff`, no socket, no sudo.
  - `*processes*`, `*network*`, `*journal*`, `*services*`, `*disks*`,
    `*packages*`, `*users*`, `*audio*` are all live buffers with
    sensible keybindings.
  - `/etc/hostname` is read and applied at boot via `pid1-set-hostname`
    (no Shepherd hostname service to depend on).
  - GRUB picks the boot mode from `geos.mode=`; `ui` is the default,
    `geos.mode=console` lands on a raw `/dev/console` Emacs without
    Xorg, `geos.mode=recovery` does the same and also skips the
    userland load chain via `early-init.el`.
  - Persistent state under `/var/emacs/`: pid1 mounts an ext4 partition
    labelled `geos-var` if present, falls back to tmpfs otherwise.
    Crash-safe `state-write` (rename + parent fsync via `pid1-fsync-dir`).
    See [docs/STATE_LAYOUT.md](docs/STATE_LAYOUT.md).
  - Static IPv4 from `*network*`: `s` prompts for address and gateway
    and goes through `pid1-set-address` + `pid1-set-route-default`
    ioctls. No `ip` binary involved.
  - DHCP from `*network*`: `d` triggers `services/dhcp.el` which
    spawns `dhcpcd` in one-shot mode (`-1 -q -B -K --nohook
    resolv.conf --nohook ntp.conf`) via `make-process`, sentinel-
    driven so the supervisor never blocks on the lease window. The
    *network* buffer refreshes when the lease lands.
  - Package install and remove from `*packages*`, driven by
    `guix package` via `make-process` with the build log streamed
    into the buffer.
  - User accounts: `passwd.el` store under `/var/emacs/users/` and a
    `*users*` buffer. The login flow itself is v0.5; right now this is
    the account store and the UI on top of it.
  - Suspend to RAM via `M-x geos-suspend`. pid1 writes `mem` to
    `/sys/power/state` after the supervisor quiesces timers.
  - Audio (preview): `*audio*` buffer wraps `amixer` and `aplay`
    through `make-process`. No pid1-side audio module yet.
  - `M-x install` opens the `*install*` wizard: pick a disk and a
    partition, the wizard does `mkfs.ext4` + `pid1-mount` + `cp -a`
    of `/gnu/store`, `/var/guix`, `/run/current-system` + GRUB
    install, then offers `r` to reboot. MVP: the operator must
    pre-partition from a Guix live ISO; partition-from-scratch is
    v0.4.1.
  - `iso-build/freeze-tests.el` is an in-VM abuse suite that asserts
    the panic buffer survives runaway loops, catastrophic regex, slow
    network, bad tramp, `kill-emacs`, and a state-write round trip.
  - `iso-build/smoke-test.sh` boots a headless qcow2 and gates on
    PID 1, userland, `/var` mount, and state-mode markers.
  - The whole image builds reproducibly from a pinned Guix channel.

## what does not work yet

The Hurd variant end-to-end (the port-layer abstraction landed on
main in the v0.7.x cycle and the Hurd backend skeleton lives on the
`hurd` side branch with mount/reboot/hostname and three pfinet
verbs implemented; boot verification waits on a Hurd cross-toolchain
and the v0.8 self-hosted runner, see
[docs/HURD_PORT.md](docs/HURD_PORT.md)). Real hardware (only QEMU
is exercised; KVM-gated boot smoke on a self-hosted runner is the
v0.8 follow-up). Bluetooth. Wayland. DNS UI (static IPv4 and DHCP
land packets but the resolver configuration is manual).
Partition-from-scratch in the install wizard (MVP requires a
pre-partitioned disk; full parted-driven partitioning is v0.4.1).
LUKS-rooted boot is documented as a config-edit path (see
[docs/INSTALL.md](docs/INSTALL.md)) but integration-tested only
by a future install-wizard pass. The list lives in
[docs/ROADMAP.md](docs/ROADMAP.md).

## the failure mode I have accepted

Emacs is single threaded. A stuck regex stalls the OS. A slow network
call stalls the OS. The panic buffer mitigates this for errors raised
through `condition-case`, but it does not save you from a tight loop
in C-level code. This is a documented design constraint, not a bug. I
lose maybe one session a week to it. If that ratio is unacceptable to
you, this is not your OS, and I will not be offended.

## status

Per-release notes are in [CHANGELOG.md](CHANGELOG.md). Short
version:

  - v0.1: tagged, ISO is 1.57 GB, boots in QEMU. Xvfb only.
  - v0.2: tagged. Real Xorg, working input, poweroff, hostname.
  - v0.3.1: tagged. Round-5 hardening across the pid1 ABI, the
    supervision throttle, and the buffer renderers. Long-standing
    fullscreen-pre-WM hang in `exwm-config.el` fixed (was making
    headless smoke-tests time out). Freeze-test suite, AUTHORS,
    contributor docs, user guide.
  - v0.4: tagged. All eleven items closed: persistent state,
    `core/supervise.el`, network UI (static IPv4 + DHCP),
    `*packages*`, suspend/resume, `passwd.el` + `*users*`,
    `*audio*` preview, the three-way GRUB boot menu (ui / console
    / recovery), LUKS-rooted boot as a config-edit path, the
    `*install*` MVP wizard, and the Hurd feasibility spike.
  - v0.5: tagged. Multi-user login. Per-user emacs sessions
    spawned from the root supervisor via `pid1-spawn-as-uid`.
    `*login*` buffer with abuse throttle.
  - v0.5.1: tagged. Per-user session polish: passwd salt off
    `/dev/urandom`, boot-rehydrate moved to
    `emacs-startup-hook`, `user-init.el` and `/usr/bin/emacs`
    laid down from the boot gexp, EXWM finish-hook actually
    attached.
  - v0.6: tagged. Multi-user, RPC, workspace-split. Per-user
    dotfiles under `/var/emacs/users/NAME/`, AF_UNIX RPC at
    `/run/geos/super.sock`, `*users*` buffer with bundled
    passwd-create, login hardening (lockout + audit log),
    concurrent sessions on separate workspaces capped at 3.
  - v0.7: tagged. User-side surfaces, input methods, audio
    promotion, supervisor views over RPC, host-side CI gate.
    `session.el` releases the X display on logout and reclaims
    on next login. IBus / quail chooser with per-user
    persistence. `*audio*` / `*services*` / `*journal*` /
    `*processes*` all run in user-emacs.
    `.github/workflows/checks.yml` runs `attribution-scan` and
    `no-shell-check` on every push. See
    [docs/HURD_PORT.md](docs/HURD_PORT.md) for the port status.
  - v0.9.11: tagged. GEOS boots end-to-end on Debian GNU/Hurd
    0.9 via the `/etc/geos/init.args` fallback and a supervised
    sshd + syslogd pair.
  - v0.9.12: tagged. End-to-end SSH on Debian GNU/Hurd 0.9:
    pid1 remounts `/` rw via `fsys_set_options`, early-init.el
    opts out of native-comp on Hurd, supervise.el mirrors state
    transitions onto `/dev/console`, and `hurd-essentials.el`
    brings eth0 up via `settrans /hurd/pfinet` with the full
    SLIRP address shape inline.  receipt at
    [docs/runlogs/2026-05-22-hurd-end-to-end-ssh.md](docs/runlogs/2026-05-22-hurd-end-to-end-ssh.md).
  - v0.9.13: tagged. journal-kmsg defservice autostart on Hurd.
    pid1 supervisor + Emacs respawn-on-crash verified by a
    6-cycle `kill -SEGV` exercise; the journal-kmsg `tail`
    follower now comes up live at first boot via a touch +
    `make-directory` for `/var/log/kern.log` and a Hurd-side
    `exec-path` extension so `make-process` can resolve
    coreutils.  receipts at
    [docs/runlogs/2026-05-22-hurd-emacs-respawn-verify.md](docs/runlogs/2026-05-22-hurd-emacs-respawn-verify.md)
    and
    [docs/runlogs/2026-05-22-v0913-journal-kmsg-verify.md](docs/runlogs/2026-05-22-v0913-journal-kmsg-verify.md).
  - v0.9.14: tagged. live verification of the v0.9 Hurd surface.
    v0.8 multi-user peer-cred handshake re-verified against the
    v0.9.13 stack (all nine slice-5 markers fire in 2.15s wall);
    live kmsg flow proven end-to-end through the v0.9.6
    `tail -F` + `journal-buffer--parse-syslog-record` pipeline,
    with a bonus respawn-and-rebackfill confirmation across an
    emacs respawn mid-probe.  no code shipped.  receipts at
    [docs/runlogs/2026-05-22-v0914-multiuser-reverify.md](docs/runlogs/2026-05-22-v0914-multiuser-reverify.md)
    and
    [docs/runlogs/2026-05-22-v0914-live-kmsg-probe.md](docs/runlogs/2026-05-22-v0914-live-kmsg-probe.md).
  - v0.9.15: tagged. four-slice Hurd cleanup release.
    slice A routes user-side `kern.*` into `/var/log/kern.log`
    by appending an override to `/etc/inetutils-syslog.conf`
    from `hurd-essentials.el` (idempotent, SIGHUPs syslogd
    when already running).  slice B adds a periodic dmesg
    re-sync timer in `journal-tail.el` so kernel events that
    landed in dmesg between supervisor ticks still appear in
    `*journal*`.  slice C is a desk-side investigation
    receipt for STATIC=1 link of pid1 on Hurd: confirms
    `libc.a` on Hurd is an ld GROUP script, identifies the
    one-line Makefile change (`-lihash -lshouldbeinlibc`
    inside `--start-group`); receipt-only, no Makefile ship.
    slice D is a 100-cycle emacs respawn long-soak on Debian
    GNU/Hurd 0.9: PASS, 100/100 cycles, respawn wait flat at
    1 s/cycle vs 5 s budget, pid1 port table essentially flat
    (16 to 17 across all 100 cycles), no monotonic resource
    growth.  receipts at
    [docs/runlogs/2026-05-23-hurd-static-link-investigation.md](docs/runlogs/2026-05-23-hurd-static-link-investigation.md),
    [docs/runlogs/2026-05-23-hurd-respawn-soak-100.md](docs/runlogs/2026-05-23-hurd-respawn-soak-100.md),
    and
    [docs/runlogs/2026-05-23-hurd-v0915-a-b-verify-deferred.md](docs/runlogs/2026-05-23-hurd-v0915-a-b-verify-deferred.md)
    (slice A and B live-verify deferred to v0.9.16 cold-boot
    cycle; code shipped, snapshot-side wedge documented).
  - v0.9.16: tagged. cold-boot live-verify cycle + STATIC=1
    Makefile ship.  slice B (periodic dmesg re-sync) PASS on
    canonical Debian GNU/Hurd 0.9 (timer arm + file-offset
    tick + idempotent re-arm + documented first-tick double-
    emit wart).  slice A (syslog kern.* override) REVERTED on
    both branches after the verify proved two load-bearing
    assumptions wrong: (1) inetutils-syslogd on Hurd reads
    `/etc/syslog.conf`, NOT `/etc/inetutils-syslog.conf`;
    (2) user-process `LOG_KERN` is demoted to `LOG_USER` at
    source-classification stage per syslog spec, so no config
    file edit can route `logger -p kern.info` to
    `/var/log/kern.log`.  v0.9.14 follow-on #1 stays open
    (next attempt should tail `/var/log/syslog` or document
    local0 convention).  STATIC=1 Makefile diff shipped on
    hurd (wraps Hurd subset in `--start-group / --end-group`
    with `-lihash -lshouldbeinlibc`); in-VM link verify is
    the v0.9.17 starter.  receipt at
    [docs/runlogs/2026-05-23-hurd-v0916-cold-boot-verify.md](docs/runlogs/2026-05-23-hurd-v0916-cold-boot-verify.md).
  - v0.9.17: tagged. closes v0.9.14 follow-on #1 properly and
    flips the last `PENDING` row in `docs/HURD_PORT.md`.
    `journal-tail.el` grows a second supervised tail on
    `/var/log/syslog` (Hurd-gated) that retags emitted
    records' `:source` plist slot to `syslog-user`, so
    user-process `logger -p kern.info` lines (which syslogd
    demotes to `LOG_USER` per syslog spec and lands in
    `/var/log/syslog`, not `/var/log/kern.log`) finally appear
    in `*journal*` with a visible source distinction from
    genuine kernel messages.  no de-dup logic because canonical
    Debian Hurd 0.9 routes `kern.*` only to `kern.log`.
    `STATIC=1` link cleanliness on Hurd flipped `PENDING ->
    YES` after the in-VM verify on the preserved v0.9.16
    work.img produced `emacs-init` 1,552,824 B with `file`
    reporting `statically linked`, no dynamic section per
    `readelf -d`, and `ldd` reporting `not a dynamic
    executable`.  receipts at
    [docs/runlogs/2026-05-23-hurd-v0917-static-in-vm-verify.md](docs/runlogs/2026-05-23-hurd-v0917-static-in-vm-verify.md)
    and
    [docs/runlogs/2026-05-23-hurd-v0917-syslog-tail-verify.md](docs/runlogs/2026-05-23-hurd-v0917-syslog-tail-verify.md).

I am the only contributor. If you want to send a patch, read the
manifesto first so you know what you are signing up for.

## license

GPLv3 or later, same as Emacs and Guix. See `COPYING`.
