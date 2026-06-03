# 2026-05-17 hurd supervisor RPC end-to-end verified

<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

## Milestone

The supervisor RPC channel works on real GNU/Hurd from socket
listen to client connect to soft-refuse to second-poll.  this
exercises three things in one test:

  1. `pid1-rpc-listen` creates an AF_UNIX listener.
  2. `pid1-rpc-poll` accepts the connection without panicking on
     Hurd's pflocal returning ENOPROTOOPT for `SO_RCVTIMEO` /
     `SO_SNDTIMEO`.
  3. `port->get_peer_cred` returns ENOSYS on Hurd (no SO_PEERCRED
     analogue on pflocal), and the supervisor treats that as
     "refuse this client and keep the poller alive", logging once
     per boot and returning nil from subsequent polls.

## Two fixes were needed

  - `pid1-rpc-poll` previously translated any `setsockopt`
    failure into `pid1-error`.  Hurd's pflocal does not implement
    `SO_RCVTIMEO` / `SO_SNDTIMEO` (returns ENOPROTOOPT), which
    would have panicked the 200ms tick on every client
    connection.  fix on main at `ffe6150` (cherry-picked to hurd
    branch as `e4f72de`): tolerate ENOPROTOOPT inline, document
    the degradation (no timeout bound on a kernel that doesn't
    support it), still surface any other errno.
  - `port_hurd.c`'s `hurd_get_peer_cred` returns -1/ENOSYS by
    design (the `3ebcbd5` commit on the hurd branch).  the
    soft-refuse path in `Fpid1_rpc_poll` was already wired but
    had not been exercised end-to-end on Hurd until this run.

## Environment

Same VM as the prior runlogs.  module rebuilt with `make
PORT=hurd STATIC=0 module` after both fixes were on the branch.

## What I ran

```elisp
(module-load "/root/geos/pid1/pid1-module.so")
(make-directory "/run/geos" t)
(let ((sock "/run/geos/super-peer.sock"))
  (when (file-exists-p sock) (delete-file sock))
  (princ (format "rpc-listen: %S\n" (pid1-rpc-listen sock #o600)))
  (let ((cproc (make-network-process
                :name "peer-test"
                :family 'local
                :service sock
                :nowait nil)))
    (princ (format "client process: %S\n"
                   (process-status cproc)))
    (sleep-for 0.2)
    (condition-case e
        (princ (format "rpc-poll #1: %S\n" (pid1-rpc-poll)))
      (t (princ (format "rpc-poll #1 ERROR: %S\n" e))))
    (condition-case e
        (princ (format "rpc-poll #2: %S\n" (pid1-rpc-poll)))
      (t (princ (format "rpc-poll #2 ERROR: %S\n" e))))
    (delete-process cproc))
  (when (file-exists-p sock) (delete-file sock)))
(princ "DONE\n")
```

## What I got

stdout:

```
rpc-listen: t
client process: open
rpc-poll #1: nil
rpc-poll #2: nil
DONE
```

stderr:

```
pid1: rpc-poll: peer cred unsupported on this kernel, refusing clients
```

Reading the result:

  - `rpc-listen: t`: the AF_UNIX listener was created at
    `/run/geos/super-peer.sock`, mode 0600.
  - `client process: open`: emacs's `make-network-process` opened
    an AF_UNIX client connection.  pflocal accepted the connect
    (the kernel-level handshake worked).
  - `rpc-poll #1: nil`: the supervisor accept4'd the connection,
    tolerated the SO_RCVTIMEO/SO_SNDTIMEO ENOPROTOOPT, called
    `port->get_peer_cred` which returned -1/ENOSYS, hit the
    `warned_enosys` branch (logging once), closed the connection,
    and returned nil.  the supervisor did NOT signal `pid1-error`,
    which is exactly what the contract requires.
  - `rpc-poll #2: nil`: a second poll with no pending connection
    returns nil from the EAGAIN branch.  the
    "peer cred unsupported" line did NOT re-appear on stderr,
    confirming the static `warned_enosys` gate works.

## Why this matters

Before today, the verification matrix in `docs/HURD_PORT.md`
listed `get_peer_cred` as "builds on Hurd" and the soft-refuse
contract as a documented intention.  this run promotes it to
"YES on 2026-05-17" because the path was actually walked.

If anyone deletes the ENOPROTOOPT tolerance in `Fpid1_rpc_poll`,
the supervisor will panic on every client connection on Hurd; the
freeze-test orchestrator does not catch this because it cannot
load the pid1 module on a dev host.  the receipt is here.

## References

  - main commit (the fix): `ffe6150`
  - hurd cherry-pick: `e4f72de`
  - main docs update: `ef8f34d` (HURD_PORT.md matrix promotion)
  - pre-existing related: `3ebcbd5` on hurd
    (`hurd_get_peer_cred` returns ENOSYS)
