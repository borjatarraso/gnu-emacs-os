#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
# Author: Borja Tarraso <borja.tarraso@member.fsf.org>
#
# emacs-os.sh, build the GEOS ISO and boot it under qemu.
#
# v0.3-track. this is the production path: byte-reproducible iso9660
# image built against the pinned channel, then booted via the same
# qemu-harness.sh the docs recommend.
#
# usage (from anywhere):
#
#   ./iso-build/emacs-os.sh                 # build, then boot
#   ./iso-build/emacs-os.sh --build-only    # build, print path, exit
#   ./iso-build/emacs-os.sh --boot <iso>    # skip build, boot existing
#   ./iso-build/emacs-os.sh -- -snapshot    # extra qemu args after --
#
# the v0.2 wrapper called `git pull` before building. that was a
# mistake: it broke after history rewrites and broke offline. v0.3
# does ZERO git operations. if you want to update the tree, do it by
# hand, eyeball the diff, then run this.
#
# build cost: ~30 minutes cold, ~2 minutes with a warm /gnu/store.
# the build line is:
#   guix time-machine -C iso-build/channels.scm -- \
#       system image -L . iso-build/build.scm

set -eu

# repo root: dirname of this script's dir.
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)

cd "$REPO_ROOT"

if [ ! -f iso-build/channels.scm ] || [ ! -f iso-build/build.scm ]; then
    echo "emacs-os.sh: not in a GEOS checkout (missing iso-build/)" >&2
    exit 1
fi

BUILD=1
BOOT=1
EXISTING_ISO=
QEMU_EXTRA=

while [ $# -gt 0 ]; do
    case "$1" in
        --build-only)
            BOOT=0; shift ;;
        --boot)
            BUILD=0
            shift
            EXISTING_ISO=${1:?--boot needs a path}
            shift ;;
        --)
            shift
            QEMU_EXTRA=$*
            break ;;
        -h|--help)
            sed -n '1,30p' "$0"
            exit 0 ;;
        *)
            echo "emacs-os.sh: unknown arg: $1" >&2
            exit 2 ;;
    esac
done

ISO=
if [ "$BUILD" = 1 ]; then
    # system.scm references ../pid1/emacs-init and ../shstub/sh as
    # local-file inputs; build them first or `guix system image` dies
    # with canonicalize-path: No such file or directory. make is
    # idempotent.
    echo "emacs-os.sh: building host-side binaries (pid1, shstub)"
    # `all` builds both emacs-init AND pid1-module.so. default `make`
    # only produces emacs-init; the .so would then be missing and
    # guix dies with canonicalize-path on pid1-module.so.
    make -C pid1 all
    make -C shstub
    echo "emacs-os.sh: building ISO from $REPO_ROOT"
    echo "emacs-os.sh: ~30min cold cache, ~2min warm"
    # guix system image writes diagnostics to stderr and the final
    # store path to stdout, but a deprecation warning or substituter
    # notice can also land on stdout, so filter to /gnu/store paths
    # before tail.
    ISO=$(guix time-machine -C iso-build/channels.scm -- \
        system image -L "$REPO_ROOT" iso-build/build.scm \
        | grep -E '^/gnu/store/[^[:space:]]+' \
        | tail -n 1)
    if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
        echo "emacs-os.sh: build did not return an iso path" >&2
        echo "emacs-os.sh: got: '$ISO'" >&2
        exit 1
    fi
    echo "emacs-os.sh: built $ISO"
else
    ISO=$EXISTING_ISO
    if [ ! -f "$ISO" ]; then
        echo "emacs-os.sh: --boot path not found: $ISO" >&2
        exit 1
    fi
fi

if [ "$BOOT" = 0 ]; then
    echo "$ISO"
    exit 0
fi

# shellcheck disable=SC2086  # QEMU_EXTRA is intentionally word-split
exec "$REPO_ROOT/iso-build/qemu-harness.sh" "$ISO" $QEMU_EXTRA
