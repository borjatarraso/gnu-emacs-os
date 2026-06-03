#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
#
# This file is part of GEOS.
#
# GEOS is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# GEOS is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with GEOS.  If not, see <https://www.gnu.org/licenses/>.
# hurd-fast-iterate.sh -- iterate on the Hurd image without re-rolling.
#
# the canonical hurd-image-reroll.sh cp's a 4 GB raw image, fires
# guestfish, regenerates ssh keys, mutates 35 files; ~3 min minimum.
# most v0.9.x iterations only touch a few elisp files in
# emacs-init/ or one C source file in pid1/.  this script skips
# the re-roll entirely:
#
#   1. boot the existing v0920 image once with `-snapshot` so writes
#      are ephemeral (no risk of corrupting the canonical image)
#   2. scp the changed sources into the running guest
#   3. either (a) restart the supervised emacs to pick up new elisp,
#      or (b) rebuild pid1 in-VM and exec it as a fresh init
#
# expected per-iteration cost:
#   elisp-only change: ~5 s (scp + ssh emacsclient eval)
#   pid1 C change:     ~3 min (in-VM gcc rebuild + supervisor restart)
#
# vs full re-roll cycle: ~20 min minimum.
#
# usage:
#   ./iso-build/hurd-fast-iterate.sh boot           # start ephemeral VM
#   ./iso-build/hurd-fast-iterate.sh sync-elisp     # scp emacs-init/ into VM
#   ./iso-build/hurd-fast-iterate.sh restart-emacs  # supervisor restart
#   ./iso-build/hurd-fast-iterate.sh probe '(pid1-as-emacs-p)'
#   ./iso-build/hurd-fast-iterate.sh build-pid1     # in-VM rebuild + scp out
#   ./iso-build/hurd-fast-iterate.sh stop           # kill ephemeral VM
#   ./iso-build/hurd-fast-iterate.sh status         # ssh check
#
# this is dev tooling, not pid1 code.  shell usage is fine here.
# the script must still work under dash, so no bashisms.

set -eu

IMG="${IMG:-/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0920.img}"
SSH_KEY="${SSH_KEY:-/home/overdrive/.ssh/geos-hurd-vm.key}"
SSH_PORT="${SSH_PORT:-2266}"
SERIAL_LOG="${SERIAL_LOG:-/tmp/geos-fast-iterate-serial.log}"
QEMU_PIDFILE="${QEMU_PIDFILE:-/tmp/geos-fast-iterate-qemu.pid}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_DIR="${REPO_DIR:-$(dirname "${SCRIPT_DIR}")}"

log() { printf '[fast-iterate] %s\n' "$*" >&2; }

cmd_boot() {
    if [ -f "${QEMU_PIDFILE}" ] && kill -0 "$(cat "${QEMU_PIDFILE}")" 2>/dev/null; then
        log "VM already running pid=$(cat "${QEMU_PIDFILE}")"
        return 0
    fi
    [ -f "${IMG}" ] || { log "FATAL: image missing: ${IMG}"; exit 1; }
    : > "${SERIAL_LOG}"
    log "booting ${IMG} (ephemeral, port ${SSH_PORT})"
    # if=ide because rumpdisk has no virtio-blk driver (wd0 enumerates
    # via piixide on the IDE primary).  -device e1000 because Hurd's
    # netdde has no virtio-net driver (pfinet settrans wedges at exit=4
    # under virtio-net-pci; e1000 brings settrans to exit=0).
    nohup qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -snapshot \
        -drive file="${IMG}",if=ide \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
        -device e1000,netdev=net0 \
        -nographic -serial file:"${SERIAL_LOG}" -display none \
        >/dev/null 2>&1 &
    echo $! > "${QEMU_PIDFILE}"
    log "qemu pid=$(cat "${QEMU_PIDFILE}"), serial=${SERIAL_LOG}"
    log "ssh-wait: try 'fast-iterate status' in 60-120s"
}

cmd_stop() {
    [ -f "${QEMU_PIDFILE}" ] || { log "no pidfile"; return 0; }
    PID="$(cat "${QEMU_PIDFILE}")"
    if kill -0 "${PID}" 2>/dev/null; then
        log "killing qemu pid=${PID}"
        kill "${PID}" || true
    fi
    rm -f "${QEMU_PIDFILE}"
}

