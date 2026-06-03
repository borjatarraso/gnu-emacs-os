<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

# GEOS roadmap

GNU/Emacs Operating System (GEOS) roadmap. What I want to fix and in
roughly what order. Not a schedule, a dependency graph: each phase
unlocks the next, and none of them is interesting without the one
before it.

Maintainer: Borja Tarraso <borja.tarraso@member.fsf.org>

## v0.1 recap (done)

Emacs is PID 1. /bin/sh is a 50-line C stub. The five system-concept
buffers are live. The ISO builds reproducibly from a pinned channel
and cold-boots in QEMU. v0.1 proved the thesis.

## v0.2 recap (done)

Real Xorg with the modesetting driver against virtio_gpu's KMS device.
Working keyboard and mouse in QEMU. `M-x geos-poweroff` /
`M-x geos-reboot` via `reboot(2)`. eshell `uname -a` rebranded to GEOS
with the kernel name in parens. `/etc/hostname` actually applied at
boot via `pid1-set-hostname`. Default host is `lambda`. GPLv3-or-later
with SPDX headers everywhere.

## v0.3 recap (done)

Dual boot modes (`geos.mode=ui` default, `geos.mode=console` via the
GRUB editor) so a broken Xorg does not lock the operator out of a
working PID 1. Iso-build wrappers (`dev-vm.sh`, `smoke-test.sh`)
replaced the per-session manual `guix time-machine` invocation.
`pid1-set-hostname` reads `/etc/hostname` from C and applies it
before forking emacs, with `\r` and `\n` rejected.

## v0.3.1 recap (done)

Maintenance bundle.  Round-5 hardening swept the pid1 emacs module
ABI (copy_string_contents two-call pattern, pid1_signal_errno
discipline), tightened the rolling crashloop window for Xorg and
emacs respawns, made wait_for_x_socket reap a fast-failing Xorg
with `WNOHANG`, and corrected a fistful of buffer renderers
(processes pid cap, services `make-symbol`, journal O(1) line
counter).  The long-standing exwm-config fullscreen-pre-WM hang
that was timing out the headless smoke-test got deferred to
`exwm-init-hook`. Added `iso-build/freeze-tests.el`, AUTHORS,
docs/CONTRIBUTING.md, docs/USER_GUIDE.md.

## v0.4 recap (done)

The detailed plan lives in [v04-plan.md](v04-plan.md). Eleven items
ordered into four phases, with dependency notes per item. All
eleven closed (item 3 in MVP form, items 9 and 11 as documented
deliverables); the user-login split moved to v0.5. The top-level
shape:

### Phase A (foundational, done)

- **1. persistent state under `/var/emacs/`** (done): `state-read` /
  `state-write` / `state-delete` with rename(2) + `pid1-fsync-dir`,
  ext4 (`geos-var` label) or tmpfs fallback. See
  [STATE_LAYOUT.md](STATE_LAYOUT.md).
- **2. first-class service definitions in Elisp** (done):
  `core/supervise.el` with `defservice` macro, restart policy
  (`on-crash`/`on-failure`/`always`/`never`), rolling 60s respawn cap
  with `'held` terminal state, `state-write`-backed registry,
  `:buffer`/`:filter`/`:autostart` passthrough. The `*journal*`
  follower migrated first; rest of the long-running processes follow
  as the userland gains them.
- **10. kernel-cmdline boot menu in GRUB** (done): three GRUB entries,
  `geos.mode=ui` (default), `geos.mode=console`, and a recovery entry
  that skips Xorg and drops the userland `-l` chain via `early-init.el`
  mutating `command-line-args-left`. Pick the mode at boot, no rebuild.

### Phase B (user-visible utility, done)

- **5. network configuration UI** (done): static IPv4 via
  `pid1-set-address` and `pid1-set-route-default` ioctls, bound to `s`
  in `*network*`. DHCP via `services/dhcp.el` (sentinel-driven dhcpcd
  in one-shot mode), bound to `d` in `*network*`. DNS UI deferred to
  v0.5.
- **6. package management buffer** (done): `*packages*` with install
  and remove driven by `guix package` via `make-process`, output
  streamed into the buffer so the user sees the build log.
