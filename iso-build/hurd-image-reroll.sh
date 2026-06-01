#!/bin/sh
# hurd-image-reroll.sh -- bake pid1 + supervisor tree + serial GRUB +
# ssh key into a derivative of the pristine canonical Debian GNU/Hurd
# 0.9 image, so future verify cycles can boot a single artifact and get
# an SSH-able supervised emacs without the 30-minute per-cycle setup
# tax (the v0.9.11 install/hurd-bootstrap.sh recipe).
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Borja Tarraso <borja.tarraso@member.fsf.org>
#
# WHY this exists: v0.9.16 cold-boot and v0.9.17 syslog-tail verifies
# both noted the same friction. the pristine canonical image ships
# stock Debian sysv init, no ssh key for root, and a GRUB cfg whose
# `terminal_output gfxterm` line silently kills serial console after
# "Welcome to GRUB!". every verify cycle has been re-doing the same
# four mutations by hand (or by the install/hurd-bootstrap.sh script,
# which runs IN the booted VM and so doesn't help the very-first-boot
# observability problem). this script does the mutations OFFLINE via
# guestfish, against a copy of the pristine base. the pristine stays
# read-only; the output is a derivative that's ready to boot.
#
# INPUTS (env-overridable):
#   PRISTINE_IMG  pristine canonical base, treated read-only
#                 default: /home/overdrive/hurd-vm/debian-hurd-amd64-20260314.pre-pid1.img
#   PID1_BIN      STATIC=1 v0.9.12+ pid1 binary (extracted from the
#                 v0.9.16 work qcow2 via scp; see staging step in this
#                 file's docstring header)
#                 default: /tmp/v0918-reroll-staging/emacs-init
#   SUPERVISOR_TAR  gzipped tar of the emacs-init/ tree, root entry
#                 must be emacs-init/ (one level)
#                 default: /tmp/v0918-reroll-staging/emacs-init-tree.tar.gz
#   SSH_PUBKEY    public key to authorize for root
#                 default: /tmp/hurd_vm_key.pub
#   OUTPUT_IMG    rerolled image written here, IDEMPOTENT (rm -f first).
#                 since v0.9.21 this is a qcow2 OVERLAY whose backing
#                 file is PRISTINE_IMG.  the extension stays .img so
#                 downstream tooling does not need updating; QEMU
#                 auto-detects qcow2 by magic bytes.
#                 default: /home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0918.img
#   SMOKE         opt-out for the step 7 boot smoke gate.  default "1"
#                 (on); set SMOKE=0 to skip the ~3-minute throwaway boot.
#   SMOKE_TIMEOUT_S  deadline for the smoke gate (default 240).
#   SMOKE_PORT    host port for the smoke gate's hostfwd (default 2299,
#                 chosen to not collide with operator's 2266 manual boot).
#   FLAVOR        image flavor to produce.  default "minimal" (the v0.9.22
#                 canonical 35-file chain; byte-identical to prior behavior;
#                 OUTPUT_IMG path unchanged from before this knob existed).
#                 the other accepted value is "apt-image", which produces a
#                 v1.x apt-image flavor: same baked artifacts as minimal,
#                 PLUS a post-step-7 boot pass that ssh's in and apt-installs
#                 the EXWM-on-Xvfb stack (xvfb, emacs-lucid, elpa-exwm,
#                 elpa-xelb) and pulseaudio.  the apt-image output lands at
#                 a separate path so the minimal artifact stays untouched;
#                 see APT_OUTPUT_IMG below.  unknown FLAVOR values fail
#                 fast in step 1.
#   APT_OUTPUT_IMG  when FLAVOR=apt-image, the apt-image flavor lands here.
#                 default: /home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0922-apt.img
#                 this is a fresh qcow2 overlay over PRISTINE_IMG built
#                 alongside OUTPUT_IMG so the minimal artifact is not
#                 disturbed (a re-run with FLAVOR=apt-image still ships
#                 the minimal one too).  ignored when FLAVOR=minimal.
#   APT_PORT      host port for the apt-install boot's hostfwd (default 2298,
#                 chosen to not collide with smoke's 2299 or operator's 2266).
#   APT_TIMEOUT_S  deadline for the apt-install ssh wait (default 300).
#
# OUTPUT:
#   $OUTPUT_IMG  rerolled Debian GNU/Hurd 0.9 image with:
#     - GRUB serial output enabled (terminal_output serial console,
#       baud 115200, and console=com0 on every multiboot gnumach line)
#     - /root/.ssh/authorized_keys with the supplied pubkey, 0600
#     - /sbin/init replaced with the STATIC pid1; original saved at
#       /sbin/init.debian-stock for forensics
#     - /etc/geos/init.args populated for the Hurd boot chain (no
#       pid1-module.so slot since STATIC=1 builds inline the supervisor
#       primitives the module would expose; init.args slot 2 is a
#       non-absolute placeholder so pid1's `argv[2][0] == '/'` check
#       short-circuits the module load)
#     - /usr/share/geos/emacs-init/ populated from the tarball
#     - /root/.emacs.d/early-init.el symlink to the staged tree
#       (v0.9.12 slice 6 ground-truth: -Q skips early-init.el load)
#
# NOTE on guestfish inspector: libguestfs's `-i` (inspect) probes
# typical Linux/BSD device names and chokes on Hurd's wd0sN naming
# scheme. we use explicit `--mount /dev/sda2:/` everywhere instead.
# /dev/sda1 is swap, /dev/sda2 is ext2 root; verified via virt-filesystems.
#
# this is install tooling, NOT pid1 code. shell usage is fine here.
# the script must still work under dash, so no bashisms.
#
# usage:
#   ./iso-build/hurd-image-reroll.sh
#   PRISTINE_IMG=/path/to/base.img OUTPUT_IMG=/path/to/out.img \
#     ./iso-build/hurd-image-reroll.sh

set -eu

PRISTINE_IMG="${PRISTINE_IMG:-/home/overdrive/hurd-vm/debian-hurd-amd64-20260314.pre-pid1.img}"
PID1_BIN="${PID1_BIN:-/tmp/v0918-reroll-staging/emacs-init}"
SUPERVISOR_TAR="${SUPERVISOR_TAR:-/tmp/v0918-reroll-staging/emacs-init-tree.tar.gz}"
SSH_PUBKEY="${SSH_PUBKEY:-/tmp/hurd_vm_key.pub}"
OUTPUT_IMG="${OUTPUT_IMG:-/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0918.img}"
FLAVOR="${FLAVOR:-minimal}"
APT_OUTPUT_IMG="${APT_OUTPUT_IMG:-/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0922-apt.img}"
APT_PORT="${APT_PORT:-2298}"
APT_TIMEOUT_S="${APT_TIMEOUT_S:-300}"

