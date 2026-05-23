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
#   OUTPUT_IMG    rerolled image written here, IDEMPOTENT (rm -f first)
#                 default: /home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0918.img
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

# log prefix on every line so the operator can grep the run for
# [hurd-image-reroll] and see exactly what happened, in order.
log() {
    printf '[hurd-image-reroll] %s\n' "$*"
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

PID1_SIZE="$(stat -c '%s' "${PID1_BIN}")"
PID1_SHA="$(sha256sum "${PID1_BIN}" | cut -d' ' -f1)"
TAR_SHA="$(sha256sum "${SUPERVISOR_TAR}" | cut -d' ' -f1)"
log "pid1 binary: ${PID1_BIN} (${PID1_SIZE} bytes, sha256=${PID1_SHA})"
log "supervisor tar: ${SUPERVISOR_TAR} (sha256=${TAR_SHA})"
log "pristine base: ${PRISTINE_IMG}"
log "output target: ${OUTPUT_IMG}"

###############################################################################
# step 2: copy pristine to output (idempotent)
###############################################################################
# rm -f first so a re-run starts from a clean copy of the pristine, not
# from a half-mutated previous run. this is the whole reason the script
# exists: idempotent re-rolls.
log "step 2: copy ${PRISTINE_IMG} -> ${OUTPUT_IMG}"
rm -f "${OUTPUT_IMG}"
cp --reflink=auto "${PRISTINE_IMG}" "${OUTPUT_IMG}"
log "copy done; output is ${OUTPUT_IMG} ($(stat -c '%s' "${OUTPUT_IMG}") bytes)"

###############################################################################
# step 3: stage temp files for guestfish upload
###############################################################################
# guestfish's `upload` verb takes a host path and a guest path, but
# can't take inline content. so we materialize init.args, the patched
# grub.cfg, and the unpacked supervisor tree on the host first, then
# upload from there. STAGING_DIR is per-run so concurrent re-rolls don't
# collide (though the script's qcow2-level invariant is single-writer).
STAGING_DIR="$(mktemp -d /tmp/hurd-image-reroll-stage.XXXXXX)"
trap 'rm -rf "${STAGING_DIR}"' EXIT
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
cat > "${STAGING_DIR}/init.args" <<'INIT_ARGS_EOF'
# v0.9.18 minimal-to-SSH init.args
# the full 35-file -l chain (see git history of hurd-bootstrap.sh) has
# an unresolved regression that causes the supervised emacs to exit
# (kill-emacs trampoline build wedge) on the first pid1-as-real-PID-1
# boot.  this minimal variant proves the rerolled image boots end-to-
# end (pid1 -> emacs -> settrans pfinet -> sshd reachable via QEMU
# SLIRP host-forward).  the full chain regression is the v0.9.19
# follow-on; see /tmp/v0918-*.log receipts for the discovery.
/usr/bin/emacs
:
:
--no-site-file
--no-splash
--no-site-lisp
-l
/usr/share/geos/emacs-init/early-init.el
--eval
(progn (setq native-comp-jit-compilation nil) (setq native-comp-enable-subr-trampolines nil) (with-temp-file "/dev/console" (insert "v0918-min: native-comp opted out\n")) (let ((settrans "/bin/settrans") (pfinet "/hurd/pfinet")) (when (and (file-executable-p settrans) (file-executable-p pfinet)) (with-temp-file "/dev/console" (insert "v0918-min: settrans pfinet eth0 10.0.2.15/24 gw 10.0.2.2\n")) (call-process settrans nil nil nil "-fgap" "/servers/socket/2" pfinet "-i" "/dev/eth0" "-a" "10.0.2.15" "-m" "255.255.255.0" "-g" "10.0.2.2"))) (let ((sshd "/usr/sbin/sshd")) (if (file-executable-p sshd) (progn (with-temp-file "/dev/console" (insert "v0918-min: starting sshd -D -e\n")) (start-process "sshd" "*sshd*" sshd "-D" "-e")) (with-temp-file "/dev/console" (insert "v0918-min: /usr/sbin/sshd MISSING\n")))) (with-temp-file "/dev/console" (insert "v0918-min: ready, dropping into event loop\n")))
INIT_ARGS_EOF
log "init.args staged ($(wc -l < "${STAGING_DIR}/init.args") lines, minimal-to-SSH variant)"

###############################################################################
# step 4: extract pristine GRUB cfg, patch it, stage the patched copy
###############################################################################
# pristine grub.cfg has two problems we have to fix for serial verifies:
#   a) `terminal_output gfxterm` swallows the boot menu and kernel
#      log into a framebuffer that QEMU's -nographic can't read.
#   b) the multiboot gnumach lines lack `console=com0`, so even if
#      GRUB itself ends up on serial, gnumach writes to vga and the
#      hand-off transcript stops at the GRUB menu.
log "step 4: extract + patch GRUB cfg"
guestfish --ro -a "${PRISTINE_IMG}" \
    run : \
    mount /dev/sda2 / : \
    download /boot/grub/grub.cfg "${STAGING_DIR}/grub.cfg.orig"

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
log "step 5: guestfish mutate ${OUTPUT_IMG}"
guestfish -a "${OUTPUT_IMG}" <<EOF
run
mount /dev/sda2 /

# 5.1: backup /sbin/init. the rm -f in step 2 guarantees we're working
# on a fresh copy of the pristine, where /sbin/init is the stock
# Debian binary and /sbin/init.debian-stock does NOT exist yet. so
# the mv is unconditional; no re-run safety branch needed here, because
# the re-run safety lives at the qcow2-overwrite level (step 2 rm -f).
mv /sbin/init /sbin/init.debian-stock

# 5.2: drop new /sbin/init
upload ${PID1_BIN} /sbin/init
chmod 0755 /sbin/init

# 5.3: patched grub.cfg in place
upload ${STAGING_DIR}/grub.cfg /boot/grub/grub.cfg
chmod 0644 /boot/grub/grub.cfg

# 5.4: root ssh key. mkdir-p is a no-op if the dir exists; chmod after
# to enforce 0700 / 0600 regardless of umask the guest happens to honor.
mkdir-p /root/.ssh
upload ${SSH_PUBKEY} /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys
chmod 0700 /root/.ssh
chown 0 0 /root/.ssh
chown 0 0 /root/.ssh/authorized_keys

# 5.5: init.args
mkdir-p /etc/geos
upload ${STAGING_DIR}/init.args /etc/geos/init.args
chmod 0644 /etc/geos/init.args
chown 0 0 /etc/geos/init.args

# 5.6: supervisor tree under /usr/share/geos/emacs-init/. tar-in
# streams the tarball into the named guest directory. the tarball's
# root entry is emacs-init/, so we extract into /usr/share/geos/
# and the result lands at /usr/share/geos/emacs-init/.
mkdir-p /usr/share/geos
tar-in ${SUPERVISOR_TAR} /usr/share/geos/ compress:gzip

# 5.7: symlink early-init.el into /root/.emacs.d/ so the supervised
# emacs picks it up BEFORE tty-setup-hook fires. see v0.9.12 slice 6.
mkdir-p /root/.emacs.d
ln-sf /usr/share/geos/emacs-init/early-init.el /root/.emacs.d/early-init.el
EOF

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
guestfish --ro -a "${OUTPUT_IMG}" <<VERIFY_EOF
run
mount /dev/sda2 /
echo "--- /sbin/init ---"
ll /sbin/init
echo "--- /sbin/init.debian-stock ---"
ll /sbin/init.debian-stock
echo "--- /etc/geos/init.args (stat) ---"
ll /etc/geos/init.args
echo "--- /root/.ssh/authorized_keys (stat) ---"
ll /root/.ssh/authorized_keys
echo "--- /usr/share/geos/emacs-init (top dirs) ---"
ls /usr/share/geos/emacs-init
echo "--- /root/.emacs.d/early-init.el (stat) ---"
ll /root/.emacs.d/early-init.el
download /boot/grub/grub.cfg ${VERIFY_TMP}/grub.cfg
download /etc/geos/init.args ${VERIFY_TMP}/init.args
download /root/.ssh/authorized_keys ${VERIFY_TMP}/authorized_keys
VERIFY_EOF
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
rm -rf "${VERIFY_TMP}"

OUT_SHA="$(sha256sum "${OUTPUT_IMG}" | cut -d' ' -f1)"
log "output image sha256: ${OUT_SHA}"
log "done: ${OUTPUT_IMG} ($(stat -c '%s' "${OUTPUT_IMG}") bytes)"
log "next: boot with"
log "  qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \\"
log "    -drive file=${OUTPUT_IMG},if=virtio \\"
log "    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2266-:22 \\"
log "    -device virtio-net-pci,netdev=net0 \\"
log "    -nographic -serial file:/tmp/v0918-first-boot-serial.log"
