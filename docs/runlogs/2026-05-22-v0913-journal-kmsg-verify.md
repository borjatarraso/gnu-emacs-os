<!-- SPDX-License-Identifier: FSFAP -->

# v0.9.13 journal-kmsg on Debian GNU/Hurd 0.9

this receipt closes the v0.9.13 slice arc that takes the
journal-kmsg defservice from "exits immediately on Hurd
because `/var/log/kern.log` does not exist and `tail -F`
gives up" (open follow-on #3 from v0.9.12) to "supervised
tail process is alive at first ssh-able moment, panic buffer
clean, hurd-essentials no regression".  three slices stacked.
first-pass VM-verify caught two real failures on top of the
slice-1 fix, slices 2 and 3 closed them, re-verify came back
PASS on all 7 checks.  prior receipt:
`docs/runlogs/2026-05-22-hurd-end-to-end-ssh.md`.

## Result

PASS on the load-bearing claim.  journal-kmsg comes up
running on Debian GNU/Hurd 0.9 at first ssh-able boot;
`tail -F --lines=+1 /var/log/kern.log` is alive under the
emacs supervisor with restarts=0; the panic buffer carries
zero `journal-tail--ensure-kern-log-hurd` lines; the other
hurd-essentials defservices (hurd-sshd, hurd-syslogd) come up
without regression.

what is not verified by this slice: live kmsg append from a
deliberately-triggered kernel message.  the syslogd path that
populates `/var/log/kern.log` is wired (v0.9.12 slice 7 fixed
the binary path), and an empty file is enough for `tail -F`
to attach, but I did not provoke a kern.* line and grep it
out of `*journal*`.  out of scope for the supervisor-liveness
gate; a separate probe receipt can pick it up if the next
slice needs it.

## What the three slices ship

  - **slice 1** (main `afd1f3f`, hurd `85c25f0`):
    `journal-tail--ensure-kern-log-hurd` in
    `emacs-init/services/journal-tail.el`.  on Hurd only, before
    starting the tail process, write the empty string to
    `/var/log/kern.log` via `write-region` if the file is
    missing.  Linux already has `/var/log/kern.log`
    populated by rsyslog/syslog-ng; this is a Hurd-only
    pre-step so the v0.9.6 `tail -F` source can attach to a
    real inode instead of looping on ENOENT.
  - **slice 2** (main `7e4fc42`, hurd `ae51c4e`, half 1):
    `(make-directory "/var/log" t)` before the write-region.
    pid1 tmpfs-mounts `/var` on Hurd, so the parent dir is
    missing at the moment journal-kmsg autostarts.  the
    bare `write-region` was failing with
    `file-error: opening output file, no such file or
    directory, /var/log/kern.log`, which routed through
    panic-handle and left a line in `*panic*`.  the
    `make-directory` with the PARENTS arg is idempotent on
    both kernels.
  - **slice 3** (main `7e4fc42`, hurd `ae51c4e`, half 2):
    in `emacs-init/early-init.el`'s existing
    `(when (equal (getenv "GEOS_KERNEL") "hurd") ...)`
    block, append `/usr/bin /usr/sbin /bin /sbin` to
    `exec-path` and mirror the same four entries into the
    `PATH` envvar.  emacs's Guix-shaped default `exec-path`
    on the GEOS image points at
    `/run/current-system/profile/{bin,sbin}` only; on the
    Debian Hurd guest those paths do not exist, so
    `(executable-find "tail")` returned nil and
    `supervise--spawn` of journal-kmsg never produced a
    live process (state stuck `stopped`, no pid).

## Background, first-pass FAIL

before slices 2 and 3 landed, the first VM-verify of slice 1
alone returned 3 of 5 checks failing.

  - `/var/log/kern.log` absent at first ssh-able moment.
    parent dir `/var/log` is missing because pid1 fresh-mounts
    `/var` as tmpfs on Hurd.
  - journal-kmsg `:state stopped`, no tail pid.  emacs's
    `exec-path` cannot resolve `tail` because the Guix-shaped
    profile paths do not exist on the Debian Hurd rootfs.
  - one `journal-tail--ensure-kern-log-hurd` line in
    `*panic*`, the file-error from the missing parent dir.