# log prefix on every line so the operator can grep the run for
# [hurd-image-reroll] and see exactly what happened, in order.
log() {
    printf '[hurd-image-reroll] %s\n' "$*"
}

# gf: thin alias for guestfish --remote.  used once the --listen
# daemon is up (step 3c).  one libguestfs appliance launch amortises
# across the whole script instead of paying ~15 s per guestfish
# invocation; with 3 invocations previously, this is ~30 s saved per
# re-roll cycle and a cleaner mutation flow (every gf line is one
# verb, no HEREDOC quoting gotchas).
gf() {
    guestfish --remote -- "$@"
}

###############################################################################
# step 1: input sanity
###############################################################################
log "step 1: input sanity"
for f in "${PRISTINE_IMG}" "${PID1_BIN}" "${SUPERVISOR_TAR}" "${SSH_PUBKEY}"; do
    if [ ! -f "${f}" ]; then
        log "FATAL: input missing: ${f}"
        exit 1
    fi
done

# guestfish must be present; we use it for every mutation. fail fast
# if the host doesn't have libguestfs-tools installed.
if ! command -v guestfish >/dev/null 2>&1; then
    log "FATAL: guestfish not on PATH (apt install libguestfs-tools)"
    exit 1
fi

# qemu-img is the qcow2 overlay constructor (step 2).  qemu-system-x86_64
# is the optional smoke gate (step 7).  fail fast on the constructor;
# smoke gate handles its own missing-binary case (SKIP if absent).
if ! command -v qemu-img >/dev/null 2>&1; then
    log "FATAL: qemu-img not on PATH (apt install qemu-utils)"
    exit 1
fi

PID1_SIZE="$(stat -c '%s' "${PID1_BIN}")"
PID1_SHA="$(sha256sum "${PID1_BIN}" | cut -d' ' -f1)"
TAR_SHA="$(sha256sum "${SUPERVISOR_TAR}" | cut -d' ' -f1)"
log "pid1 binary: ${PID1_BIN} (${PID1_SIZE} bytes, sha256=${PID1_SHA})"
log "supervisor tar: ${SUPERVISOR_TAR} (sha256=${TAR_SHA})"
log "pristine base: ${PRISTINE_IMG}"
log "output target: ${OUTPUT_IMG}"

# FLAVOR gate.  minimal is the historical default and is byte-identical
# to the pre-knob behavior.  apt-image is the v1.x flavor that bundles
# the EXWM-on-Xvfb stack and pulseaudio via a post-smoke apt pass.
# anything else is a typo, fail fast before paying for the qcow2 + bake.
case "${FLAVOR}" in
    minimal|apt-image) : ;;
    *)
        log "FATAL: unknown FLAVOR=${FLAVOR} (expected minimal or apt-image)"
        exit 1
        ;;
esac
log "flavor: ${FLAVOR}"
if [ "${FLAVOR}" = "apt-image" ]; then
    log "apt-image output target: ${APT_OUTPUT_IMG}"
fi

###############################################################################
# step 2: qcow2 overlay on top of pristine (idempotent)
###############################################################################
# WAS a 4 GB cp (~30-60s on ext4, ~1s on reflink-capable fs).  NOW a
# qcow2 overlay whose backing-file is the pristine.  pristine stays
# read-only; mutations land in the overlay only.  initial overlay file
# is ~200 KB; grows to a few hundred MB as guestfish mutates blocks.
# typical end-of-run size is ~50-200 MB vs the previous 4 GB.
# qemu-img create is ~10 ms.
#
# tradeoff: the overlay embeds an absolute path to the backing file.
# moving PRISTINE_IMG after re-roll breaks OUTPUT_IMG (it'll fail
# at QEMU open with "Could not open backing file").  if you relocate
# the pristine, re-run this script.
#
# file extension stays .img so existing downstream tooling that
# references ${OUTPUT_IMG} (hurd-fast-iterate.sh, operator boot
# commands) keeps working.  QEMU auto-detects qcow2 by magic bytes;
# the "next:" message at end-of-script prints an explicit
# format=qcow2 to make it unambiguous.
#
# rm -f first so a re-run starts from a clean overlay; otherwise
# qemu-img would refuse to overwrite an existing file.
log "step 2: qcow2 overlay ${OUTPUT_IMG} -> ${PRISTINE_IMG}"
rm -f "${OUTPUT_IMG}"
qemu-img create -q -f qcow2 -F raw -b "${PRISTINE_IMG}" "${OUTPUT_IMG}" >/dev/null
log "overlay done; ${OUTPUT_IMG} ($(stat -c '%s' "${OUTPUT_IMG}") bytes initial, backing=${PRISTINE_IMG})"

###############################################################################
# step 3: stage temp files for guestfish upload
###############################################################################
# guestfish's `upload` verb takes a host path and a guest path, but
# can't take inline content. so we materialize init.args, the patched
# grub.cfg, and the unpacked supervisor tree on the host first, then
# upload from there. STAGING_DIR is per-run so concurrent re-rolls don't
# collide (though the script's qcow2-level invariant is single-writer).
STAGING_DIR="$(mktemp -d /tmp/hurd-image-reroll-stage.XXXXXX)"
# trap installed in step 3c after the guestfish daemon is up, so the
# single trap can tear both down in one go (daemon first via gf exit,
# then staging dir).
log "step 3: staging dir ${STAGING_DIR}"

# unpack the supervisor tree. the tarball's root entry must be
# emacs-init/ (one level), so after unpack we have
# ${STAGING_DIR}/emacs-init/{core,buffers,services,user,install}/...
tar xzf "${SUPERVISOR_TAR}" -C "${STAGING_DIR}"
if [ ! -d "${STAGING_DIR}/emacs-init" ]; then
    log "FATAL: tarball did not unpack a top-level emacs-init/ dir"
    exit 1
fi
SUPERVISOR_FILES="$(find "${STAGING_DIR}/emacs-init" -type f | wc -l)"
log "unpacked ${SUPERVISOR_FILES} files under ${STAGING_DIR}/emacs-init"

