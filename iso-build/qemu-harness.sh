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
#   - kvm acceleration (boot is unbearable without it)
#   - -vga virtio + -display gtk: matches xorg-modesetting.conf, which
#     binds the modesetting driver against /dev/dri/card0 from
#     virtio_gpu. -vga std gives a black screen because there is no
#     DRM device for modesetting to attach to.
#   - usb-tablet on an xhci bus: absolute pointer, no pointer-grab
#     dance. lands on /dev/input/event4 where xorg-modesetting.conf
#     is configured to find it. without this the X session has a
#     keyboard but no mouse.
#   - serial mon:stdio (so pid1's /dev/console writes hit the tty)
#   - boot d (cdrom first), -cdrom path (the ISO)
#
# the exact command is echo'd before exec so a developer can copy it
# out of the log and tweak by hand without grepping this script.

set -eu

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

set -- \
    -enable-kvm \
    -m 2048 \
    -cpu host \
    -smp 2 \
    -vga virtio \
    -display gtk \
    -device qemu-xhci,id=xhci \
    -device usb-tablet,bus=xhci.0 \
    -serial mon:stdio \
    -boot d \
    -cdrom "$ISO" \
    "$@"

echo "qemu-harness: $QEMU $*"
exec "$QEMU" "$@"
