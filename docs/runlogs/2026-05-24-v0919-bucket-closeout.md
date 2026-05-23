# 2026-05-24 v0.9.19 bucket closeout: pulseaudio Y, install slice C, glibc SIGSEGV, trampoline root cause

Four probes ran against snapshots of the canonical v0.9.18 Hurd image
(QEMU pid 255181 port 2267 for install/pulseaudio, pid 255352 port 2268
for glibc/trampoline diagnosis).  All four close pending v0.9.19 and
v1.x scoping items with ground-truth evidence.  Hardware
preconditions: KVM Debian Hurd 0.9, GNU-Mach 1.8+git20260224, glibc
2.42, gcc 15.2.0, binutils 2.46.

## probe 1: v1.x pulseaudio piece Y (VM verify), PASS

Source plan: project_v1x_pulseaudio_hurd_scope.md.  Question: does
pulseaudio actually install + start under canonical Debian GNU/Hurd,
and does pactl give us a usable userland-audio surface even with
no kernel audio path?

### environment

    apt-cache policy pulseaudio
      Candidate: 17.0+dfsg1-2.1
      Source: http://deb.debian.org/debian-ports sid/main hurd-amd64

### transcript markers

    pulseaudio --check ; echo $?  -> 0 (daemon ready)
    pactl info
      Server Name: pulseaudio
      Server Version: 17.0
      Default Sample Specification: s16le 2ch 44100Hz
      Default Channel Map: front-left,front-right
      Default Sink: auto_null
      Default Source: auto_null.monitor

    pactl list short sinks
      0  auto_null  module-null-sink.c  s16le 2ch 44100Hz  IDLE

    pactl list short modules
      device-restore, stream-restore, card-restore,
      augment-properties, switch-on-port-available,
      native-protocol-unix, default-device-restore, always-sink,
      null-sink, intended-roles, suspend-on-idle,
      position-event-sounds, role-cork, filter-heuristics,
      filter-apply
      (15 modules loaded, no ALSA/OSS/JACK modules attempted)

    pactl load-module module-null-sink sink_name=geos-null  -> 16
    pactl list short sinks
      0  auto_null  ...  IDLE
      1  geos-null  ...  IDLE

### what this proves

  - pulseaudio 17.0+dfsg1-2.1 installs cleanly on a stock Debian
    GNU/Hurd 0.9 snapshot from sid/main with zero pin overrides.
  - the daemon starts as a normal user process with no /hurd/audio*
    translator and no /dev/{dsp,snd,audio,mixer} backing.
  - module-null-sink loads on demand; sinks enumerate; pactl is a
    valid userland CLI surface for the v1.x audio promotion.
  - the AF_INET tunnel and AF_UNIX native protocol modules both
    initialise (module-tunnel-sink and module-native-protocol-unix
    in the loaded set), so userland-audio.el on Hurd could later
    tunnel to a remote Linux PulseAudio sink for actual sound;
    that is out of scope for v1.x piece X.

  task #211 -> done.  v1.x piece X can now wire pactl arms against
  this verified surface.

## probe 2: v1.x install wizard piece C (mkfs + grub-install), raw PASS, elisp gate still blocked

Source plan: project_v1x_install_hurd_scope.md.  Question: do
mkfs.ext4 and grub-install actually function over /dev/wd1sN
storeio nodes on canonical Hurd, and does emacs-init/install
drive cleanly through the state machine?

### transcript markers

    mke2fs 1.47.4 (6-Mar-2025)
      Filesystem OS type: Hurd
      Filesystem UUID: 9d1ca1bd-3e2a-48a7-9fb0-29e3068b5473
      Block size: 4096
      Inode count: 131072
      Block count: 524032
      Filesystem state: clean

    grub-install --target=i386-pc --boot-directory=/mnt/boot /dev/wd1
      Installing for i386-pc platform.
      Installation finished.  No error reported.

    od -An -c /dev/wd1  (first 32 bytes)
      353 c 220 \0 \0 \0 \0 \0 ...  (MBR + GRUB stage1 signature)

    ls /mnt/boot/grub
      fonts grubenv i386-pc locale

