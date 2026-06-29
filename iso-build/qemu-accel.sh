#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
# Copyright (C) 2026  Adrian Yanes <ayanes@gnu.org>
#
# qemu-accel.sh, print QEMU acceleration flags for the current host.
#
# usage (within a script):
#   eval "$(./iso-build/qemu-accel.sh)"
#   exec qemu-system-x86_64 $QEMU_ACCEL -m 2048 $QEMU_DISPLAY $QEMU_SERIAL ...
#
# linux with /dev/kvm:  -enable-kvm -cpu host, gtk display, serial on stdio
# macOS (no kvm):       -accel tcg -cpu max, cocoa + full-grab, serial to file
# other hosts without kvm: tcg + gtk, serial to file (headless callers override
#   display/serial themselves, as smoke-test.sh does)

set -eu

if [ -r /dev/kvm ] 2>/dev/null; then
    printf '%s\n' 'QEMU_ACCEL="-enable-kvm -cpu host"'
    printf '%s\n' 'QEMU_SERIAL="-serial mon:stdio"'
    printf '%s\n' 'QEMU_DISPLAY="-display gtk"'
else
    printf '%s\n' 'QEMU_ACCEL="-accel tcg -cpu max"'
    echo "qemu-accel: /dev/kvm unavailable, using tcg (boot will be slow)" >&2
    case "$(uname -s)" in
        Darwin)
            printf '%s\n' 'QEMU_SERIAL="-monitor none -serial file:/tmp/geos-serial.log"'
            printf '%s\n' 'QEMU_DISPLAY="-display cocoa,full-grab=on,show-cursor=on"'
            echo "qemu-accel: serial log /tmp/geos-serial.log; click QEMU window for keyboard (Ctrl-Alt-G toggles grab)" >&2
            ;;
        *)
            printf '%s\n' 'QEMU_SERIAL="-monitor none -serial file:/tmp/geos-serial.log"'
            printf '%s\n' 'QEMU_DISPLAY="-display gtk"'
            ;;
    esac
fi
