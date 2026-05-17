# GEOS Hurd port

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- voice: first person singular, lowercase, no em-dashes. -->

This doc summarizes where the GNU Hurd port of GEOS stands. The
abstraction layer that lets both kernels share a userland lives on
main as of the v0.7.x cycle. The Hurd backend itself is a skeleton
on the `hurd` side branch, not yet bootable end-to-end.

## What's portable today

Everything in `emacs-init/` is portable as-is, and the v0.7.x cycle
made the kernel-aware spots explicit. `emacs-init/core/port.el`
defines `geos-kernel` (intern of `$GEOS_KERNEL` or `'linux`) and is
the single branch knob for the elisp side. The kernel-aware files
(`core/network.el`, `core/state.el`, `buffers/disks.el`,
`install/disk.el`, `user/userland/uname.el`,
`services/journal-tail.el`, `buffers/journal.el`,
`user/userland/audio.el`, `buffers/audio.el`) factor their Linux
bodies into `*-linux` helpers and dispatch through `port.el`; the
Hurd arms either degrade cleanly (nil, banner) or signal
`geos-port-unimplemented` until a real backend lands.

Every Hurd arm is pinned by `iso-build/freeze-tests.el`'s
`freeze-test-port-hurd` orchestrator: a refactor of any Linux arm
that silently flattens its Hurd counterpart will fail the
`port/*` sub-checks. The sub-checks emit a `'skip` result class
when the underlying module is absent (`emacs -Q -batch` dev host)
so CI can distinguish "module unbound" from "regression".

The dynamic module under `pid1/` had a small Linux dependency
surface (`reboot(2)`, `mount(2)`, `prctl(PR_SET_NAME)`,
`sethostname(2)`, the `/dev/kmsg` reader, the network ioctls, and
the `SO_PEERCRED` getsockopt that authenticates the supervisor RPC
channel). That surface is now a function-pointer struct:
`pid1/port_layer.h` declares `port_caps`, `pid1/port_linux.c` holds
every Linux syscall body that used to live inline in
`emacs-init.c`, and the module calls through `port->X()`. The
`get_peer_cred` slot (added 3a8797b) abstracts the peer-credential
lookup; Hurd's pflocal has no `SO_PEERCRED` analogue, so the Hurd
backend returns `ENOSYS` and `Fpid1_rpc_poll` treats that errno as
"refuse this client without panicking the 200ms poll timer".
Behavior on Linux is unchanged, and `port_require_or_abort()` makes
the contract explicit so a missing init aborts instead of crashing
on a null deref.

## What's NOT portable

The Linux backend is the only one currently compiled into a
production build. The Hurd backend exists in skeleton form on the
side branch (see below) and has never been linked against a real
Hurd toolchain, only written against the public Hurd headers.

EXWM assumes an Xorg server. Hurd ships Xorg too, so this part is
fine; what differs is how PID 1 spawns it. The Linux side fork+execs
with prctl; the Hurd side has no prctl and uses `proc_setowner` to
the same effect. That spawn path is not yet wired into
`port_hurd.c`.

## CI shape

`.github/workflows/checks.yml` runs the host-side gates on every
push to main and to the `hurd` branch. Pure-text passes
(attribution-scan, no-shell-check) cover both. A boot smoke test
on a Hurd qcow2 needs a self-hosted runner with KVM and a Hurd
toolchain; that's a v0.8 follow-up.

## Side-branch contract

The side branch tracks main; rebases against main weekly. The Hurd-
specific files (`port_hurd.c`, `system-hurd.scm`,
`hurd-smoke-test.sh`) live only on the branch. Anything from main
that breaks the Hurd build is a side-branch fix, not a main
rollback.

## Status

  - feasibility spike: closed (v0.4 item 11, commit 7b779a1).
  - abstraction on main: pid1 port-layer at `3f90c87` (skeptic-
    hardened at `8dae17b`), elisp port seam at `df7fb92`,
    consumer adapters extended through `94063a3` (uname),
    `87d5880` (journal kmsg follower), `a6053e0` (uname
    honesty markers), `a16d031` (audio surface), `3a8797b`
    (get_peer_cred slot for the supervisor RPC peer-credential
    lookup, the last Linux-only kernel-syscall surface in
    `pid1/`), and `a53304b` (GEOS_KERNEL env propagation: new
    `kernel_name` slot in `port_caps`, pid1 splices
    `GEOS_KERNEL=<name>` into the supervisor execve envp,
    `session.el` forwards it through to every per-user emacs so
    the elisp `geos-kernel` defvar resolves correctly on every
    kernel instead of defaulting to `'linux`). Skip-class
    freeze-test discipline at `a673679` so CI can tell a real
    Hurd-arm regression from a dev-host gap.
  - Hurd backend on the `hurd` side branch: `port_hurd.c`
    implements `mount` (file_set_translator RPC), `reboot`
    (host_reboot Mach RPC), and `set_hostname` (POSIX); `suspend`
    returns ENOSYS permanently because Hurd has no analogue.
    Three networking verbs (`bring_up_lo`, `set_address`,
    `set_route_default`) target pfinet's Linux-ABI compatibility
    surface, same SIOC* ioctl sequence as `port_linux.c`. Skeptic
    blockers B1/B2/B3/B4 closed at branch head: kern_return_t
    translation discipline, explicit errno preservation around
    MACH_PORT_NULL branches, host_reboot dispatch hardened
    against unknown cmds, network-order contract for
    `hurd_set_address` documented inline. `port_hurd_impl` carries
    `.kernel_name = "hurd"` so the GEOS_KERNEL splice on main
    resolves to the Hurd symbol on Hurd builds; the older
    `setenv("GEOS_KERNEL", ...)` pair in `main()`'s `PORT_HURD`
    #ifdef was dropped, since `port->kernel_name` is now the
    single source of truth. Makefile carries a
    `PORT=linux|hurd` switch with `-DPORT_HURD` and the Hurd
    link line (`-lhurduser -lhurd -lmach`).
  - guix-system and smoke test on the `hurd` branch:
    `guix-system/system-hurd.scm` (kernel `gnumach`, drops Xorg /
    emacs-exwm / dhcpcd / alsa / install wizard, console-only)
    and `iso-build/hurd-smoke-test.sh` (thin mirror of
    `smoke-test.sh`, gates on `geos: emacs userland up`).
  - boot to multi-user on Hurd: not yet. Blocked on a Hurd cross-
    toolchain or a Hurd guix-shell to even build the binary; not
    available on Linux dev hosts via `guix build hurd-headers`.
  - CI gate: host-side text checks only, see above. KVM-gated
    boot smoke is v0.8.

For the spike's design notes see `docs/v04-item11-hurd-spike.md`.
