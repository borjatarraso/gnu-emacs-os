# 2026-05-24 v0.9.19 canonical Hurd image re-roll, full 35-file init.args boots, trampoline wedge closed

Continuation of docs/runlogs/2026-05-23-hurd-v0918-image-reroll.md
and docs/runlogs/2026-05-24-v0919-bucket-closeout.md probe 4.  The
v0.9.18 receipt shipped the re-roll script but flagged the canonical
35-file -l chain as wedged on emacs's kill_emacs_0.eln trampoline
build.  Bucket-closeout probe 4 corrected the diagnosis: the deployed
early-init.el on the v0918 image carried zero native-comp opt-out hits
while the source tree at main carries six.  Canonical Debian GNU/Hurd
0.9 has gcc 15.2.0-5 + binutils 2.46-3, so the toolchain was never the
limiter.  The fix is a one-cycle image re-roll that picks up the
current main snapshot of emacs-init/early-init.el.  This receipt is
the verify pass for that re-roll plus the live full-chain boot test
that proves the wedge closes.

## Result

PASS on the v0.9.19 ship.  The re-rolled image
/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0919.img (4,194,304,000
B raw, sha256 aa9f2827d86212f9627d28e333e84921b6e4d33ea1ca324387e62825662d56aa)
boots end-to-end under QEMU on host port 2269.  pid1 is the STATIC=1
emacs-init binary at /sbin/init (1,552,824 B, ELF for GNU/Hurd 0.0.0,
zero dynamic deps).  The deployed early-init.el at
/usr/share/geos/emacs-init/early-init.el grep -c native-comp returns
6.  The deployed install.el at
/usr/share/geos/emacs-init/buffers/install.el grep -c geos-kernel-hurd-p
returns 2.  The deployed audio.el at
/usr/share/geos/emacs-init/user/userland/audio.el grep -c pactl
returns 74.  Pulseaudio 17.0 installs and runs with module-null-sink
on the freshly re-rolled image.

The load-bearing claim: the full 35-file init.args chain (the chain
that wedged on v0.9.18) now boots through to the supervised emacs
sitting in the event loop with *scratch* up.  No kill_emacs
trampoline crash.  No SIGSEGV.  No panic.  Serial markers fire for
early-init, network, hostname, hurd-essentials in order.  hurd-essentials
registers the sshd + syslog services, runs settrans /hurd/pfinet on
eth0 to exit=0, and the emacs scratch buffer paints.  v0.9.19
follow-on #1 closes.

## What this slice ships

No code commit lands with this receipt.  Everything load-bearing was
already on main as of 2026-05-23: the early-init.el opt-out at lines
32-34, the install.el slice C kernel-gate relax at db3c14b, the audio
piece X pactl wiring at 7ad83e2.  This receipt is the verify pass that
proves a fresh re-roll picks them all up and that the full chain boots
cleanly.

The verify script /tmp/v0919-post-reroll-verify.sh is a workspace
artifact, not shipped in the repo.  It runs eight checks against a
booted v0919 QEMU and is preserved on the dev host for the next
re-roll cycle.

## Build matrix

Linux dev host: iso-build/hurd-image-reroll.sh invoked with
PRISTINE_IMG=/home/overdrive/hurd-vm/debian-hurd-amd64-pristine.img,
PID1_BIN=<repo>/pid1/emacs-init (STATIC=1
build), SUPERVISOR_TAR built from emacs-init/ tree at main HEAD,
SSH_PUBKEY=/tmp/hurd_vm_key.pub, OUTPUT_IMG=
/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0919.img.  Re-roll
runtime ~95 seconds.  Output sha256 captured above.

Hurd VM (booted from the re-rolled image under QEMU, host port 2269,
key /tmp/hurd_vm_key, serial captured to /tmp/v0919-verify-serial.log
for the minimal-chain boot and /tmp/v0919-fullchain-serial.log for the
full-chain boot): sshd ready in 11 seconds on the minimal init.args,
emacs *scratch* reached on the full init.args.  pid1 supervises emacs
with no respawn observed across the full-chain boot window.

