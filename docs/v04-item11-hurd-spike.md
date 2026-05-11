# v0.4 item 11: Hurd kernel variant, spike report

Maintainer: Borja Tarraso <borja.tarraso@member.fsf.org>

A spike, not an implementation. The plan in
[v04-plan.md](v04-plan.md) flags item 11 as Huge (2-3 months for one
person) and explicitly puts it on a separate branch. This document
answers the one question the spike was meant to answer: **can the
same userland boot against GNU Mach + Hurd, or does pid1 need a
Hurd-side rewrite?**

Short answer: **yes, but with a console-only profile and a port
layer in C**. The rewrite is bounded; the abstraction is clean. v0.5
or a side branch can pick this up with the inventory below as the
starting point.

## what runs on Hurd as-is

These work without modification because they call POSIX surfaces
that glibc-on-Hurd implements:

  - `waitpid(2)` (pid1-reap)
  - `sethostname(2)` (pid1-set-hostname)
  - `crypt(3)` (pid1-crypt, used by passwd.el)
  - `fsync(2)` (pid1-fsync-dir)
  - `read`/`write`/`open`/`close` on regular files
  - Emacs dynamic-module ABI: Hurd glibc supports `dlopen`, the
    `emacs_module_init` contract is POSIX-portable. The module
    should load without source changes; this needs a one-line
    prototype confirmation on a booted Hurd.

The eshell-bridge story (shstub `/bin/sh`) is POSIX `execve` and a
socket dial to emacsclient. Both work on Hurd.

## what does not run on Hurd

Six C surfaces and roughly six elisp data sources are Linux-only.
The rewrite path for each:

### pid1 C surfaces

| pid1 binding              | Linux backing              | Hurd port path                                                 |
|---------------------------|----------------------------|----------------------------------------------------------------|
| `pid1-mount`              | `mount(2)`                 | `settrans(1)` equivalent: bind a translator from `/hurd/`.     |
| `pid1-bring-up-lo`        | `<linux/if.h>` ioctl       | `pfinet` translator at `/servers/socket/2` + RPC.              |
| `pid1-set-address`        | `SIOCSIFADDR` ioctl        | `pfinet` RPC (`pfinet_siocsifaddr` equivalent).                |
| `pid1-set-route-default`  | `SIOCADDRT` ioctl          | same `pfinet` RPC surface.                                     |
| `pid1-poweroff`           | `reboot(RB_POWER_OFF)`     | `host_reboot` Mach RPC with the right flag.                    |
| `pid1-reboot`             | `reboot(RB_AUTOBOOT)`      | `host_reboot` Mach RPC.                                        |
| `pid1-suspend`            | `/sys/power/state` write   | no equivalent; dropped on Hurd v0.4.                           |

`pid1-reap` is `waitpid`; it works as-is.

### elisp Linux assumptions

These files read paths that exist only on Linux:

  - `core/network.el` reads `/proc/net/dev` and `/proc/net/route`.
    Hurd has `/servers/socket/2` and pfinet RPC; the parser layer
    needs a Hurd adapter. The `*network*` buffer code itself is
    agnostic if the data layer is.
  - `core/state.el`'s `state-mode` probe reads `/proc/mounts` to
    decide ext4-vs-tmpfs. Hurd has a different mount-list surface
    (via `procfs` or by walking `/servers`).
  - `buffers/processes.el` reads `/proc/<pid>/status`. Hurd's
    `procfs` translator approximates `/proc`, so this might mostly
    work; the column set will differ.
  - `buffers/disks.el` reads `/sys/block`. Hurd has no sysfs; the
    natural source is `/dev/hd*` device nodes and translator
    inspection.
  - `install/disk.el` (v0.4 item 3 wizard) reads `/sys/block` and
    `/proc/mounts`. Same as above. Not load-bearing for the Hurd
    spike since the install wizard would not run on a Hurd live
    image in v0.4.
  - `early-init.el` reads `/proc/cmdline` to pick `geos.mode`.
    Hurd has `/proc/cmdline` via procfs; works as-is.

### features dropped on Hurd for the v0.4 line

