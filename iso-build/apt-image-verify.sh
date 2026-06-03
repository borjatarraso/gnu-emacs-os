#!/bin/sh
# apt-image-verify.sh -- live-verify the v1.x apt-image flavor on Hurd.
#
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
# Author: Borja Tarraso <borja.tarraso@member.fsf.org>
#
# the canonical apt-image flavor produced by `hurd-image-reroll.sh
# FLAVOR=apt-image` ships xvfb, emacs-lucid, elpa-exwm, elpa-xelb,
# pulseaudio.  the bake's own step-8d smoke gate proves the apt-get
# install succeeded inside the bake's qemu session; it does NOT prove
# the same packages are visible on a fresh boot, because /var is a
# /hurd/tmpfs translator on canonical and the apt-installed admin DB
# under /var/lib/dpkg only persists after the v0.9.20+
# hurd-essentials.el settrans -fg /var detach runs.  also the EXWM
# headless load needs a couple of corrections the bake never exercises.
#
# this script bakes the post-boot verify path so the operator can run
# it after any FLAVOR=apt-image bake, or against a pre-built artifact,
# without re-deriving the elisp incantation by hand.
#
# what we probe (in order, all over SSH):
#   1. dpkg-query for the five baked packages -> 5 ii rows
#   2. Xvfb :99 spawn + xdpyinfo
#   3. emacs-lucid -Q --batch loads xelb + exwm with explicit load-path
#      (the `-Q` flag skips site-start so elpa subdirs.el's load-path
#      injection never runs; we prepend the elpa subdirs by version-
#      glob so a future xelb-0.21 / exwm-0.34 bump still works without
#      editing this script)
#   4. pulseaudio + pactl --version
#   5. full chain: Xvfb on :99 + emacs-lucid loads exwm against it
#
# correctness notes baked in:
#   - EXWM 0.33 dropped the `exwm-version` defvar.  the probes here
#     check `(featurep 'exwm)` and `(fboundp 'exwm-init)` instead.
#     wiring exwm into session.el later must call `exwm-init`, not
#     `exwm-wm-mode' (which is also gone in 0.33).
#   - `reboot(8)` on canonical Debian GNU/Hurd 0.9 wedges (no
#     /run/initctl).  if you need to re-trigger boot elisp, kill the
#     qemu pid and re-boot from the same snapshot (writes land in the
#     qcow2 overlay).
#
# usage:
#   ./iso-build/apt-image-verify.sh           # verify default image
#   IMG=/path/to/apt.img ./iso-build/apt-image-verify.sh
#
# this is dev tooling, not pid1 code.  shell usage is fine here.  the
# script must still work under dash, so no bashisms.

set -eu

IMG="${IMG:-/home/overdrive/hurd-vm/debian-hurd-amd64-geos-v0922-apt.img}"
SSH_KEY="${SSH_KEY:-/home/overdrive/.ssh/geos-hurd-vm.key}"
SSH_PORT="${SSH_PORT:-2298}"
SSH_WAIT_S="${SSH_WAIT_S:-180}"
TS="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT="${SNAPSHOT:-/tmp/apt-image-verify-${TS}.qcow2}"
SERIAL_LOG="${SERIAL_LOG:-/tmp/apt-image-verify-${TS}.serial.log}"
OUT_DIR="${OUT_DIR:-/tmp/apt-image-verify-${TS}}"
QEMU_PIDFILE="${QEMU_PIDFILE:-/tmp/apt-image-verify-${TS}.qemu.pid}"

log() { printf '[apt-verify] %s\n' "$*" >&2; }