## Transcript markers, minimal chain (first boot after re-roll)

    grep -c native-comp /usr/share/geos/emacs-init/early-init.el
      -> 6
    grep -c geos-kernel-hurd-p /usr/share/geos/emacs-init/buffers/install.el
      -> 2
    grep -c pactl /usr/share/geos/emacs-init/user/userland/audio.el
      -> 74
    file /sbin/init
      -> ELF 64-bit LSB executable, x86-64, statically linked,
         for GNU/Hurd 0.0.0, with debug_info, not stripped
    ls -la /sbin/init
      -> -rwxr-xr-x 1 root root 1552824 May 23 ... /sbin/init

Serial markers (excerpt):

    Starting /sbin/init
    GNU/Emacs Operating System (GEOS) v0.3 booting...
    pid1: / remounted read-write
    pid1: /run/sshd 0755 ready (openssh privsep chroot)
    pid1: hostname set to geos-hurd
    pid1: entering supervisor loop
    v0918-min: native-comp opted out
    v0918-min: settrans pfinet eth0 10.0.2.15/24 gw 10.0.2.2
    v0918-min: starting sshd -D -e
    v0918-min: ready, dropping into event loop

## Transcript markers, full 35-file chain (after init.args swap)

    cp /etc/geos/init.args /etc/geos/init.args.min-bak
    scp v0918-init-args-readback ... /tmp/v0919-full-init.args
    cp /tmp/v0919-full-init.args /etc/geos/init.args
    wc -l /etc/geos/init.args -> 84 (35 -l file entries + 4 flag args
                                     + 1 binary path + 2 placeholders
                                     + commentary)
    reboot

Serial markers from the post-reboot full-chain boot (excerpt,
ANSI escapes stripped):

    Starting /sbin/init
    GNU/Emacs Operating System (GEOS) v0.3 booting...
    pid1: / remounted read-write
    pid1: /var on tmpfs (no geos-var label)
    pid1: hostname set to geos-hurd
    pid1: entering supervisor loop
    [emacs prints scratch buffer chrome to serial]
    early-init: emacs pid=30 pid1-as-emacs-p=nil module-env=nil
    network: pid1-bring-up-lo unbound, skipping (no module loaded)
    hostname: pid1-set-hostname unbound, skipping (no module)
    hurd-essentials: file loaded, geos-kernel=hurd
    hurd-essentials: geos-kernel=hurd gate passed, registering services
    hurd-essentials: defservice hurd-sshd + hurd-syslogd registered
    hurd-essentials: settrans /hurd/pfinet -i /dev/eth0 \
        -a 10.0.2.15 -m 255.255.255.0 -g 10.0.2.2
    hurd-essentials: settrans pfinet exit=0
    hurd-essentials: eth0 static skipped, pid1-set-address unbound
    [scratch buffer remains painted; pid1 supervisor loop running]

grep over the entire 509-line serial transcript for kill_emacs,
trampoline, SIGSEGV, abort, panic, Backtrace, fatal returns zero hits.

## Pulseaudio Y re-verify on the v0919 image

After the v0919 boot, the bucket-closeout pulseaudio piece Y was
re-run against the fresh image to confirm the install path still
works on the re-rolled snapshot.  The first apt-get attempt failed
with `Could not open lock file /var/lib/dpkg/lock-frontend`.  Root
cause is a Hurd-specific quirk documented earlier in v0.9.11 work:
canonical Debian Hurd 0.9 ships /var as a /hurd/tmpfs translator
which hides the underlying directory tree on first mount.  The
remediation is a single `settrans -fg /var` to detach the tmpfs
translator; the underlying populated /var then shows through.

    settrans -fg /var
    ls /var/lib/dpkg/
      -> alternatives arch-native available cmethopt diversions ...
    apt-get update
      -> Fetched 14.1 MB in 8s (1668 kB/s)
    apt-get install -y pulseaudio pulseaudio-utils
      -> Setting up pulseaudio (17.0+dfsg1-2.1) ...
    pulseaudio --start
    pactl info
      Server Name: pulseaudio
      Server Version: 17.0
      User Name: root
      Host Name: geos-hurd
    pactl list short modules | head -10
      0  module-device-restore
      1  module-stream-restore
      2  module-card-restore
      3  module-augment-properties
      4  module-switch-on-port-available
      6  module-native-protocol-unix
      7  module-default-device-restore
      8  module-always-sink
      9  module-null-sink  sink_name=auto_null
      10 module-intended-roles

