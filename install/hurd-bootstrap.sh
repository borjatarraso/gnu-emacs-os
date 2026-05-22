#!/bin/sh
# hurd-bootstrap.sh -- one-shot GEOS install on Debian GNU/Hurd 0.9
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Borja Tarraso <borja.tarraso@member.fsf.org>
#
# WHY this script exists: on Hurd, /hurd/startup execs /sbin/init with
# argc==1. pid1 cannot recover the boot chain from kernel argv the way
# the Guix gexp does on Linux, because there is no kernel cmdline to
# parse and /hurd/startup does not forward one. v0.9.11 added an
# /etc/geos/init.args fallback path; this script is the human-invoked
# bootstrap that writes that file and stages the rest of GEOS so the
# next boot lands in Emacs PID 1 mode.
#
# i wrote this to be re-runnable. every step is idempotent so an
# operator who got halfway through, fixed an apt issue, and re-ran the
# script does not end up with /sbin/init.debian-stock pointing at a
# previous pid1 instead of the real debian init.
#
# this is install tooling, NOT pid1 code. shell usage is fine here.
# the script must still work under dash, so no bashisms.

set -eu

# log prefix lives on every line so the operator can grep boot output
# for [geos-bootstrap] and see exactly what happened, in order.
log() {
    printf '[geos-bootstrap] %s\n' "$*"
}

# positional args: $1 overrides the pid1 source path (default lives
# under /usr/local/src/geos/pid1/emacs-init), $2 overrides /sbin/init
# as the destination. test ergonomics; production invocation passes
# zero args.
PID1_SRC="${1:-/usr/local/src/geos/pid1/emacs-init}"
INIT_DST="${2:-/sbin/init}"
EMACS_INIT_SRC="/usr/local/src/geos/emacs-init"
EMACS_INIT_DST="/usr/share/geos/emacs-init"
PID1_MODULE_SRC="/usr/local/src/geos/pid1/pid1-module.so"
PID1_MODULE_DST="/usr/lib/geos/pid1-module.so"
INIT_ARGS_PATH="/etc/geos/init.args"
INIT_BACKUP="/sbin/init.debian-stock"

###############################################################################
# step 1: sanity checks
###############################################################################
# refuse if uname is not GNU. Debian Hurd reports "GNU" here; Linux
# reports "Linux". if i somehow end up running this script on a Linux
# host i want to abort before touching /sbin/init.
log "step 1: sanity checks"
KERNEL="$(uname)"
if [ "${KERNEL}" != "GNU" ]; then
    log "refusing to run: uname=${KERNEL}, expected GNU (Debian Hurd)"
    exit 1
fi

# euid check via id -u so we don't depend on $EUID (bashism).
UID_NOW="$(id -u)"
if [ "${UID_NOW}" -ne 0 ]; then
    log "refusing to run: euid=${UID_NOW}, must be root"
    exit 1
fi

# if /sbin/init is missing, the image is already broken; refuse rather
# than write a new /sbin/init that may end up unbootable because the
# operator's PATH or rootfs layout is not what i expect.
if [ ! -e "${INIT_DST}" ]; then
    log "refusing to run: ${INIT_DST} does not exist, image is broken"
    exit 1
fi

# source path for pid1 binary must exist before we move /sbin/init.
# if i moved init first and the copy then failed, the operator would
# need to recover from a rescue shell to put debian init back. order
# matters.
if [ ! -f "${PID1_SRC}" ]; then
    log "refusing to run: pid1 source ${PID1_SRC} missing"
    exit 1
fi

if [ ! -f "${PID1_MODULE_SRC}" ]; then
    log "refusing to run: pid1 module source ${PID1_MODULE_SRC} missing"
    exit 1
fi

if [ ! -d "${EMACS_INIT_SRC}" ]; then
    log "refusing to run: emacs-init tree ${EMACS_INIT_SRC} missing"
    exit 1
fi

log "sanity checks ok: uname=GNU, euid=0, sources present"

