<!-- SPDX-License-Identifier: FSFAP -->

# /var/emacs/ on-disk layout

The persistent scratchpad for the Elisp userland. Every concept buffer
that needs to remember something across a refresh, a service restart,
or a reboot lands a file here.

This document is the contract between the Elisp side (core/state.el)
and the C side (pid1's mount_var() in pid1/emacs-init.c). Change either
without updating this document and a future reader will not know which
side lied.

## Mount source

pid1 mounts `/var` at boot, before forking emacs. The probe order is:

  1. `/dev/disk/by-label/geos-var` exists and is mountable as ext4
     -> mounted, persistent across reboots. console marker:
     `pid1: /var on ext4 (geos-var label)`.
  2. Otherwise, tmpfs at /var with mode=0755. console marker:
     `pid1: /var on tmpfs (no geos-var label)`.

Both paths leave /var writable for uid 0 (the OS emacs runs as root).
The state API itself is mode-aware: `state-mode` is 'persistent on
ext4, 'tmpfs on tmpfs, nil if /var was not writable. Buffer headers
display this so the user knows whether their actions survive a poweroff.

To carve a real geos-var partition on a host disk, format any
partition as ext4 with the label `geos-var`. The kernel udev rule
populates `/dev/disk/by-label/` from the ext4 superblock.

## Directory tree under /var/emacs/

  journal/      kmsg consumer state. seq position so we don't reread
                the entire ring buffer on every refresh; dropped-line
                counter for when the kernel ring outruns us.
                also home to auth.log: one sexp-per-line of every
                login outcome, written by login.el via
                state-append-journal.  the *login* buffer reads the
                tail to render the last-login footer.  on tmpfs this
                file vanishes on reboot, which is documented but
                worth knowing post-incident.
  packages/     last-fetched manifest cache, install history, the
                pinned channel revision so we know what produced the
                running system.
  network/      last-applied interface config (addr, route, DNS).
                lets the network buffer redisplay the live state
                without having to re-derive from /proc on each frame.
  users/        passwd / shadow file (item 4 of v0.4). still empty
                until the user buffer ships.
  services/     defservice records the supervisor restored on reboot:
                per-name restart counter and last-death timestamp,
                written via state-write from core/supervise.el's
                sentinel.
  dotfiles/     eshell aliases, M-x recent commands, anything the
                user expects to outlive a poweroff but is not part
                of system state proper.
  sessions/     per-session records the session registry persists so
                a supervisor restart can reattach to a still-living
                per-user emacs (registry-rehydrate path).
                v0.6 item 6.1 added :workspace, the integer EXWM
                workspace index the user's emacs lives on (or nil
                pre-EXWM-hook).  v0.6 item 6.3 made session.el
                authoritative on workspace allocation: the index is
                stamped before pid1-spawn-as-uid, the manage-finish
                hook just reads it back.  sticky across logout: a
                relogin reuses the prior workspace when free.  cap
                of `session-max-workspaces' (3) concurrent users.
  lockouts/     one file per locked-out username.  v0.6 item 5.3:
                10 bad attempts against ONE name inside 5 minutes
                writes /var/emacs/lockouts/NAME with a :locked-until
                expiry.  cleared on the *users* buffer `u' key, or
                automatically on read once the expiry passes.

The state API (state-write KEY VALUE) does not enforce that KEY starts
with one of the prefixes above, but everything user-facing should.
Ad-hoc keys (probes, smoke tests) are tolerated to keep debugging
ergonomic.

## Atomicity contract

Every write goes through this sequence:

  1. write the s-expr to KEY.tmp (with-temp-file, then prin1)
  2. fsync the tmp file (write-region honors it via inhibit-fsync nil)
  3. rename(2) over KEY (Emacs's rename-file with OK-IF-ALREADY t)
  4. fsync the parent directory via pid1-fsync-dir

On ext4 this gives crash-consistency: a reader sees either the old
value or the new value, never a torn or partial write. On tmpfs the
fsync is a near no-op, but the rename remains atomic per VFS semantics,
so the visibility contract holds (if not the durability one).

If pid1-fsync-dir is unbound (the module did not load, dev host),
state-write skips step 4 and proceeds. Visibility still holds; only
the durability of the directory entry is downgraded.

## Value encoding

Values are written and read as Elisp s-exprs via prin1 / read. This
rules out arbitrary-byte values (no PNGs in state) but keeps everything
debuggable: `cat /var/emacs/journal/seq` prints something a human can
parse. `print-length` and `print-level` are bound to nil during the
write so pathological deeply-nested values are not silently truncated.

Coding system is utf-8 on both ends.

## Key safety

Keys are relative paths. state--safe-key-p rejects:

  - empty strings
  - leading slash (no absolute paths)
  - any `..` segment
  - control bytes (0x00 to 0x1f)

The goal here is not security against a hostile Elisp caller (none
exists in this tree) but cheap defence against a buggy caller that
would otherwise scribble outside /var/emacs/.

## Lifecycle

state.el is loaded right after panic.el in the boot -l chain. At load
time, when `pid1-as-emacs-p` is true, it calls `state--ensure-layout`
which:

  1. mkdir -p /var/emacs/
  2. mkdir -p /var/emacs/{journal,packages,network,users,services,
                          dotfiles,sessions,lockouts}
  3. detects state-mode from /proc/mounts

It then writes a single line to /dev/console:

    geos: state-mode=<persistent|tmpfs|none> root=/var/emacs/

This line is greppable by smoke-test.sh as a positive signal that
state.el loaded and the layout is materialised.

Subsequent loaders (network.el, hostname.el, the buffers/ files)
assume the directory tree exists and call state-read / state-write
without rechecking. A first-write to a missing subdir would fail
loudly via panic-handle, which is what we want: missing layout means
state.el did not run, and that is a boot-order bug worth seeing.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
