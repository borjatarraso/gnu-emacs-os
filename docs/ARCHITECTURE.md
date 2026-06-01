# GEOS architecture

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- voice: first person singular, lowercase, no em-dashes. -->

A bird's-eye look at how GNU/Emacs Operating System (GEOS) is laid
out. Three zoom levels: the whole system, the major subsystems, and
the dual-kernel detail that lets the same userland run on Linux today
and on the GNU Hurd next.

Maintainer: Borja Tarraso <borja.tarraso@member.fsf.org>

If you have not read it yet, `MANIFESTO.md` says why this exists.
`INTERNALS.md` is the contributor-oriented walkthrough. This file is
the picture.

## Level 1, the whole thing in one diagram

The OS is one Emacs process supervised by a tiny C front-end that
became Emacs through `execve`. The kernel sits underneath; nothing
above the kernel is not Elisp or the few C files that proxy syscalls
into Elisp.

```
+--------------------------------------------------------------+
|  the user                                                    |
|  (M-x, eshell, EXWM-grabbed X clients, all in buffers)       |
+----------------------------+---------------------------------+
                             |
                             v
+--------------------------------------------------------------+
|  Emacs (the userland)                                        |
|    +-------------------------+   +------------------------+  |
|    | system-concept buffers  |   |  EXWM (X11 WM)         |  |
|    |   *processes* *network* |   |  exwm-config.el        |  |
|    |   *journal*   *services*|   +------------------------+  |
|    |   *disks*     *packages*|                               |
|    |   *users*     *audio*   |   +------------------------+  |
|    +-------------------------+   |  panic.el (error trap) |  |
|    +-------------------------+   +------------------------+  |
|    | core/                   |                               |
|    |   panic state supervise |   +------------------------+  |
|    |   network hostname port |   |  pid1-module.so (Elisp |  |
|    |   power                 |   |   bindings to syscalls)|  |
|    +-------------------------+   +-----------+------------+  |
+----------------------------------------------|---------------+
                                               |
                                               | dlopen + emacs_module_init
                                               v
+--------------------------------------------------------------+
|  pid1 binary (the supervisor)                                |
|    main():  mount /proc /sys /dev /run /tmp; lo up;          |
|             hostname; spawn Xorg; execve emacs               |
|    loop:    waitpid; respawn emacs; respawn Xorg (capped)    |
+----------------------------+---------------------------------+
                             |   |
            port_caps        |   |   /bin/sh -> shstub
        (function-ptr table) |   |   (50-line C stub that
                             |   |    forwards to emacsclient)
                             v   v
+--------------------------------------------------------------+
|  the kernel (Linux today, GNU Hurd next)                     |
+--------------------------------------------------------------+
```