# fail-fast on missing inputs.  the SSH key check uses -r because we
# need to read it for ssh -i; the image check uses -f because qemu
# wants it as a regular file (raw or qcow2).
[ -f "${IMG}" ]      || { log "FATAL: image missing: ${IMG}"; exit 1; }
[ -r "${SSH_KEY}" ]  || { log "FATAL: ssh key unreadable: ${SSH_KEY}"; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || \
    { log "FATAL: qemu-system-x86_64 not on PATH"; exit 1; }
command -v qemu-img >/dev/null 2>&1 || \
    { log "FATAL: qemu-img not on PATH"; exit 1; }
command -v ssh >/dev/null 2>&1 || \
    { log "FATAL: ssh not on PATH"; exit 1; }
command -v timeout >/dev/null 2>&1 || \
    { log "FATAL: timeout(1) not on PATH (coreutils)"; exit 1; }

mkdir -p "${OUT_DIR}"
: > "${SERIAL_LOG}"

# port-busy guard.  the prior verify session left a stale qemu holding
# this port for 1d05h; fail fast rather than collide.  no `ss`
# dependency: use a tcp probe via /dev/tcp (bash-only) replaced with a
# portable nc-style check.  if neither nc nor python is available we
# warn and proceed; the qemu launch will surface the bind failure.
if command -v ss >/dev/null 2>&1; then
    if ss -ltn "sport = :${SSH_PORT}" 2>/dev/null | grep -q LISTEN; then
        log "FATAL: TCP port ${SSH_PORT} already in use; pick a different SSH_PORT"
        exit 1
    fi
fi

# qcow2 overlay so the canonical apt-image stays read-only.  the
# backing-format detect for a qcow2-backing-a-qcow2 needs -F qcow2;
# the operator's prior session got bitten by -F raw on a qcow2 backing
# (qemu booted into iPXE because the backing-file format hint did not
# match the actual format).
case "${IMG}" in
    *.img|*.qcow2)
        BACKING_FMT="$(qemu-img info "${IMG}" 2>/dev/null \
                       | sed -n 's/^file format: //p')"
        ;;
    *) BACKING_FMT=qcow2 ;;
esac
[ -n "${BACKING_FMT}" ] || BACKING_FMT=qcow2
log "snapshot ${SNAPSHOT} -> ${IMG} (backing fmt ${BACKING_FMT})"
qemu-img create -q -f qcow2 -F "${BACKING_FMT}" -b "${IMG}" "${SNAPSHOT}" \
    >/dev/null

# qemu invocation shape per v0.9.22: if=ide because rumpdisk has no
# virtio-blk driver, -device e1000 because netdde has no virtio-net.
log "booting snapshot on port ${SSH_PORT}"
nohup qemu-system-x86_64 -enable-kvm -cpu host -m 2048 \
    -drive file="${SNAPSHOT}",if=ide,format=qcow2 \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
    -device e1000,netdev=net0 \
    -nographic -serial file:"${SERIAL_LOG}" -display none \
    >/dev/null 2>&1 &
QEMU_PID=$!
echo "${QEMU_PID}" > "${QEMU_PIDFILE}"
log "qemu pid=${QEMU_PID}, serial=${SERIAL_LOG}, out=${OUT_DIR}"

# every exit path tears the VM down so the script never leaks qemu.
# best-effort: SIGTERM, give it 5s, SIGKILL.  best-effort wait swallows
# `wait` errors after the kill so set -e does not exit non-zero on
# successful PASS paths just because the wait races the kill.
cleanup() {
    if [ -f "${QEMU_PIDFILE}" ]; then
        PID="$(cat "${QEMU_PIDFILE}" 2>/dev/null || true)"
        if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
            log "tearing down qemu pid=${PID}"
            kill "${PID}" 2>/dev/null || true
            sleep 5
            kill -9 "${PID}" 2>/dev/null || true
        fi
        rm -f "${QEMU_PIDFILE}"
    fi
}
trap cleanup EXIT INT TERM

# ServerAliveInterval/Count guards against a Hurd-side daemon that
# accepts the request but never closes the TCP connection.  the prior
# verify run blocked for 41 minutes on `shutdown -h now` until the
# operator SIGTERM'd the ssh client by hand; with these set the client
# tears itself down 10s after the peer goes silent.  cheap insurance
# for every ssh in this script, not just the shutdown.
SSH_OPTS="-i ${SSH_KEY} -p ${SSH_PORT} \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 \
    -o LogLevel=ERROR"

ssh_to_vm() {
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} root@127.0.0.1 "$@"
}

# wait for sshd.  the supervised emacs has to come up, settrans pfinet
# has to land, sshd has to bind; SSH_WAIT_S covers all of it.
log "waiting for ssh (deadline ${SSH_WAIT_S}s)"
DEADLINE="$(($(date +%s) + SSH_WAIT_S))"
SSH_UP=0
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    sleep 5
    if ssh_to_vm true >/dev/null 2>&1; then
        SSH_UP=1
        break
    fi
done
if [ "${SSH_UP}" != "1" ]; then
    log "FATAL: ssh did not come up within ${SSH_WAIT_S}s"
    log "  last 30 serial lines:"
    tail -30 "${SERIAL_LOG}" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/^/    /' >&2
    exit 2
fi
log "ssh up"

# pass/fail counters, one slot per probe so the summary at the end can
# point at exactly which probe regressed.
P1=skip P2=skip P3=skip P4=skip P5=skip

