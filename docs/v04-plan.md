;;; v0.4 implementation plan
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- voice: first person singular, lowercase, no em-dashes. -->

# GEOS v0.4 plan

The 11 items below take GEOS from "boots on a developer's QEMU" to
"installable, multi-user, network-managed, cryptography-aware". Some
of them are 1-week jobs, two of them are quarter-sized. I sequence
them at the end so dependencies are honoured and shippable subsets
fall out naturally.

## Effort summary

| #  | Item                                  | Size   | Weeks (mid) | Depends on |
|----|---------------------------------------|--------|-------------|------------|
|  1 | persistent state under /var/emacs     | Medium | 0.6         | none       |
|  2 | first-class service definitions       | Medium | 1.0         | 1          |
|  3 | real installer                        | Large  | 2.5         | 1, 4 (lite)|
|  4 | user accounts + login                 | Large  | 2.0         | 1          |
|  5 | network configuration UI              | Medium | 1.0         | 1, 2       |
|  6 | package management buffer             | Medium | 1.0         | 1, 2       |
|  7 | suspend / resume                      | Small  | 0.4         | 2          |
|  8 | audio (ALSA Elisp binding)            | Medium | 1.0         | 2          |
|  9 | disk encryption (LUKS at boot)        | Large  | 1.8         | 1          |
| 10 | kernel-cmdline boot menu in GRUB      | Small  | 0.2         | none       |
| 11 | Hurd kernel variant                   | Huge   | 8-12        | 1, 2, 5    |

Total realistic v0.4 budget without item 11: ~12 person-weeks. With
item 11 it slips to a quarter at minimum. I treat 11 as a v0.4
stretch tag, not a release blocker.

## Recommended ordering

Phase A (foundation, 3-4 weeks): items 1, 2, 10. After A the codebase
has a real state directory, declarative services, and a usable boot
menu.

Phase B (user-visible, 4-5 weeks): items 5, 6, 7. These all require
the supervise.el record from item 2 and the persistence from item 1,
and they make the boot feel finished.

Phase C (install + sec, 4-5 weeks): items 4, 9, 3. Login enables the
non-root path that the installer needs. LUKS lands before the
installer because the installer wires it. Then the installer ties
everything together.

Phase D (best-effort): items 8, 11. Audio is independent of B and C
and can interleave whenever. Hurd is on its own track.

A clean v0.4 release ships A + B + C and tags item 8 as preview, item
11 as separate branch.

---

## Item 1. persistent state under /var/emacs/

**Files to touch (existing):**
- `pid1/emacs-init.c` (mount /var as
  ext4 if a partition exists, else tmpfs; new helper `mount_var()`
  called from `main()` after the existing `do_mount` block, before
  `link_current_system()`).
- `emacs-init/early-init.el` (already
  sets `user-emacs-directory` to `/var/emacs/`; needs to actually
  ensure the dir exists and has the layout below).
- `guix-system/system.scm` (file-systems
  list, optional `/var` mount; `(file-systems (cons (file-system ...
  /var ...) %base-file-systems))`).

**Files to create (new):**
- `emacs-init/core/state.el`
  - `defvar state-root "/var/emacs/"`
  - `defun state-path (key)` returns `/var/emacs/KEY`.
  - `defun state-read (key &optional default)` reads sexp atomically.
  - `defun state-write (key value)` writes to `KEY.tmp` and renames.
  - `defun state-delete (key)`.
  - `defun state--ensure-layout` creates the subdirs at boot:
    `journal/`, `packages/`, `network/`, `users/`, `services/`,
    `dotfiles/`.
- `docs/STATE_LAYOUT.md` documenting
  the on-disk schema.

**C-side work:**
- new static `int mount_var(void)` in pid1/emacs-init.c.
  - probes `/dev/disk/by-label/geos-var`. If present, calls
    `mount("/dev/disk/by-label/geos-var", "/var", "ext4", MS_NOSUID, NULL)`.
  - else `mount("tmpfs", "/var", "tmpfs", MS_NOSUID, "mode=0755")`.
  - logs which path it took to /dev/console.
- expose `pid1-fsync-dir` as a new `Fpid1_fsync_dir` so the elisp
  state writer can durably commit a rename. Wraps `open(O_DIRECTORY)`
  + `fsync()` + `close()`.

**Elisp-side work:**
- `core/state.el` as above.
- `early-init.el` calls `state--ensure-layout` after
  `user-emacs-directory` is set.
- every existing buffer mode that has a "last seen X" gets a state
  hook: `journal.el` persists the kmsg seq position under
  `journal/seq`, `packages.el` writes its cache under
  `packages/manifest-cache`, `network.el` (core) snapshots
  `network-interface-config` to `network/last-applied`.

**Guix-side work:**
- `system.scm` adds (optional, controlled by a `geos-var` toplevel
  symbol) a real `/dev/sda2` partition. If absent, pid1 falls back to
  tmpfs and the rest of the system still works.
- bootloader unchanged.

**Risks and unknowns:**
- the boot gexp execs emacs-init before activation, so /var did not
  previously exist. Confirm `mkdir -p /var/emacs/{...}` is safe to
  run as PID 1 on first boot before any user.
