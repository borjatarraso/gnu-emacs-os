#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Borja Tarraso <borja.tarraso@member.fsf.org>
#
# smoke-test.sh, headless boot of a GEOS qcow2 with serial-log marker
# checks. catches the class of regression that just shipped (xorg.conf
# parse error -> Xorg respawn loop -> no DISPLAY -> no EXWM) without
# needing a human to look at a graphical window.
#
# what it does:
#   1. boots the qcow2 in qemu with -display none and serial wired to
#      a tmpfile (no graphics, no monitor stdio takeover, no human in
#      the loop)
#   2. polls the serial log for either a success marker or a failure
#      marker, with a deadline
#   3. exits 0/1/2 (pass/fail/timeout) and prints the relevant tail of
#      the log
#
# what it does NOT do:
#   - it cannot pick the boot mode by itself, the qcow2 boots through
#     GRUB and we never re-enter the menu. the smoke test trusts
#     whatever geos.mode= is baked into kernel-arguments
#   - it cannot verify that EXWM grabbed the root window; that's not
#     visible on serial. "X server up on :0" plus a quiet supervisor
#     loop is the closest signal we can read without a display
#
# usage:
#
#   ./iso-build/smoke-test.sh                  # build then test
#   ./iso-build/smoke-test.sh /path/to.qcow2   # test existing image
#   ./iso-build/smoke-test.sh -t 90 ...        # raise the deadline

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)

cd "$REPO_ROOT"

TIMEOUT=60
QCOW=

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--timeout)
            shift
            TIMEOUT=${1:?--timeout needs seconds}
            shift ;;
        -h|--help)
            sed -n '1,30p' "$0"
            exit 0 ;;
        -*)
            echo "smoke-test: unknown flag: $1" >&2
            exit 2 ;;
        *)
            QCOW=$1
            shift ;;
    esac
done

if [ -z "$QCOW" ]; then
    echo "smoke-test: no qcow2 given, building one"
    QCOW=$("$SELF_DIR/dev-vm.sh" --build-only)
fi
if [ ! -f "$QCOW" ]; then
    echo "smoke-test: qcow2 not found: $QCOW" >&2
    exit 2
fi

LOG=$(mktemp -t geos-smoke.XXXXXX.log)
PIDFILE=$(mktemp -t geos-smoke.XXXXXX.pid)
cleanup() {
    if [ -s "$PIDFILE" ]; then
        QPID=$(cat "$PIDFILE")
        # SIGKILL: we do not want a polite shutdown to extend the
        # smoke window. the qcow2 is read-only via -snapshot anyway.
        kill -KILL "$QPID" 2>/dev/null || true
    fi
    rm -f "$LOG" "$PIDFILE"
}
trap cleanup EXIT INT TERM

echo "smoke-test: booting $QCOW (timeout ${TIMEOUT}s, log $LOG)"

# -display none      no graphical window
# -monitor none      do not steal stdio for the qemu monitor
# -serial file:LOG   serial console straight to log file
# -snapshot          all writes to scratch, qcow2 untouched
# -no-reboot         if anything calls reboot(2), exit qemu instead of
#                    looping (catches kernel-panic paths fast)
qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -cpu host \
    -smp 2 \
    -vga virtio \
    -display none \
    -monitor none \
    -device qemu-xhci,id=xhci \
    -device usb-tablet,bus=xhci.0 \
    -serial "file:$LOG" \
    -no-reboot \
    -snapshot \
    -drive "file=$QCOW,format=qcow2,if=virtio" &
echo $! > "$PIDFILE"

# success markers (any one of these means the boot got far enough):
#   "pid1: X server up on :0"     UI mode reached the supervisor
#   "pid1: geos.mode=console"     console mode acknowledged the cmdline
# both modes also print "pid1: entering supervisor loop" but we want
# the mode-specific marker so a half-failed UI boot (where Xorg dies
# but pid1 still loops on bare emacs) does not silently pass.
SUCCESS_RE='pid1: X server up on :0|pid1: geos\.mode=console'

# failure markers (any one means hard fail, do not wait for timeout):
#   xorg parse errors, screen-discovery failures
#   pid1 reporting Xorg gave up
#   kernel panic (unlikely here but cheap to catch)
FAIL_RE='Parse error on line|no screens found|pid1: Xorg respawn failed|pid1: Xorg crashloop|pid1: spawn_xorg failed|pid1: X socket /tmp/\.X11-unix/X0 never appeared|Kernel panic'

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if [ -s "$LOG" ] && grep -Eq "$FAIL_RE" "$LOG"; then
        echo "smoke-test: FAIL"
        echo "--- matched failure markers ---"
        grep -En "$FAIL_RE" "$LOG" || true
        echo "--- last 30 lines of serial log ---"
        tail -n 30 "$LOG"
        exit 1
    fi
    if [ -s "$LOG" ] && grep -Eq "$SUCCESS_RE" "$LOG"; then
        echo "smoke-test: PASS"
        echo "--- matched success markers ---"
        grep -En "$SUCCESS_RE" "$LOG" || true
        exit 0
    fi
    sleep 1
done

echo "smoke-test: TIMEOUT after ${TIMEOUT}s, neither marker appeared"
echo "--- last 30 lines of serial log ---"
if [ -s "$LOG" ]; then
    tail -n 30 "$LOG"
else
    echo "(serial log was empty, qemu may have failed to start)"
fi
exit 2