# build init.args. v0.9.18 carries no /usr/lib/geos/pid1-module.so
# because STATIC=1 pid1 inlines the supervisor primitives the module
# would have dlopen'd. slot 2 (`:`) is a non-absolute string so pid1's
# `argv[2][0] == '/'` test fails and module_env stays NULL.
# slot 3 (`:`) same trick for the xorg spec, which keeps X disabled
# until a future v1.x image flavor adds xvfb.
#
# v0.9.18 ships a MINIMAL chain (not the full 35-file -l set).  the
# canonical chain (panic + port + cmdline + state + supervise + ...
# through hurd-essentials + install/* + boot-marker, ~35 files) wedges
# the supervised emacs on the first pid1-as-real-PID-1 boot via the
# kill_emacs_0.eln trampoline build path (the canonical image has no
# `as` so emacs cannot finish the trampoline write and exits).  the
# v0.9.17 syslog verify masked this because its snapshot ran sysv-init
# at PID 1, not pid1.  this minimal variant proves the rerolled image
# boots end-to-end (pid1 -> emacs -> settrans pfinet -> sshd reachable
# via QEMU SLIRP host-forward).  closing the wedge so the full chain
# can ship is the v0.9.19 follow-on; the discovery transcript lives at
# /tmp/v0918-rerolled-first-boot-serial.log and the v0.9.18 receipt.
###############################################################################
# step 3b: pre-generate sshd host keys
###############################################################################
# WHY pre-generation matters: the v0.9.18 minimal-to-SSH init.args (see
# step 3 below) execs `sshd -D -e`, which fails fast with "Could not
# load host key" if /etc/ssh/ssh_host_*_key is absent.  the canonical
# Debian Hurd image relies on a first-boot sysv-init script to run
# ssh-keygen -A; under pid1-as-real-PID-1 that script never runs, so
# the very first boot races sshd against a key set that does not exist
# yet.  baking the keys in OFFLINE makes the produced image deterministic
# (same image, same fingerprints, every re-roll cycle), removes the
# race, and lets the rerolled image come up ssh-able on cycle 1.
#
# i generate the standard sshd triple (rsa-3072, ecdsa-256, ed25519);
# this matches what `ssh-keygen -A` would produce on a stock Debian box.
# all three private keys land at 0600 root:root, all three public keys
# at 0644 root:root, under /etc/ssh/ inside the guest.
log "step 3b: pre-generate sshd host keys (rsa + ecdsa + ed25519)"
for kt in rsa ecdsa ed25519; do
    kf="${STAGING_DIR}/ssh_host_${kt}_key"
    case "${kt}" in
        rsa)     ssh-keygen -q -t rsa     -b 3072 -N '' -C "root@geos-hurd" -f "${kf}" ;;
        ecdsa)   ssh-keygen -q -t ecdsa   -b 256  -N '' -C "root@geos-hurd" -f "${kf}" ;;
        ed25519) ssh-keygen -q -t ed25519        -N '' -C "root@geos-hurd" -f "${kf}" ;;
    esac
    if [ ! -f "${kf}" ] || [ ! -f "${kf}.pub" ]; then
        log "FATAL: ssh-keygen did not produce ${kf}{,.pub}"
        exit 1
    fi
    log "  generated ${kt} host key: $(ssh-keygen -lf "${kf}.pub" | awk '{print $2}')"
done

cat > "${STAGING_DIR}/init.args" <<'INIT_ARGS_EOF'
# /etc/geos/init.args -- v0.9.22 canonical 35-file Hurd boot chain
# pid1 reads this when the kernel hands us argc==1 (/hurd/startup).
# one arg per line; blanks and '#' lines are ignored.
#
# slot 2 = `:` because the STATIC=1 pid1 build (Makefile EMACS_INIT_STATIC=1)
# inlines pid1-module.o into the emacs-init binary itself; there is no
# .so on disk to dlopen.  the pid1 cmdline parser treats `:` as "skip
# this slot, no module path".  for the dynamic build, slot 2 would be
# /usr/lib/geos/pid1-module.so.
#
# slot 3 = `:` because Xorg is opt-in and disabled by default.  if the
# operator does `apt install xvfb` then edits this slot to the Xvfb
# command, pid1's x-display.el will spawn and supervise it.
#
# slot 4+ becomes the emacs argv after pid1 forks into emacs.
# --no-site-file/--no-splash/--no-site-lisp drop the three Debian-stock
# behaviours that interfere with PID 1 boot (no /etc/emacs/site-start
# files, no graphical splash on the tty, no /usr/share/emacs/site-lisp
# path additions).  we do NOT pass --no-init-file because early-init.el
# is load-bearing for the native-comp opt-out -- without it, tty-setup-
# hook fires gpm-mouse-mode which triggers a trampoline build, gcc looks
# for as(1), wedges if missing.  v0.9.19 + v0.9.20 confirmed canonical
# Debian Hurd 0.9 ships gcc 15.2.0 + binutils 2.46 so the trampoline
# build CAN succeed, but the opt-out is still required because each
# build adds ~3 s to boot per .el file touched at load time.
/usr/bin/emacs
:
:
--no-site-file
--no-splash
--no-site-lisp
-l
/usr/share/geos/emacs-init/core/panic.el
-l
/usr/share/geos/emacs-init/core/port.el
-l
/usr/share/geos/emacs-init/core/cmdline.el
-l
/usr/share/geos/emacs-init/core/state.el
-l
/usr/share/geos/emacs-init/core/supervise.el
-l
/usr/share/geos/emacs-init/core/power.el
-l
/usr/share/geos/emacs-init/core/use-package-shim.el
-l
/usr/share/geos/emacs-init/core/network.el
-l
/usr/share/geos/emacs-init/core/hostname.el
-l
/usr/share/geos/emacs-init/core/passwd.el
-l
/usr/share/geos/emacs-init/core/session.el
-l
/usr/share/geos/emacs-init/core/x-display.el
-l
/usr/share/geos/emacs-init/core/rpc-server.el
-l
/usr/share/geos/emacs-init/buffers/network.el
-l
/usr/share/geos/emacs-init/buffers/processes.el
-l
/usr/share/geos/emacs-init/buffers/journal.el
-l
/usr/share/geos/emacs-init/buffers/services.el
-l
/usr/share/geos/emacs-init/buffers/disks.el
-l
/usr/share/geos/emacs-init/buffers/packages.el
-l
/usr/share/geos/emacs-init/buffers/reconfigure.el
-l
/usr/share/geos/emacs-init/buffers/users.el
-l
/usr/share/geos/emacs-init/buffers/login.el
-l
/usr/share/geos/emacs-init/services/journal-tail.el
-l
/usr/share/geos/emacs-init/services/dhcp.el
-l
/usr/share/geos/emacs-init/services/hurd-essentials.el
-l
/usr/share/geos/emacs-init/install/disk.el
-l
/usr/share/geos/emacs-init/install/mkfs.el
-l
/usr/share/geos/emacs-init/install/copy.el
-l
/usr/share/geos/emacs-init/install/grub.el
-l
/usr/share/geos/emacs-init/buffers/install.el
-l
/usr/share/geos/emacs-init/core/boot-marker.el
INIT_ARGS_EOF
log "init.args staged ($(wc -l < "${STAGING_DIR}/init.args") lines, full v0.9.22 35-file chain)"