- **7. suspend / resume** (done): `pid1-suspend` writes `mem` to
  `/sys/power/state` after the supervisor quiesces timers. Resume
  picks up where it left off.

### Phase C (multi-user, install)

- **4. user accounts** (part 1 done, part 2 deferred to v0.5): the
  `passwd.el` store under `/var/emacs/users/` and the `*users*` buffer
  shipped. The login flow and per-user emacs split (so each session
  gets its own process tree) is the v0.5 follow-up.
- **3. real installer** (MVP shipped): the `*reconfigure*` buffer
  that runs `guix system reconfigure` and streams the build log
  shipped first. The bare-metal `*install*` wizard now ships as MVP:
  the operator pre-partitions from a Guix live ISO (one ext4
  partition is enough), boots GEOS, runs `M-x install`, picks a
  disk + partition, the wizard does `mkfs.ext4` + `pid1-mount` +
  `cp -a` of the system closure + `grub-install` +
  `grub-mkconfig`, then offers `r` to reboot. Partition-from-
  scratch (parted dance, ESP layout) is v0.4.1.
- **9. disk encryption (LUKS at boot)** (documented): Guix's stock
  initrd already handles LUKS via `mapped-devices`, so this item
  shrinks to docs. The required edits to `system.scm` (mapped-devices,
  file-systems pointing at `/dev/mapper/geos-root`, initrd-modules
  extended with dm-crypt+aes+xts) live in
  [system-luks-snippet.scm](../guix-system/system-luks-snippet.scm).
  The install workflow is in [INSTALL.md](INSTALL.md#installing-with-an-encrypted-root-luks).
  QEMU smoke-test does not exercise the LUKS path; integration test
  on real hardware lives with the bare-metal install wizard.

### Phase D (long tail)

- **8. audio** (done, preview): ALSA wrappers around `amixer` and
  `aplay` via `make-process`, surfaced as the `*audio*` buffer. Ships
  as preview per the v0.4 plan; pid1-side audio module is a v0.5
  question.
- **11. Hurd kernel variant** (spike done): the feasibility report
  in [v04-item11-hurd-spike.md](v04-item11-hurd-spike.md) answers
  the spike's one question: yes, the userland can port, with a
  console-only Hurd profile and a `port_layer.h` abstraction in C.
  The report inventories every Linux-coupled syscall in pid1 and
  every Linux-only data source in elisp, and lays out the 6-8 week
  work order. The actual port lives on a side branch (per the v0.4
  plan), not main.

## v0.5 recap (done)

Multi-user login. Per-user emacs sessions spawned from the root
supervisor via `pid1-spawn-as-uid` (the twelfth bound module
function). `*login*` buffer presents at boot when no session is
running, throttles 3-in-30s, renders a structured error from the
session layer on failure. `session-spawn` rejects a bad HOME
before allocating any state; the C-side `chdir` fallback to `/`
stays as defense-in-depth.

## v0.5.1 recap (done)

Per-user session polish. passwd salt read from `/dev/urandom`,
session boot-rehydrate moved to `emacs-startup-hook`, workspace
routing and login re-prompt land after teardown, `user-init.el`
and the `/usr/bin/emacs` symlink laid down from the boot gexp,
`exwm-manage-finish-hook` installed after `(require 'exwm)` so
the hook actually attaches.

## v0.6 recap (done)

Multi-user, RPC, workspace-split. Phase A: per-user dotfiles
under `/var/emacs/users/NAME/` (0700, chowned), supervisor RPC
over AF_UNIX `/run/geos/super.sock` with verbs `ping`,
`journal-tail`, `reboot`, `poweroff`. Phase B: `*users*` adds /
deletes / sets passwords via `passwd-create-user-and-home`;
login hardening with per-user lockout writing
`/var/emacs/lockouts/NAME` (15min expiry), global cap 5-in-60s,
last-login footer, audit log under
`/var/emacs/journal/auth.log`; concurrent sessions with
`:workspace` slot on `geos-session`, multi-session UI on
`*login*` (`n` adds another, `s` switches), allocator in
`session.el` authoritative, capped at 3. Phase C deferred to
v0.7. Phase D: Hurd remains on its own side branch.

## v0.7 recap (done)

User-side surfaces, input methods, audio, RPC views, CI gate.
`session.el` releases the EXWM display on logout and reclaims it
on next login. Input methods: chooser dispatcher with the quail
builtin, per-user persistence under
`/var/emacs/users/NAME/input-method`, real IBus launcher, pid1
`ibus-daemon` respawn with inline crashloop cap. `*audio*`
lifted user-side; pcm stream parser takes an optional path arg
so user emacs walks `/proc/asound` without supervisor mediation.
Supervisor views over RPC: new `services-list` verb,
`services-client.el` and `journal-client.el` under
`user/userland/`, both 3s-tick with RPC-down fallback that pins
the last-good rows. `*processes*` lifted user-side without RPC
because `/proc` is world-readable. Host-side CI gate at
`.github/workflows/checks.yml` runs `attribution-scan` and
`no-shell-check` on push to `main` and `hurd` and on PRs.
KVM-gated boot smoke deferred to v0.8. Port status is in
[HURD_PORT.md](HURD_PORT.md).

## v0.8 through v1.0.0 recap (done)

The Hurd port arc.  `v0.8` (2026-05-18) landed peer-cred
end-to-end multi-user on both kernels (`auth_server_authenticate`
on Hurd, SO_PEERCRED on Linux; design lives in
[v08-hurd-peer-cred-design.md](v08-hurd-peer-cred-design.md)).
`v0.8.1` + `v0.8.2` (2026-05-18, 2026-05-20) closed the
`poll(POLLOUT)` + retry-loop + 64 KiB stack frame gaps on the
RPC path.  `v0.9` (2026-05-20) flipped every v0.9 elisp Hurd
arm to YES; `v0.9.5` through `v0.9.7` (2026-05-20, 2026-05-21)
closed the remaining `port_hurd.c` slots (disk size, kmsg,
audio either landed or confirmed deferred-upstream).  `v0.9.8`
+ `v0.9.9` (2026-05-21) shipped the `arm_parent_death`
`MACH_NOTIFY_DEAD_NAME` watcher; `v0.9.10` (2026-05-21)
live-verified EXWM 0.33 on Xvfb on canonical Hurd; `v0.9.12`
(2026-05-22) brought end-to-end SSH on Hurd.  `v0.9.18`
(2026-05-23) shipped `iso-build/hurd-image-reroll.sh`;
`v0.9.22` (2026-05-30) flipped to `-drive if=ide` +
`-device e1000` (Hurd's rumpdisk has no virtio-blk, netdde
has no virtio-net), making the full 35-file canonical
init.args the default bake; `v0.9.23` (2026-05-30)
live-verified the install wizard slice on Hurd
(`install-mkfs-ext4` + `install-grub-install` PASS).
`v0.9.24` (2026-05-30) landed four parallel slices: upstream
bug-report + patch drafts under `docs/upstream/`, the
`FLAVOR=apt-image` derivative that bundles xvfb + emacs-lucid
+ elpa-exwm + elpa-xelb + pulseaudio, the self-hosted KVM
boot-smoke gate skeleton at `.github/workflows/hurd-smoke.yml`,
and a 35-minute / 1383-eval pselect soak.  `v1.0.0` (2026-06-01)
is the state declaration: Emacs as PID 1 on both Linux and
canonical Debian GNU/Hurd 0.9, end-to-end through a multi-user
EXWM session, every row of [HURD_PORT.md](HURD_PORT.md) YES
modulo two upstream-translator gaps documented in-tree.
`GEOS_BYPASS=1 ./iso-build/hurd-image-reroll.sh` is the
documented bash-console escape hatch.

## what's next

  - Real install media on a non-virtualized x86_64 laptop, both
    Linux and Hurd.
  - Self-hosted KVM runner labelled `hurd-kvm` registered so
    `.github/workflows/hurd-smoke.yml` goes live.
  - Native `/hurd/audio*` translator (upstream territory; once
    it exists, the `userland/audio.el` Hurd arm wires to it).
  - pfinet per-iface counter surface (upstream territory; once
    `pfinet.defs` carries a stats slot, the network buffer
    counters flip from stub-zero to real).
  - `kmsg-tail` RPC verb to lift `/dev/kmsg` user-side without
    touching the existing `journal-tail` shape.
  - Bluetooth, Wayland, microphone capture, and webcam stay
    punted; the reasons listed above still apply.