- on tmpfs, every reboot wipes state. That is correct degraded
  behaviour, but the user must be told. Header line of every concept
  buffer should show `state: tmpfs` vs `state: persistent`.
- atomicity on tmpfs is nominal but rename is still atomic, so the
  state-write contract holds.

**Test plan:**
- new `iso-build/freeze-tests.el` test: write a key, kill the buffer,
  re-read, confirm the value round-trips.
- new smoke-test marker: `pid1: /var on <tmpfs|ext4>`.
- manual: boot, `M-x packages`, `M-x packages-buffer-refresh`,
  poweroff, boot again, confirm cache is reused on tmpfs (no) vs
  persistent (yes).

**Estimated complexity:** Medium (3-5 days).

---

## Item 2. first-class service definitions in Elisp

**Files to touch (existing):**
- `emacs-init/buffers/services.el`
  (drop the fallback to `process-list`, point at the real registry).
- every buffer file that has a `TODO(6): when core/supervise.el
  lands` block (`processes.el`, `services.el`, `journal.el`).
- `guix-system/system.scm` (load the
  new `supervise.el` after `panic.el`, before the userland chain).

**Files to create (new):**
- `emacs-init/core/supervise.el`:
  - `cl-defstruct supervise-service name command env user group restart logfile dependencies`
  - `defvar supervise--registry (make-hash-table :test 'eq)`
  - `defmacro defservice (name &rest plist)` expands to a registration
    call. `:command` is a list (PROGRAM ARG ...), `:restart` is one of
    `on-crash`, `on-failure`, `always`, `never`, `:user` and `:group`
    are strings (resolved via /etc/passwd, /etc/group), `:env` an
    alist, `:logfile` a path, `:depends-on` a list of service names.
  - `defun supervise-start (name)`, `supervise-stop (name)`,
    `supervise-restart (name)`, `supervise-registry ()`,
    `supervise-status (name)`.
  - core engine uses `make-process` (no shell wrapping) with a
    sentinel that handles restart policy and updates the registry
    plist (`:status`, `:pid`, `:restarts`, `:started-at`,
    `:last-exit`).
  - `supervise--respawn-throttle` mirrors the rolling 60s window in
    pid1/emacs-init.c (XORG_RESPAWN_*). Cap of 5 in 60s, then
    `:status` becomes `held` and operator must `M-x supervise-resume`.
  - dependencies: `supervise-start` walks `:depends-on` and starts
    each in topological order. Cycle detection raises through
    panic-handle (not bare `error`).
  - logging: `supervise--make-pipe` per service, accumulator buffer
    backing the `:logfile` write. fsync via `pid1-fsync-dir`
    (item 1) every 64 KiB or on stop.
  - persistence: registry serialized to `/var/emacs/services/registry`
    via `state-write` on every state change. Reloaded at boot so
    crashed-and-respawned counters survive an emacs restart.
- `emacs-init/services/` directory
  for the service definitions themselves. Initial entries:
  - `services/cron-like.el` (timers driven by run-at-time, declared
    as services so they show in *services*).
  - `services/journal-tail.el` (the dd-on-/dev/kmsg long-running
    process that journal.el currently spawns lazily, pulled out so
    supervise.el restarts it).
  - `services/buffer-timers.el` (the per-buffer 2s/5s refresh
    timers, registered so the *services* buffer can show their
    state and the panic-handle path can cancel-and-rearm them).

**C-side work:**
- nothing required. Item 1 already adds `pid1-fsync-dir`. If the
  Elisp `make-process` proves too heavy under heavy churn (many
  short-lived services), prototype a `pid1-spawn` that does
  `fork+execve` directly and returns the pid; defer until measured.

**Elisp-side work:** see above.

**Guix-side work:**
- `system.scm` references the new files via `local-file` and adds them
  to the boot `-l` chain. Place after `network-el`, before the buffer
  files.

**Risks and unknowns:**
- single-threaded reality: a service whose start function blocks
  (e.g. waits for a socket) blocks every other start. `defservice`
  should require `:start-async t` for anything that might block,
  using a sentinel-driven start instead.
- `make-process` does not let me set uid/gid before exec. The
  `:user`/`:group` slot is enforced by spawning through a tiny
  setuid helper, OR by deferring the multi-user story to item 4.
  Decision: until item 4 lands, `:user`/`:group` are recorded but
  not enforced; supervise.el logs a warning on the first restart.
- restart loops with bad commands need the throttle to actually
  trip; the freeze test must include a `defservice always-crash
  :command ("/bin/false") :restart always` and assert held state.

**Test plan:**
- freeze-tests.el: register a service that exits 0, verify
  `:status running` after start; register one that exits 1 with
  `:restart on-crash`, verify restart count increments; trip the
  throttle, verify held state.
- smoke-test: add `services: registry loaded N entries` marker.
- manual: `M-x services`, `s` start, `S` stop, `r` restart all reach
  the engine.

**Estimated complexity:** Medium (5-7 days).

---

## Item 3. real installer

**Files to touch (existing):**
- `guix-system/system.scm` (the
  installer image needs a different operating-system record that
  loads installer.el at boot and skips the standard userland).
- `iso-build/build.scm` (new target
  `geos-installer.iso` alongside the existing system image).
- `pid1/emacs-init.c` (new boot mode
  `geos.mode=installer` that loads only installer.el, no exwm).

