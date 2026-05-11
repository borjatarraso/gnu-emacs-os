# installing GNU/Emacs Operating System (GEOS)

Maintainer: Borja Tarraso <borja.tarraso@member.fsf.org>

This document covers the v0.3.1 release plus the v0.4 in-flight tree.
I have only tested GEOS in QEMU. Real hardware boots are part of the
v0.4 meta-task, see `docs/ROADMAP.md`. If you put this on a laptop
and it eats your filesystem I will take the bug report but I will not
be surprised.

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

The current pin is Guix commit
`230aa373f315f247852ee07dff34146e9b480aec`, carried forward unchanged
from v0.1 through the v0.4 in-flight tree. This is non-negotiable
inside a release. The ISO is reproducible byte-for-byte (modulo
kernel build-id) against that pin and only against that pin. Bumping
it is a release-cut concern, not a per-patch one.

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
    -vga virtio \
    -display gtk \
    -device qemu-xhci,id=xhci \
    -device usb-tablet,bus=xhci.0 \
    -serial mon:stdio \
    -boot d \
    -cdrom <ISO>
```

A few notes on those flags. 2 GB of RAM is the floor. With less, Emacs
starts swapping during `exwm-enable` and the boot looks hung. `-vga
virtio` is mandatory: the operating-system record's xorg config binds
the modesetting driver against `/dev/dri/card0`, which only exists when
the guest sees a virtio_gpu device. `-vga std` will boot but Xorg dies
at AddScreen and you get a black window. The usb-tablet on a dedicated
xhci bus gives an absolute pointer (no pointer-grab dance) and lands
on `/dev/input/event4` where xorg-modesetting.conf is configured to
find it. Without it the X session has a keyboard but no mouse.
`-serial mon:stdio` is how you see PID 1's writes to `/dev/console` in
your terminal, which is the only debug surface during early boot.

Boot takes about eleven seconds from `qemu` invocation to the EXWM
splash. The first thing you see on the kernel framebuffer is the boot
log. The second thing is Emacs.

## boot modes: UI vs console

GEOS supports two boot modes. The mode is picked at GRUB time via the
`geos.mode=` kernel cmdline token, which PID 1 reads from
`/proc/cmdline` before it spawns Xorg.

  - `geos.mode=ui` (the default, baked into the image's
    `kernel-arguments`, also what you fall back to if the token is
    absent or malformed). PID 1 spawns Xorg with the modesetting
    driver against `/dev/dri/card0`, then spawns Emacs with
    `DISPLAY=:0` so Emacs comes up as an X client and EXWM grabs the
    root window. `s-&` launches X clients, the frame is fullscreen.
    This is the standard graphical session.
  - `geos.mode=console`. PID 1 skips Xorg entirely and spawns Emacs
    on `/dev/console` with `TERM=linux`. No X server, no EXWM, no
    GUI. The session is the kernel framebuffer console with Emacs
    filling it. `M-x eshell` for the shell, all the system buffers
    (`*processes*`, `*network*`, `*journal*`, `*services*`,
    `*disks*`, `*packages*`) work exactly like they do in UI mode.
    This is the right mode for a serial-console headless box, an SSH-
    equivalent session, or just doing all your work in a framebuffer
    Emacs.

To pick the mode at boot, hit `e` at the GRUB menu, find the line that
starts with `linux /gnu/store/...`, and replace `geos.mode=ui` with
`geos.mode=console` (or vice versa) at the end of that line. Press
`Ctrl-x` (or `F10`) to boot. The choice persists for that boot only;
the next reboot reverts to whatever the GRUB entry has baked in. To
make the choice permanent, edit the token in `kernel-arguments` in
`guix-system/system.scm` and rebuild the image.

The boot log echoes the chosen mode as one of:

```
pid1: geos.mode=console, skipping Xorg, emacs on /dev/console
pid1: geos.mode=ui, will spawn Xorg + EXWM
```

A missing or unrecognized value defaults to UI. An unknown value
also logs a warning so you can see what the operator typed.

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

## installing GEOS onto a real disk (the MVP wizard)

GEOS now ships an in-Emacs install wizard. It is the v0.4 item 3 MVP:
it does NOT partition disks. The operator is expected to pre-
partition the target from a Guix live ISO (one ext4 partition is
enough for a non-encrypted install), then boot GEOS from any working
medium (qcow2, USB stick, network boot) and run the wizard.

Pre-partitioning from a Guix live ISO:

```
parted /dev/sda mklabel msdos
parted /dev/sda mkpart primary ext4 1MiB 100%
parted /dev/sda set 1 boot on
```

Reboot into GEOS. Then:

```
M-x install
```

The `*install*` buffer walks five states:

  1. `:welcome` — press `RET` to start, `q` to bail.
  2. `:disk-pick` — `n`/`p` navigate, `g` refresh,
     `RET` picks. Disks with a mounted partition are flagged `MNT`
     and refused.
  3. `:part-pick` — same navigation, `RET` picks a partition.
     Mounted partitions are refused.
  4. `:format-confirm` — `y` to format the partition as ext4 with
     label `geos-root` and proceed, `n` to back up.
  5. `:format` → `:mount` → `:copy` → `:grub` → `:done`. The wizard
     spawns `mkfs.ext4`, `pid1-mount`s the new partition at
     `/mnt/install`, copies `/gnu/store`, `/var/guix`, and
     `/run/current-system` with `cp -a`, then runs `grub-install`
     and `grub-mkconfig`. On `:done` press `r` to reboot.

Total wall-clock time is dominated by the copy step. A ~6 GB closure
takes a couple of minutes on SATA, half an hour on USB 2.

Per-step output streams into hidden work buffers
(`*install:mkfs:DEVICE`*, `*install:copy*`, `*install:grub*`) for
debugging. On any failure the wizard moves to `:error`, names the
failing step, and lets you press `RET` to restart at `:welcome`.

The wizard does not partition. It does not write an ESP. It does
not encrypt. Partition-from-scratch and the UEFI/ESP layout are
v0.4.1. LUKS is a separate manual flow, documented next.

## installing with an encrypted root (LUKS)

Bare-metal GEOS can boot from a LUKS-encrypted root. The flow piggy-
backs on Guix's stock initrd, which already knows how to prompt on
`/dev/console` for a passphrase and unlock a `mapped-device`. No
custom initrd helper is required.

The exact edits to `guix-system/system.scm` live in
`guix-system/system-luks-snippet.scm`. The high-level steps:

1. Boot a Guix live ISO on the target hardware.

2. Format the target partition as LUKS2 and record its UUID:

   ```
   cryptsetup luksFormat --type luks2 /dev/sdaN
   cryptsetup luksUUID /dev/sdaN
   ```

3. Open it once so you can put a filesystem inside:

   ```
   cryptsetup open /dev/sdaN geos-root
   mkfs.ext4 -L geos-root /dev/mapper/geos-root
   ```

4. Mount `/dev/mapper/geos-root` at `/mnt`. Copy your edited
   `system.scm` (with the three edits from
   `system-luks-snippet.scm`: `mapped-devices`, `file-systems`
   pointing at `/dev/mapper/geos-root`, and `initrd-modules`
   extended with `dm-crypt aes aes_generic xts sha256_generic`).

5. Replace `LUKS-UUID-HERE` in `mapped-devices` with the UUID you
   captured in step 2.

6. Run `guix system init /mnt/etc/system.scm /mnt`. This populates
   `/gnu/store` on the new root, writes the bootloader, and exits.

7. Reboot. GRUB hands off to the kernel, the initrd prompts you for
   the LUKS passphrase on `/dev/console`, the mapper device opens,
   root mounts, PID 1 (`emacs-init`) takes over.

Caveats:

  - Detached headers are out of scope for v0.4. The header stays on
    the encrypted partition.
  - Passphrase only. No key-file, no escrow, no TPM-sealed unlock.
  - On a libre-only laptop with no AES-NI the boot is slower but
    workable. XTS-AES at 256 bits is the default.
  - Unlocking additional LUKS volumes (data partitions, external
    drives) from inside running GEOS is a v0.5 follow-up. v0.4 only
    covers the root.
  - The bare-metal install wizard (v0.4 item 3 MVP) handles the
    non-encrypted flow now. LUKS layering on top of it is v0.5: the
    wizard would need a passphrase prompt and a `cryptsetup
    luksFormat` step before `mkfs.ext4`. For LUKS in v0.4, steps
    2-6 above stay manual.

QEMU smoke tests do NOT exercise this path. `system.scm` ships
without `mapped-devices` so the headless test stays simple. The
LUKS path is opt-in by edit.

## what to do once it boots

You land in EXWM with a single Emacs frame, four virtual workspaces,
and an xterm started as a smoke-test canary on workspace 0. Useful
keys:

```
s-w               switch workspace by index
s-0..s-3          jump to workspace N
s-&               launch a program (no shell, just exec)
s-r               reset EXWM input mode if an X11 app eats your keys
M-x network       open the *network* buffer
M-x processes     open the *processes* buffer
M-x geos-poweroff sync, reboot(2) with RB_POWER_OFF, qemu exits
M-x geos-reboot   sync, reboot(2) with RB_AUTOBOOT
```

`M-x eshell` is the shell. There is no other shell. If you instinctively
type `bash` and hit enter, the shstub will route it back into another
eshell, which is funny once and annoying after that. From eshell,
`uname -a` prints `GEOS lambda <release> <version> <machine> GNU/Emacs
(Linux)`. The kernel's compile-time `Linux` string stays correct in the
parens at the end; nothing in the profile calls `uname(2)` for
user-visible output.

Power off the VM with `M-x geos-poweroff`. There is no
`/sbin/poweroff`, no `sudo`, no socket protocol. The supervisor IS
Emacs, so the answer to "shut down" lives in this Emacs and goes
straight to `reboot(2)`. The QEMU window closes when the syscall
succeeds.

## verifying the build

Two scripts run before any commit, three before any release:

  - `/attribution-scan` greps the repo for forbidden tokens. Empty
    output means pass.
  - `/no-shell-check` greps for code paths that invoke a POSIX shell.
    Empty output means pass. The documented exceptions are listed in
    `guix-system/exceptions.scm`.

`/smoke-test` boots a qcow2 headlessly with the serial console wired
to a tmpfile and greps for pid1, userland, /var, state, and supervise
success markers (plus a failure-marker fast-fail set). Catches the
class of regression that wedged v0.3 boot once already (an xorg.conf
parse error -> Xorg respawn loop -> no DISPLAY -> EXWM never came
up). Run it after any change to `pid1/`, `guix-system/`, or anything
Xorg-adjacent. Implementation lives at `iso-build/smoke-test.sh`;
exit codes are 0 pass, 1 fail (with the matched marker and the last
30 serial lines printed), 2 timeout.

`/freeze-test` runs the abuse suite against a booted VM (runaway loops,
catastrophic regex, a literal `(kill-emacs)` call, a service that
trips the supervise.el respawn cap) and confirms the panic buffer
keeps the OS interactive.

## known broken things

  - Real hardware. Not tested. Part of the v0.4 meta-task.
  - Audio. The kernel modules are present but nothing in Elisp talks
    to them yet. v0.4 item 8.
  - Bluetooth. Punted to v0.5+.
  - Wayland. Not in scope. EXWM is X11 by definition.
  - Multi-user. The system has one user, named `me`. v0.4 item 4.

## reporting a bug

`/freeze-test` output, `*panic*` buffer contents, the exact ISO store
hash, and the QEMU invocation that reproduced it. I cannot do anything
useful without all four.
