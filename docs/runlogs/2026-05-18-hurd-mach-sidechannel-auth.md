<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

# 2026-05-18: auth dance is reachable on Debian GNU/Hurd 0.9

Follow-up to `2026-05-18-hurd-pflocal-cmsg-fail.md`.  That run
proved pflocal cannot carry bare Mach port names through
SCM_RIGHTS, killing design 2.1.  This run answers the next
question for design 2.2: does the auth dance itself
(`auth_user_authenticate` + `auth_server_authenticate`) complete
cleanly on this Hurd build when both sides share a rendezvous
port?

## Result

**PASS.**  Both sides of the dance return `KERN_SUCCESS` and the
server side reads back the expected effective uid set.  Probe
output (root on Debian GNU/Hurd 0.9, GNU-Mach 1.8+git20260224):

```
OK auth euid=0 (neuids=1)
```

Exit code 0.

## What the probe does

`tests/hurd-mach-sidechannel.c` (single file, 200 lines).  One
process, two pthreads sharing the rendezvous via the shared
port-name table:

  1. Main thread allocates a fresh receive right (the rendezvous
     port), then mints two send rights via `MAKE_SEND` so each
     pthread can call `MOVE_SEND` on the same name without
     underflowing the send-right user-ref count.
  2. Server pthread calls
     `auth_server_authenticate(getauth(), rendez,
     MACH_MSG_TYPE_MOVE_SEND, newport_rcv,
     MACH_MSG_TYPE_MAKE_SEND, &euids, &neuids, ...)`.
  3. Client pthread calls
     `auth_user_authenticate(getauth(), rendez,
     MACH_MSG_TYPE_MOVE_SEND, &newport)`.
  4. Both threads block inside the auth server until the rendezvous
     matches; on KERN_SUCCESS the server reads the client's
     effective uid/gid sets out of the auth-server's per-task
     authentication state.

The thread choice (vs `fork()`) sidesteps Mach's port-right
inheritance rules: a forked child does not inherit the parent's
receive right, so the rendezvous would need a real side-channel
transport to reach the child.  The transport is well-trodden
Mach IPC and not what this probe was meant to prove.  The probe
isolates the *auth-dance-completes* question; design 2.2's
transport question is "does the supervisor publish a bootstrap-
port-reachable service port and the client task_get_bootstrap_
port to send the rendezvous through it", which is standard
Hurd IPC.

## What this verifies for design 2.2

  - `getauth()` on Debian GNU/Hurd 0.9 returns a valid auth
    port for the current task.
  - `auth_user_authenticate` accepts `MACH_MSG_TYPE_MOVE_SEND`
    on the rendezvous and blocks correctly until the matching
    server call arrives.
  - `auth_server_authenticate` accepts the same disposition,
    reads the client's effective uid set, and returns the
    standard four-array (euids/auids/egids/agids).
  - The "newport" handed back by the server (here a self-
    allocated receive right + MAKE_SEND) is accepted by the
    user side and returned in `&newport`.

What's still untested (deferred to the implementation):

  - Inter-task transport: the probe shares the rendezvous
    name via the same port table, not via a Mach message.
    Sending a port from client task to supervisor task via
    `task_set_special_port(TASK_BOOTSTRAP_PORT, ...)` +
    `task_get_bootstrap_port` + a `mach_msg` carrying one
    port descriptor is documented and used by every Hurd
    server; the v0.8 implementation will exercise it directly
    in `port_hurd.c`.
  - Auth server's handling when the client task and the
    supervisor task are genuinely separate: the dance does
    rendezvous on the port object, not on task identity,
    so this should work; the runtime check is the end-to-end
    multi-user smoke (task #114).

## Decoded error from the first probe attempt

The initial probe used `fork()` and `MAKE_SEND` twice on the
parent then `MOVE_SEND` from the parent's call.  That returned
`0x1000000a = MACH_SEND_INVALID_RIGHT` because the parent's
name table entry for the rendezvous was a receive right with
send-right user-refs, and `MOVE_SEND` requires the name to
refer to a send right.  Two send rights at separate names
(or two threads in one task sharing the receive-with-send-
refs name) sidestep this.  The threaded probe is what landed.

## Reproduction

  1. Boot a Debian GNU/Hurd 0.9 VM, ssh in as root.
  2. SCP `tests/hurd-mach-sidechannel.c` to `/root/`.
  3. `cd /root && gcc -Wall -Wextra -Werror -pthread -o
     hurd-mach-sidechannel hurd-mach-sidechannel.c` (no
     `-lmach`; glibc bundles the user-side stubs).
  4. `./hurd-mach-sidechannel` -> exits 0, prints
     `OK auth euid=0 (neuids=1)`.

## What this clears

Task #117 (probe Mach side-channel rendezvous mechanics) is
done.  Path is clear for tasks #118 (rewrite
`hurd_get_peer_cred`) and #119 (rewrite
`hurd_client_auth_handshake`) on the hurd branch to take the
parallel-Mach-channel shape.  Task #120 (supervisor publishes
the long-lived auth Mach port) is the architectural commit
that ties them together.