**Files to create (new):**
- `emacs-init/buffers/install.el`:
  the `*install*` buffer. Wizard-style with these states stored in a
  buffer-local plist:
  - `:welcome` keybindings explained.
  - `:disk-pick` lists `/sys/block/*` and lets the user choose a
    target with RET.
  - `:partition-plan` defaults to `[ESP 512MiB | / ext4 rest]`,
    editable via `e`.
  - `:luks` y/n prompt; if y, prompt twice for passphrase, store in
    a buffer-local non-saved variable, hand to libcryptsetup wrapper
    (item 9) before mkfs.
  - `:mkfs` runs the partitioning sequence: parted-equivalent
    partition table create, mkfs.ext4, mkfs.fat32 for ESP.
  - `:copy-system` rsync-equivalent of /run/current-system into the
    new root, plus /gnu/store closure walk.
  - `:install-grub` invokes grub-install via supervise.el's spawn
    primitive, appends our kernel-arguments.
  - `:done` show a recap and offer reboot.
- `emacs-init/install/` subdir for
  helpers:
  - `install/disk.el` (parses /sys/block, reads model/size from
    sysfs).
  - `install/partition.el` (wraps parted via `make-process`, no
    shell). Long term: replace with libparted via a new pid1 module
    function.
  - `install/copy.el` (recursive copy through Elisp `copy-directory`
    plus a sentinel-driven progress reporter).
  - `install/grub.el` (invokes grub-install, writes grub.cfg from a
    template that pulls in items 4 (root device UUID), 9 (cryptdevice
    line), 10 (geos.mode entries)).

**C-side work:**
- new `Fpid1_partition` exposing the partition syscalls is an
  option, but parted as a child process is enough for v0.4. Skip C
  changes here unless the parted binary turns out to need a TTY
  parent (it does not under `--script`).
- new `Fpid1_blkid` that wraps `ioctl(BLKGETSIZE64)` and reads the
  partition table type via `BLKPG`. Returns a plist
  `(:size N :sector-size N :pttype gpt|mbr|none)`. Used by the
  partition-plan view to refuse to shrink a mounted partition.

**Elisp-side work:** as above. Progress feedback uses `make-thread`?
No. We are single-threaded by rule. Use sentinel callbacks driven by
`make-process` + `set-process-filter` so the buffer repaints between
syscalls.

**Guix-side work:**
- `iso-build/build.scm` grows a second target. The installer image
  needs `parted`, `dosfstools`, `e2fsprogs`, `grub`, `cryptsetup` in
  the system profile. The booted GEOS does not.
- `system.scm` stays the desktop record; a new
  `guix-system/installer.scm` is the installer record.

**Risks and unknowns:**
- partitioning a live disk under PID 1 with no other init around is
  fine but the kernel needs to re-read the partition table. `BLKRRPART`
  ioctl may need to be called explicitly because we have no udev.
- copying the closure: `/gnu/store` is content-addressed, so
  `cp -a` is correct, but it is also tens of GiB. The progress UI
  must update at most once per second and use `read-process-output-max`
  to keep emacs responsive.
- ESP firmware variation: on EFI, grub-install needs `--target=x86_64-efi`,
  on BIOS `--target=i386-pc`. Detect via `/sys/firmware/efi`.
- LUKS interaction with grub: GRUB2 supports LUKS1 only; for LUKS2
  the unencrypted /boot must be a separate partition. Default the
  layout to LUKS2 + /boot ESP-only.

**Test plan:**
- new `iso-build/installer-test.sh` that boots the installer ISO
  with a blank qcow2 attached, drives the wizard via `--eval` over
  the serial console, then boots the installed system from the same
  qcow2 and asserts `geos: emacs userland up`.
- freeze-tests for each install state's error path: bad disk,
  cancelled mkfs, grub-install failure.

**Estimated complexity:** Large (2-3 weeks).

---

## Item 4. user accounts + login

**Files to touch (existing):**
- `emacs-init/buffers/processes.el`
  (already reads /etc/passwd; switch its reader to use `passwd.el`).
- `guix-system/system.scm`
  (`%base-user-accounts` is unchanged but we add the `geos` group and
  a default unprivileged user `borja` whose home is /home/borja).

**Files to create (new):**
- `emacs-init/core/passwd.el`:
  - read/write `/etc/passwd`, `/etc/shadow`, `/etc/group`.
  - all three files use the same line-oriented colon-delimited format.
  - sexp model: `(:user STRING :uid INT :gid INT :gecos STRING :home STRING :shell STRING)`.
  - `defun passwd-add-user (plist)` performs validation + atomic
    rewrite via state-write semantics (write tmp, rename).
  - `defun passwd-set-password (user plaintext)` hashes via libcrypt
    (need a small C helper, see below) and writes /etc/shadow.
- `emacs-init/buffers/users.el`:
  the `*users*` buffer mirroring the pattern from `services.el`.
  Columns: name, uid, gid, home, shell. Keys: `a` add (prompts in
  minibuffer), `d` delete (refuses on uid 0), `p` set password,
  `g` refresh, `q` bury.
- `emacs-init/buffers/login.el`:
  the `*login*` buffer. Boot can drop here instead of straight into
  the privileged emacs (gated by `geos.login=t` in cmdline). The
  buffer asks for username and password; on success it spawns a new
  emacs as that user via the new `pid1-spawn-as` module function.

