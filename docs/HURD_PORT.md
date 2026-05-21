# GEOS Hurd port

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- voice: first person singular, lowercase, no em-dashes. -->

This doc summarizes where the GNU Hurd port of GEOS stands. The
abstraction layer that lets both kernels share a userland lives on
main as of the v0.7.x cycle. The Hurd backend lives on the `hurd`
side branch. As of v0.8 (2026-05-18) both the single-user PID-1
boot and the multi-user peer-cred dance are verified end-to-end on
a canonical Debian GNU/Hurd 0.9 VM; the elisp dispatch arms for
the kernel-aware userland buffers are the open work for v0.9.

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
  - service supervision after host_reboot: pid1 only supervises
    emacs.  Debian's sysvinit-spawned services (sshd, syslogd)
    do NOT come back after a `(pid1-reboot)` because /sbin/init
    is now emacs-init, not sysvinit.  v0.8 design item: a
    GEOS-side service supervisor on the Hurd side that reads
    /etc/geos/services.d/*.scm the way the Linux side will
    once `core/supervise.el` learns to read disk-backed service
    definitions.

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
| `port->get_peer_cred` (Hurd: side-channel Mach port + `auth_server_authenticate`) | v0.8 body shipped end-to-end on hurd branch.  After the pflocal cmsg pivot (`docs/runlogs/2026-05-18-hurd-pflocal-cmsg-fail.md`) the body now looks up the pending Mach rendezvous port via the `pending_auth[]` table the libports translator populates from `S_geos_auth_submit_nonce` (real `auth_server_authenticate`), then returns the euid/egid; deallocates rendez and the uid/gid arrays on every exit.  Shipped at hurd branch `aec165f` | ENOSYS path: YES on 2026-05-17.  v0.8 dance: **YES on 2026-05-18** (runlog `docs/runlogs/2026-05-18-hurd-end-to-end-vm.md`; child slice4_handshake_ok=1, parent slice4_handshake_ok=1, parent slice5_handshake_ok=1) |
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
| `services/journal-tail.el` Hurd kmsg source | implemented | **YES (live-verified)** on 2026-05-21 (v0.9.6; Hurd arm runs `tail -F --lines=+1 /var/log/kern.log` under supervise.el and dispatches per-line to a new `journal-buffer--parse-syslog-record` that parses the BSD/inetutils one-line format into the standard journal record plist (`:source 'syslog`, `:sev "info"` defaulted since kern.log is implicitly kern.*, `:time` parsed from `MMM DD HH:MM:SS` with current-year defaulting).  no port_caps slot needed: the v0.9.6 probe receipt at `docs/runlogs/2026-05-21-hurd-kmsg-probe.md` confirmed `/dev/klog` is a `/hurd/streamio kmsg` translator that blocks and has no history replay, and Debian Hurd 0.9 ships `inetutils-syslogd` running by default which drains it into `/var/log/kern.log`.  live end-to-end verified at runlog `docs/runlogs/2026-05-21-v096-kmsg-verify.md`: `(supervise-start 'journal-kmsg)` spawned tail, backlog replayed, synthetic appended line landed live in `*journal*`; 100-call leak smoke clean (VmSize delta 0).  one caveat documented in the verify receipt: on this Debian Hurd 0.9 snapshot kern.log is 0 bytes at boot because gnumach boot printfs land in `/var/log/dmesg` (read direct from the gnumach printbuf by `dmesg(8)`) rather than via the /dev/klog -> syslogd -> kern.log path; the pipeline is correct, future runtime kernel events would flow through.  **dmesg-prime follow-on shipped at main/3d4a88b and live-verified on 2026-05-21** (v0.9.7; `journal-tail--prime-from-dmesg` reads /var/log/dmesg at load time on Hurd and appends each non-empty line as a `:source 'dmesg` record so the day-zero buffer carries the boot transcript; 61 dmesg lines = 61 journal records, exact match; runlog `docs/runlogs/2026-05-21-v096-dmesg-prime-verify.md`)) |
| `user/userland/audio.el` Hurd not-implemented banner | implemented | YES on 2026-05-20 (v0.9.4 doc-flip; `audio-list-cards' on Hurd routes through `geos-port-unimplemented' and returns nil so the `*audio*' buffer renders "no cards visible" cleanly.  Hurd has no ALSA, no `/proc/asound', no audio translator under `/hurd/'; a native sink (OSS-style or Mach-RPC once a Hurd audio translator exists) is a later slice).  **Native audio translator surface: deferred at translator level** (v0.9.7 probe 2026-05-21 confirmed Debian GNU/Hurd 0.9 ships no /hurd/audio*, no settrans-attached /dev/dsp /dev/audio /dev/mixer /dev/snd nodes, no audio entry under /servers, no /proc/asound analogue, zero audio enumeration in the gnumach boot transcript, and `dpkg -L hurd` matches zero files with audio names; H1-H4 all falsified.  pulseaudio 17.0+dfsg1-2.1 and the sndio family are installable from debian-ports sid/main hurd-amd64 but not bundled in the canonical image, so a future v1.x slice would wire `userland/audio.el` to a pulseaudio daemon path gated on user `apt install pulseaudio`; out of scope for v0.9.x.  runlog `docs/runlogs/2026-05-21-hurd-audio-probe.md`) |
| `port->arm_parent_death` (Linux: `prctl(PR_SET_PDEATHSIG)`; Hurd: `MACH_NOTIFY_DEAD_NAME` via `mach_port_request_notification`) | v0.9.8 slot landed on main; Linux body calls `prctl` directly; Hurd body returns ENOSYS as a partial slot, the real `MACH_NOTIFY_DEAD_NAME` watcher-thread implementation is the v0.9.9 follow-on (see receipt for the design); call site is `spawn_xorg()`'s post-fork child, which tolerates ENOSYS as a defence-in-depth gap and logs to /dev/console.  same commit removed the v0.7.x force-console block under `PORT_HURD` and added the `/usr/bin/Xvfb` default for Hurd UI mode (probe C+D confirmed Xvfb 2:21.1.22-1 works) | YES on Linux (prctl shipped, freeze-test `freeze-test-arm-parent-death.el` covers slot-bound + linux-prctl-call + hurd-enosys-tolerated); PARTIAL on Hurd (ENOSYS placeholder; v0.9.9 real impl pending; receipt `docs/runlogs/2026-05-21-hurd-xorg-probe.md`) |

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