ssh_to_vm() {
    ssh -i "${SSH_KEY}" -p "${SSH_PORT}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        root@127.0.0.1 "$@"
}

scp_to_vm() {
    scp -i "${SSH_KEY}" -P "${SSH_PORT}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$@"
}

cmd_status() {
    if ssh_to_vm 'uname -a' 2>&1; then
        log "VM responding"
    else
        log "VM NOT responding on port ${SSH_PORT}"
        return 1
    fi
}

cmd_sync_elisp() {
    log "rsync-by-scp emacs-init tree to guest /usr/share/geos/emacs-init/"
    # tar over ssh avoids N round-trips for N files; one stream.
    tar -C "${REPO_DIR}" -cf - emacs-init | \
        ssh_to_vm 'tar -C /usr/share/geos -xf - && \
                   rm -rf /usr/share/geos/emacs-init.old && \
                   echo "elisp sync done: $(find /usr/share/geos/emacs-init -name "*.el" | wc -l) files"'
}

cmd_restart_emacs() {
    log "asking supervisor to bounce the user emacs"
    # send SIGTERM to emacs; pid1's supervisor respawns it under the
    # same /etc/geos/init.args, so the new elisp gets picked up.
    ssh_to_vm 'pkill -TERM -x emacs; sleep 3; pgrep -x emacs && echo "respawn OK" || echo "no emacs"'
}

cmd_probe() {
    EXPR="${1:-(emacs-version)}"
    ssh_to_vm "emacsclient --no-wait -e '${EXPR}' 2>&1 || echo 'emacsclient FAIL'"
}

cmd_build_pid1() {
    log "scp pid1 sources to /root/pid1-src/"
    ssh_to_vm 'mkdir -p /root/pid1-src'
    # main-branch sources for emacs-init.c + port_layer.h;
    # the caller must ensure /tmp/geos-hurd/pid1/{port_hurd.c,Makefile}
    # is staged from the hurd-branch worktree (operator concern).
    scp_to_vm "${REPO_DIR}/pid1/emacs-init.c" \
              "${REPO_DIR}/pid1/port_layer.h" \
              /tmp/geos-hurd/pid1/port_hurd.c \
              /tmp/geos-hurd/pid1/Makefile \
              root@127.0.0.1:/root/pid1-src/
    log "build STATIC=1 PORT=hurd in-VM"
    ssh_to_vm 'cd /root/pid1-src && make clean >/dev/null 2>&1 && \
               make STATIC=1 PORT=hurd emacs-init 2>&1 | tail -5'
    log "scp built binary back to /tmp/geos-fast-iterate-emacs-init"
    scp_to_vm root@127.0.0.1:/root/pid1-src/emacs-init \
              /tmp/geos-fast-iterate-emacs-init
    log "binary: /tmp/geos-fast-iterate-emacs-init"
    ls -la /tmp/geos-fast-iterate-emacs-init
}

case "${1:-}" in
    boot)           cmd_boot ;;
    stop)           cmd_stop ;;
    status)         cmd_status ;;
    sync-elisp)     cmd_sync_elisp ;;
    restart-emacs)  cmd_restart_emacs ;;
    probe)          shift; cmd_probe "$@" ;;
    build-pid1)     cmd_build_pid1 ;;
    serial)         tail -F "${SERIAL_LOG}" | sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' ;;
    *)
        cat >&2 <<EOF
usage: $0 <subcommand>
subcommands:
  boot           start ephemeral VM (-snapshot, no canonical image mutation)
  stop           kill the VM
  status         ssh round-trip check
  sync-elisp     tar+ssh emacs-init/ into /usr/share/geos/emacs-init/
  restart-emacs  pkill -TERM emacs, let pid1 respawn under same init.args
  probe '<sexp>' emacsclient -e in the guest
  build-pid1     in-VM rebuild + scp back to /tmp/geos-fast-iterate-emacs-init
  serial         tail the captured serial log

env vars:
  IMG=${IMG}
  SSH_KEY=${SSH_KEY}
  SSH_PORT=${SSH_PORT}
EOF
        exit 1 ;;
esac