**C-side work:**
- new `Fpid1_setuid (uid gid)`: wraps `setgid` then `setuid`. Refuses
  if non-zero is currently set (one-way drop). Returns t.
- new `Fpid1_spawn_as (uid gid program args env)`: fork, in child
  setgid+setuid+execve. Returns the new pid. Used by login.el to
  spawn the user-emacs that will own the X session.
- new `Fpid1_crypt (plaintext salt)`: wraps `crypt_r(3)` from libcrypt.
  This is the only sane way to produce yescrypt/sha512crypt hashes
  in the format /etc/shadow expects. Returns the encoded hash string.
  Add `-lcrypt` to the module's LDFLAGS.

**Elisp-side work:** see above. Security model:
- root remains PID 1 emacs, the supervisor.
- the X session runs as a normal user. exwm-config.el moves to the
  user-emacs side of the boundary; PID 1 emacs no longer loads it.
- login.el's "spawn as user" replaces today's spawn_emacs. The PID 1
  emacs becomes a thin supervisor that coordinates *services*,
  *processes*, and *journal* but does not host the user-visible exwm
  frame. On logout, the user-emacs exits and pid1 returns to login
  buffer.
- this is a major architectural shift. v0.4 ships a "single-user with
  optional login" mode by default and the multi-user split as opt-in
  via `geos.login=t`. Full decoupling of supervisor emacs from user
  emacs is v0.5.

**Guix-side work:**
- add `linux-pam` dependency? No: PAM is a yak nobody asked for. Use
  /etc/shadow + crypt directly.
- add `libxcrypt` to the build environment for the module.

**Risks and unknowns:**
- setuid in emacs is rare and the module ABI was not designed for
  it. Fine in principle (we run on the main thread, no thread races)
  but every sentinel that fires after setuid runs as the new user.
  The architectural fix is the supervisor/user split above.
- /etc/shadow permissions: 0640, owner root, group shadow. We need a
  shadow group, which means item 4's group writer must run before
  the first password set.
- file locking on /etc/passwd: traditional unix uses /etc/passwd.lock
  flock dance. We have one writer (the supervisor emacs) so fine.
- the *login* buffer must not echo the password. `read-passwd` covers
  it but we need to make sure no `message` or panic-handle leak picks
  it up if hashing fails.

**Test plan:**
- freeze-tests.el: add user, verify in /etc/passwd, set password,
  verify hash format, attempt login with wrong password, attempt with
  right password.
- smoke-test: boot with `geos.login=t`, confirm `*login*` is the
  initial buffer.
- manual: poweroff cleanly as a user, confirm root emacs survives
  and login buffer reappears.

**Estimated complexity:** Large (1.5-2 weeks).

---

## Item 5. network configuration UI

**Files to touch (existing):**
- `emacs-init/buffers/network.el`
  (add the keymap entries `c`, `d`, `s`).
- `emacs-init/core/network.el`
  (extend `network--apply-entry` to actually apply :address /
  :netmask / :gateway via the new module functions).

**Files to create (new):**
- `emacs-init/services/dhcp.el`:
  registers a dhcp client per interface as a `defservice`. Initial
  implementation: spawn `dhcpcd -B -f /dev/null <iface>` (already in
  guix); medium-term, port a tiny RFC2131 client to elisp so we have
  no shell-out. Argument for spawning dhcpcd today: it works and the
  whole net stack is not blocked on a parser rewrite. Argument
  against: dhcpcd has its own daemon ambitions and we have to neuter
  half its plumbing to keep it from rewriting /etc/resolv.conf and
  spawning hooks. Decision for v0.4: spawn dhcpcd in -1 (one-shot)
  mode, parse its stdout via filter, hand the lease to
  `network--apply-entry`. Renewal handled by a supervise.el timer.

**C-side work:** the meaty part.
- new `Fpid1_set_address (iface address netmask)`:
  - opens AF_INET socket
  - fills `struct ifreq` with iface name, calls `SIOCSIFADDR` with
    a `struct sockaddr_in` carrying the address
  - calls `SIOCSIFNETMASK` with the netmask
  - calls `SIOCGIFFLAGS`/`SIOCSIFFLAGS` to set IFF_UP
  - all four ioctls fully checked, errno reported via
    `pid1_signal_errno`.
- new `Fpid1_add_route (dest mask gateway iface)`:
  - opens AF_INET socket
  - fills `struct rtentry`
  - calls `ioctl(SIOCADDRT, &rt)`
  - same error handling
- new `Fpid1_iface_down (iface)`: clears IFF_UP via SIOCSIFFLAGS.
- decision against rtnetlink: the ioctl path is older, smaller, well
  understood, and matches the loopback bring-up code already in
  pid1/emacs-init.c. Rtnetlink is more flexible (IPv6, multipath)
  but the Elisp side has no use for it yet. v0.5 can add an
  rtnetlink module if we need IPv6 RA.

**Elisp-side work:**
- `buffers/network.el` keymap: `c` calls
  `network-buffer-bring-up-iface` which prompts for an interface and
  calls `pid1-set-address` with values from
  `network-interface-config`. `d` triggers DHCP via the dhcp.el
  service. `s` prompts for address/netmask/gateway (defaults from
  the config) and calls the static path.
