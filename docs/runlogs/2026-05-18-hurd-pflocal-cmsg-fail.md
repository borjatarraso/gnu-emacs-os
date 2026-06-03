<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

# 2026-05-18: pflocal SCM_RIGHTS will not carry bare Mach ports

The v0.8 multi-user-on-Hurd design (`docs/v08-hurd-peer-cred-design.md`)
section 6 flagged "does pflocal pass Mach port rights through
SCM_RIGHTS cmsgs" as the highest-risk unknown.  Today's probe answers
that: it does not, at least not as the design assumed.  The 2.1
approach (AF_UNIX cmsg carrying the client's rendezvous port) is
dead; the design falls back to alternative 2.2 (parallel Mach
channel).

## Result

**FAIL.**  Every SOCK_STREAM / SOCK_DGRAM / SOCK_SEQPACKET pair
returns the same Hurd-flavored EBADF (`0x40000009`) on the first
`sendmsg` with an SCM_RIGHTS cmsg attached, even though a plain
`send` on the same fd works.  The freshly-minted Mach send right in
the cmsg payload is not interpretable by pflocal: pflocal's
SCM_RIGHTS handler treats the integer as a file-descriptor index
and looks it up in the sender's `io_t` table.  A bare port name has
no fd backing, so the lookup fails.

## Verbatim probe output (Debian GNU/Hurd 0.9, GNU-Mach 1.8+git20260224)

```
STREAM: plain send -> 1 (errno=0)
STREAM: sendmsg+cmsg -> -1 (errno=1073741833 0x40000009)
DGRAM: plain send -> 1 (errno=1073741833)
DGRAM: sendmsg+cmsg -> -1 (errno=1073741833 0x40000009)
SEQPACKET: plain send -> 1 (errno=1073741833)
SEQPACKET: sendmsg+cmsg -> -1 (errno=1073741833 0x40000009)
```

(plain-send errno is stale from a prior call; the return of 1 means
the send actually succeeded.)

Decoded errno via on-VM helper:

```
0x40000009    0x40000009 = Bad file descriptor
EBADF         0x40000009 = Bad file descriptor
```

EBADF is the right diagnosis here for "the integer in your cmsg is
not a live fd".  pflocal is doing fd translation, not raw Mach port
forwarding, on its SCM_RIGHTS path.

## Why this kills design 2.1

Section 2.1 of the design routes the client's rendezvous Mach port
to the supervisor in a single AF_UNIX RPC by attaching the send
right as SCM_RIGHTS.  On Linux's AF_UNIX this works because
SCM_RIGHTS payload integers are kernel-translated file descriptors.
On Hurd's pflocal the same wire-shape is preserved but the
*semantics* are stricter: the integer must already be a member of
the sender's open-fd set so libports can look up the io_t and pass
its send right.  A raw `mach_port_allocate` result is not in any
fd table.

Workarounds considered and rejected for 2.1:

  - Wrap the rendezvous port in a custom server (libports
    boilerplate) so the client gets an `int fd = open("/servers/...
    ")` to pass.  This is more code than the parallel channel
    fallback and adds a new privileged server to PID-1's surface.
  - Mint an `io_t` with `io_make_self` and ship that.  io_t names
    point to existing files, not arbitrary rendezvous targets;
    repurposing the type just to satisfy SCM_RIGHTS would mean a
    real file (e.g. an anonymous pipe) and would defeat the
    purpose of the rendezvous design.

The cheaper path is alternative 2.2, which is what the design
already documented as the fallback.

## What 2.2 looks like in code terms

Two channels per client:

  1. AF_UNIX `/run/geos/super.sock` for the RPC verbs (existing,
     unchanged on the wire).
  2. A second client-allocated Mach receive port whose name the
     client sends as the *first request* on channel 1, encoded as
     an opaque integer the supervisor passes back to
     `auth_server_authenticate` via the parallel-channel auth
     dance.  The send right travels through a side channel
     bootstrapped by the supervisor's `bootstrap_port` rather than
     through pflocal cmsg.

Specifically, the supervisor calls `task_get_bootstrap_port` of
its own task at startup and publishes the resulting send right to
clients via the existing on-disk path (e.g. `/run/geos/super.bs`),
where each client `task_set_bootstrap_port`s it before issuing
the first RPC.  The auth handshake then runs through the Mach
channel directly: client calls `auth_user_authenticate(rendez)`
on its own auth_t, supervisor reads the matched rendezvous on
the side channel via `auth_server_authenticate(rendez)`.

That avoids pflocal entirely for the rendezvous-port hand-off
while keeping the AF_UNIX RPC for verbs.

## What this means for the v0.8 commits

Already-shipped code on the `hurd` branch and on `main` that
needs revisiting:

  - `main 78c7428` `port_caps.client_auth_handshake` slot:
    KEEP.  The seam shape is fine, only the implementation
    semantics change.
  - `main c5a7ed4` five `Fpid1_unix_*` bindings: KEEP.  The
    AF_UNIX RPC still uses them; only the SCM_RIGHTS plumbing
    inside the elisp layer goes away.
  - `main 5201055` `rpc-client.el` rewrite: REVISIT.  The
    rendezvous-port hand-off needs to move to the side channel.
    Today's code does not actually attach a cmsg in elisp
    (only the pid1 client_auth_handshake slot would have), so
    this is a smaller change than it sounds.
  - `hurd 81f3add` `hurd_get_peer_cred`: REVISIT.  Today it
    recvmsg's a cmsg.  Tomorrow it reads from the parallel
    Mach channel.
  - `hurd d9645a3` `hurd_client_auth_handshake`: REVISIT.
    Today it sendmsg's a cmsg.  Tomorrow it sends through
    the parallel Mach channel.
  - `hurd 414d20b` `tests/hurd-pflocal-cmsg.c`: KEEP, with a
    one-line comment at the top noting the verdict and a
    pointer to this runlog.  The probe stands as the
    verification artifact for why we went with 2.2.

## Reproduction

  1. Boot Debian GNU/Hurd 0.9 VM (any).  ssh in as root.
  2. SCP `tests/hurd-pflocal-cmsg.c` to `/root/`.
  3. `cd /root && gcc -Wall -Wextra -Werror -o hurd-pflocal-cmsg
     hurd-pflocal-cmsg.c` (no `-lmach` needed; Hurd's glibc
     bundles the user-side Mach RPC stubs).
  4. `./hurd-pflocal-cmsg` -> exits 1, prints
     `FAIL: sendmsg returned -1 (errno=1073741833 Bad file
     descriptor)`.

For the variants probe shown above, see `/tmp/hurd-pflocal-
variants.c` in the runlog's working notes; the wire test is the
single-file probe checked in at `tests/hurd-pflocal-cmsg.c`.

## Why this is fine

The v0.8 design doc explicitly named 2.2 as the fallback and
laid out the parallel-Mach-channel mechanics.  The probe was
the gate between "ship 2.1 quietly" and "spend a week on 2.2".
The probe failed, the gate is now clear, the rework is bounded
to two server-side functions, one client-side function, and the
elisp wiring layer.  The seam stays, the bindings stay, only
the auth-port hand-off moves to its own Mach channel.
