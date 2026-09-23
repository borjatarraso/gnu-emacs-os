#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
# Copyright (C) 2026  Adrian Yanes <ayanes@gnu.org>
#
# docker-build.sh, build a GEOS qcow2 inside a Guix container.
#
# Intended for macOS (and other non-Linux) hosts where Guix and /dev/kvm
# are unavailable. On Linux with Guix installed, use dev-vm.sh instead;
# it builds natively and boots with KVM.
#
# usage:
#   ./iso-build/docker-build.sh
#   QCOW=$(./iso-build/docker-build.sh)
#
# environment:
#   GEOS_GUIX_IMAGE   override the container image (default: debdistutils)

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)
OUT_DIR="$REPO_ROOT/.build"
OUT_QCOW="$OUT_DIR/geos-dev.qcow2"

GUIX_IMAGE=${GEOS_GUIX_IMAGE:-registry.gitlab.com/debdistutils/guix/container:latest}

if ! command -v docker >/dev/null 2>&1; then
    echo "docker-build.sh: docker not found" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

echo "docker-build.sh: building qcow2 in $GUIX_IMAGE" >&2
echo "docker-build.sh: first build can take 30+ minutes; /gnu/store lives in the container" >&2

docker run --rm --platform linux/amd64 --privileged \
    -v "$REPO_ROOT:/geos:rw" \
    -w /geos \
    "$GUIX_IMAGE" \
    sh -eu -c '
        cp -rL /gnu/store/*profile/etc/* /etc/ 2>/dev/null || true
        if ! grep -q "^root:" /etc/passwd 2>/dev/null; then
            echo "root:x:0:0:root:/:/bin/sh" > /etc/passwd
        fi
        if ! grep -q "^root:" /etc/group 2>/dev/null; then
            echo "root:x:0:" > /etc/group
        fi
        if ! getent group guixbuild >/dev/null 2>&1; then
            groupadd --system guixbuild
        fi
        i=1
        while [ "$i" -le 10 ]; do
            u=$(printf guixbuilder%02d "$i")
            if ! id "$u" >/dev/null 2>&1; then
                useradd -g guixbuild -G guixbuild -d /var/empty \
                    -s "$(command -v nologin)" -c "Guix build user $i" \
                    --system "$u"
            fi
            i=$((i + 1))
        done
        export HOME=/
        guix-daemon --disable-chroot --build-users-group=guixbuild &
        DAEMON_PID=$!
        trap "kill $DAEMON_PID 2>/dev/null || true" EXIT INT TERM
        for key in /share/guix/*.pub; do
            guix archive --authorize < "$key" || true
        done
        guix install libgpg-error gcc-toolchain make >/dev/null
        GUIX_PROFILE="/.guix-profile"
        # shellcheck disable=SC1090
        . "$GUIX_PROFILE/etc/profile"
        mkdir -p /geos/.build
        QCOW=$(./iso-build/dev-vm.sh --build-only)
        cp -f "$QCOW" /geos/.build/geos-dev.qcow2
    ' >/dev/null

if [ ! -f "$OUT_QCOW" ]; then
    echo "docker-build.sh: build did not produce $OUT_QCOW" >&2
    exit 1
fi

echo "$OUT_QCOW"
