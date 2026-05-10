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
ordered into four phases, with dependency notes per item. The
top-level shape:

### Phase A (foundational, items 1+2 done)

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
- **10. kernel-cmdline boot menu in GRUB**: GRUB editor entries for
  `geos.mode=ui` and `geos.mode=console` so the operator picks at
  boot instead of having to rebuild.

### Phase B (user-visible utility)

- **5. network configuration UI** (DHCP, DNS, real interface bring-up
  via SIOCS\* through a `pid1-set-address` module call)
- **6. package management buffer** (`*packages*` with install / remove
  driven by `guix package` via `make-process`)
- **7. suspend / resume** through `/sys/power/state` with a
  `pid1-suspend` wrapper so the supervisor can quiesce timers

### Phase C (multi-user, install)

- **4. user accounts + login** (passwd / shadow under `/var/emacs/users/`,
  setuid helper for service `:user`/`:group` enforcement)
- **9. disk encryption (LUKS at boot)** (cryptsetup wired into the
  initrd, passphrase prompt before pid1 takes over)
- **3. real installer** (a `*reconfigure*` buffer that runs
  `guix system reconfigure` and surfaces the build log)

### Phase D (long tail)

- **8. audio**: ALSA via a small `pid1-audio.so` companion module,
  mpv-as-backend for media
- **11. Hurd kernel variant**: spike on whether the same userland
  builds against gnumach, or whether pid1 needs a Hurd-side rewrite

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