- `core/network.el` `network--apply-entry` for non-lo entries now
  calls `pid1-set-address` and `pid1-add-route`.
- DNS: write `/etc/resolv.conf` via state.el's atomic writer when the
  user supplies one with `s` or DHCP returns one. Tag the file with a
  comment so a casual reader knows GEOS owns it.

**Guix-side work:**
- add `dhcpcd` to system.scm packages (only until the elisp client
  lands). Document the exception in `guix-system/exceptions.scm`.

**Risks and unknowns:**
- ioctl-based config does not support multiple addresses per
  interface (SIOCSIFADDR is single-address). For v0.4 this is fine.
- DHCP interaction with the panic-handle pattern: dhcpcd can take
  10s to converge, so the spawn must be sentinel-driven, not blocking.
- /etc/resolv.conf races with anything else that wants to write it
  (nothing today).

**Test plan:**
- freeze-tests: bring lo down via `iface-down`, confirm `*network*`
  shows it down within one refresh tick; bring lo back up.
- new test that adds a /32 route to 192.0.2.1 via lo, asserts
  /proc/net/route has it.
- smoke-test: add `network: lo up` marker (already there) plus a new
  `network: applied N entries`.
- manual: in a QEMU run with a virtio-net NIC, hit `d` on the eth0
  row, confirm a lease arrives.

**Estimated complexity:** Medium (5-7 days), of which 3 days is the
ioctl wrapper.

---

## Item 6. package management buffer

**Files to touch (existing):**
- `emacs-init/buffers/packages.el`
  (extend the keymap with `i` install, `r` remove, both prompting
  for a package name; refresh after the spawn finishes).

**Files to create (new):**
- `emacs-init/services/guix-spawn.el`:
  a thin wrapper around `make-process` that runs
  `/run/current-system/profile/bin/guix package -i NAME` (or `-r`),
  with stdout/stderr piped into a temporary buffer
  `*packages-progress*`. Sentinel updates `*packages*` when the child
  exits. Registered with supervise.el so a stuck guix invocation can
  be cancelled (`q` in `*packages-progress*`).
- `emacs-init/buffers/packages-progress.el`
  (small mode that pretty-prints the guix output, follows the tail).

**C-side work:** none. `make-process` is enough; pid1's spawn helper
is for the supervisor, this is a foreground operation.

**Elisp-side work:**
- `packages-buffer-install (name)`: prompt for NAME (with completion
  from `guix-spawn--known-packages`, which we cache to
  `/var/emacs/packages/known` once a day via supervise.el timer).
- `packages-buffer-remove (name)`: same shape, defaults to the entry
  at point.
- after the child exits successfully, re-read the manifest and
  repaint.
- progress feedback: the filter function appends incoming bytes to
  `*packages-progress*` and updates the header line of `*packages*`
  to `installing NAME (NN%)` if a percentage is parseable from guix
  output.

**Guix-side work:**
- nothing required; guix is already in `%base-packages`.
- consider adding `guix gc --collect-garbage=10G` as a defservice
  weekly timer.

**Risks and unknowns:**
- `guix package -i` writes to `~/.guix-profile`, which is per-user.
  In single-user PID 1 mode that is /root/.guix-profile, and that
  has nothing to do with `/run/current-system/profile/manifest`
  which is what `*packages*` reads today. The buffer needs to show
  BOTH and let the user pick which one they are operating on. UI:
  add a `[system|user]` toggle in the header line and a new keymap
  entry `t` to switch between them.
- `guix system reconfigure` is the right way to install at the system
  level; that requires a generated config and a reboot. Out of scope
  for v0.4. The buffer treats system-level changes as read-only.
- guix can take minutes. Sentinel must not block, refresh timer must
  not stomp the in-progress install.

**Test plan:**
- freeze-tests: `i` a tiny package (hello), confirm exit 0 and the
  manifest cache picks it up; `r` it, confirm gone.
- error path: `i` a nonexistent package, confirm sentinel routes the
  error through panic-handle.
- smoke-test: no new marker (the buffer is interactive only).

**Estimated complexity:** Medium (4-6 days).

---

## Item 7. suspend / resume

**Files to touch (existing):**
- `emacs-init/core/power.el` (add
  `geos-suspend` next to `geos-poweroff`).

**Files to create (new):**
- `emacs-init/services/acpi-watch.el`:
  follows `/proc/acpi/event` (legacy) or, more reliably, opens a
  netlink socket on `NETLINK_KOBJECT_UEVENT` and watches for
  `power_supply` and `button/power` events. Registered with
  supervise.el. On a power-button press, calls `geos-poweroff` after
  a 1s confirmation (settable). On a lid-close event, calls
  `geos-suspend` if `geos-suspend-on-lid` is non-nil.

**C-side work:**
- new `Fpid1_suspend ()`:
  - opens `/sys/power/state` O_WRONLY
  - writes the literal "mem"
  - returns t on success, signals `pid1-error` with strerror on
    failure (typical EBUSY when a wakelock is held).
