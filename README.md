<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

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

This is v1.0.0. Emacs is PID 1 on both Linux and canonical Debian
GNU/Hurd 0.9, end-to-end through a multi-user EXWM session.  As
far as I know, this is the first project where GNU/Emacs runs as
PID 1 with Hurd support of this depth.  Per-release notes in
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
  - `eshell/uname` reads `GEOS lambda <release> ... GNU/Emacs (Linux)`
    on Linux and `GNU/Emacs (Hurd)` on canonical Debian GNU/Hurd 0.9,
    so the user-facing kernel string says what GEOS actually is and
    keeps the real kernel name visible at the end.
  - `M-x geos-poweroff` and `M-x geos-reboot` go through `reboot(2)`
    on Linux and `host_reboot` via `get_privileged_ports` on Hurd,
    both via the pid1 module. No `/sbin/poweroff`, no socket, no sudo.
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
  - Multi-user: `passwd.el` store under `/var/emacs/users/` plus a
    `*users*` buffer, the `*login*` flow with audit / throttle /
    lockout / last-login footer, and concurrent per-user EXWM
    sessions with workspace isolation. Peer-cred is `SO_PEERCRED`
    on Linux and `auth_server_authenticate` on Hurd.
  - Suspend to RAM via `M-x geos-suspend`. pid1 writes `mem` to
    `/sys/power/state` after the supervisor quiesces timers.
    No-op on Hurd (no suspend analogue; degrades to a banner).
  - Audio: the `*audio*` buffer drives `amixer` / `aplay` /
    `pactl` through `make-process`. Real-hardware audio on Hurd
    is deferred-upstream (canonical Debian GNU/Hurd 0.9 ships no
    `/hurd/audio*` translator and no ALSA/OSS surface, see
    [docs/HURD_PORT.md](docs/HURD_PORT.md)).
  - `M-x install` opens the `*install*` wizard: pick a disk and a
    partition, the wizard does `mkfs.ext4` + `pid1-mount` + `cp -a`
    of `/gnu/store`, `/var/guix`, `/run/current-system` + GRUB
    install, then offers `r` to reboot. Live-verified end-to-end
    on canonical Debian GNU/Hurd 0.9 in `v0.9.23`. The operator
    must pre-partition from a Guix live ISO (or any live Linux
    with parted); partition-from-scratch inside the wizard is
    still a known gap.
  - Supervisor RPC over `/run/geos/super.sock` (`AF_UNIX` peer-
    cred gated). Verbs: `ping`, `journal-tail`, `services-list`,
    `processes`, `reboot`, `poweroff`. Userland buffers
    (`*services*`, `*journal*`, `*processes*`) render the RPC
    snapshot every few seconds and keep the last good frame
    visible when the supervisor is unreachable.
  - End-to-end SSH on canonical Debian GNU/Hurd 0.9 (`v0.9.12`):
    `ssh -p 2266 root@127.0.0.1` opens an interactive session
    against the supervised emacs.
  - Port seam (`port_caps` in `pid1/port_layer.h`): every
    Linux-only syscall in `pid1/` routes through a function-
    pointer struct with `port_linux.c` and `port_hurd.c`
    backends. `STATIC=1` builds inline the supervisor primitives
    into a statically linked `emacs-init` (verified at
    `v0.9.17`: ~1.5 MiB, zero dynamic deps).
  - `iso-build/hurd-image-reroll.sh` bakes a derivative of the
    canonical Debian GNU/Hurd 0.9 image: static `pid1` + supervisor
    tree + serial GRUB + SSH authorized_keys. `FLAVOR=apt-image`
    layers EXWM-on-Xvfb + pulseaudio userland on top.
    `GEOS_BYPASS=1` produces a stock canonical image with
    `/sbin/init` + bash + sysvinit for emergency comparison work.
  - `iso-build/freeze-tests.el` is an in-VM abuse suite that asserts
    the panic buffer survives runaway loops, catastrophic regex, slow
    network, bad tramp, `kill-emacs`, and a state-write round trip.
  - `iso-build/smoke-test.sh` boots a headless qcow2 and gates on
    PID 1, userland, `/var` mount, and state-mode markers.
  - The whole image builds reproducibly from a pinned Guix channel.