Listed for completeness against the v04-plan budget:

  - **Xorg + EXWM.** No usable DRM/KMS on Hurd. Hurd v0.4 is
    console-only, `geos.mode=console`-equivalent by default.
  - **Suspend.** No `/sys/power/state`. The whole `pid1-suspend`
    path is `#ifdef __linux__` in the port-layer plan.
  - **LUKS.** cryptsetup port to Hurd is incomplete. Hurd boots
    unencrypted; LUKS is a Linux-line feature.
  - **The install wizard.** v0.4 item 3 is Linux-only because of
    its `/sys/block` and grub-install (i386-pc) coupling. Hurd
    installs stay the Guix manual `guix system init` flow until
    v0.6+.
  - **cgroups** (used by nothing today, but listed because the
    long-term `defservice` design has room for resource isolation
    that would not port).

## the recommended port shape

The plan's `port_layer.h` design is the right answer. Concretely:

```c
typedef struct port_caps {
    int (*reap)(pid_t *out_pid, int *out_status);
    int (*mount)(const char *src, const char *tgt, const char *type,
                 unsigned long flags, const char *opts);
    int (*set_hostname)(const char *name, size_t len);
    int (*bring_up_lo)(void);
    int (*set_address)(const char *iface, uint32_t addr, uint32_t mask);
    int (*set_route_default)(const char *iface, uint32_t gw);
    int (*reboot)(int cmd);
    int (*suspend)(void);
    /* spawn is intentionally left to posix_spawn on both ports. */
} port_caps;
extern const port_caps *port;
```

Linux backend (`pid1/port_linux.c`) keeps the current behaviour
verbatim — every `mount(2)` and ioctl from today's emacs-init.c
moves under one of these function pointers. Hurd backend
(`pid1/port_hurd.c`) implements the Mach/Hurd equivalents listed
above, with `suspend` returning `ENOSYS` so the elisp layer can
render `M-x geos-suspend` as "not on this kernel".

Elisp gets one new file:

```elisp
;; core/port.el
(defvar geos-kernel (intern (or (getenv "GEOS_KERNEL") "linux")))
```

Buffers that touch `/proc` or `/sys` branch on `geos-kernel` at the
data-source layer. Renderers are kernel-agnostic.

## Guix-side

Two operating-system records, sharing the bulk via `inherit`:

  - `guix-system/system.scm` — today's Linux record. Renamed in
    spirit to `system-linux.scm`, but kept at the current path so
    `iso-build/dev-vm.sh` does not need to change.
  - `guix-system/system-hurd.scm` (new) — `(use-modules (gnu system
    hurd))`, kernel = `gnumach`, hurd = `hurd`, file-systems on
    `/dev/hd0s1`, drops xorg-server + emacs-exwm + dhcpcd from
    packages.
  - `iso-build` gains a `geos-hurd.iso` target via
    `guix system disk-image -t hurd64-raw guix-system/system-hurd.scm`.
  - `iso-build/hurd-smoke-test.sh` mirrors `smoke-test.sh`,
    minimum marker: `geos: emacs userland up` on Hurd console.

## realistic timeline

The plan's 2-3 months for one person assumes the port-layer
refactor lands as one PR plus a Hurd implementation as a separate
PR. The work order:

  1. **Port layer refactor on Linux**, no Hurd code yet (~1 week).
     `port_layer.h` + `port_linux.c`, every existing pid1 binding
     dispatches through it, every existing smoke test still passes.
     **Reviewable by skeptic in isolation; zero behaviour change.**
  2. **`core/port.el` + adapters** (~3 days). Elisp data sources
     branch on `geos-kernel`. Renderers untouched.
  3. **`system-hurd.scm` skeleton** (~3 days). Build attempt,
     iterate on which packages exist on Hurd.
  4. **`port_hurd.c` mount + reboot** (~1 week). Enough to boot.
  5. **`port_hurd.c` networking** (~2 weeks). pfinet RPC is its
     own learning curve.
  6. **Hurd smoke test green** (~1 week). Buffer regressions.

Total realistic estimate: 6-8 weeks, single-person, full-time. The
plan's 8-12-week budget is the right outer bound.

## conclusion

The port is feasible. The abstraction layer is clean and bounded.
The work belongs on a side branch (per the v0.4 plan's explicit
note) because it dwarfs everything else in flight. **v0.4 closes
item 11 with this report; v0.5 or a `hurd-port` branch picks up
step 1 above.**

The single technical question left open is the dynamic-module
prototype: confirm `pid1-module.so` loads inside an `emacs` running
on Hurd. That can be done in an afternoon with a checked-out Hurd
live ISO and a hand-built `pid1-module.so`. It is the first thing I
will do on the side branch.