# ---------------------------------------------------------------------
# pre-P1 step: detach the /hurd/tmpfs translator masking /var so the
# underlying ext2fs /var/lib/dpkg becomes visible.
#
# this was originally going to live in hurd-essentials.el (boot-time
# detach), but that breaks the bake's own apt-install phase: when the
# detach happens at the apt-install boot, dpkg writes 14 MB into the
# exposed underlying ext2fs and the gnumach ext2fs translator panics
# at pager.c:455 file_pager_write_pages "Assertion 'blk' failed".
# the conflict is fundamental: the bake needs the tmpfs mounted so
# apt's writes succeed in RAM, the verify path needs the tmpfs
# detached so dpkg-query sees the persistent underlying state.  doing
# the detach here (verify path) leaves the bake's tmpfs path
# untouched and surfaces the underlying state for P1.
#
# the ext2fs assertion itself is a gnumach/Hurd bug filed upstream
# as the 08 thread in docs/upstream/.  best-effort: even with the
# detach here, heavy writes to underlying /var can still trip the
# assertion if the kernel is the canonical 1.8+git20260224 version;
# we read only, so the probe is safe.
# ---------------------------------------------------------------------
log "pre-P1: settrans -fg /var to expose underlying ext2fs dpkg state"
ssh_to_vm 'showtrans /var; settrans -fg /var 2>&1; echo settrans=$?' \
    > "${OUT_DIR}/preP1-var-detach.log" 2>&1 || true

# ---------------------------------------------------------------------
# probe 1: dpkg-query for the five baked packages.  expect 5 ii rows.
# the canonical /var/hurd/tmpfs masks /var/lib/dpkg; the pre-P1 step
# above detaches it.  if this returns 0 ii rows the detach failed.
# ---------------------------------------------------------------------
log "probe 1: dpkg-query of the five baked packages"
ssh_to_vm \
    "dpkg-query -W -f='\${db:Status-Abbrev} \${Package} \${Version}\n' \
        xvfb emacs-lucid elpa-exwm elpa-xelb pulseaudio 2>&1; \
     echo exit=\$?" \
    > "${OUT_DIR}/probe1-dpkg-query.log" 2>&1 || true
P1_HITS="$(grep -c '^ii ' "${OUT_DIR}/probe1-dpkg-query.log" || true)"
log "  ii rows: ${P1_HITS}/5"
if [ "${P1_HITS}" = "5" ]; then
    P1=pass
else
    P1=fail
    log "  FAIL.  if this is zero, the /var tmpfs detach regressed."
fi

# ---------------------------------------------------------------------
# probe 2: Xvfb on :99, xdpyinfo speaks to it.  minimum precondition
# for the display-driven probes that follow.
# ---------------------------------------------------------------------
log "probe 2: Xvfb :99 + xdpyinfo"
ssh_to_vm "
    Xvfb :99 -screen 0 1024x768x24 >/tmp/xvfb99.log 2>&1 &
    XPID=\$!
    sleep 2
    DISPLAY=:99 xdpyinfo 2>&1 | head -8
    RC=\$?
    kill \"\$XPID\" 2>/dev/null || true
    echo exit=\$RC
" > "${OUT_DIR}/probe2-xvfb-xdpyinfo.log" 2>&1 || true
if grep -q 'X.Org version' "${OUT_DIR}/probe2-xvfb-xdpyinfo.log"; then
    P2=pass
else
    P2=fail
fi
log "  ${P2}"

# ---------------------------------------------------------------------
# probe 3: emacs-lucid -Q loads xelb + exwm against an explicit
# load-path.  `-Q` skips site-start so elpa subdirs.el never injects
# the elpa subdirs; we glob the parent elpa dir so a future version
# bump (xelb-0.21, exwm-0.34) does not break this script.
#
# the version probe uses (featurep 'exwm) + (fboundp 'exwm-init)
# because EXWM 0.33 dropped the exwm-version defvar.  any future
# session.el wiring must follow the same pattern.
# ---------------------------------------------------------------------
log "probe 3: emacs-lucid -Q loads xelb + exwm"
ssh_to_vm "emacs-lucid -Q --batch \
    --eval \"(dolist (d (file-expand-wildcards \\\"/usr/share/emacs/site-lisp/elpa/xelb-*\\\")) (add-to-list 'load-path d))\" \
    --eval \"(dolist (d (file-expand-wildcards \\\"/usr/share/emacs/site-lisp/elpa/exwm-*\\\")) (add-to-list 'load-path d))\" \
    --eval \"(require 'xelb)\" \
    --eval \"(require 'exwm)\" \
    --eval \"(message \\\"xelb=%S exwm=%S exwm-init=%S\\\" (featurep 'xelb) (featurep 'exwm) (fboundp 'exwm-init))\" \
    2>&1 | tail -10" \
    > "${OUT_DIR}/probe3-exwm-headless.log" 2>&1 || true
