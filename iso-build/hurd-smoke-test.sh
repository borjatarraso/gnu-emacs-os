#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Borja Tarraso <borja.tarraso@member.fsf.org>
#
# hurd-smoke-test.sh, headless boot of a GEOS Hurd raw image with
# serial-log marker checks.  mirror of smoke-test.sh, narrowed to the
# hurd-console deliverable.  step 3 + step 4 (this round) leave the
# script in place; the actual green pass is step 6.
#
# what gates as a step-3 deliverable:
#   nothing.  the image likely will not boot to userland this round
#   because pid1's networking is ENOSYS-stubbed and the mount path
#   has not been exercised against a real hurd translator.  the
#   script exists so the next round (step 5, then step 6) has a
#   landing pad: bring up pfinet, then flip on the markers below.
#
# what gates as a step-6 deliverable (the green hurd smoke test):
#   - SUCCESS_USERLAND_RE: the same "geos: emacs userland up" marker
#     boot-marker.el writes on linux.  if every -l in the boot gexp
#     succeeded on hurd we see this line on serial.
#
# what we deliberately do NOT gate on for hurd v0.4:
#   - the X-server "pid1: X server up on :0" marker: hurd profile is
#     console-only, no Xorg.
#   - the rpc-server "rpc: listening on ..." marker: rpc-server.el
#     does load on hurd, but its bottom-of-load gate is
#     pid1-as-emacs-p which depends on the module being loaded.  the
#     module load story on hurd is the one open question
#     (docs/v04-item11-hurd-spike.md line 28).  step 4 leaves this
#     marker out of the gate; step 6 may add it back once the
#     module-load prototype lands.
#   - the supervise "registry loaded N entries" marker: requires
#     journal-tail.el to define a service that boots on hurd; the
#     journal-tail service reads /dev/kmsg today which has no hurd
#     equivalent.  step 6 either ports journal-tail or drops the
#     gate.
#
# usage mirrors smoke-test.sh:
#   ./iso-build/hurd-smoke-test.sh                  # build then test
#   ./iso-build/hurd-smoke-test.sh /path/to/img     # test existing image
#   ./iso-build/hurd-smoke-test.sh -t 120 ...       # raise the deadline

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)

cd "$REPO_ROOT"

TIMEOUT=120
IMG=

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--timeout)
            shift
            TIMEOUT=${1:?--timeout needs seconds}
            shift ;;
        -h|--help)
            sed -n '1,40p' "$0"
            exit 0 ;;
        -*)
            echo "hurd-smoke-test: unknown flag: $1" >&2
            exit 2 ;;
        *)
            IMG=$1
            shift ;;
    esac
done

if [ -z "$IMG" ]; then
    echo "hurd-smoke-test: no image given, building one"
    # the hurd image build is significantly slower than the linux qcow2
    # build because the gnumach + hurd closure compiles from source on
    # most hosts.  we wrap the guix invocation rather than reusing
    # dev-vm.sh: dev-vm.sh is hard-wired to system.scm.
    IMG=$(guix system disk-image -t hurd64-raw \
            --image-size=4G \
            guix-system/system-hurd.scm)
fi
if [ ! -f "$IMG" ]; then
    echo "hurd-smoke-test: image not found: $IMG" >&2
    exit 2
fi

LOG=$(mktemp -t geos-hurd-smoke.XXXXXX.log)
QPID=
cleanup() {
    if [ -n "$QPID" ]; then
        kill -TERM "$QPID" 2>/dev/null || true
        i=0
        while [ "$i" -lt 2 ] && kill -0 "$QPID" 2>/dev/null; do
            i=$((i + 1))
            sleep 1
        done
        kill -KILL "$QPID" 2>/dev/null || true
        QPID=
    fi
    rm -f "$LOG"
}
trap cleanup EXIT INT TERM HUP QUIT

echo "hurd-smoke-test: booting $IMG (timeout ${TIMEOUT}s, log $LOG)"

# qemu invocation: gnumach is x86_64 on the v0.4 line.  the -drive
# spec uses if=ide because /dev/hd0 in hurd is enumerated from the
# IDE controller; virtio-blk would expose the disk as /dev/wd0 which
# system-hurd.scm's file-systems record does not match.
#
# -no-reboot mirrors smoke-test.sh: catches a kernel-panic loop
# instead of letting qemu spin.
qemu-system-x86_64 \
    -m 1024 \
    -display none \
    -monitor none \
    -serial "file:$LOG" \
    -no-reboot \
    -snapshot \
    -drive "file=$IMG,format=raw,if=ide" &
QPID=$!

# step 3/4 success gate: any of the pid1 lifecycle markers that
# happen before the full -l chain.  step 6 will tighten this to the
# userland-up marker.
SUCCESS_USERLAND_RE='geos: emacs userland up'
# failure markers: hurd gnumach panics, plus the same generic kernel
# panic strings linux can emit on a confused boot.
FAIL_RE='gnumach: panic|panic: |Hurd server died|Kernel panic'

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if [ -s "$LOG" ] && grep -Eq "$FAIL_RE" "$LOG"; then
        echo "hurd-smoke-test: FAIL"
        echo "--- matched failure markers ---"
        grep -En "$FAIL_RE" "$LOG" || true
        echo "--- last 30 lines of serial log ---"
        tail -n 30 "$LOG"
        exit 1
    fi
    if [ -s "$LOG" ] && grep -Eq "$SUCCESS_USERLAND_RE" "$LOG"; then
        echo "hurd-smoke-test: PASS (console)"
        echo "--- matched userland markers ---"
        grep -En "$SUCCESS_USERLAND_RE" "$LOG" || true
        exit 0
    fi
    sleep 1
done

echo "hurd-smoke-test: TIMEOUT after ${TIMEOUT}s, userland-up marker never matched"
echo "--- last 30 lines of serial log ---"
if [ -s "$LOG" ]; then
    tail -n 30 "$LOG"
else
    echo "(serial log was empty, qemu may have failed to start)"
fi
exit 2