###############################################################################
# step 2: backup /sbin/init
###############################################################################
log "step 2: backup ${INIT_DST}"
if [ -e "${INIT_BACKUP}" ]; then
    # re-run path. the previous bootstrap already moved the stock
    # debian init aside; if we move again, we would overwrite the
    # debian init backup with our own pid1, which would brick the
    # rollback path. skip the move.
    log "backup already present, skipping move"
else
    mv "${INIT_DST}" "${INIT_BACKUP}"
    log "moved ${INIT_DST} -> ${INIT_BACKUP}"
fi

###############################################################################
# step 3: install pid1 binary
###############################################################################
log "step 3: install pid1 binary"
cp "${PID1_SRC}" "${INIT_DST}"
chmod 0755 "${INIT_DST}"
if [ ! -x "${INIT_DST}" ]; then
    log "FAILED: ${INIT_DST} not executable after copy"
    exit 1
fi
log "installed ${PID1_SRC} -> ${INIT_DST} (0755)"

###############################################################################
# step 4: stage emacs-init/ tree
###############################################################################
log "step 4: stage emacs-init/ tree"
mkdir -p "${EMACS_INIT_DST}"
# copy the contents (note the trailing /. on the source) so a re-run
# updates the in-place tree rather than nesting an emacs-init/ inside
# the destination.
cp -r "${EMACS_INIT_SRC}/." "${EMACS_INIT_DST}/"

# fix perms: every .el file 0644 (world-readable, root-writable), every
# directory 0755 (world-traversable). the per-user emacs runs as the
# logged-in user and must be able to read the .el files.
find "${EMACS_INIT_DST}" -type f -name '*.el' -exec chmod 0644 {} +
find "${EMACS_INIT_DST}" -type d -exec chmod 0755 {} +
log "staged emacs-init/ under ${EMACS_INIT_DST}"

###############################################################################
# step 5: stage pid1-module.so
###############################################################################
log "step 5: stage pid1-module.so"
mkdir -p "$(dirname "${PID1_MODULE_DST}")"
cp "${PID1_MODULE_SRC}" "${PID1_MODULE_DST}"
chmod 0755 "${PID1_MODULE_DST}"
log "installed ${PID1_MODULE_SRC} -> ${PID1_MODULE_DST} (0755)"

###############################################################################
# step 5b: install early-init.el into user-emacs-directory (v0.9.12 slice 6)
###############################################################################
# Emacs only loads early-init.el from user-emacs-directory (~/.emacs.d/
# by default) and ONLY when init-file-user is non-nil.  -Q expands to
# --no-init-file --no-site-file --no-splash --no-site-lisp, and the first
# flag sets init-file-user to nil, which skips early-init.el loading
# entirely.  passing the file via `-l` only loads it during command-line-1,
# which fires AFTER tty-setup-hook -- by that point term/linux.el has
# already invoked gpm-mouse-mode which on Hurd triggers a native-comp
# trampoline build that wedges because `as(1)' is missing from the
# canonical image.  v0.9.12 slice 4 set the right variables but in the
# wrong place; this slice puts the file where emacs actually looks.
#
# the link target is the staged copy under ${EMACS_INIT_DST}, so a re-run
# of step 4 (which rewrites the staged tree) is picked up automatically.
# symlink rather than copy so the file stays authoritative in one place.
log "step 5b: link early-init.el into /root/.emacs.d"
mkdir -p /root/.emacs.d
ln -sfn "${EMACS_INIT_DST}/early-init.el" /root/.emacs.d/early-init.el
log "linked /root/.emacs.d/early-init.el -> ${EMACS_INIT_DST}/early-init.el"