- new `Fpid1_uevent_open ()`: opens a `NETLINK_KOBJECT_UEVENT`
  AF_NETLINK socket, returns the fd as an integer. Elisp wraps it
  with `make-pipe-process` so the existing process-filter pattern
  picks up events. Alternative: do the netlink read in C and pass
  parsed events as a list, but the unstructured stream is fine to
  parse in elisp (key=value lines separated by NUL).

**Elisp-side work:**
- `geos-suspend`: confirms, then calls `pid1-suspend`. The syscall
  blocks until the kernel returns from S3, so the function returns
  AFTER resume. On resume, post a hook `geos-resume-hook`.
- the resume hook re-runs `network-apply-config` (some NICs come
  back down), retriggers `hostname-apply` (some kernels reset
  utsname on resume - paranoia), and re-arms the per-buffer 2s
  timers (they may have drifted).

**Guix-side work:**
- nothing required. ACPI is in linux-libre.
- consider `acpid` package? No: we just read the events ourselves
  via netlink. acpid is yet another shepherd-shaped daemon we do not
  want.

**Risks and unknowns:**
- on bare metal, suspend may fail because of a missing firmware blob.
  Document `M-x geos-suspend` failure as "expected on libre-only
  laptops with proprietary GPUs".
- the syscall blocking until resume means the supervisor is also
  blocked. This is fine: nothing for it to supervise during S3.
- wakeup events come from many sources (RTC, USB hotplug, lid). The
  uevent watcher only sees the ones the kernel emits as uevents,
  which excludes the actual wake (we are already running by then).
  That is correct behaviour, just noting it.

**Test plan:**
- manual: `M-x geos-suspend` in QEMU with `-machine accel=kvm`; QEMU
  pauses then resumes on host signal. Verify that emacs picks up
  where it left off and the network buffer shows lo still up.
- on bare-metal: defer to the v0.4 release-candidate test pass.
- no smoke-test marker (suspend is interactive).

**Estimated complexity:** Small (2-3 days).

---

## Item 8. audio

**Files to touch (existing):**
- `guix-system/system.scm` (add
  `alsa-utils`, `alsa-lib` to system packages so the userland has
  alsamixer and the headers pkg-config can find).

**Files to create (new):**
- `emacs-init/userland/audio.el`:
  - `defcustom audio-sink "default"` ALSA sink name.
  - `defun audio-volume (level)` 0-100 integer; spawns
    `amixer -q sset Master Nf%` for now via `make-process`. Long-term
    a tiny alsa.c module that wraps `snd_mixer_open` / `selem_set`.
  - `defun audio-mute-toggle ()` and `defun audio-play-file (path)`
    (the latter spawns `aplay`).
- `emacs-init/buffers/audio.el`:
  the `*audio*` buffer. Lists ALSA cards from `/proc/asound/cards`,
  shows current Master volume, has `+`/`-` for volume, `m` for mute,
  RET on a card to make it the default sink.

