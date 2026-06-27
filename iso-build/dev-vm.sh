#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
# Copyright (C) 2026  Adrian Yanes <ayanes@gnu.org>
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
# dev-vm.sh, build a qcow2 dev image of GEOS and boot it under qemu.
#
# host support:
#   linux + guix + kvm:  native build and boot (this script, default path)
#   macOS (no guix):     auto-delegates to dev-vm-macos.sh (docker build + tcg)
#   either platform:     dev-vm.sh --boot <qcow2> once a qcow2 exists
#
# v0.3-track. qcow2 over iso9660 because the dev loop wants:
#   - writable root (so init.el edits survive a reboot)
#   - faster boot (no cdrom indirection)
#   - smaller turn-around than the reproducible release path
#
# for the byte-reproducible release ISO, use emacs-os.sh.
# this script does no git operations on purpose.
#
# usage:
#
#   ./iso-build/dev-vm.sh                  # build, then boot UI mode
#   ./iso-build/dev-vm.sh --build-only     # build, print path, exit
#   ./iso-build/dev-vm.sh --boot <qcow2>   # skip build, boot existing
#   ./iso-build/dev-vm.sh -- -snapshot     # extra qemu args after --
#
# console mode: GEOS picks the boot mode from the kernel cmdline
# (geos.mode=ui|console). this script does NOT pass an -append because
# the qcow2 boots through GRUB, not direct kernel. to land in console
# mode, hit `e` at the GRUB menu and append `geos.mode=console` to
# the linux line. full walkthrough in docs/INSTALL.md (search for
# "geos.mode=").

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)

# macOS without Guix: delegate build/default flows to dev-vm-macos.sh.
# --boot skips delegation: booting an existing qcow2 needs only qemu.
GEOS_WANT_BOOT_ONLY=0
for _arg in "$@"; do
    case "$_arg" in
        --boot) GEOS_WANT_BOOT_ONLY=1 ;;
    esac
done

if [ "$GEOS_WANT_BOOT_ONLY" = 0 ] && ! command -v guix >/dev/null 2>&1; then
    case "$(uname -s)" in
        Darwin)
            exec "$SELF_DIR/dev-vm-macos.sh" "$@"
            ;;
    esac
fi

cd "$REPO_ROOT"

if [ ! -f guix-system/channels.scm ] || [ ! -f guix-system/system.scm ]; then
    echo "dev-vm.sh: not in a GEOS checkout (missing guix-system/)" >&2
    exit 1
fi

BUILD=1
BOOT=1
EXISTING_QCOW=
QEMU_EXTRA=

while [ $# -gt 0 ]; do
    case "$1" in
        --build-only)
            BOOT=0; shift ;;
        --boot)
            BUILD=0
            shift
            EXISTING_QCOW=${1:?--boot needs a path}
            shift ;;
        --)
            shift
            QEMU_EXTRA=$*
            break ;;
        -h|--help)
            sed -n '1,30p' "$0"
            exit 0 ;;
        *)
            echo "dev-vm.sh: unknown arg: $1" >&2
            exit 2 ;;
    esac
done

