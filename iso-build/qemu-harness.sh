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
# qemu-harness.sh, cold-boot a GNU/Emacs Operating System (GEOS) ISO
# under qemu.
#
# usage: ./qemu-harness.sh /gnu/store/...-image.iso [extra qemu args...]
#
# this script lives in iso-build/, which is the host-side dev tooling
# tree. it runs on the developer machine, NOT inside the booted OS,
# so /bin/sh here is the host's POSIX shell. the no-shell rule in the
# project root applies to the OS image's userland, not to this
# script. plain sh is fine and intentional.
#
# the invocation tracks v0.2's xorg pipeline:
#   - 2GB RAM (less and emacs starts swapping during exwm-enable)
#   - host-appropriate accel via qemu-accel.sh (kvm on linux, tcg elsewhere)
#   - -vga virtio + display from qemu-accel.sh (gtk on linux, cocoa on macOS)
#   - usb-tablet on an xhci bus: absolute pointer; xorg reads
#     /run/geos/input-ptr (stable symlink from pid1, not a fixed eventN)
#   - serial from qemu-accel.sh (stdio on linux/kvm, file on macOS)
#   - boot d (cdrom first), -cdrom path (the ISO)
#
# the exact command is echo'd before exec so a developer can copy it
# out of the log and tweak by hand without grepping this script.

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

if [ $# -lt 1 ]; then
    echo "usage: $0 <iso-path> [extra qemu args...]" >&2
    exit 2
fi

ISO="$1"
shift

if [ ! -f "$ISO" ]; then
    echo "qemu-harness: ISO not found: $ISO" >&2
    exit 1
fi

QEMU=qemu-system-x86_64

# shellcheck disable=SC1091
eval "$("$SELF_DIR/qemu-accel.sh" 2>/dev/null)"

# shellcheck disable=SC2086
set -- \
    $QEMU_ACCEL \
    -m 2048 \
    -smp 2 \
    -vga virtio \
    $QEMU_DISPLAY \
    $QEMU_SERIAL \
    -device qemu-xhci,id=xhci \
    -device usb-tablet,bus=xhci.0 \
    -boot d \
    -cdrom "$ISO" \
    "$@"

echo "qemu-harness: $QEMU $*"
exec "$QEMU" "$@"
