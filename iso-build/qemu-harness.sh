#!/bin/sh
# qemu-harness.sh, cold-boot a GNU/Emacs OS ISO under qemu.
#
# usage: ./qemu-harness.sh /gnu/store/...-image.iso [extra qemu args...]
#
# this script lives in iso-build/, which is the host-side dev tooling
# tree. it runs on the developer machine, NOT inside the booted OS,
# so /bin/sh here is the host's POSIX shell. the no-shell rule in the
# project root applies to the OS image's userland, not to this
# script. plain sh is fine and intentional.
#
# the invocation matches the qcow2 dev harness used in phases 1-6:
#   - 2GB RAM (less and emacs starts swapping during exwm-enable)
#   - kvm acceleration (boot is unbearable without it)
#   - vga=std + display=gtk (matches xorg.conf's fbdev wiring)
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
    -vga std \
    -display gtk \
    -serial mon:stdio \
    -boot d \
    -cdrom "$ISO" \
    "$@"

echo "qemu-harness: $QEMU $*"
exec "$QEMU" "$@"
