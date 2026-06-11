<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
# GEOS Hurd port

<!-- voice: first person singular, lowercase, no em-dashes. -->

This doc summarizes where the GNU Hurd port of GEOS stands.  The
abstraction layer that lets both kernels share a userland lives on
main as of the v0.7.x cycle.  The Hurd backend (`port_hurd.c`)
lives on the `hurd` side branch.

As of v1.0.0 (2026-06-01) every row in the matrix below is YES on
canonical Debian GNU/Hurd 0.9 modulo two deferred-upstream rows
(real-hardware audio and pfinet per-interface counters).  The
release arc:

  - v0.8 (2026-05-18): single-user PID-1 boot and the multi-user
    peer-cred dance verified end-to-end.
  - v0.9 (2026-05-20): every kernel-aware userland buffer arm
    flipped to YES; remaining gaps moved into `port_hurd.c`.
  - v0.9.10 (2026-05-21): EXWM 0.33 over Xvfb on Hurd, live.
  - v0.9.12 (2026-05-22): end-to-end SSH on Hurd.
  - v0.9.17 (2026-05-23): `STATIC=1` build verified in-VM; zero
    dynamic deps.
  - v0.9.18 (2026-05-23): `iso-build/hurd-image-reroll.sh` bakes
    a canonical-derivative image; SSH-able supervised emacs on
    first boot.
  - v0.9.23 (2026-05-30): install wizard end-to-end on Hurd
    (`mkfs.ext4` + `grub-install` through the elisp wrappers).

The operator runbook is `docs/HURD_BOOT.md`; the installer-side
script for the manual path is `install/hurd-bootstrap.sh`; the
image re-roll script is `iso-build/hurd-image-reroll.sh`.

v0.9.12 (2026-05-22) closes the end-to-end SSH gap.  twelve
slices: a `port->remount_root_rw` slot (Linux no-op, Hurd
`fsys_set_options "--writable"` against the root file_t) so the
underlying ext2 `/tmp` is writable for emacs's native-comp
trampoline path; a native-comp opt-out in early-init.el gated
on `GEOS_KERNEL == "hurd"` (belt + suspenders); a
`supervise--console` helper that mirrors supervisor state
transitions onto `/dev/console` so silent autostart failures
stop being invisible mid-boot; install-side
`/root/.emacs.d/early-init.el` install so early-init actually
runs before tty setup; a one-line syslogd path fix; and the
five-slice network bring-up arc that ended in a static eth0
configuration via `settrans /hurd/pfinet` with the full SLIRP
address shape (`-a 10.0.2.15 -m 255.255.255.0 -g 10.0.2.2`)
inline, plus a `pid1-set-address` reconcile/verify call below
it gated on a new `geos-hurd-static-eth0` defcustom (default
`t`; flip to `nil` for a bare-metal DHCP deployment).  the host
now opens an interactive ssh session into the guest and the
supervisor stays up across the session.  receipt:
`docs/runlogs/2026-05-22-hurd-end-to-end-ssh.md`.

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
surface (`reboot(2)`, `mount(2)`, `prctl(PR_SET_NAME)` (cited as
future surface; pid1 does not currently call it, see
`port_layer.h:32-36`), `sethostname(2)`, the `/dev/kmsg` reader, the
network ioctls, and the `SO_PEERCRED` getsockopt that authenticates
the supervisor RPC channel). That surface is now a function-pointer struct:
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
production build on main. The Hurd backend exists on the side
branch (see below); v0.8 (2026-05-18) closes the peer-cred
multi-user dance end-to-end with VM verification on Debian
GNU/Hurd 0.9, so the Hurd side is now exercised in production
shape on its branch, not just written against the public Hurd
headers.

EXWM assumes an X server. Hurd ships Xorg too, but native Xorg
is blocked on the input-driver gap on hurd-amd64 today: `kbd_drv.so`
issues a Linux-style "set event mode" ioctl against `/dev/cons/kbd`
that the gnumach console translator returns EBADF for, and there
is no `evdev_drv.so` or `libinput_drv.so` in the hurd-amd64
package set to fall back to (see
`docs/runlogs/2026-05-21-hurd-xorg-probe.md` probes E3, E4, I).
v0.9.8 wires the Xvfb spawn path on Hurd instead: pid1 spawns
`/usr/bin/Xvfb :0 -screen 0 1024x768x24` the same way it spawns
Xvfb in Linux dev hosts. EXWM hosts emacs against the virtual
framebuffer; the userland code does not branch on kernel.
v0.9.10 (2026-05-21) live-verifies the full attach path on the
canonical Debian GNU/Hurd 0.9 VM: EXWM 0.33 + xelb 0.20 on
emacs-lucid 30.2 attaches to Xvfb 21.1.22 on `:99`,
`_NET_SUPPORTING_WM_CHECK` on the root points at the EXWM
identity window, xterm and xclock appear under the EXWM
container hierarchy with WM_CLASS and `_NET_WM_PID` set
(runlog `docs/runlogs/2026-05-21-v0910-exwm-xvfb-hurd.md`).
The canonical image ships emacs-nox, so four apt packages
(`xvfb`, `emacs-lucid`, `elpa-exwm`, `elpa-xelb`) need
installing for the X mode. v0.9.24 ships the v1.x apt-image
flavor that bundles them; run `FLAVOR=apt-image
iso-build/hurd-image-reroll.sh` to bake a derivative image
with the four packages plus `pulseaudio` already installed.
`x11-utils`, `xterm`, `xdotool`, `x11-apps` are already in the
canonical set.

The "die when parent dies" link that Linux gets via
`prctl(PR_SET_PDEATHSIG)` is abstracted through the new
`port->arm_parent_death(signal)` slot in `port_layer.h`. The
Linux body calls prctl; the Hurd body returns ENOSYS in v0.9.8
and gets the real `MACH_NOTIFY_DEAD_NAME` watcher-thread
implementation in v0.9.9 (cited above). Note: `proc_setowner`,
which an earlier draft of this doc and the v0.9.7 release memory
incorrectly named as the Hurd analogue, is marked Deprecated at
`/usr/include/x86_64-gnu/hurd/process.defs:127` and is not the
right primitive. The right primitive is `MACH_NOTIFY_DEAD_NAME`
requested via `mach_port_request_notification` at
`mach_port.defs:247`.

## CI shape