What every box does, in two lines or less:

  - **the user**: types `M-x`, sees buffers. The shell is eshell.
  - **system-concept buffers**: every concept a Unix user would
    reach a CLI for (top, ip a, dmesg, df, apt) is a buffer.
  - **EXWM**: turns X11 windows into Emacs buffers.
  - **panic.el**: catches every Elisp error before it can kill
    Emacs (and therefore the OS).
  - **core/**: the always-on Elisp foundation. State persistence,
    service supervision, the port-layer accessor, error trap.
  - **pid1-module.so**: same C source as the pid1 binary, compiled
    with `-DPID1_MODULE`. Exposes mount, reboot, hostname, peer-
    credential lookup, network ioctls as Elisp functions.
  - **pid1 binary**: PID 1. The supervisor of Emacs.
  - **port_caps**: the function-pointer struct that lets the same
    pid1 source run on two kernels.
  - **shstub**: `/bin/sh` is a tiny stub that forwards `sh -c`
    into eshell via `emacsclient`. No bash, no dash, no busybox.

## Level 2, the major subsystems

Same drawing, expanded. Each region is a directory; each arrow is a
real call path you can grep for.

### Boot path

```
firmware -> GRUB -> kernel -> initrd
                                |
                                v
                         /sbin/init   (Linux: pid1 binary)
                                |     (Hurd: /hurd/startup -> /sbin/init)
                                |
            +-------------------+-------------------+
            v                                       v
       do_mount() x6                          link_current_system()
       (proc sys dev run tmp                  (parse /proc/cmdline
        devpts)                                gnu.system=, symlink)
            |
            v
       port->bring_up_lo()       set_hostname_at_boot()
            |                             |
            v                             v
       sigaction(SIGCHLD)         read_geos_mode()
            |                             |
            +---------------+-------------+
                            v
                     xorg_bring_up()   (UI mode only)
                            |
                            v
                     spawn_emacs()
                            |
                            v
                     supervisor loop:
                       waitpid(-1)
                       respawn emacs
                       respawn Xorg (capped 5/60s)
```

### Inside Emacs, load order

The `-l` chain in the boot gexp dictates this. Earlier files are
dependencies of later ones.

```
emacs --batch -l early-init.el \
              -l core/panic.el \
              -l core/state.el \
              -l core/power.el \
              -l core/use-package-shim.el \
              -l core/port.el          <- the kernel branch knob
              -l core/network.el \
              -l core/hostname.el \
              -l core/supervise.el \
              -l buffers/network.el \
              -l user/multimon.el \
              -l user/fonts.el \
              -l user/input.el \
              -l user/exwm-config.el \
              -l user/userland/*.el \   (8 use-package blocks)
              -l buffers/*.el \         (concept buffers)
              -l services/*.el \        (defservice consumers)
              -l core/boot-marker.el    (supervise-finalize)
```

### Supervisor RPC (v0.6 item 3, v0.7 item 4)

```
   per-user emacs (login session)
            |
            | make-network-process :family local
            |    :service /run/geos/super.sock
            v
   +-------------------------------+
   | supervisor (pid1-as-emacs)    |
   |   Fpid1_rpc_listen creates    |
   |     AF_UNIX socket mode 0600  |
   |   Fpid1_rpc_poll on a 200ms   |
   |     timer:                    |
   |     - accept4 client          |
   |     - port->get_peer_cred()   |
   |        |                      |
   |        +-- Linux: SO_PEERCRED |
   |        +-- Hurd:  ENOSYS,     |
   |             soft-refuse + log |
   |             once per boot     |
   |     - dispatch verb           |
   +-------------------------------+
            |
            v
   verbs:  ping  journal-tail  services-list  reboot  poweroff
```

### State persistence

```
/var/emacs/                           (ext4 with label "geos-var",
                                        tmpfs fallback)
   journal/      *journal* RPC client snapshot
   packages/     guix manifest readout cache
   network/      DHCP leases, last static config
   users/        passwd db + per-user dotfiles
   services/     supervise.el restart counters
   dotfiles/     per-user emacs init
   audit.log     login hardening trail (v0.6 item 5)
```

`state-write` is tmpfile + rename + `pid1-fsync-dir`. The parent
fsync is what makes the rename atomic across crash.

## Level 3, the dual-kernel seam

This is the architectural piece that separates GEOS from any other
"Emacs as desktop" project: the same userland boots on Linux and
on the GNU Hurd. The whole story lives in three places.

### The C seam: `port_caps`

```c
/* pid1/port_layer.h */
struct port_caps {
    const char *kernel_name;                 /* "linux" or "hurd" */
    int  (*mount)(const char *src, const char *tgt,
                  const char *type, unsigned long flags,
                  const char *opts);
    int  (*set_hostname)(const char *name, size_t len);
    int  (*bring_up_lo)(void);
    int  (*set_address)(const char *ifname,
                        const char *addr, int prefixlen);
    int  (*set_route_default)(const char *gateway,
                              const char *ifname);
    int  (*reboot)(int cmd);                 /* RB_AUTOBOOT etc */
    int  (*suspend)(const char *target);     /* "mem", "disk" */
    int  (*get_peer_cred)(int fd, int *uid_out, int *pid_out);
};
extern struct port_caps *port;
```

The boot wires the active backend before any port-> call:

```c
/* pid1/emacs-init.c, main() */
port = &port_linux_impl;       /* or &port_hurd_impl under PORT=hurd */
port_require_or_abort();       /* loud crash on a missing slot */
```

`port_require_or_abort` walks every slot in the struct and aborts
with a `/dev/console` message if any is NULL. That converts a
silent footgun (forgot to register a new slot in the Hurd backend)
into a noisy boot failure.

### The Elisp seam: `core/port.el`

```elisp
;; emacs-init/core/port.el
(defvar geos-kernel
  (intern (or (getenv "GEOS_KERNEL") "linux"))
  "Kernel this Emacs is running on.  'linux or 'hurd.")