###############################################################################
# step 6: write /etc/geos/init.args
###############################################################################
# the file has one argv slot per line. blanks and '#' lines are
# stripped by pid1's parse_init_args. slot 1 is the emacs binary,
# slot 2 is the pid1 module path, slot 3 is the xorg spec (empty path
# field disables X spawn on Hurd until apt install xvfb), slot 4+ is
# the -l chain forwarded into emacs's own argv.
#
# the load order below mirrors the canonical guix boot gexp:
#   panic -> port -> cmdline -> state -> supervise -> power
#   -> use-package-shim -> network -> hostname -> passwd -> session
#   -> x-display -> rpc-server -> network buffer -> the rest of buffers/
#   -> services/journal-tail -> services/dhcp -> services/hurd-essentials
#   -> install/* helpers -> install buffer -> boot-marker (LAST)
#
# every file path below was verified to exist under emacs-init/ on
# 2026-05-21 against the v0.9.10 tree. if a path disappears in a
# future refactor and this bootstrap is not updated, pid1 will log
# the missing -l in *Messages* and continue (load errors are caught
# by emacs); but the operator will get a half-booted userland, which
# is worse than failing fast. keep this list in sync.
log "step 6: write ${INIT_ARGS_PATH}"
mkdir -p "$(dirname "${INIT_ARGS_PATH}")"
cat > "${INIT_ARGS_PATH}" <<'INIT_ARGS_EOF'
# /etc/geos/init.args -- v0.9.11 Hurd boot chain
# pid1 reads this when the kernel hands us argc==1 (/hurd/startup).
# one arg per line; blanks and '#' lines are ignored.
# slot 1: emacs binary
/usr/bin/emacs
# slot 2: pid1 dynamic module
/usr/lib/geos/pid1-module.so
# slot 3: xorg spec.  empty path field disables X spawn; pid1 will
# launch Xvfb only if the operator runs `apt install xvfb` and edits
# this spec.  see docs/HURD_BOOT.md for the v0.9.10 Xvfb workflow.
:
# slot 4+: forwarded into emacs's own argv as the -l chain.
# v0.9.12 slice 6: NOT -Q.  -Q expands to --no-init-file --no-site-file
# --no-splash --no-site-lisp; the --no-init-file part sets init-file-user
# to nil which skips early-init.el loading entirely.  on Hurd that means
# the native-comp opt-out in early-init.el never runs before tty-setup-
# hook fires, gpm-mouse-mode triggers a trampoline build, gcc spawns a
# missing as(1), emacs wedges.  we use the three explicit flags that -Q
# also expands to, MINUS --no-init-file, so emacs loads
# /root/.emacs.d/early-init.el (symlinked to ${EMACS_INIT_DST}/early-init.el
# by step 5b above) BEFORE tty setup.  early-init.el's body short-circuits
# on a non-Hurd kernel via the GEOS_KERNEL env check, so this is safe to
# share with the Linux Guix gexp once it picks up the same pattern.
# /root/.emacs.d/init.el is not shipped, so emacs's natural init.el load
# is a no-op and the explicit -l chain below remains the source of truth
# for what loads.
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

# pid1's fstat check on /etc/geos/init.args requires uid 0 and a
# world-readable mode. chown to root:root explicitly so a script run
# under sudo from a non-root home does not leave the file owned by
# whoever invoked sudo's target.
chmod 0644 "${INIT_ARGS_PATH}"
chown root:root "${INIT_ARGS_PATH}"
ARGS_STAT="$(stat -c '%U:%G %a' "${INIT_ARGS_PATH}")"
log "wrote ${INIT_ARGS_PATH} (${ARGS_STAT})"
if [ "${ARGS_STAT}" != "root:root 644" ]; then
    log "FAILED: init.args perms wrong, got '${ARGS_STAT}' want 'root:root 644'"
    exit 1
fi

###############################################################################
# step 7: document apt prereqs
###############################################################################
log "done."
log "next steps:"
log "  apt install ssh inetutils-syslogd isc-dhcp-client   # required for hurd-essentials supervisor"
log "  apt install xvfb emacs-lucid elpa-exwm elpa-xelb   # optional, for EXWM X mode"
log "  reboot"

###############################################################################
# step 8: final state dump
###############################################################################
ls -la "${INIT_DST}" "${INIT_BACKUP}" "${INIT_ARGS_PATH}"
log "verify next boot lands in Emacs PID 1 mode; if not, run \`mv ${INIT_BACKUP} ${INIT_DST}\` from a rescue shell to roll back."