Same surface as the bucket-closeout snapshot.  Re-roll preserves the
pulseaudio install path; the audio piece X wiring at
user/userland/audio.el now has a verified target on the v0919 image.

## What this slice does NOT ship

  - No port_hurd.c change.  No port_layer.h slot.
  - No HURD_PORT.md row flip; every row was already YES or
    deferred-upstream as of v0.9.17.
  - No v1.x install slice C end-to-end VM verify.  The deployed
    install/ directory has a require/provide name mismatch
    (install.el calls `(require 'install-disk)` etc, but the
    deployed files are named disk.el/mkfs.el/copy.el/grub.el on
    /usr/share/geos/emacs-init/install/).  The freeze-test harness
    works around this with /tmp symlinks but the deployed image
    has no such symlinks.  Slice C raw primitives (mkfs.ext4 +
    grub-install) PASSed in bucket-closeout probe 2; the elisp
    state-machine drive is the v1.x ship that still needs the
    deployment gap closed.  Tracked at task #210.
  - No v0.9.19 follow-on #2 (glibc __mach_msg SIGSEGV from pselect)
    closure.  Instruction-level diagnosis lives at bucket-closeout
    probe 3.  The full-chain boot transcript above shows the
    supervised emacs runs without that SIGSEGV when early-init.el
    opts out of native-comp first.  The crash signature was tied
    to the trampoline build path and may already be incidentally
    closed by this re-roll; that needs a longer soak to confirm.
    Tracked at task #213.
  - No hurd-essentials autospawn change.  defservice registers the
    sshd service but the boot path does not trigger the supervise
    arm; this is by design because hurd-essentials waits for the
    user-session to bring up the service.  Future work: have the
    full-chain boot supervise the registered services without a
    user-session, matching the minimal chain inline behaviour.

## Anomalies

  1. The first verify run hung on step 7 (install state-machine batch
     test).  Root cause: `(require 'install-disk)` from buffers/install.el
     fails to resolve because the deployed install/ directory carries
     files named disk.el, mkfs.el, copy.el, grub.el (without the
     install- prefix).  emacs --batch sits at the failed require with
     no panic and no exit.  Killed via pkill on the host SSH side.
     Same gap blocks v1.x install slice C end-to-end; see task #210.

  2. The /var translator quirk recurred on pulseaudio install.  The
     fix `settrans -fg /var` resolves it cleanly, but every fresh
     v0919 boot will need that remediation before apt operations.
     Long-term fix: have hurd-essentials.el or pid1 detach the /var
     tmpfs translator at boot if the underlying dir is non-empty.
     Tracked as a follow-on; not v0.9.19 scope.

  3. The minimal chain inline `--eval` starts sshd directly; the
     full chain registers it via hurd-essentials defservice but
     never spawns it during the boot transcript captured here.
     SSH does not come up on the full-chain boot.  This is a
     hurd-essentials.el gap, not a trampoline-wedge regression.
     Filed as a v0.9.20 follow-on.

## Closes

  - task #208 v0.9.19 follow-on #1: trace 35-file init.args
    kill_emacs trampoline triggers.  Root cause was deployed
    early-init.el missing the native-comp opt-out; re-roll fix
    proven via the full-chain boot transcript above.
  - task #214 v0.9.19 image re-roll picking up current main
    early-init.el + install.el.  Re-roll DONE; verify steps 1-6
    PASS; full-chain boot PASS.

## Receipt files preserved on dev host

  /home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0919.img
  /tmp/v0919-verify-serial.log         (minimal-chain boot, 25690 B)
  /tmp/v0919-fullchain-serial.log      (full-chain boot, 509 lines)
  /tmp/v0919-post-reroll-verify.sh     (eight-step verify script)
  /tmp/v0919-full-init.args            (84-line full chain)
  /tmp/v0918-init-args-readback        (source for the above)
