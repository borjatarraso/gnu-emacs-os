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
# QPID is assigned immediately after the qemu fork; using a shell var
# (not a pid file) eliminates the open-then-write race where a SIGINT
# arriving between `qemu &` and `cat >file` would leak qemu.
QPID=
cleanup() {
    if [ -n "$QPID" ]; then
        # SIGTERM first so qemu can flush stdio and tear down KVM
        # cleanly. give it 2 whole seconds (integer sleep, not 0.1,
        # because POSIX sh requires integer arguments to sleep, dash
        # and busybox both reject fractions, and the script uses
        # #!/bin/sh) then SIGKILL anything that didn't notice. the
        # qcow2 is read-only via -snapshot, so data integrity isn't
        # at risk either way; this stops qemu from leaving stale
        # tap fds or virtio-net entries on the host network
        # namespace when the smoke test is rerun back-to-back.
        kill -TERM "$QPID" 2>/dev/null || true
        i=0
        while [ "$i" -lt 2 ] && kill -0 "$QPID" 2>/dev/null; do
            i=$((i + 1))
            sleep 1
        done
        kill -KILL "$QPID" 2>/dev/null || true
        # zero the pid so the EXIT trap re-firing after INT/TERM
        # doesn't run the whole TERM-grace-KILL dance against an
        # already-dead pid (or, worse, against a recycled one).
        QPID=
    fi
    rm -f "$LOG"
}
# HUP added so closing the controlling terminal still runs cleanup
# (without it, qemu would be inherited by init and leak). QUIT for
# C-\ symmetry with INT.
trap cleanup EXIT INT TERM HUP QUIT

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
QPID=$!

# multi-layer success gate, mode-aware:
#
#   PID1 marker: supervisor reached its main loop with a known mode
#     active. catches Xorg-died-and-pid1-fell-back half-failures
#     (because we require the mode-specific line, not just "entering
#     supervisor loop"). also tells us which mode this image boots in.
#       UI mode:      "pid1: X server up on :0"
#       console mode: "pid1: geos.mode=console"
#
#   USERLAND marker: emacs got past the entire -l chain and ran
#     boot-marker.el. proves init.el, panic.el, all userland modules,
#     all buffers actually loaded.
#       both modes:   "geos: emacs userland up"
#
#   VAR marker (v0.4 item 1): pid1 mounted /var either as ext4 (geos-var
#     label found) or as tmpfs (fallback). missing this line means
#     mount_var() either crashed or printed nothing, which would leave
#     state.el's ensure-layout silently writing into rootfs.
#       persistent:   "pid1: /var on ext4"
#       tmpfs:        "pid1: /var on tmpfs"
#
#   STATE marker (v0.4 item 1): state.el's bottom-of-load auto-init
#     ran and detected a state-mode. proves the elisp half of the
#     persistent-state subsystem loaded and produced a writable layout.
#       both modes:   "geos: state-mode="
#
#   SUPERVISE marker (v0.4 item 2): supervise.el's finalize ran AFTER
#     every defservice form, so the registry has every entry the
#     boot chain registered. number is informational; >=1 means at
#     least journal-tail registered.
#       both modes:   "supervise: registry loaded N entries"
#
#   RPC marker (v0.6 item 3): rpc-server.el bound /run/geos/super.sock
#     via pid1-rpc-listen.  missing this line means the supervisor came
#     up but the user-emacs has no privileged channel; geos-rpc-* will
#     time out on the client side.  this gate would have caught the
#     libcrypt.so.2 module-load miss in v0.5.1 (where module-load
#     silently failed and every pid1-* primitive was unbound).
#       both modes:   "rpc: listening on /run/geos/super.sock"
#
# pass = (any pid1 marker) AND userland AND var AND state AND supervise
#        AND rpc.
#
# we do NOT gate on "geos: exwm up" headlessly. exwm-init-hook only
# fires once EXWM processes its first real X event, which depends on
# user interaction; in a -display none QEMU there is no such event.
# boot-marker.el still arms that hook so an interactive freeze-test
# session can grep for it, but smoke-test does not require it.
SUCCESS_PID1_UI_RE='pid1: X server up on :0'
SUCCESS_PID1_CONSOLE_RE='pid1: geos\.mode=console'
SUCCESS_USERLAND_RE='geos: emacs userland up'
SUCCESS_VAR_RE='pid1: /var on (ext4|tmpfs)'
SUCCESS_STATE_RE='geos: state-mode='
SUCCESS_SUPERVISE_RE='supervise: registry loaded [0-9]+ entries'
SUCCESS_RPC_RE='rpc: listening on /run/geos/super\.sock'

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
    if [ -s "$LOG" ] \
       && grep -Eq "$SUCCESS_USERLAND_RE" "$LOG" \
       && grep -Eq "$SUCCESS_VAR_RE" "$LOG" \
       && grep -Eq "$SUCCESS_STATE_RE" "$LOG" \
       && grep -Eq "$SUCCESS_SUPERVISE_RE" "$LOG" \
       && grep -Eq "$SUCCESS_RPC_RE" "$LOG"; then
        if grep -Eq "$SUCCESS_PID1_UI_RE" "$LOG"; then
            echo "smoke-test: PASS (ui)"
            echo "--- matched pid1 markers ---"
            grep -En "$SUCCESS_PID1_UI_RE" "$LOG" || true
            echo "--- matched userland markers ---"
            grep -En "$SUCCESS_USERLAND_RE" "$LOG" || true
            echo "--- matched /var markers ---"
            grep -En "$SUCCESS_VAR_RE" "$LOG" || true
            echo "--- matched state markers ---"
            grep -En "$SUCCESS_STATE_RE" "$LOG" || true
            echo "--- matched supervise markers ---"
            grep -En "$SUCCESS_SUPERVISE_RE" "$LOG" || true
            echo "--- matched rpc markers ---"
            grep -En "$SUCCESS_RPC_RE" "$LOG" || true
            exit 0
        elif grep -Eq "$SUCCESS_PID1_CONSOLE_RE" "$LOG"; then
            echo "smoke-test: PASS (console)"
            echo "--- matched pid1 markers ---"
            grep -En "$SUCCESS_PID1_CONSOLE_RE" "$LOG" || true
            echo "--- matched userland markers ---"
            grep -En "$SUCCESS_USERLAND_RE" "$LOG" || true
            echo "--- matched /var markers ---"
            grep -En "$SUCCESS_VAR_RE" "$LOG" || true
            echo "--- matched state markers ---"
            grep -En "$SUCCESS_STATE_RE" "$LOG" || true
            echo "--- matched supervise markers ---"
            grep -En "$SUCCESS_SUPERVISE_RE" "$LOG" || true
            echo "--- matched rpc markers ---"
            grep -En "$SUCCESS_RPC_RE" "$LOG" || true
            exit 0
        fi
    fi
    sleep 1
done

echo "smoke-test: TIMEOUT after ${TIMEOUT}s, success markers never matched"
echo "--- last 30 lines of serial log ---"
if [ -s "$LOG" ]; then
    tail -n 30 "$LOG"
else
    echo "(serial log was empty, qemu may have failed to start)"
fi
exit 2