## what does not work yet

Real desktop-class hardware (testing has been QEMU + a small set
of x86_64 laptops; the KVM-gated boot smoke on a self-hosted
runner is wired but not run on a hardware matrix yet).
Real-hardware audio on Hurd (canonical Debian GNU/Hurd 0.9 ships
no `/hurd/audio*` translator and no ALSA/OSS surface; the v1.x
apt-image flavor bundles pulseaudio userland for the elisp side,
but the audio layer itself is deferred-upstream, see
[docs/HURD_PORT.md](docs/HURD_PORT.md) and
[docs/upstream/hurd-audio-translator.md](docs/upstream/hurd-audio-translator.md)).
Per-interface byte/packet counters on Hurd pfinet (also
deferred-upstream, the elisp arm renders zeros until the
translator surface lands).  Bluetooth.  Wayland.  DNS UI (static
IPv4 and DHCP land packets but the resolver configuration is
manual).  Partition-from-scratch inside the install wizard (the
operator still pre-partitions from a Guix live ISO; a
parted-driven flow is on the roadmap).  LUKS-rooted boot is
documented as a config-edit path (see
[docs/INSTALL.md](docs/INSTALL.md)) but integration-tested only
by a future install-wizard pass.  The list lives in
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
  - v0.9.18: tagged. canonical Hurd image re-roll, quality-
    of-life.  new `iso-build/hurd-image-reroll.sh` takes the
    pristine canonical Debian GNU/Hurd 0.9 image plus an
    extracted STATIC=1 pid1 binary and produces a derivative
    image with the four per-cycle setup mutations already
    baked in: GRUB serial output (`terminal_output serial
    console` + `console=com0` on every multiboot gnumach
    line), `/root/.ssh/authorized_keys` with the supplied
    pubkey, `/sbin/init` replaced with the STATIC pid1
    (original saved as `/sbin/init.debian-stock`), and
    `/etc/geos/init.args` in the minimal-to-SSH shape.
    verified: SSH first-try on two boot cycles, pid1 reports
    as `/sbin/init` 1,552,824 bytes statically linked, sshd
    reparented to the supervised emacs, forced SIGSEGV
    respawn cycles through the supervisor.  first time pid1
    has booted as actual PID 1 on canonical Debian Hurd 0.9
    (the v0.9.17 syslog verify substituted sysv-init at PID
    1, masking this entirely).  the canonical 35-file `-l`
    init.args chain triggers a `kill_emacs_0.eln` trampoline
    build path that wedges because the canonical image has
    no `as`; the script ships the minimal variant that boots
    cleanly, and closing the wedge so the full chain can
    ship is the v0.9.19 follow-on.  receipt at
    [docs/runlogs/2026-05-23-hurd-v0918-image-reroll.md](docs/runlogs/2026-05-23-hurd-v0918-image-reroll.md).
  - v0.9.19: tagged. trampoline wedge closed.  the v0.9.18
    follow-on resolved as a deployment freshness gap, not a
    missing toolchain.  canonical Debian GNU/Hurd 0.9 has
    gcc 15.2.0 and binutils 2.46 in stock apt; the v0.9.18
    image had baked an early snapshot of
    `emacs-init/early-init.el` that predated the native-comp
    opt-out clause.  a single re-roll cycle picks up current
    main; the full 35-file `-l` init.args chain then boots
    through to the supervised emacs sitting in `*scratch*`
    with hurd-essentials registering services and `settrans
    /hurd/pfinet` exit=0.  zero `kill_emacs`, `trampoline`,
    `SIGSEGV`, `abort`, `panic`, `Backtrace`, or `fatal` hits
    over the 509-line full-chain serial transcript.  pulseaudio
    Y re-verified on the fresh v0919 image (server up,
    module-null-sink loaded) after the `/var` translator
    quirk worked around via `settrans -fg /var`.  bucket-2
    probes shipped instruction-level diagnoses for glibc
    `pt-hurd-cond-timedwait.o` and pflocal `SO_RCVTIMEO`,
    both with deferred-upstream HURD_PORT.md rows.  three
    v1.x install slices (partitions A/B + kernel-gate relax
    C) and audio piece X pactl wiring landed early.  zero
    HURD_PORT.md row flips this release; every row was already
    YES or deferred-upstream as of v0.9.17.  first GEOS
    release where the canonical 35-file emacs-init chain
    boots end-to-end on real Debian GNU/Hurd 0.9 with pid1
    as actual PID 1.  receipts at
    [docs/runlogs/2026-05-23-hurd-v0919-bucket2-probes.md](docs/runlogs/2026-05-23-hurd-v0919-bucket2-probes.md),
    [docs/runlogs/2026-05-24-v0919-bucket-closeout.md](docs/runlogs/2026-05-24-v0919-bucket-closeout.md),
    and
    [docs/runlogs/2026-05-24-hurd-v0919-image-reroll-fullchain.md](docs/runlogs/2026-05-24-hurd-v0919-image-reroll-fullchain.md).
  - v0.9.20: tagged. supervised-autostart predicate flip.  pid1
    now splices `GEOS_PID1=1` into the supervised emacs envp at
    spawn, and `pid1-as-emacs-p` in early-init.el OR-checks
    against that env var as well as `PID1_MODULE_PATH`.  on
    STATIC=1 PORT=hurd builds the module is inlined so
    `PID1_MODULE_PATH` is never set, which had been silently
    no-op'ing every downstream supervision wiring guarded by
    the predicate since v0.9.16.  also lands
    `iso-build/hurd-fast-iterate.sh`, a tar-over-ssh push +
    supervisor bounce that cuts elisp-only iteration from
    `~20 min` (full image re-roll) to `~5 s`.  receipt at
    [docs/runlogs/2026-05-30-hurd-v0920-slice-a.md](docs/runlogs/2026-05-30-hurd-v0920-slice-a.md).
  - v0.9.21: tagged. iso-build/hurd-image-reroll.sh efficiency
    triple.  qcow2 backing-chain replaces a 4 GB `cp` with a
    `~200 KiB` thin overlay over the read-only pristine; a
    single `guestfish --listen` daemon collapses three
    `~15 s` appliance launches into one; new step 7 boots the
    rolled image in a throwaway QEMU up to 240 s and fails
    fast on `No such device or address` or `Kernel panic`.
    a clean elisp-only re-roll now costs `15-30 s` end-to-end
    vs the previous `75-90 s`.  slice B (the full 35-file
    canonical init.args bake) was rebuilt this cycle then
    re-deferred to v0.9.22 after the new smoke gate caught a
    deterministic rumpdisk wd0 enumeration race in the
    canonical pristine itself, reproducible on the known-good
    v0.9.20 image with byte-identical serial output.  receipt
    at
    [docs/runlogs/2026-05-30-hurd-v0921-efficiency-triple.md](docs/runlogs/2026-05-30-hurd-v0921-efficiency-triple.md).
  - v0.9.22: tagged. slice B done.  the "wd0 race" of v0.9.21
    turned out to be a flat missing-driver bug: Hurd's
    rumpdisk has no virtio-blk driver, so `-drive if=virtio`
    cannot enumerate wd0 at all.  iso-build/hurd-image-reroll.sh
    and iso-build/hurd-fast-iterate.sh both flip to
    `-drive if=ide` (wd0 enumerates via piixide first try) and
    `-device e1000` (netdde has no virtio-net driver either, so
    pfinet settrans wedges at exit=4 under virtio-net-pci;
    e1000 brings settrans to exit=0).  the full 35-file
    canonical init.args HEREDOC is now the default bake and
    boots end-to-end to an SSH-able supervised emacs with
    four supervisor registry entries (journal-kmsg,
    journal-syslog, hurd-syslogd, hurd-sshd) autostarting.
    receipt at
    [docs/runlogs/2026-05-30-hurd-v0922-slice-b-ide-e1000.md](docs/runlogs/2026-05-30-hurd-v0922-slice-b-ide-e1000.md).
  - v0.9.23: tagged. install wizard slice C live-verified on
    Hurd, no code change.  v0.9.22 unblocked the last
    outstanding v1.x slice; the verify rig boots the v0.9.22
    image with a second IDE disk attached and drives
    `install-mkfs-ext4` and `install-grub-install` over
    `emacsclient` end-to-end against `/dev/wd1`.  both
    callbacks return `(t nil)`; the fresh ext4 mounts and
    shows `lost+found`; grub-install writes the i386-pc
    `core.img` (28,424 B) to `/mnt/wd1/boot/grub/i386-pc/`,
    the work buffer logs "Installation finished. No error
    reported.", and the MBR carries the GRUB signature.
    closes task #210.  receipt at
    [docs/runlogs/2026-05-30-hurd-v0923-install-slice-c-verify.md](docs/runlogs/2026-05-30-hurd-v0923-install-slice-c-verify.md).
  - v0.9.24: tagged. four parallel slices landed: (1)
    `docs/upstream/` carries four upstream-ready bug-report +
    patch drafts for the deferred-Hurd items (pflocal
    SO_RCVTIMEO, pfinet per-iface counters, native Hurd audio
    translator, native Xorg evdev/libinput); (2)
    `iso-build/hurd-image-reroll.sh` grows a `FLAVOR=apt-image`
    knob that bakes a derivative image with xvfb + emacs-lucid
    + elpa-exwm + elpa-xelb + pulseaudio apt-installed on top
    of the canonical bake, so the v1.x EXWM-on-Xvfb + pulseaudio
    surface ships turnkey; (3) `.github/workflows/hurd-smoke.yml`
    plus `docs/CI_HURD_RUNNER.md` draft the self-hosted KVM
    boot-smoke gate that goes live the day a runner labelled
    `hurd-kvm` registers; (4) a 35-minute / 1383-eval pselect
    soak on the v0.9.22 image upgrades task #213's verdict from
    "5-min / 60-eval non-reproduction" to "35-min / 1383-eval
    non-reproduction", zero SIGSEGV/__mach_msg markers, PID
    stable at 30 across 63 side-polls.  receipt at
    [docs/runlogs/2026-05-30-hurd-pselect-soak-35min.md](docs/runlogs/2026-05-30-hurd-pselect-soak-35min.md).
  - v1.0.0: tagged.  state declaration.  Emacs as PID 1 on both
    Linux and canonical Debian GNU/Hurd 0.9, end-to-end through
    a multi-user EXWM session.  every row in
    [docs/HURD_PORT.md](docs/HURD_PORT.md) is YES modulo two
    upstream-translator gaps (audio translator, pfinet per-iface
    counters) documented in-tree as deferred-upstream.  upstream
    filings: eight emails on-list, none blocking GEOS.
    `GEOS_BYPASS=1 ./iso-build/hurd-image-reroll.sh` is the
    documented escape hatch for operators who want canonical
    Debian userland (bash + sysvinit + getty) instead of the
    Emacs PID 1, while keeping the bake-time conveniences
    (serial console, root authorized_keys, sshd host keys); see
    [docs/HURD_BOOT.md](docs/HURD_BOOT.md) under "bash console
    option (GEOS_BYPASS, build-time)".  the first GEOS release
    where the "full Hurd support" claim is defensible from the
    matrix alone, no asterisks.

I am the only contributor. If you want to send a patch, read the
manifesto first so you know what you are signing up for.

## license

GPLv3 or later, same as Emacs and Guix. See `COPYING`.
