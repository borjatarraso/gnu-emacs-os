#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Borja Tarraso <borja.tarraso@member.fsf.org>
#
# cleanup.sh, remove host-side dev leftovers from a GEOS tree.
#
# what it deletes:
#   - /tmp/geos-dev-overlay.qcow2  (copy-on-write boot overlay)
#   - /tmp/gnu-emacs-os.qcow2      (legacy /boot-vm output)
#   - /tmp/geos-*.iso              (any iso copies the dev made)
#   - $REPO/boot-*.log             (serial-console captures)
#   - $REPO/pid1/emacs-init        (rebuilt by next make)
#   - $REPO/shstub/sh              (rebuilt by next make)
#   - *.elc under emacs-init/      (compiled byproducts)
#
# what it does NOT touch:
#   - /gnu/store. that is guix's job; run `guix gc` to reclaim.
#   - .git, working-tree files, anything tracked or staged.
#   - the qcow2/iso under /gnu/store. only the overlays and
#     /tmp copies.
#
# safe to run any time. idempotent.

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)

cd "$REPO_ROOT"

echo "cleanup.sh: scrubbing host-side dev artifacts under $REPO_ROOT"

rm -f /tmp/geos-dev-overlay.qcow2
rm -f /tmp/gnu-emacs-os.qcow2
rm -f /tmp/geos-*.iso

rm -f "$REPO_ROOT"/boot-*.log
rm -f "$REPO_ROOT"/pid1/emacs-init
rm -f "$REPO_ROOT"/shstub/sh

# .elc under emacs-init/. tolerate the absence of any.
find "$REPO_ROOT/emacs-init" -name '*.elc' -delete 2>/dev/null || true

echo "cleanup.sh: done. /gnu/store untouched (run 'guix gc' to reclaim)."
