#!/bin/bash
# hurd-pselect-stress.sh -- v1.x stress profile for the supervised
# emacs pselect path on the canonical Debian GNU/Hurd 0.9 image
# baked by iso-build/hurd-image-reroll.sh.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
# Author: Borja Tarraso <borja.tarraso@member.fsf.org>
#
# WHY this exists: v0.9.24 shipped a 35-min / 1383-eval soak that
# closed task #213 with a "non-reproducible at this exercise level"
# verdict, captured in docs/runlogs/2026-05-30-hurd-pselect-soak-35min.md.
# the receipt's open follow-on #1 hints at the stronger statement i
# want next: ~10000 evals, no host sleep between iters (SSH-mux RTT
# is the only pacing), and bursts of 10 instead of bursts of 3.
# this script is that profile. it lives under iso-build/ because it
# is a host-side QEMU driver, same class as hurd-image-reroll.sh and
# hurd-fast-iterate.sh; the /no-shell-check rule covers code that
# runs INSIDE the OS, not host-side test infrastructure.
#
# the script is /bin/bash on purpose. /bin/sh in this repo is the
# eshell stub from shstub/ and is not a real shell. host-side drivers
# that want arrays, process substitution, or wait -n use bash directly.
#
# CONTRACT i hold with the operator:
#   - i do NOT touch the on-disk image. all writes land in QEMU's
#     own snapshot overlay if the operator booted with -snapshot;
#     this script does not boot QEMU, it expects the operator has
#     already done so on STRESS_SSH_PORT (default 2266, matching the
#     iso-build convention).
#   - i do NOT fix bugs. if a crash marker fires i record where and
#     exit nonzero so the operator can dispatch to pid1-engineer.
#   - the 10000-eval target is multi-hour. nothing in this script
#     short-circuits the target except a hard crash marker hit.
#
# EVAL SPLIT MATH:
#   - i drive ITERS = ceil(STRESS_TARGET_EVALS / IPI) driver iters,
#     where IPI is "evals per iteration averaged across the burst
#     cadence". with STRESS_BURST_SIZE=10 and STRESS_BURST_EVERY=20,
#     1 in every 20 iters does 10 evals and the other 19 do 1 each.
#     so IPI = (19 + 10) / 20 = 1.45, and ITERS = ceil(10000/1.45)
#     = 6897.
#   - at the v0.9.24 measured ~1.8 s/iter SSH-mux RTT, 6897 iters is
#     ~3 h 27 min wall clock. with no host sleep, RTT may compress
#     to ~0.6 s/iter; floor is ~1 h 9 min wall clock. the operator
#     should budget at least 4 h to be safe.
#   - the SUMMARY block at the end recomputes the actuals so the
#     receipt math matches what really happened, not what was planned.
#
# CRASH MARKERS i grep against STRESS_SERIAL_LOG every 60 s:
#   - SIGSEGV
#   - "Mach exception"
#   - __mach_msg
#   - "pid1: emacs exited"
#   - kill_emacs
# any hit aborts the soak with a captured serial context window.
#
# usage:
#   ./iso-build/hurd-pselect-stress.sh
#   STRESS_TARGET_EVALS=2000 ./iso-build/hurd-pselect-stress.sh
#
# DO NOT RUN this script casually. it is multi-hour. the default
# 10000-eval target is a v1.x cycle artifact, not a per-commit gate.

set -uo pipefail

STRESS_TARGET_EVALS="${STRESS_TARGET_EVALS:-10000}"
STRESS_BURST_SIZE="${STRESS_BURST_SIZE:-10}"
STRESS_BURST_EVERY="${STRESS_BURST_EVERY:-20}"
STRESS_SSH_HOST="${STRESS_SSH_HOST:-root@127.0.0.1}"
STRESS_SSH_PORT="${STRESS_SSH_PORT:-2266}"
STRESS_SSH_IDENT="${STRESS_SSH_IDENT:-$HOME/.ssh/geos_hurd_id_ed25519}"
STRESS_SERIAL_LOG="${STRESS_SERIAL_LOG:-/tmp/v1x-stress-serial.log}"
STRESS_PASS_LOG="${STRESS_PASS_LOG:-/tmp/v1x-stress-pass.log}"
STRESS_FAIL_LOG="${STRESS_FAIL_LOG:-/tmp/v1x-stress-fail.log}"
STRESS_PID_LOG="${STRESS_PID_LOG:-/tmp/v1x-stress-pid.log}"

