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
    link line (`-lhurduser -lmachuser`, corrected on the side
    branch at `7c2d6bc` after the 2026-05-17 build verification:
    Debian Hurd's libhurd-dev folds `libhurd.so` / `libmach.so`
    into glibc and exposes only the `-luser` user-side stubs).
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
For the boot recipe (what a Hurd-VM operator runs to verify
`port_hurd.c` for the first time) see `docs/HURD_BOOT.md`.

## Verification status

Code-side completion is high; ground-truth verification on a real
Hurd kernel is at first-checkpoint as of 2026-05-17. Honesty matters
here, so each port surface gets a line.

The verification levels in the last column:

  - **NO**: never touched a real Hurd kernel.
  - **builds on Hurd 2026-05-17**: compiles and links cleanly against
    real Debian GNU/Hurd 0.9 / GNU-Mach 1.8 headers and libraries;
    `ldd -r` resolves every dynamic symbol; the per-slot static
    function is present in the binary's symbol table.  the body has
    NOT been exercised against a live Mach RPC server; a wrong-shape
    request struct could still fail at runtime.
  - **YES on YYYY-MM-DD**: actually invoked on a running Hurd kernel
    and observed to do the right thing.

| Surface | Code status | Verified on Hurd? |
|---|---|---|
| `port->kernel_name` | both backends populated | n/a, identity slot |
| `port->mount` (Hurd: `fshelp_start_translator` + `file_set_translator`) | rewritten 2026-05-17 (hurd branch `e3fd411`) to fork the translator via libfshelp before binding it; the prior body passed `MACH_PORT_NULL` as the active port and was a silent no-op | YES on 2026-05-17 (`/hurd/tmpfs 256M` round-trip: showtrans, df, write, settrans -g) |
| `port->set_hostname` (Hurd: POSIX) | written | YES on 2026-05-17 (`pid1-set-hostname "geos-hurd"` returned `t`, hostname changed) |
| `port->bring_up_lo` (Hurd: pfinet SIOCSIFFLAGS) | written | YES on 2026-05-17 (lo came up UP/LOOPBACK/RUNNING) |
| `port->set_address` (Hurd: pfinet SIOCSIFADDR+) | normalizes bare ifnames (hurd branch `b031db5`); `"eth0"` -> `"/dev/eth0"` before the ioctl, `"lo"` passes through | YES on 2026-05-17 (`pid1-set-address "eth0" "10.0.2.15" 24` returned `t` after the normalization fix; bare `"eth0"` had returned ENODEV before) |
| `port->set_route_default` (Hurd: pfinet SIOCADDRT) | rewritten 2026-05-17 to use Hurd's `ifrtreq_t`; ifname normalization shared with `set_address` (hurd branch `b031db5`) | YES on 2026-05-17 (`pid1-set-route-default "10.0.2.2" "eth0"` returned `t`, NAT gateway stayed reachable) |
| `port->reboot` (Hurd: `host_reboot` Mach RPC) | written | builds on Hurd 2026-05-17 |
| `port->suspend` (Hurd: ENOSYS forever) | written | n/a, design |
| `port->get_peer_cred` (Hurd: ENOSYS, supervisor RPC poll soft-fails) | written; surrounding rpc-poll tolerates `SO_RCVTIMEO`/`SO_SNDTIMEO` returning ENOPROTOOPT on Hurd's pflocal (`ffe6150` on main, `e4f72de` on hurd) | YES on 2026-05-17 (AF_UNIX client connect + `pid1-rpc-poll` returned `nil`, stderr logged "peer cred unsupported on this kernel" once; second poll returned `nil` without re-logging, confirming the `warned_enosys` gate) |
| `geos-kernel` elisp defvar (reads `GEOS_KERNEL` env) | runs everywhere | YES on Linux |
| GEOS_KERNEL env splice (`port->kernel_name` → execve envp → per-user emacs) | implemented (`a53304b`) | YES on Linux |
| `core/network.el` Linux/Hurd dispatch | implemented | YES on Linux, NO on Hurd |
| `core/state.el` Linux/Hurd dispatch | implemented | YES on Linux, NO on Hurd |
| `core/uname.el` Linux/Hurd dispatch | implemented | YES on Linux, NO on Hurd |
| `buffers/disks.el` Hurd not-implemented banner | implemented | YES on Linux, NO on Hurd |
| `install/disk.el` Hurd not-implemented banner | implemented | YES on Linux, NO on Hurd |
| `services/journal-tail.el` Hurd no-op | implemented | YES on Linux, NO on Hurd |
| `user/userland/audio.el` Hurd not-implemented banner | implemented | YES on Linux, NO on Hurd |

The 2026-05-17 verification pass ran `docs/HURD_BOOT.md` steps 1-3
end-to-end on a fresh Debian GNU/Hurd 2026-03 snapshot VM.  the
build chain surfaced four issues that the desk review on Linux had
not caught; the fixes landed on the hurd side branch as commit
`7c2d6bc`:

  - emacs-init.c was unconditionally including `<linux/if.h>`,
    `<net/route.h>`, `<sys/mount.h>`, `<sys/reboot.h>`.  those
    headers do not exist on Hurd; gated behind `!PORT_HURD` with
    Linux-compatible fallback constants for the Hurd path.
  - `PATH_MAX` is intentionally undefined on Hurd (no max path
    length is a Hurd feature); a 4096 fallback closed the gap for
    the few stack-buffer sites in pid1.
  - port_hurd.c's `hurd_set_route_default` was using Linux's
    `struct rtentry`; on Hurd pfinet's SIOCADDRT takes `ifrtreq_t`
    instead.  rewritten body, identical semantics.
  - the Makefile link line `-lhurduser -lhurd -lmach` does not link
    on a modern Debian Hurd toolchain: the standalone `libhurd.so`
    and `libmach.so` no longer exist (folded into glibc); user-side
    RPC stubs live in `-lhurduser` and `-lmachuser`.