###############################################################################
# step 3c: start guestfish --listen daemon, mount once
###############################################################################
# WHY: the previous flow launched guestfish 3 separate times (step 4
# read pristine grub.cfg; step 5 mutated output image; step 6 read-only
# verified).  each launch pays ~15 s appliance spin-up.  --listen mode
# starts the daemon once, exports GUESTFISH_PID, and lets every later
# call use `gf` (= guestfish --remote --) to talk to the same appliance
# at microsecond cost.
#
# step 4 used to read grub.cfg from PRISTINE_IMG.  the qcow2 overlay
# from step 2 is byte-identical to pristine until step 5 mutations
# land, so reading grub.cfg from OUTPUT_IMG before step 5 yields the
# same bytes.  this lets one daemon serve all three steps.
#
# the trap fires on any exit path (success, error, signal) so the
# daemon never leaks.  `gf exit 2>/dev/null || true` because if the
# daemon already exited cleanly, --remote will error and we don't
# care.
log "step 3c: start guestfish --listen daemon over ${OUTPUT_IMG}"
eval "$(guestfish --listen)"
if [ -z "${GUESTFISH_PID:-}" ]; then
    log "FATAL: guestfish --listen did not export GUESTFISH_PID"
    exit 1
fi
trap 'rm -rf "${STAGING_DIR}"; gf exit 2>/dev/null || true' EXIT
log "guestfish daemon pid=${GUESTFISH_PID}"

gf add "${OUTPUT_IMG}"
gf run
gf mount /dev/sda2 /

###############################################################################
# step 4: extract pristine GRUB cfg (via overlay), patch it
###############################################################################
# pristine grub.cfg has two problems we have to fix for serial verifies:
#   a) `terminal_output gfxterm` swallows the boot menu and kernel
#      log into a framebuffer that QEMU's -nographic can't read.
#   b) the multiboot gnumach lines lack `console=com0`, so even if
#      GRUB itself ends up on serial, gnumach writes to vga and the
#      hand-off transcript stops at the GRUB menu.
log "step 4: extract + patch GRUB cfg (via overlay, pre-mutation)"
gf download /boot/grub/grub.cfg "${STAGING_DIR}/grub.cfg.orig"

# patch a: prepend `serial --unit=0 --speed=115200` and replace
# `terminal_output gfxterm` with `terminal_output serial console`.
# `console` keeps a vga fallback in case someone boots this image
# with a real display; `serial` puts it on com0 for our QEMU runs.
sed -e 's|^terminal_output gfxterm$|serial --unit=0 --speed=115200\nterminal_output serial console|' \
    "${STAGING_DIR}/grub.cfg.orig" > "${STAGING_DIR}/grub.cfg.step1"

# patch b: every multiboot line that loads gnumach gets `console=com0`
# appended. the existing line has a trailing space (one or two), then
# whatever -s recovery flags follow. we match the gnumach-amd64-up.gz
# path explicitly so we don't accidentally rewrite some future entry
# that loads a different kernel.  the regex allows one OR two tab
# indents because the main menuentry sits at tab-depth 1 while the
# advanced-submenu entries sit at tab-depth 2.  the alternation in a
# basic ERE keeps GNU sed happy without -E.
sed -E -e 's|^(\t{1,2}multiboot\t/boot/gnumach-1.8-amd64-up.gz root=part:2:device:wd0)(.*)$|\1 console=com0\2|' \
    "${STAGING_DIR}/grub.cfg.step1" > "${STAGING_DIR}/grub.cfg"

# sanity-check the patches landed. if either expected substring is
# absent, fail rather than silently produce a broken image.
if ! grep -q '^terminal_output serial console$' "${STAGING_DIR}/grub.cfg"; then
    log "FATAL: terminal_output patch did not apply"
    exit 1
fi
if ! grep -q 'console=com0' "${STAGING_DIR}/grub.cfg"; then
    log "FATAL: console=com0 patch did not apply"
    exit 1
fi
GRUB_DELTA="$(diff -u "${STAGING_DIR}/grub.cfg.orig" "${STAGING_DIR}/grub.cfg" | wc -l)"
log "grub.cfg patched (${GRUB_DELTA}-line unified diff)"

###############################################################################
# step 5: drive guestfish to mutate the output image
###############################################################################
# all mutations run in ONE guestfish session so we pay the libguestfs
# spin-up cost once. ordering matters:
#   1. backup /sbin/init -> /sbin/init.debian-stock (only on first run;
#      a re-run would otherwise overwrite the real Debian init with our
#      previous pid1, breaking the rescue path).  the script is invoked
#      against a fresh-from-pristine copy in step 2, so this is always
#      the first-run path here.
#   2. upload new /sbin/init from PID1_BIN
#   3. upload patched grub.cfg
#   4. mkdir /root/.ssh + upload authorized_keys + chmod
#   5. mkdir /etc/geos + upload init.args + chmod
#   6. mkdir /usr/share/geos + tar-in the supervisor tree
#   7. mkdir /root/.emacs.d + symlink early-init.el
#   8. upload pre-generated sshd host keys into /etc/ssh/, perms 0600/0644
log "step 5: gf mutate ${OUTPUT_IMG} via daemon pid=${GUESTFISH_PID}"

# 5.1: backup /sbin/init. the rm -f in step 2 guarantees we're working
# on a fresh copy of the pristine, where /sbin/init is the stock
# Debian binary and /sbin/init.debian-stock does NOT exist yet. so
# the mv is unconditional; no re-run safety branch needed here, because
# the re-run safety lives at the qcow2-overwrite level (step 2 rm -f).
gf mv /sbin/init /sbin/init.debian-stock

# 5.2: drop new /sbin/init
gf upload "${PID1_BIN}" /sbin/init
gf chmod 0755 /sbin/init

# 5.3: patched grub.cfg in place
gf upload "${STAGING_DIR}/grub.cfg" /boot/grub/grub.cfg
gf chmod 0644 /boot/grub/grub.cfg

# 5.4: root ssh key. mkdir-p is a no-op if the dir exists; chmod after
# to enforce 0700 / 0600 regardless of umask the guest happens to honor.
gf mkdir-p /root/.ssh
gf upload "${SSH_PUBKEY}" /root/.ssh/authorized_keys
gf chmod 0600 /root/.ssh/authorized_keys
gf chmod 0700 /root/.ssh
gf chown 0 0 /root/.ssh
gf chown 0 0 /root/.ssh/authorized_keys

# 5.5: init.args
gf mkdir-p /etc/geos
gf upload "${STAGING_DIR}/init.args" /etc/geos/init.args
gf chmod 0644 /etc/geos/init.args
gf chown 0 0 /etc/geos/init.args

# 5.6: supervisor tree under /usr/share/geos/emacs-init/. tar-in
# streams the tarball into the named guest directory. the tarball's
# root entry is emacs-init/, so we extract into /usr/share/geos/
# and the result lands at /usr/share/geos/emacs-init/.
gf mkdir-p /usr/share/geos
gf tar-in "${SUPERVISOR_TAR}" /usr/share/geos/ compress:gzip