QCOW=
if [ "$BUILD" = 1 ]; then
    # system.scm references ../pid1/emacs-init and ../shstub/sh as
    # local-file inputs. on a fresh clone (or after cleanup.sh) those
    # binaries are absent and `guix system image` dies with
    # canonicalize-path: No such file or directory. make is idempotent;
    # if the binaries are up to date this is a no-op.
    # diagnostics go to stderr because --build-only callers capture
    # stdout: smoke-test.sh does `QCOW=$(dev-vm.sh --build-only)` and
    # the path on the final stdout line is the contract.  any echo on
    # stdout above that line poisons QCOW with multi-line garbage.
    echo "dev-vm.sh: building host-side binaries (pid1, shstub)" >&2
    # emacs-init: static, built on the host (no shared deps to resolve).
    # pid1-module.so: dlopen'd from inside the booted guix image, so it
    # must link against guix's libxcrypt (libcrypt.so.1) and bake that
    # store path into RUNPATH.  building on the bare host yields a .so
    # with NEEDED libcrypt.so.2 and no RUNPATH, which dlopen inside the
    # image cannot resolve.  the module build therefore runs inside
    # `guix shell --pure` with gcc-toolchain + libxcrypt + emacs.  the
    # LIBXCRYPT_STOREPATH var is passed in because pure shell strips
    # `guix` itself, so the Makefile cannot shell out to find it.
    #
    # when the host lacks libc.a (common in minimal guix containers and
    # on macOS), fall back to `guix shell glibc:static` so PID 1 stays
    # statically linked. a dynamic emacs-init dies at boot with
    # "libgcc_s.so.1: cannot open shared object file" before userland.
    if ! make -C pid1 emacs-init >&2; then
        if command -v guix >/dev/null 2>&1; then
            guix shell gcc-toolchain glibc:static make -- \
                env CC=gcc make -C "$REPO_ROOT/pid1" emacs-init >&2
        else
            echo "dev-vm.sh: pid1 build failed and guix is unavailable" >&2
            exit 1
        fi
    fi
    LIBXCRYPT_STOREPATH=$(guix build libxcrypt 2>/dev/null)
    guix shell --pure coreutils bash gcc-toolchain libxcrypt \
        emacs-no-x-toolkit make -- \
        env LIBXCRYPT_STOREPATH="$LIBXCRYPT_STOREPATH" \
        make CC=gcc -C "$REPO_ROOT/pid1" module >&2
    make -C shstub >&2
    echo "dev-vm.sh: building qcow2 from $REPO_ROOT/guix-system/system.scm" >&2
    # filter for the /gnu/store/... line.  guix prints status messages
    # to stderr and the store path to stdout, but a deprecation warning
    # or substituter notice can land on stdout too; bare `tail -n 1`
    # would then return the wrong line.
    QCOW=$(guix time-machine -C guix-system/channels.scm -- \
        system image -t qcow2 -L "$REPO_ROOT" guix-system/system.scm \
        | grep -E '^/gnu/store/[^[:space:]]+' \
        | tail -n 1)
    if [ -z "$QCOW" ] || [ ! -f "$QCOW" ]; then
        echo "dev-vm.sh: build did not return a qcow2 path" >&2
        echo "dev-vm.sh: got: '$QCOW'" >&2
        exit 1
    fi
    echo "dev-vm.sh: built $QCOW" >&2
else
    QCOW=$EXISTING_QCOW
    if [ ! -f "$QCOW" ]; then
        echo "dev-vm.sh: --boot path not found: $QCOW" >&2
        exit 1
    fi
    QCOW=$(cd "$(dirname "$QCOW")" && pwd)/$(basename "$QCOW")
fi

if [ "$BOOT" = 0 ]; then
    echo "$QCOW"
    exit 0
fi

# the qcow2 from /gnu/store is read-only on the host. qemu needs to
# write boot state, so wrap it in a copy-on-write overlay placed in
# /tmp. this also makes consecutive boots fast and lets the dev
# discard state by deleting the overlay.
OVERLAY=/tmp/geos-dev-overlay.qcow2
if [ ! -f "$OVERLAY" ] || [ "$QCOW" -nt "$OVERLAY" ]; then
    echo "dev-vm.sh: refreshing overlay at $OVERLAY"
    rm -f "$OVERLAY"
    qemu-img create -f qcow2 -F qcow2 -b "$QCOW" "$OVERLAY" >/dev/null
fi

QEMU=qemu-system-x86_64
# shellcheck disable=SC1091
eval "$("$SELF_DIR/qemu-accel.sh")"
echo "dev-vm.sh: booting $OVERLAY (overlay over $QCOW)"

# shellcheck disable=SC2086
exec "$QEMU" \
    $QEMU_ACCEL \
    -m 2048 \
    -smp 2 \
    -vga virtio \
    $QEMU_DISPLAY \
    $QEMU_SERIAL \
    -device qemu-xhci,id=xhci \
    -device usb-tablet,bus=xhci.0 \
    -drive "file=$OVERLAY,format=qcow2,if=virtio" \
    $QEMU_EXTRA
