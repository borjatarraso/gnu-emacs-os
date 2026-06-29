#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
# Copyright (C) 2026  Adrian Yanes <ayanes@gnu.org>
#
# dev-vm-macos.sh, build GEOS in Docker and boot it on macOS.
#
# Linux hosts with Guix and KVM should use dev-vm.sh instead (native
# build, faster KVM boot). This wrapper is for macOS (and any host
# without a local Guix install): it builds the qcow2 inside a Guix
# container via docker-build.sh, then hands off to dev-vm.sh for QEMU
# boot (TCG on Apple Silicon, so first boot is slow).
#
# usage:
#   ./iso-build/dev-vm-macos.sh
#   ./iso-build/dev-vm-macos.sh --build-only
#   ./iso-build/dev-vm-macos.sh --boot /path/to.qcow2
#
# dev-vm.sh on macOS without guix execs this script automatically.

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)

cd "$REPO_ROOT"

BUILD=1
BOOT=1
EXISTING_QCOW=
PASS_ARGS=

while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) BUILD=1; BOOT=0; shift ;;
        --boot)
            BUILD=0
            shift
            EXISTING_QCOW=${1:?--boot needs a path}
            shift ;;
        --)
            shift
            PASS_ARGS=$*
            break ;;
        -h|--help)
            sed -n '1,30p' "$0"
            exit 0 ;;
        *)
            echo "dev-vm-macos.sh: unknown arg: $1" >&2
            exit 2 ;;
    esac
done

QCOW=
if [ "$BUILD" = 1 ]; then
    if [ -f "$REPO_ROOT/.build/geos-dev.qcow2" ]; then
        QCOW="$REPO_ROOT/.build/geos-dev.qcow2"
        echo "dev-vm-macos.sh: using existing $QCOW" >&2
    else
        QCOW=$("$SELF_DIR/docker-build.sh")
        if [ -z "$QCOW" ] || [ ! -f "$QCOW" ]; then
            echo "dev-vm-macos.sh: build did not return a qcow2 path" >&2
            exit 1
        fi
        echo "dev-vm-macos.sh: built $QCOW" >&2
    fi
else
    QCOW=$EXISTING_QCOW
fi

if [ "$BOOT" = 0 ]; then
    echo "$QCOW"
    exit 0
fi

if [ -n "$PASS_ARGS" ]; then
    exec "$SELF_DIR/dev-vm.sh" --boot "$QCOW" -- $PASS_ARGS
else
    exec "$SELF_DIR/dev-vm.sh" --boot "$QCOW"
fi