# 5.7: symlink early-init.el into /root/.emacs.d/ so the supervised
# emacs picks it up BEFORE tty-setup-hook fires. see v0.9.12 slice 6.
gf mkdir-p /root/.emacs.d
gf ln-sf /usr/share/geos/emacs-init/early-init.el /root/.emacs.d/early-init.el

# 5.8: pre-generated sshd host keys.  mkdir-p /etc/ssh because on a
# minimal canonical image the dir may exist already (openssh-server is
# in the base), but i don't want to depend on that.  perms enforced
# explicitly per key after upload: 0600 for the private halves, 0644
# for the public halves, root:root everywhere.  see step 3b for the
# rationale on baking these in offline.
gf mkdir-p /etc/ssh
for kt in rsa ecdsa ed25519; do
    gf upload "${STAGING_DIR}/ssh_host_${kt}_key"     "/etc/ssh/ssh_host_${kt}_key"
    gf upload "${STAGING_DIR}/ssh_host_${kt}_key.pub" "/etc/ssh/ssh_host_${kt}_key.pub"
    gf chmod 0600 "/etc/ssh/ssh_host_${kt}_key"
    gf chmod 0644 "/etc/ssh/ssh_host_${kt}_key.pub"
    gf chown 0 0  "/etc/ssh/ssh_host_${kt}_key"
    gf chown 0 0  "/etc/ssh/ssh_host_${kt}_key.pub"
done

log "step 5 complete"

###############################################################################
# step 6: post-mutation verification (offline, no boot yet)
###############################################################################
# spot-check the artifacts. if any of these probes fail the image is
# unbootable for our purposes and we want to know NOW, not after a
# 4-minute QEMU boot timeout.
log "step 6: post-mutation verification"
# the verify pass downloads init.args + grub.cfg + authorized_keys to
# the host and greps there; the guestfish `sh` verb runs commands
# inside the appliance which makes quoting fragile when the body
# contains tabs or single quotes.  do the inspection where we have
# decent tools.
VERIFY_TMP="$(mktemp -d /tmp/hurd-image-reroll-verify.XXXXXX)"
# uses the same --listen daemon from step 3c; the daemon was opened
# read-write but we're done mutating, so the remaining ops are reads.
# `ll` and `ls` are diagnostic-only here; their stdout goes to the
# operator log so a forensic re-roll can be grepped after the fact.
echo "--- /sbin/init ---";                              gf ll /sbin/init
echo "--- /sbin/init.debian-stock ---";                 gf ll /sbin/init.debian-stock
echo "--- /etc/geos/init.args (stat) ---";              gf ll /etc/geos/init.args
echo "--- /root/.ssh/authorized_keys (stat) ---";       gf ll /root/.ssh/authorized_keys
echo "--- /usr/share/geos/emacs-init (top dirs) ---";   gf ls /usr/share/geos/emacs-init
echo "--- /root/.emacs.d/early-init.el (stat) ---";     gf ll /root/.emacs.d/early-init.el
echo "--- /etc/ssh/ssh_host_*_key* (stat) ---"
for kt in rsa ecdsa ed25519; do
    gf ll "/etc/ssh/ssh_host_${kt}_key"
    gf ll "/etc/ssh/ssh_host_${kt}_key.pub"
done
gf download /boot/grub/grub.cfg                   "${VERIFY_TMP}/grub.cfg"
gf download /etc/geos/init.args                   "${VERIFY_TMP}/init.args"
gf download /root/.ssh/authorized_keys            "${VERIFY_TMP}/authorized_keys"
gf download /etc/ssh/ssh_host_rsa_key.pub         "${VERIFY_TMP}/ssh_host_rsa_key.pub"
gf download /etc/ssh/ssh_host_ecdsa_key.pub       "${VERIFY_TMP}/ssh_host_ecdsa_key.pub"
gf download /etc/ssh/ssh_host_ed25519_key.pub     "${VERIFY_TMP}/ssh_host_ed25519_key.pub"
# done with the daemon; trap cleanup will SIGTERM it via `gf exit`,
# but explicit shutdown here frees the appliance before step 7 starts
# its own QEMU.  ignore errors in case the daemon already died.
gf umount-all || true
gf exit 2>/dev/null || true
log "verify: GRUB serial line + first multiboot:"
# literal tab byte for the regex; POSIX grep doesn't honor \t.
TAB="$(printf '\t')"
grep -E '^(serial|terminal_output)' "${VERIFY_TMP}/grub.cfg" | sed 's/^/    /'
grep -E "^${TAB}{1,2}multiboot.*gnumach" "${VERIFY_TMP}/grub.cfg" | sed 's/^/    /'
MB_TOTAL="$(grep -cE "^${TAB}{1,2}multiboot.*gnumach" "${VERIFY_TMP}/grub.cfg")"
MB_PATCHED="$(grep -cE "^${TAB}{1,2}multiboot.*gnumach.*console=com0" "${VERIFY_TMP}/grub.cfg")"
log "verify: ${MB_PATCHED}/${MB_TOTAL} multiboot lines carry console=com0"
if [ "${MB_PATCHED}" != "${MB_TOTAL}" ]; then
    log "WARNING: some multiboot lines were not patched (re-run from rescue if a recovery boot is needed)"
fi
log "verify: init.args first slot:"
grep -v '^#' "${VERIFY_TMP}/init.args" | grep -v '^$' | head -1 | sed 's/^/    /'
log "verify: authorized_keys fingerprint:"
ssh-keygen -lf "${VERIFY_TMP}/authorized_keys" 2>&1 | sed 's/^/    /'
log "verify: sshd host key fingerprints (rsa + ecdsa + ed25519):"
for hk in ssh_host_rsa_key.pub ssh_host_ecdsa_key.pub ssh_host_ed25519_key.pub; do
    ssh-keygen -lf "${VERIFY_TMP}/${hk}" 2>&1 | sed 's/^/    /'
done
rm -rf "${VERIFY_TMP}"

###############################################################################
# step 7: boot smoke gate (opt-out via SMOKE=0)
###############################################################################
# WHY: v0.9.20 re-roll burned ~30 minutes on a silent rumpdisk wd0
# enumeration race -- gnumach loaded, ext2fs.static printed
# `ext2fs: part:2:device:wd0: No such device or address`, and the
# boot wedged with no further output.  zero indication from the
# re-roll script that the artifact was broken.  fix: boot the
# rerolled image in a throwaway QEMU for up to SMOKE_TIMEOUT_S
# (default 240s), tail the serial log, fail fast on the known FAIL
# substring and exit 0 on a PASS marker proving the init.args eval
# fired.  pass means the full chain works: GRUB -> gnumach loaded
# -> wd0 enumerated -> ext2fs root mounted -> pid1 ran -> emacs
# spawned -> init.args eval reached.
#
# opt-out is for cycles where the operator wants the artifact
# without paying the ~3-minute smoke cost (e.g. iterating offline
# changes only).  set SMOKE=0 to skip; SMOKE_TIMEOUT_S overrides
# the deadline; SMOKE_PORT (default 2299) avoids colliding with
# the operator's manual boot on 2266.
SMOKE="${SMOKE:-1}"
SMOKE_TIMEOUT_S="${SMOKE_TIMEOUT_S:-240}"
SMOKE_PORT="${SMOKE_PORT:-2299}"
SMOKE_SERIAL="${SMOKE_SERIAL:-/tmp/hurd-image-reroll-smoke-serial.log}"
SMOKE_PIDFILE="${SMOKE_PIDFILE:-/tmp/hurd-image-reroll-smoke-qemu.pid}"

