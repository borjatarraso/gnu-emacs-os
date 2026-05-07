# installing GNU/Emacs OS v0.1

I have only tested v0.1 in QEMU. Real hardware boots are tracked for
v0.2. If you put this on a laptop and it eats your filesystem I will
take the bug report but I will not be surprised.

## what you need

  - A Linux host with KVM available (`/dev/kvm` readable by your user).
  - Guix installed, daemon running. Any version Guix itself supports
    `time-machine` on works, the channel pin does the rest.
  - About 8 GB of free space in `/gnu/store` for the build closure.
    The ISO itself is 1.57 GB.
  - QEMU with `qemu-system-x86_64`.

I build on a Fedora 43 host with a stock `guix` installation. Other
hosts should work, the Guix daemon hides the host distribution from
the build.

## the channel pin

v0.1 is pinned to Guix commit
`230aa373f315f247852ee07dff34146e9b480aec`. This is non-negotiable. The
ISO is reproducible byte-for-byte (modulo kernel build-id) against
that pin and only against that pin. Bumping it is a v0.2 concern.

The pin lives in two files that must agree:

  - `guix-system/channels.scm`
  - `iso-build/channels.scm`

Both contain a `%guix-pin` binding, so a `grep -R %guix-pin` is the
sanity check.

## building the ISO

From the repo root:

```
cd iso-build
guix time-machine -C channels.scm -- \
    system image -L .. build.scm
```

The `-L ..` puts the repo root on `%load-path` so `build.scm` can find
`guix-system/system.scm`. Without it the build fails with a "cannot
find" error from `build.scm` itself, which is the failure mode I want.

The build takes about thirty minutes on a cold cache, two minutes on a
warm one. The final line of output is a `/gnu/store/...-image.iso`
path. That is the ISO.

For reference, my last build produced:

```
/gnu/store/1qljm6g1lhfdcybl5zzaji781q5qk3ah-image.iso  (1.57 GB)
```

If you get a different store hash with the same pin, something has
drifted. File a bug, do not just shrug and ship.

## booting the ISO

There is a harness script:

```
./iso-build/qemu-harness.sh /gnu/store/1qljm6g...-image.iso
```

It runs:

```
qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -cpu host \
    -smp 2 \
    -vga std \
    -display gtk \
    -serial mon:stdio \
    -boot d \
    -cdrom <ISO>
```

A few notes on those flags. 2 GB of RAM is the floor. With less, Emacs
starts swapping during `exwm-enable` and the boot looks hung. `-vga std`
plus `-display gtk` matches the framebuffer wiring in the operating
system record's xorg config; switch either flag and you get a black
screen. `-serial mon:stdio` is how you see PID 1's writes to
`/dev/console` in your terminal, which is the only debug surface
during early boot.

Boot takes about eleven seconds from `qemu` invocation to the EXWM
splash. The first thing you see on the kernel framebuffer is the boot
log. The second thing is Emacs.

## fast iteration with the qcow2 image

For development I build a qcow2 instead of an ISO. The qcow2 boots
faster and has a writable root, so I can edit `init.el`, restart Emacs
with `C-x C-c` (the C wrapper respawns it), and see the change in the
same VM session.

```
cd guix-system
guix time-machine -C channels.scm -- \
    system image -t qcow2 system.scm
```

Last good qcow2:

```
/gnu/store/vm6rsd5a9ifr63a3c74isc1zbxvadrrl-image.qcow2
```

Boot it the same way the harness boots the ISO, swap `-cdrom` for
`-drive file=...,format=qcow2` and drop `-boot d`.

## what to do once it boots

You land in EXWM with a single Emacs frame, four virtual workspaces,
and an xterm started as a smoke-test canary on workspace 0. Useful
keys:

```
s-w           switch workspace by index
s-0..s-3      jump to workspace N
s-&           launch a program (no shell, just exec)
s-r           reset EXWM input mode if an X11 app eats your keys
M-x network   open the *network* buffer
M-x processes open the *processes* buffer
```

`M-x eshell` is the shell. There is no other shell. If you instinctively
type `bash` and hit enter, the shstub will route it back into another
eshell, which is funny once and annoying after that.

## verifying the build

Two scripts run before any release:

  - `/attribution-scan` greps the repo for forbidden tokens. Empty
    output means pass. v0.1 ships with a clean scan over `docs/`,
    `pid1/`, `shstub/`, `guix-system/`, `emacs-init/`, and `iso-build/`.
  - `/no-shell-check` greps for code paths that invoke a POSIX shell.
    Empty output means pass. The documented exceptions are listed in
    `guix-system/exceptions.scm`.

`/freeze-test` runs the abuse suite against a booted VM (runaway loops,
catastrophic regex, a literal `(kill-emacs)` call) and confirms the
panic buffer keeps the OS interactive.

## known broken things

  - Real hardware. Not tested. v0.2.
  - Audio. The kernel modules are present but nothing in Elisp talks
    to them yet. v0.2.
  - Bluetooth. Same.
  - Wayland. Not in scope. EXWM is X11 by definition.
  - Multi-user. The system has one user, named `me`. v0.2.

## reporting a bug

`/freeze-test` output, `*panic*` buffer contents, the exact ISO store
hash, and the QEMU invocation that reproduced it. I cannot do anything
useful without all four.