`ldd -r emacs-init` on the resulting binary resolves every dynamic
symbol; `nm emacs-init` shows all nine port_caps slots present.

Runtime exercising began the same day.  the first slot to fail in
practice was `port->mount`: the body called `file_set_translator`
with `MACH_PORT_NULL` as the active port and `passive_flags=0`,
which is a silent no-op (no translator installed, no on-disk
record set).  fixed on the hurd branch at `e3fd411` by routing
through `fshelp_start_translator` (libfshelp) to fork the
translator binary first, then handing its control port to
`file_set_translator`.  the same commit fixed two related
discoveries: tmpfs rejects the linux placeholder `"none"` as an
argv ("argument must be a number"), and Hurd's tmpfs has no
implicit default size (unlike Linux's half-of-RAM), so a 256M
fallback is injected when src does not parse as a numeric size.
verification round-trip: `(pid1-mount "none" "/tmp/geos-mp-test"
"tmpfs" 0 nil)` returns `t`; `showtrans` shows `/hurd/tmpfs 256M`;
`df -h` shows the mount; `echo > .../sentinel` writes to the
translator; `settrans -g` detaches and the sentinel disappears
(it lived in tmpfs, not the underlying inode).

The second runtime gap surfaced in the networking verbs: pfinet on
a stock Debian Hurd install keys hardware interfaces by the devnode
translator path passed to `/hurd/pfinet` at settrans time (i.e.
`/dev/eth0`), not by the bare `eth0` name the Linux backend uses.
`pid1-set-address "eth0" ...` returned ENODEV; the same call with
`"/dev/eth0"` succeeded.  the supervisor speaks Linux-shaped
ifnames, so the translation belongs in the backend, not the elisp
callers.  fixed on the hurd branch at `b031db5` by adding
`hurd_normalize_ifname` and routing both `hurd_set_address` and
`hurd_set_route_default` through it.  rule: prepend `/dev/` unless
the name starts with `/` (already an absolute devnode path) or is
literally `"lo"` (pfinet special-cases loopback regardless of
devnode configuration).  `bring_up_lo` uses the literal `"lo"` and
was unaffected.  with this patch `pid1-set-address "eth0"
"10.0.2.15" 24` returns `t` and the SSH session running over the
NAT survives the reconfiguration.

boot-as-PID-1 happened on 2026-05-18.  Hurd does not honor an
`init=` kernel cmdline; the bootstrap server `/hurd/startup` (PID
1 in Hurd's model) execs `/sbin/init` unconditionally, so the
install path is `cp /sbin/init /sbin/init.debian-orig` then `cp
emacs-init /sbin/init`.  the first boot ran through the early-
mount sequence, hit three bootstrap-order bugs (read-only root at
init time, tmpfs default-pager missing, `/hurd/tmpfs` argv shape),
still reached the supervisor loop, attempted to exec
`/usr/bin/emacs`, fell into the crashloop holding pattern, and
stayed alive to reap zombies as designed.  Receipt + screen
capture: `docs/runlogs/2026-05-18-hurd-pid1-boot-result.md`.

post-mortem on the crashloop turned up the real root cause:
`/hurd/startup` passes a sysvinit-style runlevel token as
`argv[1]` (e.g. `"6"` after a clean `shutdown -r`).  emacs-init's
argv-parser blindly set `emacs_path = argv[1]`, so `execve("6")`
returned ENOENT in a tight loop.  the fix landed on the hurd
branch and was cherry-picked to main: argv[1..3] are now only
accepted as paths when they start with `/`, with a breadcrumb
log on rejection so the next operator does not chase the same
ghost.  the diagnostic format was also flipped to emit errno
first, path second, so snprintf truncation drops the path tail
rather than the errno.

second boot on the same date, with the argv fix in place,
spawned emacs and rendered the `*scratch*` greeting on
/dev/console.  receipt: `docs/runlogs/2026-05-18-hurd-pid1-
emacs-spawn.md`.  the supervisor loop is now a verified path,
not a hypothetical one.

Freeze-tests (`iso-build/freeze-tests/freeze-test-port-hurd.el`)
exercise the elisp Hurd-arm code paths under a stubbed
`geos-kernel = 'hurd`; they are skip-class on a dev host that does
not have the pid1 module loaded. They DO catch regressions in the
elisp dispatch logic; they DO NOT exercise `port_hurd.c` or prove
anything about real Hurd RPCs.

The first real Hurd PID-1 boot landed 2026-05-18 (see runlog).
The followup boot the same day shipped the argv fix and got emacs
spawning.  Both are pinned by screen captures + runlogs in
`docs/runlogs/`.  `port->reboot` still stays at "builds": calling
`host_reboot` end-to-end from the booted emacs requires driving
`M-x pid1-reboot RET` from a console we cannot easily script.
That promotion is tracked as task #98 and is the last gating
item for the row in the table.
