# GEOS Hurd port

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- voice: first person singular, lowercase, no em-dashes. -->

This doc summarizes where the GNU Hurd port of GEOS stands. The port
itself lives on a side branch, not on main. Main carries only the
abstractions that let both kernels share a userland.

## What's portable today

Everything in `emacs-init/` is portable as-is. The userland buffers
walk `/proc` and the supervisor talks to PID 1 through the dynamic
module. Neither path is Linux-specific in shape, only in path strings
(`/proc/asound`, `/dev/kmsg`).

The dynamic module under `pid1/` has a small Linux dependency surface:
`reboot(2)`, `mount(2)`, `prctl(PR_SET_NAME)`, `sethostname(2)`, and
the `/dev/kmsg` reader. None are hot paths; each becomes a
`port_linux.c` vs `port_hurd.c` shim.

## What's NOT portable

The `panic-allow-kill-emacs` reboot path uses Linux's `reboot(2)`
syscall numbers. Hurd has its own halt protocol via Mach RPC to
`proc_server`. The v0.4 feasibility spike traced that out; the v0.6
RPC channel does not change the picture.

EXWM assumes an Xorg server. Hurd ships Xorg too, so this part is
fine; what differs is how PID 1 spawns it. The Linux side fork+execs
with prctl; the Hurd side has no prctl and uses `proc_setowner` to
the same effect.

## CI shape

`.github/workflows/checks.yml` runs the host-side gates on every push
to main and to the `hurd` branch (the side branch's expected name).
Pure-text passes (attribution-scan, no-shell-check). A boot smoke
test on a Hurd qcow2 needs a self-hosted runner with KVM and a Hurd
toolchain; that's a v0.8 follow-up.

## Side-branch contract

The side branch tracks main; rebases against main weekly. The Hurd-
specific files (`port_hurd.c`, `system-hurd.scm`) live only on the
branch. Anything from main that breaks the Hurd build is a side-
branch fix, not a main rollback.

## Status

  - feasibility spike: closed (v0.4 item 11, commit 7b779a1).
  - port skeleton: side branch, weekly rebase.
  - boot to multi-user: not yet.
  - CI gate: host-side text checks only, see above.

For the spike's design notes see `docs/v04-item11-hurd-spike.md`.