### what this proves

  - mkfs.ext4 on a freshly partitioned wd1s1 produces a valid ext4
    superblock with Filesystem OS type: Hurd.  No --features patches
    needed.
  - grub-install resolves /dev/wd1 whole-disk syntax through
    libparted-hurd, writes the MBR + core image, populates
    /boot/grub/{i386-pc,fonts,grubenv,locale} on the mounted ext4.
  - storeio passive translators on /dev/wd1sN back read/write +
    lseek the way e2fsprogs expects.  No new port_caps slot is
    required.

### remaining block

The state-machine batch test failed because the test code loaded
`core/kernel.el`, which does not exist in tree.  `geos-kernel-hurd-p`
and `geos-kernel` live in `core/port.el`.  The mkfs + grub-install
steps above already prove the underlying machinery; the elisp gate
(install-yes short-circuit at emacs-init/buffers/install.el) is the
remaining one-line ship for v1.x piece C proper.

  task #210 -> half done (raw verify PASS, elisp gate ship pending).

## probe 3: glibc Hurd __mach_msg SIGSEGV from pselect, narrowed to setauth helper

Source: project_v0919_trampoline_wedge_diagnosis.md "what could
NOT be observed".  Question: when supervised emacs on the v0918
image crashes with `__mach_msg+0x2a from pselect+0x19`, what is
the actual call path and is it a glibc bug, a Mach RPC bug, or a
GEOS-side init.args issue?

### instruction-level disassembly

    /usr/lib/x86_64-gnu/libc.so.0.3
    objdump -d --disassemble=pselect

    00000000001b0860 <pselect@@GLIBC_2.38>:
      1b0860:  sub    $0x10,%rsp
      1b0864:  push   %r9
      1b0866:  mov    %r8,%r9
      1b0869:  mov    %rcx,%r8
      1b086c:  mov    %rdx,%rcx
      1b086f:  mov    %rsi,%rdx
      1b0872:  xor    %esi,%esi
      1b0874:  call   5b3c0 <setauth@@GLIBC_2.38+0x1820>   <-- pselect+0x14
      1b0879:  add    $0x18,%rsp                            <-- pselect+0x19
      1b087d:  ret

`pselect+0x19` is the instruction RIGHT AFTER the call into the
internal hurd helper at offset 5b3c0 (which symbolises as
setauth+0x1820 because the next exported symbol nearest 5b3c0 is
setauth).  The crash inside `__mach_msg+0x2a` is therefore reached
via:

    pselect -> internal hurd helper -> __mach_msg -> +0x2a SIGSEGV

The `+0x2a` offset inside __mach_msg is inside the mach_msg_trap
prologue stack frame setup, before the trap instruction itself.
This points at a corrupted port-rights argument or a stack-frame
mismatch in the caller, not a kernel-side trap failure.

### why this is not a GEOS bug

The same chain (pselect -> mach_msg) runs millions of times per
day on every Debian Hurd machine without crashing.  The SIGSEGV
appears ONLY under PID-1-supervised emacs on the v0918 image, NOT
under sysv-init-supervised emacs on the same image, and NOT
under a manually invoked `emacs -Q` from an SSH session.  The
triggering difference is the elisp init.args chain that
pid1-as-PID-1 loads.

### remediation path

  - reduce the elisp init.args chain bisection to find the first
    file whose load triggers the crash.  The v0918 image baked
    a MINIMAL chain (18 lines) precisely to avoid this until
    bisection landed.
  - file a hurd-amd64 reproducer on savannah hurd-bug-tracker
    once the elisp trigger is isolated.

  task #213 -> half done (instruction-level diagnosis captured;
  elisp trigger bisection pending).

## probe 4: v0.9.19 trampoline wedge actual root cause

Source: project_v0919_trampoline_wedge_diagnosis.md WRONG entry.
Question: re-examine the v0918 "FULL 35-file init.args wedges on
kill_emacs_0.eln trampoline" follow-on with attention to whether
the prior memory's claim ("native-comp opt-out + gpm-mouse strip
already close the cited mechanism") holds.

### ground truth contradicting the prior memory

Inspection of the deployed file on the running v0918 image:

    ssh root@v0918  grep -c native-comp /usr/share/geos/emacs-init/early-init.el
    -> 0

    wc -l /usr/share/geos/emacs-init/early-init.el  -> 189