if [ "${SMOKE}" = "0" ]; then
    log "step 7: SMOKE=0, skipping boot smoke gate"
else
    log "step 7: boot smoke gate (timeout ${SMOKE_TIMEOUT_S}s, port ${SMOKE_PORT})"
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        log "step 7: qemu-system-x86_64 not on PATH, skipping smoke (SMOKE=0 to silence)"
    else
        : > "${SMOKE_SERIAL}"
        # background QEMU.  pidfile so we can kill it deterministically.
        # no KVM accel flag in case the host kernel module is missing;
        # smoke is slower without it but still bounded by SMOKE_TIMEOUT_S.
        # NOTE: nohup + & means this script keeps running while QEMU boots.
        # NOTE: -drive if=ide is load-bearing.  rumpdisk on canonical
        # Debian Hurd 0.9 has no virtio-blk driver, so if=virtio shows
        # "vendor 1af4 product 1001 ... not configured" and ext2fs
        # wedges on "part:2:device:wd0: No such device or address".
        # if=ide enumerates the disk as wd0 at atabus0 drive 0 (IDE
        # primary) which rumpdisk drives via its piixide back-end.
        # NOTE: tried -snapshot here (would keep OUTPUT_IMG byte-identical
        # to post-step-6 state), but it caused a different boot regression
        # that this commit does not bother chasing.  without -snapshot the
        # smoke writes land in the qcow2 overlay; operator should treat
        # post-smoke OUTPUT_IMG as "boot-tested, not boot-pristine" and
        # re-roll if a fresh image is required.
        # NIC: -device e1000 is load-bearing.  Hurd's netdde does NOT
        # drive virtio-net-pci (vendor 1af4 product 1000 logs as
        # "not configured"); pfinet settrans then returns exit=4 and
        # sshd has no IPv4 routing.  e1000 binds to netdde cleanly,
        # settrans pfinet returns exit=0, ssh -p ${SMOKE_PORT} works.
        nohup qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \
            -drive file="${OUTPUT_IMG}",if=ide,format=qcow2 \
            -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SMOKE_PORT}"-:22 \
            -device e1000,netdev=net0 \
            -nographic -serial file:"${SMOKE_SERIAL}" -display none \
            >/dev/null 2>&1 &
        SMOKE_PID=$!
        echo "${SMOKE_PID}" > "${SMOKE_PIDFILE}"
        log "smoke qemu pid=${SMOKE_PID}, serial=${SMOKE_SERIAL}"

        # poll loop.  FAIL markers exit immediately; PASS marker exits
        # 0; deadline exit logs the last 30 serial lines.
        SMOKE_RESULT="timeout"
        SMOKE_DEADLINE="$(($(date +%s) + SMOKE_TIMEOUT_S))"
        while [ "$(date +%s)" -lt "${SMOKE_DEADLINE}" ]; do
            sleep 3
            if [ ! -s "${SMOKE_SERIAL}" ]; then
                continue
            fi
            # FAIL: rumpdisk wd0 enumeration race (the v0.9.20 wedge).
            if grep -aq 'No such device or address' "${SMOKE_SERIAL}"; then
                SMOKE_RESULT="fail-wd0"
                break
            fi
            # FAIL: gnumach panic.
            if grep -aq 'Kernel panic' "${SMOKE_SERIAL}"; then
                SMOKE_RESULT="fail-panic"
                break
            fi
            # PASS: init.args eval reached final marker.  the canonical
            # marker is the "ready, dropping into event loop" line from
            # the eval body in step 3.  if the operator customised the
            # eval, "starting sshd" and "settrans pfinet" are earlier
            # fall-back PASS markers proving the supervised emacs ran
            # the eval far enough to mean the boot chain works.
            if grep -aqE 'ready, dropping into event loop|starting sshd|settrans pfinet|v[0-9]+-min: native-comp opted out' "${SMOKE_SERIAL}"; then
                SMOKE_RESULT="pass"
                break
            fi
        done

        # tear down before reporting; the script must not leak QEMU.
        if kill -0 "${SMOKE_PID}" 2>/dev/null; then
            kill "${SMOKE_PID}" 2>/dev/null || true
            # give QEMU 2s to settle, then SIGKILL if still up.
            sleep 2
            kill -9 "${SMOKE_PID}" 2>/dev/null || true
        fi
        rm -f "${SMOKE_PIDFILE}"

        case "${SMOKE_RESULT}" in
            pass)
                log "smoke PASS: init.args eval reached PASS marker"
                log "  serial log: ${SMOKE_SERIAL} ($(wc -l < "${SMOKE_SERIAL}") lines)"
                ;;
            fail-wd0)
                log "smoke FAIL: ext2fs cannot reach wd0 (was the if=virtio wedge; check qemu drive flag)"
                log "  last 30 serial lines:"
                tail -30 "${SMOKE_SERIAL}" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/^/    /'
                exit 2
                ;;
            fail-panic)
                log "smoke FAIL: gnumach panic during boot"
                log "  last 30 serial lines:"
                tail -30 "${SMOKE_SERIAL}" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/^/    /'
                exit 2
                ;;
            timeout)
                log "smoke FAIL: deadline ${SMOKE_TIMEOUT_S}s exceeded with no PASS/FAIL marker"
                log "  last 30 serial lines:"
                tail -30 "${SMOKE_SERIAL}" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/^/    /'
                exit 2
                ;;
        esac
    fi
fi

OUT_SHA="$(sha256sum "${OUTPUT_IMG}" | cut -d' ' -f1)"
log "output image sha256: ${OUT_SHA}"
log "done: ${OUTPUT_IMG} ($(stat -c '%s' "${OUTPUT_IMG}") bytes)"