`.github/workflows/checks.yml` runs the host-side gates on every
push to main and to the `hurd` branch. Pure-text passes
(attribution-scan, no-shell-check) cover both. A boot smoke test
on a Hurd qcow2 needs a self-hosted runner with KVM and a Hurd
toolchain; workflow drafted at `.github/workflows/hurd-smoke.yml`,
ungates the day a self-hosted runner labelled `hurd-kvm` registers,
see `docs/CI_HURD_RUNNER.md` for the operator recipe.

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
  - boot to multi-user on Hurd: shipped 2026-05-18 in v0.8.
    Design 2.2 (parallel Mach channel for the auth handshake)
    implemented in 5 slices; end-to-end multi-user verified on
    canonical Debian GNU/Hurd 0.9 VM. See
    `docs/runlogs/2026-05-18-hurd-end-to-end-vm.md`.  The
    earlier pflocal SCM_RIGHTS probe (receipt at
    `docs/runlogs/2026-05-18-hurd-pflocal-cmsg-fail.md`) is
    what forced the pivot to design 2.2; the port_caps slots,
    the AF_UNIX `pid1-unix-*` bindings, and the elisp
    dispatcher all stayed, only the rendezvous-port hand-off
    moved to the side Mach channel.  The Hurd cross-toolchain
    question is closed: the build runs natively on the Hurd VM
    (`make PORT=hurd` against Debian GNU/Hurd 0.9's gcc +
    libhurd-dev).
  - CI gate: host-side text checks only, see above. KVM-gated
    boot smoke is v0.8.
  - service supervision after host_reboot: closed in v0.9.11.
    Until v0.9.11 pid1 only supervised emacs, so Debian's
    sysvinit-spawned services (sshd, syslogd) did not come back
    after a `(pid1-reboot)` because /sbin/init is now emacs-init,
    not sysvinit.  `emacs-init/services/hurd-essentials.el`
    closes the gap by defining `hurd-sshd` (`:restart on-crash`)
    and `hurd-syslogd` (`:restart always`) under `supervise.el`;
    both autostart.  The whole file is a top-level
    `(when (eq geos-kernel 'hurd) ...)` guard so it is a strict
    no-op on Linux even though the Linux boot gexp now also
    passes `-l services/hurd-essentials.el`.  The old v0.8 design
    item ("GEOS-side service supervisor on the Hurd side that
    reads /etc/geos/services.d/*.scm") is closed for the two
    daemons that matter today; the broader disk-backed
    service-definition story remains future work on the Linux
    side too.
  - args-file fallback for /hurd/startup argc==1: closed in
    v0.9.11.  `/hurd/startup` execs `/sbin/init` with `argc==1`
    (or with a sysvinit runlevel token in argv[1]); neither is
    an absolute path, so pid1 cannot derive its boot chain from
    kernel argv the way the Guix gexp gives it on Linux.
    `parse_init_args` in `pid1/emacs-init.c` reads
    `/etc/geos/init.args` (one arg per line, `#` comments
    stripped) when `argv[1]` is not absolute, then splices the
    synthesized argv into `main()` and the rest of pid1 runs
    unchanged.  Linux/Guix passes an absolute store path in
    `argv[1]`, so `parse_init_args` is short-circuited before
    the `open()` call.  See `docs/HURD_BOOT.md` for the
    operator-side workflow.

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
| `port->mount` (Hurd: `fshelp_start_translator` + `file_set_translator`) | rewritten 2026-05-17 (hurd branch `e3fd411`) to fork the translator via libfshelp before binding it; the prior body passed `MACH_PORT_NULL` as the active port and was a silent no-op. argv assembly fixed 2026-05-18 (hurd branch `3b77e06`): linux-style `-o mode=0755` opts were being forwarded to `/hurd/tmpfs` as positional words, which the translator rejected with "too many arguments"; opts are now dropped on the floor when `type == "tmpfs"` because the Hurd translator takes only a numeric size | YES on 2026-05-17 (`/hurd/tmpfs 256M` round-trip: showtrans, df, write, settrans -g); argv-fix path verified by the PID-1 boot transcript on 2026-05-18 where the pre-fix run logged "tmpfs: too many arguments" |
| `port->set_hostname` (Hurd: POSIX) | written | YES on 2026-05-17 (`pid1-set-hostname "geos-hurd"` returned `t`, hostname changed) |
| `port->bring_up_lo` (Hurd: pfinet SIOCSIFFLAGS) | written | YES on 2026-05-17 (lo came up UP/LOOPBACK/RUNNING) |
| `port->set_address` (Hurd: pfinet SIOCSIFADDR+) | normalizes bare ifnames (hurd branch `b031db5`); `"eth0"` -> `"/dev/eth0"` before the ioctl, `"lo"` passes through | YES on 2026-05-17 (`pid1-set-address "eth0" "10.0.2.15" 24` returned `t` after the normalization fix; bare `"eth0"` had returned ENODEV before) |
| `port->set_route_default` (Hurd: pfinet SIOCADDRT) | rewritten 2026-05-17 to use Hurd's `ifrtreq_t`; ifname normalization shared with `set_address` (hurd branch `b031db5`) | YES on 2026-05-17 (`pid1-set-route-default "10.0.2.2" "eth0"` returned `t`, NAT gateway stayed reachable) |
| `port->reboot` (Hurd: `host_reboot` Mach RPC) | rewritten to use `get_privileged_ports` instead of `mach_host_self` (hurd branch `72f86f6`); the unprivileged host name port was rejected with KERN_INVALID_HOST | **YES on 2026-05-18** (`(pid1-reboot)` from emacs --batch dropped the SSH session and GRUB came back; emacs respawned on the fresh boot) |
| `port->suspend` (Hurd: ENOSYS forever) | written | n/a, design |
| `port->get_peer_cred` (Hurd: side-channel Mach port + `auth_server_authenticate`) | v0.8 body shipped end-to-end on hurd branch.  After the pflocal cmsg pivot (`docs/runlogs/2026-05-18-hurd-pflocal-cmsg-fail.md`) the body now looks up the pending Mach rendezvous port via the `pending_auth[]` table the libports translator populates from `S_geos_auth_submit_nonce` (real `auth_server_authenticate`), then returns the euid/egid; deallocates rendez and the uid/gid arrays on every exit.  Shipped at hurd branch `aec165f` | ENOSYS path: YES on 2026-05-17.  v0.8 dance: **YES on 2026-05-18** (runlog `docs/runlogs/2026-05-18-hurd-end-to-end-vm.md`; child slice4_handshake_ok=1, parent slice4_handshake_ok=1, parent slice5_handshake_ok=1).  **Re-verified on 2026-05-22 (v0.9.14 slice 1)**: all nine slice-5 markers fire on the v0.9.13 stack (hurd `aec165f`); harness exits 0 in 2.15s wall; pending_auth fingerprint changed across the drain; runlog `docs/runlogs/2026-05-22-v0914-multiuser-reverify.md` |
| `port->client_auth_handshake` (Hurd: side-channel Mach port + `auth_user_authenticate`) | v0.8 body now reads the per-connection nonce from the AF_UNIX socket, posts the `submit_nonce` `mach_msg` through the parallel Mach channel to the libports translator at `/servers/geos-auth`, then calls `auth_user_authenticate(getauth(), rendez, ...)`; every exit branch deallocates rendez.  Shipped at hurd branch `c2b6246` + `ce4f693` + `9c005e0` | Linux no-op: YES on Linux (Fpid1_client_auth_handshake binding lives on main `c5a7ed4`, rpc-client.el calls it per connection at `5201055`).  Hurd dance: **YES on 2026-05-18** (runlog `docs/runlogs/2026-05-18-hurd-end-to-end-vm.md`; child slice4_handshake_ok=1, parent slice4_handshake_ok=1, parent slice5_handshake_ok=1) |
| `port->publish_auth_port` (Hurd: libports-based fsys translator at `/servers/geos-auth`) | Linux returns ENOSYS, coerced to `t` in the `Fpid1_publish_auth_port` binding for kernel-uniformity.  Hurd backend installs a libports-based fsys translator at `/servers/geos-auth` and drains incoming `submit_nonce` Mach messages once per tick.  Slot + stub shipped at hurd `a52cbf3` / `0a1852e`; libports + fsys server demuxer shipped at hurd `d6716cc` / `64adc69` | **YES on 2026-05-18** (runlog `docs/runlogs/2026-05-18-hurd-publish-auth-port.md`) |
| `port->auth_drain` (Hurd: per-tick `mach_msg` drain pump) | Linux: no-op returning 0.  Hurd: bounded drain at 16 messages per tick, called from the supervisor's 200ms poll, feeds the `pending_auth[]` table that `get_peer_cred` reads.  Shipped at hurd `64adc69` | **YES on 2026-05-18** (drain confirmed by the slice-5 harness in `docs/runlogs/2026-05-18-hurd-end-to-end-vm.md`) |
| `pid1-unix-*` AF_UNIX bindings (own the rpc-client fd) | five Femacs bindings on main (`c5a7ed4`): `pid1-unix-connect/send/recv/recv-exactly/close`.  geos-rpc rewritten on top (`5201055`) so pid1 owns the fd from `socket()` through `close()`; the Hurd peer-cred cmsg now travels on a fd this process controls | YES on Linux (rpc-client.el rewrite passes byte-compile clean; freeze-tests for the rpc verbs shadow `geos-rpc` via cl-letf and do not exercise the wire) |
| `geos-kernel` elisp defvar (reads `GEOS_KERNEL` env) | runs everywhere | YES on Linux |
| GEOS_KERNEL env splice (`port->kernel_name` → execve envp → per-user emacs) | implemented (`a53304b`) | YES on Linux |
| `core/network.el` Linux/Hurd dispatch | implemented | YES on 2026-05-18 (v0.9.2; Hurd arm parses `/proc/route` with decimal addresses and the `/dev/` prefix stripped; dev reader derives iface set from the same parse with counters stub-zero).  **Per-iface counters: deferred at translator level** (v0.9.6 probe 2026-05-20 confirmed pfinet does not expose byte/packet counters via any ioctl, Mach RPC, or procfs file; `pfinet.defs` subsystem 37000 has exactly two routines and no stats slot is reserved in `iioctl.defs`; runtime SIOCGIFSTATS returns ENOTTY; counters remain stub-zero pending an upstream pfinet patch which is FSF/GNU territory); runlogs `docs/runlogs/2026-05-18-v092-procnet-verify.md` + `docs/runlogs/2026-05-20-hurd-pfinet-counters-probe.md` |
| `core/state.el` Linux/Hurd dispatch | implemented | YES on 2026-05-18 (v0.9.1; VM-verified on Debian Hurd 0.9: no /var translator and no /proc/sys, so writable-probe is authoritative; native procfs read is wired but inert today; runlog `docs/runlogs/2026-05-18-v091-procfs-verify.md`) |
| `core/uname.el` Linux/Hurd dispatch | implemented | YES on 2026-05-18 (v0.9.1; VM-verified on Debian Hurd 0.9: /proc/sys/kernel/* absent, /proc/version parsed for release+version, per-field synthesis fills the rest; runlog `docs/runlogs/2026-05-18-v091-procfs-verify.md`) |
| `buffers/disks.el` Hurd not-implemented banner | implemented | **YES (live-verified)** on 2026-05-20 (v0.9.5; Hurd arm walks `/dev/` for whole-disk node patterns (wd*, hd*, sd*, ucd*, ud*, cd*, fd*), parses `/proc/mounts` for the device column matching the literal `/dev/<name>` form the live VM emits; `:size-bytes` now resolves through `(pid1-disk-size-bytes name)` which routes to `port_hurd_disk_size_bytes` and the `file_get_storage_info` RPC at `hurd/2e91f9f` (`device_get_status DEV_GET_SIZE` on the file_t port returns MIG_BAD_ID, per probe `docs/runlogs/2026-05-20-hurd-storeio-getsize.md`); end-to-end VM-verify returned `(:name "wd0" :size-bytes 4194304000 :removable nil)` with zero Mach port leak across 100 calls, runlog `docs/runlogs/2026-05-20-v095-disk-size-verify.md`) |
| `install/disk.el` Hurd not-implemented banner | implemented | **YES (live-verified)** on 2026-05-20 (v0.9.5; Hurd arm enumerates whole disks the same way, parses `/proc/mounts` for mounted-p, and `install-disk--size-bytes-hurd` now calls `(pid1-disk-size-bytes name)` via the same RPC path as the disks buffer; install wizard's partition/format/grub steps remain Linux-only and refused on Hurd by `buffers/install.el`; live-verified at `(install-disk--size-bytes-hurd "wd0") -> 4194304000`, runlog `docs/runlogs/2026-05-20-v095-disk-size-verify.md`) |
| install wizard slice C: mkfs.ext4 + grub-install end-to-end on Hurd (`emacs-init/install/mkfs.el` + `emacs-init/install/grub.el` + `emacs-init/buffers/install.el` `install-yes` gate) | code shipped on main at `db3c14b` (the `install-yes` gate accepts both `geos-kernel-linux-p` and `geos-kernel-hurd-p`; `install-mkfs-ext4` and `install-grub-install` both go through `make-process` with no shell wrapping; the hurd plist shape resolves to a `/dev/wd0sN` string via `install--part-node`).  v1.x bucket-3 research at `docs/runlogs/2026-05-23-...-v1x-install-hurd-scope.md` already verified mke2fs and grub-install open `/dev/wd0sN` storeio nodes byte-for-byte | **YES (live-verified)** on 2026-05-30 (v0.9.23 in-VM verify on v0.9.22 image with a second IDE disk: `install-mkfs-ext4 "/dev/wd1s1" "geos-elisp-test"` returned `(t nil)` and the resulting ext4 mounts via `settrans -a /mnt/wd1 /hurd/ext2fs /dev/wd1s1` with `lost+found` visible; `install-grub-install "/dev/wd1" "/mnt/wd1"` returned `(t nil)` with work-buffer tail "Installation finished. No error reported." + exit code=0, `/mnt/wd1/boot/grub/i386-pc/core.img` is 28,424 B, MBR (`dd if=/dev/wd1 bs=512 count=1`) contains the GRUB signature; runlog `docs/runlogs/2026-05-30-hurd-v0923-install-slice-c-verify.md`) |
| `services/journal-tail.el` Hurd kmsg source | implemented | **YES (live-verified)** on 2026-05-21 (v0.9.6; Hurd arm runs `tail -F --lines=+1 /var/log/kern.log` under supervise.el and dispatches per-line to a new `journal-buffer--parse-syslog-record` that parses the BSD/inetutils one-line format into the standard journal record plist (`:source 'syslog`, `:sev "info"` defaulted since kern.log is implicitly kern.*, `:time` parsed from `MMM DD HH:MM:SS` with current-year defaulting).  no port_caps slot needed: the v0.9.6 probe receipt at `docs/runlogs/2026-05-21-hurd-kmsg-probe.md` confirmed `/dev/klog` is a `/hurd/streamio kmsg` translator that blocks and has no history replay, and Debian Hurd 0.9 ships `inetutils-syslogd` running by default which drains it into `/var/log/kern.log`.  live end-to-end verified at runlog `docs/runlogs/2026-05-21-v096-kmsg-verify.md`: `(supervise-start 'journal-kmsg)` spawned tail, backlog replayed, synthetic appended line landed live in `*journal*`; 100-call leak smoke clean (VmSize delta 0).  one caveat documented in the verify receipt: on this Debian Hurd 0.9 snapshot kern.log is 0 bytes at boot because gnumach boot printfs land in `/var/log/dmesg` (read direct from the gnumach printbuf by `dmesg(8)`) rather than via the /dev/klog -> syslogd -> kern.log path; the pipeline is correct, future runtime kernel events would flow through.  **dmesg-prime follow-on shipped at main/3d4a88b and live-verified on 2026-05-21** (v0.9.7; `journal-tail--prime-from-dmesg` reads /var/log/dmesg at load time on Hurd and appends each non-empty line as a `:source 'dmesg` record so the day-zero buffer carries the boot transcript; 61 dmesg lines = 61 journal records, exact match; runlog `docs/runlogs/2026-05-21-v096-dmesg-prime-verify.md`)) |
| `user/userland/audio.el` Hurd not-implemented banner | implemented | YES on 2026-05-20 (v0.9.4 doc-flip; `audio-list-cards' on Hurd routes through `geos-port-unimplemented' and returns nil so the `*audio*' buffer renders "no cards visible" cleanly.  Hurd has no ALSA, no `/proc/asound', no audio translator under `/hurd/'; a native sink (OSS-style or Mach-RPC once a Hurd audio translator exists) is a later slice).  **Native audio translator surface: deferred at translator level** (v0.9.7 probe 2026-05-21 confirmed Debian GNU/Hurd 0.9 ships no /hurd/audio*, no settrans-attached /dev/dsp /dev/audio /dev/mixer /dev/snd nodes, no audio entry under /servers, no /proc/asound analogue, zero audio enumeration in the gnumach boot transcript, and `dpkg -L hurd` matches zero files with audio names; H1-H4 all falsified.  pulseaudio 17.0+dfsg1-2.1 and the sndio family are installable from debian-ports sid/main hurd-amd64 but not bundled in the canonical image, so a future v1.x slice would wire `userland/audio.el` to a pulseaudio daemon path gated on user `apt install pulseaudio`; out of scope for v0.9.x.  runlog `docs/runlogs/2026-05-21-hurd-audio-probe.md`) |
| `port->arm_parent_death` (Linux: `prctl(PR_SET_PDEATHSIG)`; Hurd: `MACH_NOTIFY_DEAD_NAME` via `mach_port_request_notification`) | v0.9.8 slot landed on main with Hurd ENOSYS placeholder; v0.9.9 ships the real Hurd body on the side branch (`hurd/9f2fe6f`): proc_pid2task(getppid()) + mach_port_allocate(RECEIVE) + mach_port_request_notification(MACH_NOTIFY_DEAD_NAME) + a DETACHED pthread watcher that blocks in mach_msg until the dead-name arrives, then pthread_kill(main_thread, sig).  parent_task SEND right ownership transfers to the watcher (do NOT deallocate in the armer; the kernel binds the notification to the ipc_entry).  re-entrancy: IDEMPOTENT on same signal, EALREADY on different signal.  watcher targets the main thread by pthread_kill, not the process by kill(getpid()) (multi-threaded Hurd race).  call site is `spawn_xorg()`'s post-fork child, which still tolerates ENOSYS as defence-in-depth | YES on Linux (prctl shipped, freeze-test `freeze-test-arm-parent-death.el` covers slot-bound + linux-prctl-call + raises-pid1-error-class + error-shape); **YES on Hurd (live-verified)** on 2026-05-21 (v0.9.9 third VM-verify pass on Debian GNU/Hurd 0.9: Probe A 10/10 unamended fork-and-die end-to-end with no orphan B; Probe B EALREADY contract intact (B1 rc=0; B2 same-sig idempotent rc=0; B3 different-sig rc=-1 errno=0x40000025 = err_hurd|EALREADY); Probe C 100-call leak smoke Threads delta +1, VmSize delta +8196 KiB; Probe D2 helper-call returns -1 with errno=ESRCH and SIGUSR2 sentinel within 1s; freeze-test triple green; v0.9.5/v0.9.6/v0.9.7/v0.9.8 regression sweep clean; runlog `docs/runlogs/2026-05-21-v099-vm-verify.md`.  load-bearing ground truth recorded: gnumach 1.8+git20260224 + Hurd userspace encode kern_return_t as `err_hurd|unix_errno`, so proc_pid2task returns `0x40000003 == ESRCH` and `0x40000005 == EIO` directly (not `err_kern|KERN_*` as two earlier iterations assumed); the parent-gone guard compares against the wire values `(kern_return_t)ESRCH` / `(kern_return_t)EIO` / `KERN_INVALID_NAME` (the last retained as a portability defence)) |
| EXWM attaches to Xvfb on Hurd (userland surface, no port_caps slot) | EXWM 0.33 + xelb 0.20 on emacs-lucid 30.2 attach to the v0.9.8-spawned Xvfb on Hurd unchanged from the Linux path; the userland code does not branch on kernel.  packaging gap on the canonical image: `xvfb`, `emacs-lucid`, `elpa-exwm`, `elpa-xelb` must be `apt install`ed (canonical ships emacs-nox only; `x11-utils`, `xterm`, `xdotool`, `x11-apps` are already in the canonical set).  a future v1.x apt-image flavor bundles them | **YES (live-verified)** on 2026-05-21 (v0.9.10: Xvfb 21.1.22 live on `:99`; emacsclient eval reports `connection=t workspaces=2 managed=1 buffers=1`; root window has the EXWM identity / wmsn / timestamp / workspace-container family; `_NET_SUPPORTING_WM_CHECK` on the root points at the `"EXWM"` window in the same tree; xclock captured as a managed top-level with `WM_CLASS = "xclock","XClock"` and `_NET_WM_PID = 1770`; *Messages* clean of `pid1-error`/`exwm-error`; runlog `docs/runlogs/2026-05-21-v0910-exwm-xvfb-hurd.md`) |
| pid1 args-file fallback (`/etc/geos/init.args`) | argv[1] non-absolute -> read `/etc/geos/init.args` (O_NOFOLLOW + fstat root-owned regular file); covers the `/hurd/startup argc==1` case and the sysvinit-runlevel-token case (e.g. argv[1]=="6"); Linux/Guix passes argv[1]=/gnu/store/.../emacs and the file is never opened.  parse_init_args at `pid1/emacs-init.c` is the source of truth for the failure-mode contract (open errno, non-regular, non-root, short read, empty file, file > 8 KiB, slot-cap overflow; all fall through to the default argv with one-line console log).  installer wrapper at `install/hurd-bootstrap.sh` writes the file as root:root 0644 with explicit chown after chmod | **YES (v0.9.11)** on 2026-05-21 |
| GEOS supervisor for sshd + syslogd on Hurd (`emacs-init/services/hurd-essentials.el`) | defines `hurd-sshd` (`:restart on-crash`, `/usr/sbin/sshd -D -e`) and `hurd-syslogd` (`:restart always`, `/usr/sbin/inetutils-syslogd --no-detach`); both autostarted via the supervise.el sentinel.  top-level `(when (eq geos-kernel 'hurd) ...)` guard makes the file a strict no-op on Linux even though the Linux boot gexp also passes `-l services/hurd-essentials.el`.  closes the prior v1.0.0 design item "GEOS-side service supervisor on the Hurd side" for the two daemons that actually matter today (sshd to keep the box reachable across `(pid1-reboot)`, syslogd to keep `/var/log/kern.log` growing for the journal-kmsg source) | **YES (v0.9.11)** on 2026-05-21 |
| `port->remount_root_rw` (Linux: no-op; Hurd: `fsys_set_options "--writable"` against the root file_t) | slot lives at `pid1/port_layer.h`; Linux body is a `return 0` (the GEOS Linux image already mounts `/` rw and would silently regress on a future image change); Hurd body opens `/`, gets the underlying control port via `file_getcontrol`, then `fsys_set_options(rootctl, "--writable", 1, &options, sizeof options)`.  called from `emacs-init.c` in the post-mount block, before the `/run/sshd` mkdir; failure logs to `/dev/console` and continues (downstream native-comp opt-out covers the regression case) | **YES (v0.9.12)** on 2026-05-22 (`pid1: remount / rw OK` on serial; underlying ext2 `/tmp` writable; native-comp trampoline write no longer aborts emacs at startup) |
| native-comp opt-out on Hurd (`emacs-init/early-init.el`) | `GEOS_KERNEL == "hurd"` branch sets `native-comp-jit-compilation nil` and `native-comp-enable-subr-trampolines nil`.  read env directly here because native-comp can fire before core/port.el loads.  belt + suspenders against any future image where the remount-rw path fails or `/tmp` becomes RO again | **YES (v0.9.12)** on 2026-05-22 (no `kill_emacs` trampoline-loop on Hurd; emacs reaches the supervisor loop and registers `hurd-sshd` + `hurd-syslogd`) |
| supervisor `/dev/console` breadcrumbs (`emacs-init/core/supervise.el`) | `supervise--console` helper writes one line per state transition (`supervise--spawn` pre/post-make-process, `supervise--sentinel` entry, `supervise-autostart` per-service START/SKIP-held/ERROR).  `supervise-finalize` refactored onto the same helper.  makes silent autostart failures (the v0.9.12 slice-8 dhclient dead end was discovered by this) visible on the serial log without changing supervisor semantics | YES on Linux (helper inert if `/dev/console` is missing or unwritable; condition-case swallows the errno); **YES (v0.9.12)** on 2026-05-22 (verbatim breadcrumb lines `hurd-essentials: settrans pfinet exit=0` + `hurd-essentials: eth0 static OK` + per-service START lines captured on serial during slice 12 VM-verify) |
| static eth0 bring-up on Hurd (`emacs-init/services/hurd-essentials.el`) | `geos-hurd-static-eth0` defcustom (default `t`); when set, runs `/bin/settrans -fgap /servers/socket/2 /hurd/pfinet -i /dev/eth0 -a <addr> -m <mask> -g <gw>` to attach pfinet with the full SLIRP address shape inline, then calls `pid1-set-address` + `pid1-set-route-default` as reconcile/verify.  flip the defcustom to `nil` for bare-metal DHCP; the settrans pre-step still runs so an apt-installed dhcp client has a live pfinet to bind to | **YES (v0.9.12)** on 2026-05-22 (`inetutils-ifconfig` inside the guest shows `/dev/eth0` with inet 10.0.2.15 netmask 255.255.255.0; route table has the SLIRP default 10.0.2.2) |
| end-to-end SSH on Hurd (host -> guest interactive session) | downstream surface, no new slot; depends on remount-rw + native-comp opt-out + static eth0 + the v0.9.11 supervisor + the v0.9.11 `/run/sshd` privsep chroot fix.  no GEOS-side code beyond what the previous rows shipped; this row exists to anchor the load-bearing release claim | **YES (v0.9.12)** on 2026-05-22 (host runs `ssh -p 2266 root@127.0.0.1 'uname -a'` and gets back `GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224/Hurd-0.9 i686-AT386 GNU`; banner string `SSH-2.0-OpenSSH_10.2p1 Debian-5` on `nc 127.0.0.1 2266`; full interactive session opens and closes cleanly; supervisor stays up; runlog `docs/runlogs/2026-05-22-hurd-end-to-end-ssh.md`) |
| journal-kmsg defservice autostart on Hurd (`emacs-init/services/journal-tail.el` + `emacs-init/early-init.el`) | three v0.9.13 slices stack: slice 1 (`journal-tail--ensure-kern-log-hurd`) writes "" to `/var/log/kern.log` via `write-region` so the supervised `tail -F --lines=+1` does not race syslogd's first kern.log write and burn the on-crash respawn cap; slice 2 wraps a `(make-directory "/var/log" t)` ahead of the write because pid1 tmpfs-mounts `/var` and the parent directory is absent on the live FS; slice 3 (Hurd block in `early-init.el`) appends `/usr/bin /usr/sbin /bin /sbin` to `exec-path` and mirrors them into `PATH` because emacs's Guix-shaped default `exec-path` (`/run/current-system/profile/{bin,sbin}`) does not exist on a Debian Hurd guest and `make-process :command '("tail" ...)` resolved to nil before fork.  the three slices ship as main `afd1f3f` + `7e4fc42` (hurd `85c25f0` + `ae51c4e`), all kernel-gated and no-op on Linux | **YES (live-verified)** on 2026-05-22 (fresh ephemeral snapshot off canonical Debian Hurd 0.9; all 7 re-verify checks PASS: `/var/log/kern.log` exists at first ssh-able moment, journal-kmsg `:status running :pid 35` with `tail -F --lines=+1 /var/log/kern.log` alive under emacs supervisor, `:restarts 0 :respawn-times nil` so cap unburned, `*panic*` empty, hurd-sshd + hurd-syslogd no regression, `exec-path` contains `/usr/bin` and `(executable-find "tail")` returns `"/usr/bin/tail"`, `PATH` envvar carries the four Debian dirs; runlog `docs/runlogs/2026-05-22-v0913-journal-kmsg-verify.md`) |
| pid1 respawns supervisor emacs after crash on Hurd (no port_caps slot; POSIX `waitpid` path shared with Linux) | no code change; the supervisor loop, `sigaction(SIGCHLD, ...)`, and `waitpid(-1, &status, 0)` in `pid1/emacs-init.c` are byte-identical between branches.  `port_layer.h` documents the design intent explicitly: "waitpid(2) is POSIX and works on Hurd as-is; it does not go through the port layer".  the v0.9.11 receipt's observation that pid1 did NOT respawn on Hurd was correlated with emacs aborting mid-startup (native-comp trampoline failure before completing dynamic-module hookup), not a gnumach SIGCHLD delivery gap; v0.9.12's slice 2 + slice 4 closed the cause | **YES (live-verified)** on 2026-05-22 (6-cycle forced `kill -SEGV` exercise via host ssh: initial emacs pid=27 respawned through 93/146/182/218/254/290 with every cycle showing `pid1: emacs exited, respawning` + a new `early-init: emacs pid=N` on serial + `ppid=1` confirmed via `ps -A` over the re-established ssh + RPC channel up on each respawned emacs; runlog `docs/runlogs/2026-05-22-hurd-emacs-respawn-verify.md`) |
| STATIC=1 link cleanliness on Hurd (`pid1/Makefile` PORT=hurd PORT_BOOT_LIBS) | hurd-branch-only diff; main has no PORT=hurd block on the Makefile (the PORT machinery lives only on the side branch).  `PORT_BOOT_LIBS` wrapped in `-Wl,--start-group ... -Wl,--end-group` and extended with `-lihash -lshouldbeinlibc`.  under `-static` the linker has no DT_NEEDED chase, so libports.a's `hurd_ihash_*` references and libfshelp/libports' `idvec_*`/`exec_reauth`/`__assert_*_backtrace` references must come from named archives.  both ship in `hurd-dev` on Debian GNU/Hurd 0.9, the same package as `-lports` / `-lfshelp`.  shipped at hurd `5a2acec`; symbol-provider table, dpkg ownership map, and DT_NEEDED audit at `docs/runlogs/2026-05-23-hurd-static-link-investigation.md`.  module link line untouched (the `.so` resolves DT_NEEDED at dlopen time); the existing STATIC=0 dynamic path is unaffected (extra `-l` on a dynamic link is a no-op, start-group is inert for DSOs) | **YES (live-verified)** on 2026-05-23 (v0.9.17 in-VM verify on the preserved v0.9.16 work.img: `PORT=hurd STATIC=1 make` produced `emacs-init` 1,552,824 B with `file` reporting `statically linked` + no dynamic section per `readelf -d` + `ldd` reporting `not a dynamic executable`; STATIC=0 reference in the same VM linked at 51,592 B with all six Hurd `.so` plus glibc dynamically resolved; one benign upstream warning on `pt-hurd-cond-timedwait.o` lacks `.note.GNU-stack`, unrelated to GEOS; runlog `docs/runlogs/2026-05-23-hurd-v0917-static-in-vm-verify.md`) |
| pflocal `SO_RCVTIMEO` setsockopt (userland surface, no port_caps slot) | v0.9.19 bucket-2 probe traced the long-carried "emacsclient: setsockopt: Protocol not available" warning to a single setsockopt call: `setsockopt(fd, SOL_SOCKET=65535, SO_RCVTIMEO=0x1006, ...)` issued by emacsclient on every connection to bound the read timeout for the server reply.  pflocal (Hurd's AF_UNIX translator) returns ENOPROTOOPT for this option; glibc's strerror on Hurd renders that as "Protocol not available".  the failure is **non-fatal**: emacsclient prints the warning, continues without the timeout, and returns the correct eval result with exit 0.  evidence: gdb breakpoint on setsockopt caught `fd=3 level=65535 optname=4102` on the v0.9.16 work snapshot, decoded against `/usr/include/x86_64-gnu/bits/socket.h:377` (`SO_RCVTIMEO = 0x1006`).  remediation paths: (a) two-line emacsclient.c upstream patch suppresses the message when `errno == ENOPROTOOPT` (correct fix, ships in emacs 31); (b) pflocal patch teaches SO_RCVTIMEO on the server-side recv() path (out of scope; savannah hurd tracker).  no GEOS-side change warranted (single stderr line is not worth a wrapper, per the repo's no-premature-abstraction rule).  runlog `docs/runlogs/2026-05-23-hurd-v0919-bucket2-probes.md` | **deferred-upstream** (pflocal SO_RCVTIMEO is a translator-level gap; the user-visible noise is a single stderr line per emacsclient invocation, behaviour is functionally correct) |

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

Three 2026-05-18 runlogs close the verification gap end-to-end:
the first PID-1 boot (`2026-05-18-hurd-pid1-boot-result.md`),
the argv-fix followup that got emacs spawning
(`2026-05-18-hurd-pid1-emacs-spawn.md`), and the host_reboot
Mach RPC end-to-end verification
(`2026-05-18-hurd-pid1-reboot.md`).  The reboot RPC needed one
real code change: `hurd_reboot_cmd` was calling
`mach_host_self()` (the unprivileged host name port), which
gnumach rejects for `host_reboot`; the fix uses
`get_privileged_ports(&host_priv, NULL)` from `<hurd.h>` to
fetch the proc-server-cached privileged port.  Live on the hurd
branch as `72f86f6`.

## 2026-05-18 bootstrap-order fix round

The first-boot transcript surfaced three issues on the pid1 /
Hurd-bootstrap seam: read-only root at init time, tmpfs argv
shape, and the absent-default-pager line.  All three landed
the same day:

  - **tmpfs argv** (hurd branch `3b77e06`).  `/hurd/tmpfs`
    treats positional words past its size argument as additional
    sizes and dies with "too many arguments" the moment we
    forward Linux's `-o mode=0755` opts.  Fix in `hurd_mount`:
    when `type == "tmpfs"`, drop opts on the floor entirely.
    Other types still forward opts unchanged.
  - **mkdir EROFS noise** (main `031d933`).  On a read-only
    rootfs, `mkdir` on a directory that already exists returns
    EROFS, NOT EEXIST, so the existing EEXIST guard never fires
    and the boot log fills with one line per standard
    directory.  Fix in `do_mount` and `mount_var`: `access(F_OK)`
    pre-check skips `mkdir` entirely when the directory exists.
    Behavior on Linux is unchanged (the access path is fast).
  - **sethostname EROFS** (main `b5e00e2`).  glibc-hurd's
    `sethostname` wrapper persists to `/etc/hostname` after the
    proc-server RPC, hitting EROFS against the read-only root
    at init time.  The C side now stays a single
    log-and-continue; `core/hostname.el`'s `hostname-apply`
    already runs at supervisor load time and re-calls
    `pid1-set-hostname` through the same `port->set_hostname`
    slot, so the proc-server picks up the right name once the
    rootfs is remounted rw.

The "/hurd/tmpfs: No default pager (memory manager) is running
/ Started it" line that scrolled past during the first boot
turned out to be self-healing: gnumach's `/hurd/proxy-defpager`
starts on demand, and the next translator request succeeds.
No code change needed; left as an informational log line.

Verification of the post-fix state on a fresh Hurd boot is the
next runlog (`docs/runlogs/2026-05-1X-hurd-pid1-bootstrap-
post-fix.md`).  Expected delta against
`2026-05-18-hurd-pid1-boot-result.md`: the "mkdir ... failed:
Read-only file system" lines disappear; the "tmpfs: too many
arguments" line disappears; the "sethostname failed: Read-only
file system" line still appears once at C-level, then a second
attempt from `hostname-apply` either succeeds silently or logs
a structured `*panic*` frame.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".

# GNU Free Documentation License

Version 1.3, 3 November 2008

Copyright (C) 2000, 2001, 2002, 2007, 2008 Free Software Foundation,
Inc. <https://fsf.org/>

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.

## 0. PREAMBLE

The purpose of this License is to make a manual, textbook, or other
functional and useful document "free" in the sense of freedom: to
assure everyone the effective freedom to copy and redistribute it,
with or without modifying it, either commercially or noncommercially.
Secondarily, this License preserves for the author and publisher a way
to get credit for their work, while not being considered responsible
for modifications made by others.

This License is a kind of "copyleft", which means that derivative
works of the document must themselves be free in the same sense. It
complements the GNU General Public License, which is a copyleft
license designed for free software.

We have designed this License in order to use it for manuals for free
software, because free software needs free documentation: a free
program should come with manuals providing the same freedoms that the
software does. But this License is not limited to software manuals; it
can be used for any textual work, regardless of subject matter or
whether it is published as a printed book. We recommend this License
principally for works whose purpose is instruction or reference.

## 1. APPLICABILITY AND DEFINITIONS

This License applies to any manual or other work, in any medium, that
contains a notice placed by the copyright holder saying it can be
distributed under the terms of this License. Such a notice grants a
world-wide, royalty-free license, unlimited in duration, to use that
work under the conditions stated herein. The "Document", below, refers
to any such manual or work. Any member of the public is a licensee,
and is addressed as "you". You accept the license if you copy, modify
or distribute the work in a way requiring permission under copyright
law.

A "Modified Version" of the Document means any work containing the
Document or a portion of it, either copied verbatim, or with
modifications and/or translated into another language.

A "Secondary Section" is a named appendix or a front-matter section of
the Document that deals exclusively with the relationship of the
publishers or authors of the Document to the Document's overall
subject (or to related matters) and contains nothing that could fall
directly within that overall subject. (Thus, if the Document is in
part a textbook of mathematics, a Secondary Section may not explain
any mathematics.) The relationship could be a matter of historical
connection with the subject or with related matters, or of legal,
commercial, philosophical, ethical or political position regarding
them.

The "Invariant Sections" are certain Secondary Sections whose titles
are designated, as being those of Invariant Sections, in the notice
that says that the Document is released under this License. If a
section does not fit the above definition of Secondary then it is not
allowed to be designated as Invariant. The Document may contain zero
Invariant Sections. If the Document does not identify any Invariant
Sections then there are none.

The "Cover Texts" are certain short passages of text that are listed,
as Front-Cover Texts or Back-Cover Texts, in the notice that says that
the Document is released under this License. A Front-Cover Text may be
at most 5 words, and a Back-Cover Text may be at most 25 words.

A "Transparent" copy of the Document means a machine-readable copy,
represented in a format whose specification is available to the
general public, that is suitable for revising the document
straightforwardly with generic text editors or (for images composed of
pixels) generic paint programs or (for drawings) some widely available
drawing editor, and that is suitable for input to text formatters or
for automatic translation to a variety of formats suitable for input
to text formatters. A copy made in an otherwise Transparent file
format whose markup, or absence of markup, has been arranged to thwart
or discourage subsequent modification by readers is not Transparent.
An image format is not Transparent if used for any substantial amount
of text. A copy that is not "Transparent" is called "Opaque".

Examples of suitable formats for Transparent copies include plain
ASCII without markup, Texinfo input format, LaTeX input format, SGML
or XML using a publicly available DTD, and standard-conforming simple
HTML, PostScript or PDF designed for human modification. Examples of
transparent image formats include PNG, XCF and JPG. Opaque formats
include proprietary formats that can be read and edited only by
proprietary word processors, SGML or XML for which the DTD and/or
processing tools are not generally available, and the
machine-generated HTML, PostScript or PDF produced by some word
processors for output purposes only.

The "Title Page" means, for a printed book, the title page itself,
plus such following pages as are needed to hold, legibly, the material
this License requires to appear in the title page. For works in
formats which do not have any title page as such, "Title Page" means
the text near the most prominent appearance of the work's title,
preceding the beginning of the body of the text.

The "publisher" means any person or entity that distributes copies of
the Document to the public.

A section "Entitled XYZ" means a named subunit of the Document whose
title either is precisely XYZ or contains XYZ in parentheses following
text that translates XYZ in another language. (Here XYZ stands for a
specific section name mentioned below, such as "Acknowledgements",
"Dedications", "Endorsements", or "History".) To "Preserve the Title"
of such a section when you modify the Document means that it remains a
section "Entitled XYZ" according to this definition.

The Document may include Warranty Disclaimers next to the notice which
states that this License applies to the Document. These Warranty
Disclaimers are considered to be included by reference in this
License, but only as regards disclaiming warranties: any other
implication that these Warranty Disclaimers may have is void and has
no effect on the meaning of this License.

## 2. VERBATIM COPYING

You may copy and distribute the Document in any medium, either
commercially or noncommercially, provided that this License, the
copyright notices, and the license notice saying this License applies
to the Document are reproduced in all copies, and that you add no
other conditions whatsoever to those of this License. You may not use
technical measures to obstruct or control the reading or further
copying of the copies you make or distribute. However, you may accept
compensation in exchange for copies. If you distribute a large enough
number of copies you must also follow the conditions in section 3.

You may also lend copies, under the same conditions stated above, and
you may publicly display copies.

## 3. COPYING IN QUANTITY

If you publish printed copies (or copies in media that commonly have
printed covers) of the Document, numbering more than 100, and the
Document's license notice requires Cover Texts, you must enclose the
copies in covers that carry, clearly and legibly, all these Cover
Texts: Front-Cover Texts on the front cover, and Back-Cover Texts on
the back cover. Both covers must also clearly and legibly identify you
as the publisher of these copies. The front cover must present the
full title with all words of the title equally prominent and visible.
You may add other material on the covers in addition. Copying with
changes limited to the covers, as long as they preserve the title of
the Document and satisfy these conditions, can be treated as verbatim
copying in other respects.

If the required texts for either cover are too voluminous to fit
legibly, you should put the first ones listed (as many as fit
reasonably) on the actual cover, and continue the rest onto adjacent
pages.

If you publish or distribute Opaque copies of the Document numbering
more than 100, you must either include a machine-readable Transparent
copy along with each Opaque copy, or state in or with each Opaque copy
a computer-network location from which the general network-using
public has access to download using public-standard network protocols
a complete Transparent copy of the Document, free of added material.
If you use the latter option, you must take reasonably prudent steps,
when you begin distribution of Opaque copies in quantity, to ensure
that this Transparent copy will remain thus accessible at the stated
location until at least one year after the last time you distribute an
Opaque copy (directly or through your agents or retailers) of that
edition to the public.

It is requested, but not required, that you contact the authors of the
Document well before redistributing any large number of copies, to
give them a chance to provide you with an updated version of the
Document.

## 4. MODIFICATIONS

You may copy and distribute a Modified Version of the Document under
the conditions of sections 2 and 3 above, provided that you release
the Modified Version under precisely this License, with the Modified
Version filling the role of the Document, thus licensing distribution
and modification of the Modified Version to whoever possesses a copy
of it. In addition, you must do these things in the Modified Version:

-   A. Use in the Title Page (and on the covers, if any) a title
    distinct from that of the Document, and from those of previous
    versions (which should, if there were any, be listed in the
    History section of the Document). You may use the same title as a
    previous version if the original publisher of that version
    gives permission.
-   B. List on the Title Page, as authors, one or more persons or
    entities responsible for authorship of the modifications in the
    Modified Version, together with at least five of the principal
    authors of the Document (all of its principal authors, if it has
    fewer than five), unless they release you from this requirement.
-   C. State on the Title page the name of the publisher of the
    Modified Version, as the publisher.
-   D. Preserve all the copyright notices of the Document.
-   E. Add an appropriate copyright notice for your modifications
    adjacent to the other copyright notices.
-   F. Include, immediately after the copyright notices, a license
    notice giving the public permission to use the Modified Version
    under the terms of this License, in the form shown in the
    Addendum below.
-   G. Preserve in that license notice the full lists of Invariant
    Sections and required Cover Texts given in the Document's
    license notice.
-   H. Include an unaltered copy of this License.
-   I. Preserve the section Entitled "History", Preserve its Title,
    and add to it an item stating at least the title, year, new
    authors, and publisher of the Modified Version as given on the
    Title Page. If there is no section Entitled "History" in the
    Document, create one stating the title, year, authors, and
    publisher of the Document as given on its Title Page, then add an
    item describing the Modified Version as stated in the
    previous sentence.
-   J. Preserve the network location, if any, given in the Document
    for public access to a Transparent copy of the Document, and
    likewise the network locations given in the Document for previous
    versions it was based on. These may be placed in the "History"
    section. You may omit a network location for a work that was
    published at least four years before the Document itself, or if
    the original publisher of the version it refers to
    gives permission.
-   K. For any section Entitled "Acknowledgements" or "Dedications",
    Preserve the Title of the section, and preserve in the section all
    the substance and tone of each of the contributor acknowledgements
    and/or dedications given therein.
-   L. Preserve all the Invariant Sections of the Document, unaltered
    in their text and in their titles. Section numbers or the
    equivalent are not considered part of the section titles.
-   M. Delete any section Entitled "Endorsements". Such a section may
    not be included in the Modified Version.
-   N. Do not retitle any existing section to be Entitled
    "Endorsements" or to conflict in title with any Invariant Section.
-   O. Preserve any Warranty Disclaimers.

If the Modified Version includes new front-matter sections or
appendices that qualify as Secondary Sections and contain no material
copied from the Document, you may at your option designate some or all
of these sections as invariant. To do this, add their titles to the
list of Invariant Sections in the Modified Version's license notice.
These titles must be distinct from any other section titles.

You may add a section Entitled "Endorsements", provided it contains
nothing but endorsements of your Modified Version by various
parties—for example, statements of peer review or that the text has
been approved by an organization as the authoritative definition of a
standard.

You may add a passage of up to five words as a Front-Cover Text, and a
passage of up to 25 words as a Back-Cover Text, to the end of the list
of Cover Texts in the Modified Version. Only one passage of
Front-Cover Text and one of Back-Cover Text may be added by (or
through arrangements made by) any one entity. If the Document already
includes a cover text for the same cover, previously added by you or
by arrangement made by the same entity you are acting on behalf of,
you may not add another; but you may replace the old one, on explicit
permission from the previous publisher that added the old one.

The author(s) and publisher(s) of the Document do not by this License
give permission to use their names for publicity for or to assert or
imply endorsement of any Modified Version.

## 5. COMBINING DOCUMENTS

You may combine the Document with other documents released under this
License, under the terms defined in section 4 above for modified
versions, provided that you include in the combination all of the
Invariant Sections of all of the original documents, unmodified, and
list them all as Invariant Sections of your combined work in its
license notice, and that you preserve all their Warranty Disclaimers.

The combined work need only contain one copy of this License, and
multiple identical Invariant Sections may be replaced with a single
copy. If there are multiple Invariant Sections with the same name but
different contents, make the title of each such section unique by
adding at the end of it, in parentheses, the name of the original
author or publisher of that section if known, or else a unique number.
Make the same adjustment to the section titles in the list of
Invariant Sections in the license notice of the combined work.

In the combination, you must combine any sections Entitled "History"
in the various original documents, forming one section Entitled
"History"; likewise combine any sections Entitled "Acknowledgements",
and any sections Entitled "Dedications". You must delete all sections
Entitled "Endorsements".

## 6. COLLECTIONS OF DOCUMENTS

You may make a collection consisting of the Document and other
documents released under this License, and replace the individual
copies of this License in the various documents with a single copy
that is included in the collection, provided that you follow the rules
of this License for verbatim copying of each of the documents in all
other respects.

You may extract a single document from such a collection, and
distribute it individually under this License, provided you insert a
copy of this License into the extracted document, and follow this
License in all other respects regarding verbatim copying of that
document.

## 7. AGGREGATION WITH INDEPENDENT WORKS

A compilation of the Document or its derivatives with other separate
and independent documents or works, in or on a volume of a storage or
distribution medium, is called an "aggregate" if the copyright
resulting from the compilation is not used to limit the legal rights
of the compilation's users beyond what the individual works permit.
When the Document is included in an aggregate, this License does not
apply to the other works in the aggregate which are not themselves
derivative works of the Document.

If the Cover Text requirement of section 3 is applicable to these
copies of the Document, then if the Document is less than one half of
the entire aggregate, the Document's Cover Texts may be placed on
covers that bracket the Document within the aggregate, or the
electronic equivalent of covers if the Document is in electronic form.
Otherwise they must appear on printed covers that bracket the whole
aggregate.

## 8. TRANSLATION

Translation is considered a kind of modification, so you may
distribute translations of the Document under the terms of section 4.
Replacing Invariant Sections with translations requires special
permission from their copyright holders, but you may include
translations of some or all Invariant Sections in addition to the
original versions of these Invariant Sections. You may include a
translation of this License, and all the license notices in the
Document, and any Warranty Disclaimers, provided that you also include
the original English version of this License and the original versions
of those notices and disclaimers. In case of a disagreement between
the translation and the original version of this License or a notice
or disclaimer, the original version will prevail.

If a section in the Document is Entitled "Acknowledgements",
"Dedications", or "History", the requirement (section 4) to Preserve
its Title (section 1) will typically require changing the actual
title.

## 9. TERMINATION

You may not copy, modify, sublicense, or distribute the Document
except as expressly provided under this License. Any attempt otherwise
to copy, modify, sublicense, or distribute it is void, and will
automatically terminate your rights under this License.

However, if you cease all violation of this License, then your license
from a particular copyright holder is reinstated (a) provisionally,
unless and until the copyright holder explicitly and finally
terminates your license, and (b) permanently, if the copyright holder
fails to notify you of the violation by some reasonable means prior to
60 days after the cessation.

Moreover, your license from a particular copyright holder is
reinstated permanently if the copyright holder notifies you of the
violation by some reasonable means, this is the first time you have
received notice of violation of this License (for any work) from that
copyright holder, and you cure the violation prior to 30 days after
your receipt of the notice.

Termination of your rights under this section does not terminate the
licenses of parties who have received copies or rights from you under
this License. If your rights have been terminated and not permanently
reinstated, receipt of a copy of some or all of the same material does
not give you any rights to use it.

## 10. FUTURE REVISIONS OF THIS LICENSE

The Free Software Foundation may publish new, revised versions of the
GNU Free Documentation License from time to time. Such new versions
will be similar in spirit to the present version, but may differ in
detail to address new problems or concerns. See
<https://www.gnu.org/licenses/>.

Each version of the License is given a distinguishing version number.
If the Document specifies that a particular numbered version of this
License "or any later version" applies to it, you have the option of
following the terms and conditions either of that specified version or
of any later version that has been published (not as a draft) by the
Free Software Foundation. If the Document does not specify a version
number of this License, you may choose any version ever published (not
as a draft) by the Free Software Foundation. If the Document specifies
that a proxy can decide which future versions of this License can be
used, that proxy's public statement of acceptance of a version
permanently authorizes you to choose that version for the Document.

## 11. RELICENSING

"Massive Multiauthor Collaboration Site" (or "MMC Site") means any
World Wide Web server that publishes copyrightable works and also
provides prominent facilities for anybody to edit those works. A
public wiki that anybody can edit is an example of such a server. A
"Massive Multiauthor Collaboration" (or "MMC") contained in the site
means any set of copyrightable works thus published on the MMC site.

"CC-BY-SA" means the Creative Commons Attribution-Share Alike 3.0
license published by Creative Commons Corporation, a not-for-profit
corporation with a principal place of business in San Francisco,
California, as well as future copyleft versions of that license
published by that same organization.

"Incorporate" means to publish or republish a Document, in whole or in
part, as part of another Document.

An MMC is "eligible for relicensing" if it is licensed under this
License, and if all works that were first published under this License
somewhere other than this MMC, and subsequently incorporated in whole
or in part into the MMC, (1) had no cover texts or invariant sections,
and (2) were thus incorporated prior to November 1, 2008.

The operator of an MMC Site may republish an MMC contained in the site
under CC-BY-SA on the same site at any time before August 1, 2009,
provided the MMC is eligible for relicensing.

## ADDENDUM: How to use this License for your documents

To use this License in a document you have written, include a copy of
the License in the document and put the following copyright and
license notices just after the title page:

        Copyright (C)  YEAR  YOUR NAME.
        Permission is granted to copy, distribute and/or modify this document
        under the terms of the GNU Free Documentation License, Version 1.3
        or any later version published by the Free Software Foundation;
        with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
        A copy of the license is included in the section entitled "GNU
        Free Documentation License".

If you have Invariant Sections, Front-Cover Texts and Back-Cover
Texts, replace the "with … Texts." line with this:

        with the Invariant Sections being LIST THEIR TITLES, with the
        Front-Cover Texts being LIST, and with the Back-Cover Texts being LIST.

If you have Invariant Sections without Cover Texts, or some other
combination of the three, merge those two alternatives to suit the
situation.

If your document contains nontrivial examples of program code, we
recommend releasing these examples in parallel under your choice of
free software license, such as the GNU General Public License, to
permit their use in free software.