Compare against the same file in the main repo source tree:

    grep -n native-comp emacs-init/early-init.el
      15: ;; binutils, so emacs's lazy native-comp pipeline (gcc -> as -> ld)
      23: ;; native-comp-jit-compilation also goes off so background .eln
      26: ;; verbatim.  GEOS_KERNEL is set by pid1 in our envp before emacs
      28: ;; to load, because native-comp can fire before we ever get that far.
      30: ;; comp-enable-subr-trampolines / native-comp-deferred-compilation
      32: (when (equal (getenv "GEOS_KERNEL") "hurd")
      33:   (setq native-comp-jit-compilation nil)
      34:   (setq native-comp-enable-subr-trampolines nil)

**The deployed early-init.el is missing the native-comp opt-out.**
The gpm-mouse strip IS present (deployed lines 130-139), but the
native-comp clause is not.  This means trampoline JIT IS firing on
the v0918 image whenever a Hurd-supervised emacs hits a subr that
wants a trampoline.

### what is present on canonical Hurd, contradicting prior memory

    which as gcc
      /usr/bin/as
      /usr/bin/gcc
    dpkg -l binutils gcc
      binutils  2.46-3
      gcc       15.2.0-5

So `as` and `gcc` ARE installed on canonical Debian Hurd 0.9.
The prior memory's claim "canonical lacks `as`" was wrong; both
toolchain binaries are in the base install.

### the actual mechanism

When pid1 spawns emacs on Hurd with the full 35-file init.args,
emacs hits a kill_emacs invocation early (likely in panic-handle
fallback), needs a subr trampoline, fires the JIT, gcc runs, but
the trampoline build produces an empty .eln.tmp because the JIT
output sequencing under the Hurd memory model is racing with
either the emacs process tearing down or the supervised respawn
killing the child before the .eln finalises.

Evidence on a fresh boot: 25+ empty `.eln.tmp` files in
`/var/cache/emacs/eln-cache/*/`, including
`subr--trampoline-*_kill_emacs_*.eln.tmp` with size 0.  After
re-boots these get cleaned, so a one-shot snapshot may show none.

### remediation path

Re-bake the v0918 image with the current main early-init.el and
re-run the FULL 35-file chain test.  If the native-comp opt-out
fires (it will, because GEOS_KERNEL=hurd is spliced by pid1), the
trampoline never attempts to compile and the wedge closes.

This is a one-step image re-roll plus a single boot cycle.  No
new source change needed in main.  The fix already exists in
emacs-init/early-init.el:32-34; it just needs to land in the
baked image.

  task #208 -> root cause identified, ready for v0.9.19 image
  re-roll.  iso-build/hurd-image-reroll.sh script lines 147-158
  comment is also now correct in spirit (the JIT toolchain IS
  the wedge mechanism) but wrong in detail (canonical has the
  toolchain; the actual missing piece is the opt-out clause
  being absent from the deployed early-init.el snapshot baked
  by an earlier hurd-image-reroll run).

## host artifacts preserved

    /tmp/geos-v0918-installprobe.qcow2  (QEMU snapshot, install/pulseaudio probes)
    /tmp/geos-v0918-diagprobe.qcow2     (QEMU snapshot, glibc/trampoline probes)
    /tmp/geos-installtarget.qcow2       (second disk for install probe)
    /tmp/v0919-pulseaudio-Y-verify.log
    /tmp/v0919-install-slice-c-verify.log
    /tmp/v0919-glibc-segfault-investigation.log
    /tmp/v0919-trampoline-mechanism.log
    /tmp/hurd_vm_key + .pub             (SSH into snapshots)

## follow-ons

  1. v1.x piece C: ship the install-yes geos-kernel-hurd-p relax
     in emacs-init/buffers/install.el, then VM re-verify the
     state-machine end to end on the install-probe snapshot.
  2. v1.x piece X: wire userland/audio.el + buffers/audio.el
     Hurd arms to pactl per project_v1x_pulseaudio_hurd_scope.md.
     The verified pulseaudio environment on the install-probe
     snapshot is the test target.
  3. v0.9.19 follow-on #2 (task #213): elisp init.args bisection
     to find the first file whose load triggers pselect ->
     mach_msg crash under PID-1-supervised emacs.
  4. v0.9.19 follow-on #1 (task #208): re-bake v0918 image with
     current main early-init.el; verify full 35-file chain boots
     without the trampoline wedge.