if grep -qE 'xelb=t exwm=t exwm-init=t' "${OUT_DIR}/probe3-exwm-headless.log"; then
    P3=pass
else
    P3=fail
fi
log "  ${P3}"

# ---------------------------------------------------------------------
# probe 4: pulseaudio + pactl version.  not a runtime audio probe (no
# backend on Hurd as of v1.x; tracked deferred-upstream), only proves
# the binaries are present and runnable.
# ---------------------------------------------------------------------
log "probe 4: pulseaudio + pactl --version"
ssh_to_vm 'pulseaudio --version 2>&1; echo "---"; pactl --version 2>&1' \
    > "${OUT_DIR}/probe4-pulseaudio.log" 2>&1 || true
if grep -q '^pulseaudio [0-9]' "${OUT_DIR}/probe4-pulseaudio.log" \
   && grep -q '^pactl [0-9]'   "${OUT_DIR}/probe4-pulseaudio.log"; then
    P4=pass
else
    P4=fail
fi
log "  ${P4}"

# ---------------------------------------------------------------------
# probe 5: full chain.  Xvfb on :99, emacs-lucid loads exwm against
# that DISPLAY, exits clean.  closest reproduction of v0.9.10
# EXWM-on-Xvfb-on-Hurd without a real display.
# ---------------------------------------------------------------------
log "probe 5: full chain Xvfb + emacs+exwm"
ssh_to_vm "
    Xvfb :99 -screen 0 1024x768x24 >/tmp/xvfb99b.log 2>&1 &
    XPID=\$!
    sleep 2
    DISPLAY=:99 emacs-lucid -Q --batch \
        --eval \"(dolist (d (file-expand-wildcards \\\"/usr/share/emacs/site-lisp/elpa/xelb-*\\\")) (add-to-list 'load-path d))\" \
        --eval \"(dolist (d (file-expand-wildcards \\\"/usr/share/emacs/site-lisp/elpa/exwm-*\\\")) (add-to-list 'load-path d))\" \
        --eval \"(require 'xelb)\" \
        --eval \"(require 'exwm)\" \
        --eval \"(message \\\"display=%S xelb=%S exwm=%S exwm-init=%S\\\" (getenv \\\"DISPLAY\\\") (featurep 'xelb) (featurep 'exwm) (fboundp 'exwm-init))\" \
        2>&1 | tail -10
    RC=\$?
    kill \"\$XPID\" 2>/dev/null || true
    echo exit=\$RC
" > "${OUT_DIR}/probe5-full-chain.log" 2>&1 || true
if grep -qE 'display="?:99"? xelb=t exwm=t exwm-init=t' "${OUT_DIR}/probe5-full-chain.log"; then
    P5=pass
else
    P5=fail
fi
log "  ${P5}"

# graceful shutdown via ssh.  shutdown -h now (which inetutils-syslogd
# routes through halt(8)) is the cleanest path; reboot(8) wedges on
# canonical Hurd ("/run/initctl: No such file or directory") and is
# not used here.
#
# the ssh client gets a hard 15s ceiling via timeout(1) because the
# Hurd shutdown path does not close the TCP connection cleanly, and
# the ServerAliveInterval keepalive alone occasionally races on a
# heavily loaded VM.  the cleanup trap below tears the qemu down
# regardless, so this call is best-effort.
log "graceful shutdown over ssh"
# shellcheck disable=SC2086
timeout 15 ssh ${SSH_OPTS} root@127.0.0.1 'shutdown -h now' \
    >/dev/null 2>&1 || true

# summary.  exit 0 iff all five PASS.  any FAIL = exit 2.  per-probe
# logs are in OUT_DIR; the snapshot is retained for follow-on
# inspection (it embeds the post-verify state of the VM).
log "---"
log "summary:"
log "  P1 dpkg-query              : ${P1}"
log "  P2 Xvfb + xdpyinfo         : ${P2}"
log "  P3 emacs+xelb+exwm headless: ${P3}"
log "  P4 pulseaudio + pactl      : ${P4}"
log "  P5 full chain DISPLAY+exwm : ${P5}"
log "  per-probe logs: ${OUT_DIR}/"
log "  serial log:     ${SERIAL_LOG}"
log "  snapshot:       ${SNAPSHOT} (retained)"

case "${P1}${P2}${P3}${P4}${P5}" in
    passpasspasspasspass)
        log "ALL PROBES PASS"
        exit 0
        ;;
    *)
        log "ONE OR MORE PROBES FAILED"
        exit 2
        ;;
esac