# ssh-mux control socket. per-run path keyed by $$ so a concurrent
# soak on a different image (different port) does not collide.
STRESS_SSH_MUX="${STRESS_SSH_MUX:-/tmp/v1x-stress-mux-$$.sock}"

log() {
    printf '[hurd-pselect-stress] %s\n' "$*" >&2
}

# rfc3339 timestamp with timezone offset; matches the convention the
# v0.9.24 receipt uses on its serial timestamps. no trailing newline.
ts() {
    date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# crash markers as an array; iterated by crash_grep below. keep these
# in lockstep with the markers documented in the header comment.
CRASH_MARKERS=(
    'SIGSEGV'
    'Mach exception'
    '__mach_msg'
    'pid1: emacs exited'
    'kill_emacs'
)

# ssh args: ControlMaster mux so every eval reuses one TCP+SSH session.
# StrictHostKeyChecking=no because every re-roll bakes fresh sshd host
# keys and i do not want this script's known_hosts churn to contaminate
# the operator's ~/.ssh/known_hosts. ConnectTimeout=10 keeps the mux
# open call bounded; later eval calls reuse the mux and pay sub-RTT.
SSH_BASE_OPTS=(
    -o "StrictHostKeyChecking=no"
    -o "UserKnownHostsFile=/dev/null"
    -o "LogLevel=ERROR"
    -o "ControlMaster=auto"
    -o "ControlPath=${STRESS_SSH_MUX}"
    -o "ControlPersist=10m"
    -i "${STRESS_SSH_IDENT}"
    -p "${STRESS_SSH_PORT}"
)

ssh_run() {
    # shellcheck disable=SC2029
    # SC2029: client-side expansion of "$@" is intentional. callers
    # pass literal command strings (see ssh_eval, ssh_pid_snap) that
    # need to land on the remote shell as-is, not re-quoted locally.
    ssh "${SSH_BASE_OPTS[@]}" "${STRESS_SSH_HOST}" "$@"
}

# one eval round-trip. stdout is the emacsclient response. i return
# the ssh exit code so the caller can classify PASS vs FAIL by ssh
# transport success, not by eval body content. the eval body itself
# is `(length (buffer-list))`, matching the v0.9.24 baseline driver.
ssh_eval() {
    ssh_run "emacsclient --no-wait -e '(length (buffer-list))'" 2>/dev/null
}

# pid snapshot for the supervised emacs. matches the v0.9.24 receipt
# ps line (root  30  1  co  ...  /usr/bin/emacs ...). i pgrep -f the
# emacs argv because pgrep -x emacs alone misses the absolute path.
ssh_pid_snap() {
    ssh_run "pgrep -f '/usr/bin/emacs' | head -1" 2>/dev/null
}

# crash grep against the serial log. returns 0 on match, 1 on no
# match. STRESS_SERIAL_LOG may not exist if the operator forgot to
# wire -serial file:... into QEMU; in that case i return 1 silently
# so the soak continues, but i log a warning the first time.
WARNED_SERIAL_MISSING=0
crash_grep() {
    if [[ ! -f "${STRESS_SERIAL_LOG}" ]]; then
        if [[ "${WARNED_SERIAL_MISSING}" -eq 0 ]]; then
            log "WARNING: serial log ${STRESS_SERIAL_LOG} missing, crash-grep disabled"
            WARNED_SERIAL_MISSING=1
        fi
        return 1
    fi
    local m
    for m in "${CRASH_MARKERS[@]}"; do
        if grep -aFq -- "${m}" "${STRESS_SERIAL_LOG}"; then
            log "CRASH MARKER HIT: ${m}"
            return 0
        fi
    done
    return 1
}

# trap: kill the ssh mux master on any exit path so a re-run does
# not collide with a stale socket. ssh -O exit returns nonzero if
# the mux is already gone; do not let that propagate via set -e.
# shellcheck disable=SC2329
# SC2329: cleanup is invoked via the `trap ... EXIT` line below,
# which shellcheck does not statically detect.
cleanup() {
    if [[ -S "${STRESS_SSH_MUX}" ]]; then
        ssh -O exit "${SSH_BASE_OPTS[@]}" "${STRESS_SSH_HOST}" 2>/dev/null || true
        rm -f "${STRESS_SSH_MUX}"
    fi
}
trap cleanup EXIT INT TERM

# input sanity. ssh and the identity file must both be readable;
# the serial log is optional but i log its presence/absence up front.
if ! command -v ssh >/dev/null 2>&1; then
    log "FATAL: ssh not on PATH"
    exit 1
fi
if [[ ! -r "${STRESS_SSH_IDENT}" ]]; then
    log "FATAL: ssh identity not readable: ${STRESS_SSH_IDENT}"
    exit 1
fi
if [[ ! -f "${STRESS_SERIAL_LOG}" ]]; then
    log "WARNING: serial log not present at start: ${STRESS_SERIAL_LOG}"
    log "  crash-grep will activate when the operator wires it up mid-soak"
fi

# truncate the per-soak append-only logs. the serial log is operator-
# owned (QEMU writes it); i never touch it.
: > "${STRESS_PASS_LOG}"
: > "${STRESS_FAIL_LOG}"
: > "${STRESS_PID_LOG}"

# eval-per-iter average for ITERS calculation. 19 plain iters + 1
# burst-of-N iter per STRESS_BURST_EVERY window. IPI is a float i
# carry as integer-times-1000 to avoid awk for the simple cases.
# example: BURST_SIZE=10, BURST_EVERY=20 -> IPI*1000 = (19000 + 10000) / 20 = 1450.
IPI_X1000=$(( ((STRESS_BURST_EVERY - 1) * 1000 + STRESS_BURST_SIZE * 1000) / STRESS_BURST_EVERY ))
if [[ "${IPI_X1000}" -le 0 ]]; then
    log "FATAL: computed IPI is zero or negative; check STRESS_BURST_SIZE/EVERY"
    exit 1
fi
# ITERS = ceil(TARGET * 1000 / IPI_X1000).
ITERS=$(( (STRESS_TARGET_EVALS * 1000 + IPI_X1000 - 1) / IPI_X1000 ))

log "stress profile:"
log "  target evals       : ${STRESS_TARGET_EVALS}"
log "  burst size         : ${STRESS_BURST_SIZE}"
log "  burst every        : ${STRESS_BURST_EVERY} iters"
log "  computed iters     : ${ITERS} (IPI=${IPI_X1000}/1000)"
log "  ssh host           : ${STRESS_SSH_HOST}:${STRESS_SSH_PORT}"
log "  ssh identity       : ${STRESS_SSH_IDENT}"
log "  ssh mux            : ${STRESS_SSH_MUX}"
log "  serial log         : ${STRESS_SERIAL_LOG}"
log "  pass log           : ${STRESS_PASS_LOG}"
log "  fail log           : ${STRESS_FAIL_LOG}"
log "  pid log            : ${STRESS_PID_LOG}"

# warm the mux. if this fails the operator gave us a bad host/port/key
# and i want to find out now, not on iter 1.
log "warming ssh mux..."
if ! ssh_run 'true'; then
    log "FATAL: ssh warm failed; verify the guest is up on port ${STRESS_SSH_PORT}"
    exit 1
fi

# initial pid snapshot. drift is computed as (final != initial) OR
# (any side-poll != initial). a respawn changes pid; a stable pid
# across the whole soak means pid1 never had to re-fork emacs.
INITIAL_PID="$(ssh_pid_snap)"
if [[ -z "${INITIAL_PID}" ]]; then
    log "FATAL: could not read initial emacs pid via pgrep"
    exit 1
fi
printf '%s initial pid=%s\n' "$(ts)" "${INITIAL_PID}" >> "${STRESS_PID_LOG}"
log "initial supervised emacs pid: ${INITIAL_PID}"

# counters. these become the SUMMARY block at end of run.
PASS_COUNT=0
FAIL_COUNT=0
SEQUENTIAL_EVALS=0
BURST_EVALS=0
TOTAL_EVALS=0
MID_SOAK_RESPAWNS=0
SIDE_POLL_COUNT=0
SIDE_POLL_DRIFTS=0
LAST_PID_SNAP="${INITIAL_PID}"

# wall-clock anchors for the periodic 30 s pid poll and 60 s crash
# grep. epoch seconds, refreshed at the top of each iter.
START_EPOCH="$(date +%s)"
NEXT_PID_POLL_EPOCH=$(( START_EPOCH + 30 ))
NEXT_CRASH_GREP_EPOCH=$(( START_EPOCH + 60 ))

# the main loop. iter index i is 1-based for readability in logs.
log "starting soak; first eval at $(ts)"
for (( i=1; i<=ITERS; i++ )); do

    NOW_EPOCH="$(date +%s)"

    # 30 s pid poll. snap the supervised emacs pid; record drift in
    # both the pid log and the in-memory counters. a drift is a
    # mid-soak respawn signal even if the new pid is reachable; i
    # log it but i do NOT abort, because the supervisor restoring
    # the user emacs is a successful failure mode worth measuring.
    if (( NOW_EPOCH >= NEXT_PID_POLL_EPOCH )); then
        SNAP_PID="$(ssh_pid_snap)"
        SIDE_POLL_COUNT=$(( SIDE_POLL_COUNT + 1 ))
        if [[ -z "${SNAP_PID}" ]]; then
            printf '%s side-poll #%d pid=MISSING (emacs gone)\n' \
                "$(ts)" "${SIDE_POLL_COUNT}" >> "${STRESS_PID_LOG}"
            SIDE_POLL_DRIFTS=$(( SIDE_POLL_DRIFTS + 1 ))
            MID_SOAK_RESPAWNS=$(( MID_SOAK_RESPAWNS + 1 ))
        else
            printf '%s side-poll #%d pid=%s\n' \
                "$(ts)" "${SIDE_POLL_COUNT}" "${SNAP_PID}" >> "${STRESS_PID_LOG}"
            if [[ "${SNAP_PID}" != "${LAST_PID_SNAP}" ]]; then
                SIDE_POLL_DRIFTS=$(( SIDE_POLL_DRIFTS + 1 ))
                MID_SOAK_RESPAWNS=$(( MID_SOAK_RESPAWNS + 1 ))
                log "PID DRIFT: was ${LAST_PID_SNAP}, now ${SNAP_PID}"
                LAST_PID_SNAP="${SNAP_PID}"
            fi
        fi
        NEXT_PID_POLL_EPOCH=$(( NOW_EPOCH + 30 ))
    fi

    # 60 s crash grep. any hit terminates the soak with a captured
    # context window so the operator can hand the diagnostic to
    # pid1-engineer without re-grepping a multi-hundred-MB log.
    if (( NOW_EPOCH >= NEXT_CRASH_GREP_EPOCH )); then
        if crash_grep; then
            log "soak ABORTED on iter ${i}; serial context follows"
            log "  last 60 serial lines:"
            tail -60 "${STRESS_SERIAL_LOG}" 2>/dev/null \
                | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/^/    /'
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            break
        fi
        NEXT_CRASH_GREP_EPOCH=$(( NOW_EPOCH + 60 ))
    fi

    # is this a burst iter or a sequential iter? the burst lands on
    # iters that are multiples of STRESS_BURST_EVERY. the very first
    # iter (i==1) is sequential so the soak does not open with a
    # parallel-N storm before the mux has fully warmed.
    if (( i % STRESS_BURST_EVERY == 0 )); then
        # burst of STRESS_BURST_SIZE parallel evals. i fork N ssh
        # calls (all using the same mux) and wait for all. ssh mux
        # serialises channels server-side, but the host-side parallel
        # makes the supervised emacs see N simultaneous emacsclient
        # connections inside one pselect window. each parallel eval
        # is its own PASS/FAIL classification.
        BURST_PIDS=()
        BURST_RC_FILES=()
        for (( b=0; b<STRESS_BURST_SIZE; b++ )); do
            RC_FILE="$(mktemp /tmp/v1x-stress-burst-rc.XXXXXX)"
            BURST_RC_FILES+=( "${RC_FILE}" )
            (
                if ssh_eval >/dev/null 2>&1; then
                    printf '0' > "${RC_FILE}"
                else
                    printf '1' > "${RC_FILE}"
                fi
            ) &
            BURST_PIDS+=( $! )
        done
        for bp in "${BURST_PIDS[@]}"; do
            wait "${bp}" 2>/dev/null || true
        done
        BURST_OK=0
        BURST_KO=0
        for rcf in "${BURST_RC_FILES[@]}"; do
            RC="$(cat "${rcf}" 2>/dev/null || printf '1')"
            if [[ "${RC}" == "0" ]]; then
                BURST_OK=$(( BURST_OK + 1 ))
            else
                BURST_KO=$(( BURST_KO + 1 ))
            fi
            rm -f "${rcf}"
        done
        BURST_EVALS=$(( BURST_EVALS + STRESS_BURST_SIZE ))
        TOTAL_EVALS=$(( TOTAL_EVALS + STRESS_BURST_SIZE ))
        PASS_COUNT=$(( PASS_COUNT + BURST_OK ))
        FAIL_COUNT=$(( FAIL_COUNT + BURST_KO ))
        if (( BURST_KO == 0 )); then
            printf '%s iter=%d evals=%d burst=%d PASS\n' \
                "$(ts)" "${i}" "${TOTAL_EVALS}" "${STRESS_BURST_SIZE}" \
                | tee -a "${STRESS_PASS_LOG}"
        else
            printf '%s iter=%d evals=%d burst=%d FAIL ok=%d ko=%d\n' \
                "$(ts)" "${i}" "${TOTAL_EVALS}" "${STRESS_BURST_SIZE}" "${BURST_OK}" "${BURST_KO}" \
                | tee -a "${STRESS_FAIL_LOG}"
        fi
    else
        # sequential single eval; no host sleep, SSH-mux RTT paces.
        if ssh_eval >/dev/null 2>&1; then
            PASS_COUNT=$(( PASS_COUNT + 1 ))
            SEQUENTIAL_EVALS=$(( SEQUENTIAL_EVALS + 1 ))
            TOTAL_EVALS=$(( TOTAL_EVALS + 1 ))
            printf '%s iter=%d evals=%d seq=1 PASS\n' \
                "$(ts)" "${i}" "${TOTAL_EVALS}" \
                | tee -a "${STRESS_PASS_LOG}"
        else
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            SEQUENTIAL_EVALS=$(( SEQUENTIAL_EVALS + 1 ))
            TOTAL_EVALS=$(( TOTAL_EVALS + 1 ))
            printf '%s iter=%d evals=%d seq=1 FAIL\n' \
                "$(ts)" "${i}" "${TOTAL_EVALS}" \
                | tee -a "${STRESS_FAIL_LOG}"
        fi
    fi
done

# final pid snap. drift is recorded against the initial pid; this
# is the canonical "did pid1 have to respawn emacs across the soak"
# question that drives the SUMMARY block.
FINAL_PID="$(ssh_pid_snap)"
if [[ -z "${FINAL_PID}" ]]; then
    FINAL_PID="MISSING"
fi
printf '%s final pid=%s\n' "$(ts)" "${FINAL_PID}" >> "${STRESS_PID_LOG}"

END_EPOCH="$(date +%s)"
WALL_S=$(( END_EPOCH - START_EPOCH ))

# SUMMARY block. shape matches the v0.9.24 receipt counts table so
# the operator can drop this directly into a new docs/runlogs entry
# with minimal editing. PID drift here is the count of side-polls
# whose pid differed from the prior snap, NOT the binary "did pid
# change at all"; the latter is captured by initial vs final.
log ""
log "==== SUMMARY ===="
log "counts:"
log "  PASS                  : ${PASS_COUNT}"
log "  FAIL                  : ${FAIL_COUNT}"
log "  mid-soak respawns     : ${MID_SOAK_RESPAWNS}"
log "  PID drift             : ${SIDE_POLL_DRIFTS}   (initial=${INITIAL_PID}, final=${FINAL_PID}, side-polls=${SIDE_POLL_COUNT})"
log "  driver iterations     : ${i}   (target ${ITERS})"
log "  burst evals           : ${BURST_EVALS}"
log "  sequential evals      : ${SEQUENTIAL_EVALS}"
log "  total evals           : ${TOTAL_EVALS}   (target ${STRESS_TARGET_EVALS})"
log ""
log "timing:"
log "  wall-clock            : ${WALL_S} s"
if (( WALL_S > 0 )); then
    log "  eval throughput       : $(( TOTAL_EVALS / WALL_S )) eval/s (integer)"
fi
log ""
log "logs:"
log "  pass log              : ${STRESS_PASS_LOG} ($(wc -l < "${STRESS_PASS_LOG}") lines)"
log "  fail log              : ${STRESS_FAIL_LOG} ($(wc -l < "${STRESS_FAIL_LOG}") lines)"
log "  pid log               : ${STRESS_PID_LOG} ($(wc -l < "${STRESS_PID_LOG}") lines)"
if [[ -f "${STRESS_SERIAL_LOG}" ]]; then
    log "  serial log            : ${STRESS_SERIAL_LOG} ($(wc -l < "${STRESS_SERIAL_LOG}") lines)"
fi
log ""

# exit nonzero on any FAIL OR mid-soak respawn so a CI gate around
# this script can fail the v1.x cycle. operator dispatch in that
# case: hand the pass/fail/pid/serial quad to pid1-engineer.
if (( FAIL_COUNT > 0 )); then
    log "result: FAIL (${FAIL_COUNT} eval failures)"
    exit 2
fi
if (( MID_SOAK_RESPAWNS > 0 )); then
    log "result: FAIL (${MID_SOAK_RESPAWNS} mid-soak respawns)"
    exit 3
fi
log "result: PASS"
exit 0