```

`pid1` splices `GEOS_KERNEL=<port->kernel_name>` into emacs's envp,
so the elisp side never has to call out to `uname -s` and can branch
deterministically. Files that have to do something kernel-specific
(`core/network.el`, `core/state.el`, `buffers/disks.el`,
`install/disk.el`, `user/userland/uname.el`,
`services/journal-tail.el`, `buffers/journal.el`,
`user/userland/audio.el`, `buffers/audio.el`) factor their Linux
bodies into `*-linux` helpers and dispatch through `geos-kernel`.
Hurd arms either degrade (nil, banner) or signal
`geos-port-unimplemented` until a real backend lands.

### Where the kernels actually differ

| Surface             | Linux               | Hurd                       |
|---------------------|---------------------|----------------------------|
| mount               | `mount(2)`          | `fshelp_start_translator` + `file_set_translator` |
| reboot              | `reboot(RB_*)`      | `host_reboot` Mach RPC     |
| hostname            | `sethostname(2)`    | `sethostname(2)` (POSIX)   |
| bring up loopback   | `SIOCSIFFLAGS`      | pfinet `SIOCSIFFLAGS`      |
| set address         | `SIOCSIFADDR`+      | pfinet, ifname normalized  |
|                     |                     |  bare `eth0` -> `/dev/eth0`|
| set default route   | `SIOCADDRT` rtentry | pfinet `SIOCADDRT ifrtreq_t`|
| suspend             | `/sys/power/state`  | ENOSYS forever             |
| peer credentials    | `SO_PEERCRED`       | ENOSYS, supervisor soft-refuses |
| socket timeouts     | `SO_{RCV,SND}TIMEO` | pflocal returns ENOPROTOOPT, tolerated |
| network device naming| bare `eth0`        | devnode `/dev/eth0`        |
| `/proc`             | linux procfs        | `/hurd/procfs` translator  |
| init mechanism      | `init=` kernel cmdline | `/hurd/startup` execs `/sbin/init`, no init= |

### Build matrix

```
make -C pid1                       Linux build (default)
make -C pid1 PORT=hurd             Hurd build (side branch)
make -C pid1 STATIC=0 module       dynamic module variant
                                   (the .so loaded by Emacs)

link line under PORT=linux:        -lcrypt
link line under PORT=hurd:         -lcrypt -lfshelp -lhurduser -lmachuser

source under PORT=linux:           emacs-init.c + port_linux.c
source under PORT=hurd:            emacs-init.c + port_hurd.c
```

`port_hurd.c` lives only on the `hurd` side branch. Anything from
main that breaks the Hurd build is a side-branch fix, not a main
rollback.

### Verification ladder

Three rungs, because lying to yourself about a port is easy.

```
+-------------------------------------+
| YES on YYYY-MM-DD                   |  invoked on a running kernel,
|                                     |  observed to do the right thing
+-------------------------------------+
| builds on Hurd YYYY-MM-DD           |  compiles + links, ldd -r clean,
|                                     |  body NOT exercised against the
|                                     |  live Mach RPC server
+-------------------------------------+
| NO                                  |  never touched a real kernel
+-------------------------------------+
```

The current per-slot promotion table is `docs/HURD_PORT.md`.
Each promotion to "YES on YYYY-MM-DD" is backed by a sanitized
verification receipt under `docs/runlogs/`. As of 2026-05-17:
mount, set_hostname, bring_up_lo, set_address, set_route_default,
get_peer_cred have all been promoted to YES; reboot still reads
"builds on Hurd 2026-05-17" because the test is destructive to
the VM and is gated on the boot-as-PID-1 milestone.

### What still differs at the OS level

  - **boot mechanism**: Linux uses GRUB + `init=/sbin/init` kernel
    cmdline. Hurd uses GRUB + a multiboot module chain (pci-arbiter,
    acpi, rumpdisk, ext2fs, exec), and `/hurd/startup` is PID 1
    unconditionally; user-mode init is whatever `/hurd/startup`
    `execve`s, which on a stock Debian Hurd is `/sbin/init`. To
    boot emacs-init on Hurd, the install path is "replace
    `/sbin/init`", not "edit the kernel cmdline".
  - **pseudo-filesystem mounts**: Linux pid1 mounts proc/sys/devtmpfs/
    devpts. Hurd has none of those as filesystems; `/proc` is a
    translator (`/hurd/procfs`), `/dev` is real, `/sys` does not
    exist. The Hurd boot path has to skip these or treat the
    syscalls as no-ops.
  - **EXWM**: Hurd ships Xorg but no modesetting DRM analogue.
    The v1.x apt-image flavor of the re-rolled Hurd image runs
    EXWM 0.33 over Xvfb (see v0.9.10); native Xorg on Hurd
    real hardware is tracked separately and is deferred-upstream.
  - **suspend**: Hurd has no analogue. `port->suspend` returns
    ENOSYS forever; the `*audio*` buffer's mixer is the only
    user-facing place that cares, and it degrades to a banner.

## Where to read next

  - `MANIFESTO.md`: the thesis.
  - `INTERNALS.md`: contributor walkthrough, every file in load order.
  - `HURD_PORT.md`: per-slot verification matrix.
  - `HURD_BOOT.md`: what a Hurd-VM operator runs to verify the port.
  - `STATE_LAYOUT.md`: the persistence contract.
  - `ROADMAP.md`: what is unfinished and why.
  - `runlogs/`: dated verification receipts per milestone.
