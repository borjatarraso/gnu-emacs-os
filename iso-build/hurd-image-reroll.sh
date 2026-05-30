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
        nohup qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \
            -drive file="${OUTPUT_IMG}",if=virtio,format=qcow2 \
            -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SMOKE_PORT}"-:22 \
            -device virtio-net-pci,netdev=net0 \
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
                log "smoke FAIL: rumpdisk wd0 enumeration race (the v0.9.20 wedge)"
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
log "next: boot with"
log "  qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \\"
log "    -drive file=${OUTPUT_IMG},if=virtio,format=qcow2 \\"
log "    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2266-:22 \\"
log "    -device virtio-net-pci,netdev=net0 \\"
log "    -nographic -serial file:/tmp/v0918-first-boot-serial.log"
