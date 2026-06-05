<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# pid1-spawn-as-uid: the v0.5 session spawn ABI

Status: spec, awaiting pid1-engineer implementation.
Audience: pid1-engineer (C side), session.el / login.el (callers).

## thesis

PID 1 emacs is the supervisor and stays root forever. A per-user emacs
is a CHILD process owned by that user's uid. The transition happens in
the parent (PID 1) between fork and execve, never via a setuid binary.
This file is the contract for the new module binding that performs
that transition.

## elisp-side signature

    (pid1-spawn-as-uid UID GID NAME PROGRAM ARGV ENV)

Args, all required, no &optional:

  UID      integer, target real+effective+saved uid.
  GID      integer, target real+effective+saved gid (set BEFORE uid).
  NAME     string, the username; used for setgroups initgroups(3)-equiv
           lookup against /etc/group, and as the value of $USER and
           $LOGNAME in the child env.
  PROGRAM  string, absolute path to the binary to exec. For v0.5 this
           is always "/usr/bin/emacs", but the binding is generic.
  ARGV    list of strings. The first element is argv[0] as the child
           sees it; the binding does NOT prepend PROGRAM. Caller writes
           e.g. ("emacs" "-Q" "-l" "/var/emacs/users/borja/init.el").
  ENV     list of "KEY=VALUE" strings. Replaces the child's environment
           wholesale; the binding scrubs everything else.

Return: the child pid as an integer. The parent does NOT wait; the
supervisor's existing reaper (pid1-reap) catches the exit later.

Errors: signals pid1-error with a single string of the form
"pid1: spawn-as-uid: <stage>: <strerror>". Stages:

  fork, setgid, setgroups, setuid, chdir, execve

The signal happens IN THE PARENT. The child cannot signal; if any
post-fork step fails in the child, it writes one line to /dev/console
and calls _exit(127). The parent's wait will see exit-status 127 via
the supervisor.

## c-side syscall sequence

Numbered because order matters. Anything out of order is a security
bug.

  1. parent: validate args. UID >= 1000 unless caller passed the
     module flag `pid1-spawn-allow-system' (deferred to v0.6; v0.5
     refuses uid < 1000 with EPERM mapped to "uid below floor"). The
     same floor of 1000 applies to GID, refused as "gid below floor",
     because passwd-add-user allocates primary gids from the same
     range and a uid=1000 child with gid=0 would have write access to
     anything mode 070.
  2. parent: fork(). On -1 -> signal pid1-error fork.
  3. child: setsid() so the child is its own session leader. ignore
     EPERM (already a leader is fine).
  4. child: setresgid(GID, GID, GID). All three slots, no leaving
     saved-gid as root. errno -> exit 127 with "setgid" tag.
  5. child: setgroups(N, groups). N and groups are computed by the
     parent from /etc/group (callable lookup, no nsswitch) and passed
     into the child via a pre-fork-populated buffer. setgroups MUST
     come BEFORE setuid: a child whose euid is non-root cannot call
     setgroups. Skipping this step would leave the child in root's
     supplementary group set, which is the classic privilege bug.
  6. child: setresuid(UID, UID, UID). After this point the child is
     fully unprivileged. errno -> exit 127 "setuid".
  7. child: scrub env. The binding builds a fresh envp from the ENV
     list arg; nothing inherited. This is the chokepoint for not
     leaking LD_PRELOAD, PATH, XDG_*, or anything else from PID 1's
     environment into the user session.
  8. child: chdir to the user's home from /etc/passwd. If the home
     does not exist, chdir to "/" and log. We do not create homes
     here; that's passwd-add-user's job.
  9. child: close all fds >= 3. stdin/stdout/stderr are inherited
     from PID 1 (they all point at /dev/console). The login buffer
     either accepts that or hands the child a pty (see open question
     below).
 10. child: execve(PROGRAM, argv, envp). If execve returns, errno
     -> exit 127 "execve".
 11. parent: return the child pid to elisp.

## what the supervisor does with the pid

`session.el` registers the child under `core/supervise.el`:

  - supervise-service with :restart 'never (logging out is not a
    crash; the user decides when to re-login). The session record's
    own `'held`/`'running` state lives in session.el, separately
    from supervise's status, so we can rehydrate without lying to
    supervise.
  - The existing crashloop cap (5 in 60s) still applies if the
    child segfaults at startup; the user sees "session held, see
    *panic*" instead of fork-bombing /dev/console.

## why no setuid binary

A setuid binary is a piece of bytes on disk that any local process
can re-execute, which means every bug in that binary's argv-parsing
becomes a local privilege escalation. We don't have any local
unprivileged processes on a fresh boot (PID 1 is the only thing
running until login), but the moment we add one we'd need the setuid
helper to be auditable to a higher standard than the rest of the
system.

The alternative is: privilege transition happens INSIDE PID 1 emacs,
which is already root, between fork and exec. No on-disk artifact
has the setuid bit. The attack surface is the pid1-spawn-as-uid
binding's argument-parsing, which has exactly one caller (session.el)
and zero attacker control over the args (the username comes from
/etc/passwd via passwd-read-passwd, not from network or argv).

## errno -> string mapping

The signal data string is "pid1: spawn-as-uid: STAGE: STRERROR" so a
panic-handle log entry tells you both where in the sequence we were
and what the kernel said. Examples:

  pid1: spawn-as-uid: fork: Cannot allocate memory
  pid1: spawn-as-uid: setgid: Operation not permitted
  pid1: spawn-as-uid: execve: No such file or directory

Same pattern as the existing Fpid1_mount, Fpid1_set_address, etc.

## open question: pty/tty handoff

Decision for v0.5: NO pty in the binding.

Argument: the per-user emacs opens its own connection to whatever
display surface it needs. In UI mode that's the running Xorg via
$DISPLAY in ENV; in console mode the child emacs is started with
"--daemon=user-NAME" and the operator attaches via emacsclient from
a tty (or the login buffer hands the operator a *user-NAME* buffer
in the supervisor emacs, but that's a session.el concern, not a
pid1 concern).

Why not pty: a pty allocation in C is finicky (openpty/grantpt/
unlockpt/ptsname, then setsid + ioctl TIOCSCTTY in the child after
the fork), and getting it wrong silently breaks job control in the
child. Pushing it out of pid1 keeps the C surface small and lets us
iterate the user-facing tty story in elisp without touching the
module. If we discover we need pty handoff for console mode in
v0.5.x, we add a `pid1-spawn-as-uid-pty` sibling rather than
re-shaping this one.

The fds-0-1-2 question: child inherits PID 1's /dev/console. That
is fine for v0.5: the child's stderr lands in the same place as
every supervised service's stderr, which is the same place an
operator already looks for crash info. Real per-user tty isolation
is v0.6+.

## things this ABI does NOT do

  - PAM. We do not link libpam, will not, ever.
  - chroot or namespace setup. The child runs in PID 1's mount/pid/
    net namespace. Per-user namespaces are v0.6+ if at all.
  - capability(7) drops. Children are uid != 0, so caps are gone
    via the standard linux semantics; no separate prctl needed.
  - rlimit configuration. v0.6+; for now the child inherits PID 1's
    rlimits which are kernel defaults (no setrlimit in emacs-init.c).

## license

This document is licensed under the GNU Free Documentation License,
Version 1.3 or any later version published by the Free Software
Foundation; with no Invariant Sections, no Front-Cover Texts, and no
Back-Cover Texts.

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3 or
any later version published by the Free Software Foundation; with no
Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.  A
copy of the license is included in the file `COPYING.DOC` at the top
of this distribution.