**C-side work:** optional v0.4 stretch. If the alsa.c module lands:
- new `pid1-alsa-mixer.so` (separate from pid1-module.so to keep PID
  1's footprint clean; built only for the userland emacs).
- functions: `alsa-set-volume CARD CONTROL LEVEL`,
  `alsa-get-volume CARD CONTROL`, `alsa-list-cards`.
- linker: `-lasound`.

**Elisp-side work:** as above.

**Guix-side work:**
- add `alsa-utils`, `alsa-lib` to packages.
- if the alsa.c module ships, add `pkg-config` and `alsa-lib` to the
  build inputs of pid1's Makefile target list.

**Risks and unknowns:**
- PipeWire vs ALSA: PipeWire requires a session daemon and we are
  shepherd-free. ALSA is simpler and fits the model. Decision: ALSA
  for v0.4. PipeWire revisited if applications need it (notmuch
  voicemail integration is the only candidate I can see, and not
  this release).
- `aplay` is a shell-out, even via make-process. That is fine because
  it is invoked by user-facing commands, not boot supervision.
- `M-x audio-volume 50` and the `+`/`-` keys must not slow the
  redisplay; volume changes must be sentinel-driven.

**Test plan:**
- manual: in QEMU with `-audiodev pa,id=hda -device intel-hda
  -device hda-output,audiodev=hda`, confirm `*audio*` shows the
  card and `audio-play-file` plays a sample.
- no smoke-test marker (audio is interactive).

**Estimated complexity:** Medium (4-7 days), most of it in the
optional alsa.c module.

---

## Item 9. disk encryption (LUKS at boot)

**Files to touch (existing):**
- `pid1/Makefile` (add `-lcryptsetup`
  to the standalone binary's LDFLAGS, gated on `LUKS=1`).
- `pid1/emacs-init.c` (call
  `unlock_luks_root()` before `do_mount("ext4", "/", ...)` happens.
  Today our root is the kernel-supplied /, so this only fires when
  the kernel-supplied root is a `/dev/mapper/...` device that does
  not yet exist; we have to set up the mapping in the initrd, NOT
  in PID 1 itself.).
- `guix-system/system.scm` (add
  `mapped-devices` field, kernel-arguments include `cryptdevice=`).

**Files to create (new):**
- `pid1/luks.c`:
  - `int luks_unlock(const char *device, const char *name, const char *passphrase, size_t plen)`.
  - uses `crypt_init`, `crypt_load`, `crypt_activate_by_passphrase`.
  - called from a NEW initrd helper, NOT from /sbin/emacs-init,
    because root must be unlocked before pivot_root.
- `pid1/luks-initrd.c`:
  - small standalone binary that runs in the initrd. prompts on
    /dev/console for the passphrase using termios non-echo mode,
    calls luks_unlock, exec /sbin/init (which is emacs-init by
    chained gexp).
  - this is its own binary so the initrd does not pull in libemacs.

**C-side work:** as above.

**Elisp-side work:**
- post-boot: the *disks* buffer learns to show `crypto-LUKS`
  filesystems and offer `u` to unlock additional volumes (data
  partitions). Calls a new `Fpid1_luks_unlock` exposed by the
  module (not the initrd; the module shares luks.c via the same
  source file).

**Guix-side work:**
- system.scm gains `mapped-devices`:
  ```
  (mapped-devices
   (list (mapped-device
          (source (uuid "..."))
          (target "geos-root")
          (type luks-device-mapping))))
  ```
- file-systems updates root to `/dev/mapper/geos-root`.
- initrd-modules adds `dm-crypt` and `aes`.
- the boot gexp's execl chain stays the same; the initrd unlock
  happens before our gexp runs.

**Risks and unknowns:**
- Guix's stock initrd already supports LUKS via `mapped-devices`. We
  may not need our own luks-initrd binary at all; verify by reading
  `(gnu system mapped-devices)` and confirming the prompt routing.
  If Guix's initrd handles it, this item shrinks to "wire the field
  in system.scm and document".
- LUKS2 vs LUKS1: LUKS2 is the default since cryptsetup 2.1. GRUB
  supports LUKS2 since 2.06. Confirm Guix's grub-bootloader is
  >= 2.06 (it is, as of 2024).
- header location: stock LUKS keeps the header on the encrypted
  device. Detached headers are out of scope for v0.4.
- passphrase entry on serial console: `getpass(3)` does the right
  thing on a TTY, but our initrd helper must explicitly use
  termios `~ECHO` because `/dev/console` is not always a tty.

**Test plan:**
- new `iso-build/luks-test.sh` that builds an installer image,
  installs to a luks-formatted qcow2, then boots with
  `-display none`, sends the passphrase via serial pipe, and asserts
  userland-up.
- freeze-test: nothing (LUKS is bootstrap-only).

**Estimated complexity:** Large (1.5-2 weeks), most of it in
verifying the Guix initrd + cryptsetup version interactions.

---

## Item 10. kernel-cmdline boot menu in GRUB

**Files to touch (existing):**
- `guix-system/system.scm`
  (`bootloader-configuration` learns a `menu-entries` field with
  three entries: ui (default), console, recovery).

**Files to create (new):**
- none.

**C-side work:**
- `pid1/emacs-init.c` already parses `geos.mode=`; extend the parser
  to recognize `recovery`, which:
  - skips Xorg
  - skips userland `-l` chain (only loads early-init.el and panic.el)
  - drops the user straight to `*scratch*`.
- one-liner wrapper:
  ```
  if (strcmp(val, "recovery") == 0) return GEOS_MODE_RECOVERY;
  ```
  and main() branches on `GEOS_MODE_RECOVERY` to skip the userland
  argv build.

**Elisp-side work:**
- early-init.el reads `(getenv "GEOS_MODE")` (set by emacs-init in
  the recovery branch) and refuses to load the userland chain.
- /scratch/ buffer gets a banner explaining the mode.

**Guix-side work:**
- bootloader-configuration menu-entries:
  ```
  (menu-entries
   (list (menu-entry (label "GEOS (UI)")
                     (linux ...) (linux-arguments
                       (cons "geos.mode=ui" %default-...)))
         (menu-entry (label "GEOS (console)")
                     (linux ...) (linux-arguments
                       (cons "geos.mode=console" %default-...)))
         (menu-entry (label "GEOS (recovery)")
                     (linux ...) (linux-arguments
                       (cons "geos.mode=recovery" %default-...)))))
  ```

**Risks and unknowns:**
- guix's `bootloader-configuration` field shape; menu-entries is
  documented and stable.
- a recovery boot still needs /var to exist if the user wants to
  edit state. Item 1's mount_var must run unconditionally.

**Test plan:**
- smoke-test grows a `--mode=recovery` flag that boots with the
  recovery entry and asserts a minimal `geos: recovery shell` marker.
- manual: GRUB menu shows three entries; pick recovery, confirm
  scratch + no userland.

**Estimated complexity:** Small (1-2 days).

---

## Item 11. Hurd kernel variant

**Files to touch (existing):**
- everything in `pid1/emacs-init.c`
  that calls a syscall.
- `pid1/Makefile` (add `linux` and
  `hurd` build modes; emit `pid1-module-linux.so` and
  `pid1-module-hurd.so`).
- `guix-system/system.scm` becomes
  one of two records living in `guix-system/system-linux.scm` and
  `guix-system/system-hurd.scm`, with the shared bits factored out.

**Files to create (new):**
- `pid1/port_layer.h`: the abstraction.
  Every syscall the supervisor uses goes through this header. Shape:
  ```
  typedef struct port_caps {
      int (*reap)(pid_t *out_pid, int *out_status);
      int (*mount)(const char *src, const char *tgt, const char *type,
                   unsigned long flags, const char *opts);
      int (*set_hostname)(const char *name, size_t len);
      int (*bring_up_lo)(void);
      int (*reboot)(int cmd);
      int (*spawn)(pid_t *out_pid, const char *path, char *const argv[],
                   char *const envp[]);
  } port_caps;
  extern const port_caps *port;
  ```
- `pid1/port_linux.c`: today's
  implementation (mount(2), waitpid, reboot(2), socket+ioctl).
- `pid1/port_hurd.c`:
  - `mount` -> `settrans` against the target node, plus the right
    translator from `/hurd/`.
  - `reap` -> `proc_waitpid` from `<hurd/process.h>`.
  - `set_hostname` -> Hurd has `sethostname(2)`, same as Linux.
    Delegate.
  - `bring_up_lo` -> `pfinet` translator on `/servers/socket/2`,
    then ioctl-equivalent via `pfinet`'s RPC.
  - `reboot` -> `proc_set_arg_locations`-inspired graceful, plus
    fallback to `host_reboot` mach RPC.
  - `spawn` -> `task_create` + `task_set_special_port` dance, or
    `posix_spawn` if glibc-on-Hurd ships it (it does).

**C-side work:**
- audit every syscall in emacs-init.c. Replace each with a `port->`
  call. Linux backend keeps current behaviour; Hurd backend
  implements the equivalent.
- features dropped on Hurd for v0.4:
  - Xorg (no DRM/KMS story on Hurd we want to depend on)
  - cgroups (no cgroups on Hurd)
  - LUKS (cryptsetup Hurd port is incomplete)
  - netlink-based uevent watcher (item 7)
  - so v0.4 Hurd is console-only, no exwm, no suspend, no encryption.

**Elisp-side work:**
- `core/port.el`: `(defvar geos-kernel 'linux)` set from
  `(getenv "GEOS_KERNEL")` which the Hurd boot script exports.
- every elisp file that calls a kernel-coupled function (network
  ioctl, /proc walker) checks `geos-kernel` and either does the
  Hurd-equivalent or no-ops with a `message`.
- `buffers/processes.el` parses `/proc` on Linux; on Hurd it calls
  `proc_pids` via a small new module function. The buffer code
  itself does not branch; the data-source layer does.

**Guix-side work:**
- `guix-system/system-hurd.scm`:
  - `(use-modules (gnu system hurd))`
  - kernel = `gnumach`, hurd = `hurd`.
  - file-systems uses `/dev/hd0s1` instead of `/dev/sda1`.
  - drop xorg-server, exwm, dhcpcd from packages.
  - emacs-init binary built as `pid1/emacs-init-hurd` with the hurd
    port linked in.
- pin a known-good Hurd channel revision in channels.scm.
- iso-build needs a `geos-hurd.iso` target via
  `guix system disk-image -t hurd64-raw guix-system/system-hurd.scm`.

**Risks and unknowns:**
- the Guix Hurd target builds in a cross environment; CI time will
  triple.
- Hurd's `/proc` is not Linux's `/proc`. Many of our buffers will
  show empty data on Hurd until per-buffer adapters land.
- the emacs dynamic module ABI assumes a Linux-y dlopen. Hurd's
  glibc supports dlopen, so the module should load, but I want
  prototype confirmation before committing the rest of the work.
- console handling on Hurd: the kernel console is a Mach device,
  not a tty. spawn_emacs may need a different fd setup.
- Hurd is single-server-per-translator and many of the things we
  treat as syscalls are RPCs that can fail in new ways (server died
  mid-call). The error model in pid1_signal_errno needs to grow a
  Mach-error path.

**Test plan:**
- new `iso-build/hurd-smoke-test.sh` mirroring the Linux smoke test
  against the hurd64-raw image.
- minimum success: `geos: emacs userland up` on Hurd console.
- freeze-tests stay Linux-only for v0.4; the Hurd port just needs
  not to wedge.

**Estimated complexity:** Huge (2-3 months for one person; faster
with prior Hurd experience).

---

## Cross-cutting concerns

**voice + commits:**
- every new file follows the `;;; filename.el --- one-liner -*- lexical-binding: t -*-` header.
- every commit message lowercase, no prefixes, no em-dashes.
- run `/attribution-scan` before every commit.
- run `/no-shell-check` after items 5 (dhcpcd), 6 (guix spawn), and 8
  (aplay) land; document the exceptions in `guix-system/exceptions.scm`.

**panic-handle discipline:**
- every new defservice's `:command` failure routes through
  panic-handle, NOT bare error. Add a freeze-test that asserts a
  bad-command service ends up in *panic*, not in the kernel log.

**single-thread reality:**
- items 2 (supervise.el), 3 (installer copy), 5 (dhcp), 6 (guix
  install), 8 (alsa volume) all involve work that could block. Each
  uses sentinel-driven make-process or its own pid1-spawn variant.
  There is no `:start-blocking` in `defservice`; it is
  `:start-async` only.

**budget for cuts:**
- if v0.4 slips, drop in this order: 11 (Hurd) -> 8 (audio) -> 7
  (suspend). The release still ships the installer + login + LUKS +
  network UI which is the user-facing v0.4 promise.

;;; v04-plan.md ends here