two checks passed (zero crash count and hurd-essentials no
regression), which is consistent with the slice-1 code being
correct given a writable parent.

## Probe run, re-verify

7 checks, all PASS.  evidence table verbatim from the
hurd-vm-driver re-verify report.

| # | Check | Result | Evidence |
|---|-------|--------|----------|
| 1 | /var/log/kern.log exists at first ssh-able moment | PASS | -rw-r--r-- root 0 May 22 15:17 /var/log/kern.log |
| 2 | journal-kmsg :state running, tail pid alive | PASS | (:status running :pid 35 ...); process tree shows tail -F --lines=+1 /var/log/kern.log pid 35 owned by emacs pid 29 |
| 3 | Zero crashes for journal-kmsg | PASS | (:restarts 0 :respawn-times nil) |
| 4 | No journal-tail--ensure-kern-log-hurd line in *panic* | PASS | *panic* buffer empty string |
| 5 | hurd-essentials services come up clean | PASS | ((hurd-sshd . running) (hurd-syslogd . running) (journal-kmsg . running)) |
| 6 | exec-path on Hurd contains /usr/bin; (executable-find "tail") non-nil | PASS | ("/usr/bin" "/usr/sbin" "/bin" "/sbin"); "/usr/bin/tail" |
| 7 | (getenv "PATH") contains /usr/bin after early-init | PASS | "/run/current-system/profile/bin:/run/current-system/profile/sbin:/usr/bin:/usr/sbin:/bin:/sbin" |

artifacts from the re-verify run, retained on the host for
follow-on inspection:

  - snapshot: `/tmp/geos-hurd-vm-v0913-reverify-1779459141.qcow2`
  - serial log: `/tmp/geos-hurd-vm-v0913-reverify-serial.log`
    (617 lines, 33 KB)

## Open follow-ons (do NOT block this slice's commit)

  1. live kmsg append probe.  this slice verified the tail
    process is alive against an empty file; it did not
    verify that a real kern.* line lands in `*journal*`.
    next step: trigger a benign kernel message inside the
    guest (an obvious source is a deliberate
    `gnumach`-level diagnostic or a syslog-side
    `logger -p kern.info`), then grep `*journal*` for the
    matching substring.  not load-bearing for the
    supervisor-liveness gate; ship as a separate probe
    receipt if v0.9.14 wants to flip a "live kmsg verified"
    matrix cell.
  2. exec-path drift on apt upgrades.  slice 3 hard-codes
    the four Debian dirs.  if a future Debian Hurd snapshot
    moves `tail` somewhere outside `coreutils`, or a
    different image flavor relocates `/usr/bin`, the
    `executable-find` gate in slice 1 will return nil and
    journal-kmsg goes back to `stopped`.  no action item
    yet; flag it for the next time hurd-essentials grows a
    new defservice that wants a Debian-side binary.
  3. task #168 (`/etc/geos/tmpfiles.d`-equivalent) gets a
    second consumer.  slice 2's `make-directory
    "/var/log"` is now the second postinst-state mkdir on
    the Hurd path, after v0.9.11's C-side
    `mkdir("/run/sshd")`.  once a third consumer shows up,
    refactor the three call sites into a table.  hint:
    keep the C-side ones in pid1 and the elisp-side ones
    behind a `geos-hurd-ensure-path` helper.

## Files touched on the main branch

  - `emacs-init/services/journal-tail.el` (+14):
    `journal-tail--ensure-kern-log-hurd` defun;
    `make-directory "/var/log" t` ahead of the
    `write-region`; called from the Hurd branch of the
    journal-kmsg start path.
  - `emacs-init/early-init.el` (+6): inside the existing
    `(when (equal (getenv "GEOS_KERNEL") "hurd") ...)`
    block, `dolist` over the four Debian dirs, push onto
    `exec-path` if not already member, and rebuild PATH
    via `setenv` with the same four dirs appended.

## Files touched on the hurd branch

cherry-picked both elisp slices from main (`85c25f0` covers
slice 1, `ae51c4e` covers slices 2 + 3).  no port_hurd.c or
other C-side changes; this whole arc lives in elisp.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
