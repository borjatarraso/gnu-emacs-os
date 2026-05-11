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

## v0.4 in flight

The detailed plan lives in [v04-plan.md](v04-plan.md). Eleven items
ordered into four phases, with dependency notes per item. Nine items
fully landed plus the in-place half of item 3 and the documented half
of item 9; the first-install wizard, the user-login split (deferred
to v0.5), and the Hurd spike remain. The top-level shape:

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
- **3. real installer** (partial): the `*reconfigure*` buffer that
  runs `guix system reconfigure` and streams the build log has
  shipped. The bare-metal first-install wizard (partition, mkfs,
  copy closure, install grub) is still in flight.
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
- **11. Hurd kernel variant** (not done): spike on whether the same
  userland builds against gnumach, or whether pid1 needs a Hurd-side
  rewrite. Lives on a separate branch.

## explicitly punted to v0.5 or later

  - Wayland. EXWM is X11-only. A Wayland equivalent is a different
    project.
  - Bluetooth. bluez is its own dependency mountain.
  - Microphone capture and webcam. Same reason as Bluetooth.

## the meta-task

After v0.4 is functionally complete, I want to actually ship GEOS as
a daily driver. That means:

  - real install media that boots on a non-virtualized x86_64 laptop
  - a one-page "is this for you" landing page on the manifesto
  - a `git tag v0.4` that I am willing to point friends at

That is the actual goal. Everything above is the path to get there.