###############################################################################
# step 8: FLAVOR=apt-image, bake the v1.x X+audio userland on top
###############################################################################
# WHY this step exists: the v0.9.10 EXWM-on-Xvfb live-verify needed
# xvfb + emacs-lucid + elpa-exwm + elpa-xelb apt-installed inside the
# image, and the v1.x pulseaudio scope wants pactl available out of the
# box.  doing this per-cycle costs ~5-10 minutes of apt + ~150 MB of
# fetch every boot.  bake it once here and ship a derivative image that
# already has the packages installed.
#
# the apt-image is a qcow2 overlay over OUTPUT_IMG, so the minimal
# artifact stays the canonical 35-file v0.9.22 baseline and the
# apt-installed layer is a separate file (APT_OUTPUT_IMG).  the apt
# pass needs network: SLIRP gives outbound DNS + tcp out of the box,
# and we hostfwd APT_PORT->22 so we can ssh in from the host to drive
# apt-get.  graceful shutdown via `shutdown -h now` over ssh, not
# qemu kill, because killing qemu mid-apt corrupts the qcow2.
if [ "${FLAVOR}" = "apt-image" ]; then
    log "step 8: FLAVOR=apt-image, baking X+audio userland over ${OUTPUT_IMG}"
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        log "FATAL: FLAVOR=apt-image needs qemu-system-x86_64 (apt install qemu-system-x86)"
        exit 1
    fi
    if ! command -v ssh >/dev/null 2>&1; then
        log "FATAL: FLAVOR=apt-image needs ssh on PATH"
        exit 1
    fi

    # ssh private key path: the convention here is to point SSH_PUBKEY
    # at the .pub and have the private half live alongside it (same path
    # without .pub).  derive the private path by stripping .pub if present;
    # fail fast if the private key is not readable.
    SSH_PRIVKEY="${SSH_PUBKEY%.pub}"
    if [ ! -r "${SSH_PRIVKEY}" ]; then
        log "FATAL: cannot read ssh private key at ${SSH_PRIVKEY} (derived from SSH_PUBKEY)"
        exit 1
    fi

    # fresh qcow2 overlay over the smoke-tested OUTPUT_IMG, so the
    # minimal artifact is not disturbed by the apt pass.  same rm -f
    # idempotency pattern as step 2.
    rm -f "${APT_OUTPUT_IMG}"
    qemu-img create -q -f qcow2 -F qcow2 -b "${OUTPUT_IMG}" "${APT_OUTPUT_IMG}" >/dev/null
    log "apt-image overlay ${APT_OUTPUT_IMG} -> ${OUTPUT_IMG}"

    APT_SERIAL="${APT_SERIAL:-/tmp/hurd-image-reroll-apt-serial.log}"
    APT_PIDFILE="${APT_PIDFILE:-/tmp/hurd-image-reroll-apt-qemu.pid}"
    : > "${APT_SERIAL}"

    # same qemu invocation shape as the smoke gate (if=ide + e1000 are
    # both load-bearing per v0.9.22).  hostfwd on APT_PORT this time.
    nohup qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \
        -drive file="${APT_OUTPUT_IMG}",if=ide,format=qcow2 \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${APT_PORT}"-:22 \
        -device e1000,netdev=net0 \
        -nographic -serial file:"${APT_SERIAL}" -display none \
        >/dev/null 2>&1 &
    APT_QEMU_PID=$!
    echo "${APT_QEMU_PID}" > "${APT_PIDFILE}"
    log "apt qemu pid=${APT_QEMU_PID}, serial=${APT_SERIAL}, port=${APT_PORT}"

    # ssh args.  StrictHostKeyChecking=no because every re-roll bakes
    # fresh sshd host keys in step 3b; UserKnownHostsFile=/dev/null so
    # the operator's ~/.ssh/known_hosts does not collect throwaway
    # entries.  ConnectTimeout keeps the polling loop tight.
    # ServerAliveInterval/Count: cap any single ssh call's blocking
    # window to about 10 s after the remote stops responding.  Hurd
    # never sends FIN when `shutdown -h now` brings sshd down, so
    # without these knobs the step 8e shutdown ssh blocks forever.
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR -i ${SSH_PRIVKEY} -p ${APT_PORT}"

    # wait for ssh.  poll every 5 s until ssh succeeds or the deadline
    # passes.  the supervised emacs needs to come up, settrans pfinet
    # has to land, and sshd has to bind, all within APT_TIMEOUT_S.
    log "step 8a: waiting for ssh on 127.0.0.1:${APT_PORT} (deadline ${APT_TIMEOUT_S}s)"
    APT_DEADLINE="$(($(date +%s) + APT_TIMEOUT_S))"
    APT_SSH_UP=0
    while [ "$(date +%s)" -lt "${APT_DEADLINE}" ]; do
        sleep 5
        if ssh ${SSH_OPTS} root@127.0.0.1 true >/dev/null 2>&1; then
            APT_SSH_UP=1
            break
        fi
    done
    if [ "${APT_SSH_UP}" != "1" ]; then
        log "FATAL: apt-image ssh did not come up within ${APT_TIMEOUT_S}s"
        log "  last 30 serial lines:"
        tail -30 "${APT_SERIAL}" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/^/    /'
        kill "${APT_QEMU_PID}" 2>/dev/null || true
        sleep 2
        kill -9 "${APT_QEMU_PID}" 2>/dev/null || true
        rm -f "${APT_PIDFILE}"
        exit 2
    fi
    log "ssh up; running apt-get update + install"

    # pre-apt: detach the canonical /hurd/tmpfs /var to expose the
    # underlying ext2fs /var/lib/dpkg.  canonical Debian GNU/Hurd 0.9
    # ships /var as a 256M tmpfs that starts empty on every mount with
    # no seed mechanism, so /var/lib/dpkg does not exist until detached.
    # apt-get install bails with a 1073741826 (err_local|err_sub_unix|
    # ENOENT) on /var/lib/dpkg/lock-frontend without this step.  the
    # detach has to happen in the bake's own ssh session rather than at
    # boot in hurd-essentials.el because boot-time detach loses every
    # mkdir state.el ran against the tmpfs view of /var/emacs/*.  known
    # risk: heavy writes onto the underlying ext2fs may trip ext2fs's
    # pager.c:455 file_pager_write_pages assertion (filed upstream as
    # docs/upstream/emails/08); if that fires, the bake fails fast and
    # the v1.x apt-image flavor stays on the verify-path-only detach.
    PREAPT_LOG="${PREAPT_LOG:-/tmp/hurd-image-reroll-preapt-var-detach.log}"
    log "step 8a-pre: settrans -fg /var to expose underlying ext2fs (log: ${PREAPT_LOG})"
    ssh ${SSH_OPTS} root@127.0.0.1 'showtrans /var; settrans -fg /var 2>&1; echo settrans=$?; ls -la /var/lib/dpkg 2>&1 | head -5' \
        > "${PREAPT_LOG}" 2>&1 || true
    log "  pre-apt detach log tail:"
    tail -10 "${PREAPT_LOG}" 2>/dev/null | sed 's/^/    /' || true

    # apt-get update.  if this fails or returns "no candidate" for the
    # EXWM stack (canonical Debian Hurd 0.9 may not have debian-ports
    # sid in sources.list), add debian-ports key + sid main and retry.
    # the EXWM/emacs-lucid packages live in debian-ports, not Debian
    # proper; the pulseaudio package is in canonical Debian.
    APT_PKGS="xvfb emacs-lucid elpa-exwm elpa-xelb pulseaudio"
    if ! ssh ${SSH_OPTS} root@127.0.0.1 'apt-get update' >/dev/null 2>&1; then
        log "apt-get update failed on first try, attempting debian-ports fallback"
    fi
    # probe candidate for emacs-lucid; if missing, splice debian-ports.
    APT_CANDIDATE="$(ssh ${SSH_OPTS} root@127.0.0.1 'apt-cache policy emacs-lucid 2>/dev/null | grep -c "Candidate: [0-9]"' || echo 0)"
    if [ "${APT_CANDIDATE}" = "0" ]; then
        log "step 8b: emacs-lucid has no candidate, splicing debian-ports sid main"
        # debian-ports archive key + sid main line.  apt-key is
        # deprecated on bookworm+ but still works on Hurd 0.9; the
        # /etc/apt/trusted.gpg.d drop-in is the modern path so use that.
        # the keyring package debian-ports-archive-keyring lives in
        # debian-ports itself (chicken-and-egg), so fetch the key bytes
        # via wget over plain http first, then add the apt source.
        ssh ${SSH_OPTS} root@127.0.0.1 'set -e
            apt-get install -y --no-install-recommends wget gnupg
            wget -qO /tmp/dp.gpg http://ftp.ports.debian.org/debian-ports/pool-amd64/main/d/debian-ports-archive-keyring/debian-ports-archive-keyring_2023.02.01_all.deb || true
            if [ -s /tmp/dp.gpg ]; then
                dpkg -i /tmp/dp.gpg || true
            fi
            echo "deb http://ftp.ports.debian.org/debian-ports/ sid main" > /etc/apt/sources.list.d/debian-ports.list
            apt-get update' >/dev/null 2>&1 || log "WARNING: debian-ports splice ssh exited nonzero, proceeding to install attempt anyway"
    fi

    # the install proper.  --no-install-recommends keeps pulseaudio
    # from pulling 80+ MB of fonts and sound themes; the EXWM packages
    # have light recommends so it does not hurt them either.
    log "step 8c: apt-get install -y --no-install-recommends ${APT_PKGS}"
    if ! ssh ${SSH_OPTS} root@127.0.0.1 "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${APT_PKGS}"; then
        log "FATAL: apt-get install failed"
        timeout 15 ssh ${SSH_OPTS} root@127.0.0.1 'shutdown -h now' >/dev/null 2>&1 || true
        wait "${APT_QEMU_PID}" 2>/dev/null || true
        rm -f "${APT_PIDFILE}"
        exit 2
    fi
    ssh ${SSH_OPTS} root@127.0.0.1 'apt-get clean' >/dev/null 2>&1 || true

    # smoke gate on the install: count installed packages from the
    # APT_PKGS list.  we expect 5 ii rows back (xvfb, emacs-lucid,
    # elpa-exwm, elpa-xelb, pulseaudio).  the `-E` regex pinpoints
    # exact package names from the dpkg list so a sibling package that
    # happens to contain "pulseaudio" in its name does not over-count.
    log "step 8d: dpkg verify (expect 5 ii rows)"
    APT_INSTALLED="$(ssh ${SSH_OPTS} root@127.0.0.1 "dpkg-query -W -f='\${db:Status-Abbrev} \${Package}\n' xvfb emacs-lucid elpa-exwm elpa-xelb pulseaudio 2>/dev/null | grep -cE '^ii  (xvfb|emacs-lucid|elpa-exwm|elpa-xelb|pulseaudio)\$'" || echo 0)"
    log "  installed count: ${APT_INSTALLED}/5"
    if [ "${APT_INSTALLED}" != "5" ]; then
        log "FATAL: apt-image verify saw only ${APT_INSTALLED}/5 of ${APT_PKGS}"
        ssh ${SSH_OPTS} root@127.0.0.1 'dpkg -l | grep -E "(xvfb|emacs-lucid|elpa-exwm|elpa-xelb|pulseaudio)"' 2>&1 | sed 's/^/    /'
        timeout 15 ssh ${SSH_OPTS} root@127.0.0.1 'shutdown -h now' >/dev/null 2>&1 || true
        wait "${APT_QEMU_PID}" 2>/dev/null || true
        rm -f "${APT_PIDFILE}"
        exit 2
    fi

    # graceful shutdown.  the ssh command returns immediately because
    # shutdown sends SIGTERM to sshd before the disk sync finishes; we
    # `wait` for the qemu pid to harvest the guest's clean exit.  if
    # qemu does not exit within 60 s (Hurd shutdown is slow), fall back
    # to SIGTERM then SIGKILL; this is best-effort, the worst case is a
    # dirty qcow2 that ext2fs will fsck on next boot.
    log "step 8e: graceful shutdown over ssh"
    timeout 15 ssh ${SSH_OPTS} root@127.0.0.1 'shutdown -h now' >/dev/null 2>&1 || true
    SHUTDOWN_DEADLINE="$(($(date +%s) + 60))"
    while kill -0 "${APT_QEMU_PID}" 2>/dev/null; do
        if [ "$(date +%s)" -ge "${SHUTDOWN_DEADLINE}" ]; then
            log "WARNING: guest did not halt within 60s, sending SIGTERM to qemu"
            kill "${APT_QEMU_PID}" 2>/dev/null || true
            sleep 5
            kill -9 "${APT_QEMU_PID}" 2>/dev/null || true
            break
        fi
        sleep 2
    done
    wait "${APT_QEMU_PID}" 2>/dev/null || true
    rm -f "${APT_PIDFILE}"

    APT_SHA="$(sha256sum "${APT_OUTPUT_IMG}" | cut -d' ' -f1)"
    log "apt-image sha256: ${APT_SHA}"
    log "apt-image done: ${APT_OUTPUT_IMG} ($(stat -c '%s' "${APT_OUTPUT_IMG}") bytes)"
fi

log "next: boot with"
log "  qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \\"
log "    -drive file=${OUTPUT_IMG},if=ide,format=qcow2 \\"
log "    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2266-:22 \\"
log "    -device e1000,netdev=net0 \\"
log "    -nographic -serial file:/tmp/v0918-first-boot-serial.log"
if [ "${FLAVOR}" = "apt-image" ]; then
    log "or for the apt-image flavor:"
    log "  qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \\"
    log "    -drive file=${APT_OUTPUT_IMG},if=ide,format=qcow2 \\"
    log "    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2266-:22 \\"
    log "    -device e1000,netdev=net0 \\"
    log "    -nographic -serial file:/tmp/v0918-first-boot-serial.log"
fi
