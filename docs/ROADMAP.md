# roadmap

What I want to fix in v0.2 and roughly in what order. This is not a
schedule, it is a dependency graph: each phase unlocks the next, and
none of them is interesting without the one before it.

## v0.1 recap (done)

Emacs is PID 1. /bin/sh is a 50-line C stub. The five system-concept
buffers are live. The ISO builds reproducibly from a pinned channel
and cold-boots in QEMU. v0.1 proves the thesis. v0.2 is about turning
it into something I can run on hardware for a full day without
flinching.

## v0.2 in priority order

### 1. core/supervise.el (the registry)

The Phase 6 buffers all have `TODO(6):` markers waiting for a real
supervisor. processes/disks/services register their refresh timers
with it. journal registers its `dd if=/dev/kmsg` subprocess as kind
`'process` so a follower death gets restarted. epdfinfo (pdf-tools)
and any future ibus-daemon hang off the same registry.

The shape: a defvar holding `((id . (:kind X :restart-fn FN :state
S))...)` plus `supervise-register`, `supervise-deregister`,
`supervise-tick`. `supervise-tick` runs from a timer, walks the
registry, and respawns anything dead. Restart cap: 5 in 60 seconds,
mirroring the C-side Xorg cap.

This is a one-week task and it closes a paper-cut from v0.1. Do this
first because everything below registers with it.

### 2. real Xorg over KMS

Xvfb was the right answer for a QEMU smoke test. It is the wrong
answer for hardware. The path:

  - bring up `bochs-drm` (or `i915` / `amdgpu`) from the initrd via
    explicit `kernel-loadable-modules` in the operating-system record
  - ship a real `xorg.conf` (the dead one in guix-system/xorg.conf is
    a placeholder waiting for this work) that uses the modesetting
    driver against the KMS device
  - flip pid1's `spawn_xorg` to launch Xorg with the real binary
    instead of Xvfb, keep the supervisor wrapper unchanged
  - re-run /boot-vm against `-vga virtio` and `-vga std` to confirm
    the modesetting driver picks up either

The supervisor side is already correct (5/60 respawn cap, sentinel,
SIGTERM grace). This is purely a userspace + initrd question.

### 3. networking that is not just lo

Right now `network-interface-config` only knows how to bring up
loopback. To make the box useful on a network I need:

  - `pid1-set-address` exposed as a dynamic-module call wrapping
    SIOCSIFADDR / SIOCSIFNETMASK / SIOCSIFFLAGS. The TODO(5c) marker
    in core/network.el is waiting for this.
  - a DHCPv4 client. dhcpcd as a long-running process registered with
    supervise.el. The `*network*` buffer grows a `D` keystroke to
    request a lease.
  - a DNS resolver. The simplest thing that works: a `/etc/resolv.conf`
    written by the dhcp lease handler, plus emacs-side use of
    `dns-query` for any name lookups in elisp. No nss, no glibc
    resolver hooks.
  - wifi. `wpa_supplicant` registered with supervise.el. A new
    `*wifi*` buffer (run /buffer-it for it) that lists scan results
    and calls into wpa_cli over its control socket. No shell-out.

This phase is the largest and the most user-visible. After this the
OS is actually useful.

### 4. audio

ALSA-only first, PulseAudio later or never. The kernel module loads
at boot, `/dev/snd/*` shows up. emacs has no native audio, so:

  - a small audio dynamic module (`pid1-audio.so` or a sibling) that
    wraps `snd_pcm_*` for playback. Read-only from the buffer side
    initially: a `*audio*` buffer that shows current cards and
    streams.
  - mpv-as-backend for actual media playback, via `make-process` (no
    shell). mpv supports a JSON IPC socket which is the right shape
    for emacs to drive.
  - microphone capture punted to v0.3.

### 5. persistence and `*reconfigure*`

A v0.1 boot is stateless. Every reboot resets `~/`. For v0.2 I want:

  - a separate `/home` partition (or a qcow2 layer) that survives the
    image rebuild
  - a `*reconfigure*` buffer that runs `guix system reconfigure
    /etc/config.scm` from inside the OS. This is the loop-closing
    moment: the OS rebuilds itself.
  - the buffer captures the build log incrementally (same pattern as
    journal.el's `dd` subprocess), surfaces success or failure, and
    on success prompts for reboot.

After this, the OS is self-hosting in the meaningful sense.

### 6. odds and ends that I will not let slip past v0.2

  - fontconfig cache build hook on first boot, so emoji/CJK actually
    render instead of warning and skipping
  - power management: suspend/resume via `/sys/power/state`. Wrap it
    in a `pid1-suspend` module call so the supervisor can quiesce
    timers across the suspend/resume boundary.
  - keyboard layout buffer (`*kbd*`) backed by `setxkbmap` driven via
    `process-file`, no shell

## explicitly punted to v0.3 or later

  - Hurd variant. Interesting but not on the daily-driver path.
  - Multi-user. The current model is "one human at the console". I
    do not have a good answer for what `su` would mean when the
    shell is eshell and the supervisor is shared.
  - Wayland. EXWM is X11-only. A Wayland equivalent is a different
    project.
  - Bluetooth. bluez is its own dependency mountain.
  - Microphone capture and webcam. Same reason as Bluetooth.

## the meta-task

After v0.2 is functionally complete, I want to actually ship it. That
means:

  - real install media that boots on a non-virtualized x86_64 laptop
  - a one-page "is this for you" landing page on the manifesto
  - a `git tag v0.2` that I am willing to point friends at

That is the actual goal. Everything above is the path to get there.
