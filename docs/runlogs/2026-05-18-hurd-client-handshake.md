<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

# 2026-05-18: hurd client-handshake slice 4 verification

Slice 4 of v0.8 design 2.2 (the Hurd peer-cred handshake).
Closes the rendezvous-port loop the slice 3 publish path left
open: a child task's `file_name_lookup` on `/servers/geos-auth`
now returns a usable send right, the client posts the
`submit_nonce` mach_msg with the rendezvous descriptor, and
`auth_user_authenticate` completes the rendezvous dance.

This runlog also closes the open blueprint entry "fsys_getroot
reply does not unblock client file_name_lookup" (RESOLVED) and
adds the drain segfault entry to `hurd-gotchas.md`.

## SPEC for pid1-engineer (apply on main, side branch is owner)

The slice-4 client-side surface grew the `port_caps.client_auth_handshake`
slot from `int (*)(int fd)` to `int (*)(int fd, const uint8_t nonce[16])`.
The Linux backend ignores NONCE; the Hurd backend uses it as the
16-byte rendezvous identifier the elisp client read off the AF_UNIX
socket immediately after connect. This SPEC describes the
main-side changes the side branch already shipped; pid1-engineer
applies them on main after skeptic review.

The Hurd-side body (`port_hurd.c::hurd_client_auth_handshake`) stays
on the side branch, where it owns the file_name_lookup +
mach_port_allocate + hand-rolled mach_msg + auth_user_authenticate
sequence.

### 1. `pid1/port_layer.h`: slot signature

```
/* client-side counterpart to get_peer_cred.  the Linux peer-cred
 * model is server-only [...]  the Hurd model is bidirectional [...].
 *
 * Linux backend: returns 0 immediately, no syscalls.  the nonce arg
 * is ignored.
 *
 * Hurd backend: returns 0 on a successful handshake, -1 with errno
 * on failure (EACCES if the auth server rejects; EAGAIN if the auth
 * server or the supervisor's auth port is unreachable so the caller
 * can retry).  the slice 4 body looks up the supervisor's auth port
 * via file_name_lookup("/servers/geos-auth", 0, 0), allocates a
 * rendezvous receive right + send-right pair, hand-rolls a
 * mach_msg(msgh_id=90001, rendezvous MOVE_SEND, nonce[16]) against
 * the auth port, then runs auth_user_authenticate against the
 * rendezvous to complete the dance.
 *
 * NONCE is the 16-byte rendezvous identifier the elisp client read
 * off the AF_UNIX socket immediately after connect (the supervisor
 * writes 16 raw bytes on accept, no length prefix).  must be
 * non-NULL; NULL returns -1 with errno=EINVAL. */
int (*client_auth_handshake)(int fd, const uint8_t nonce[16]);
```

### 2. `pid1/port_linux.c`: Linux body

```
static int
linux_client_auth_handshake(int fd, const uint8_t nonce[16])
{
    (void)fd;
    (void)nonce;
    return 0;
}
```

The `(void)nonce` cast is the standard `-Wunused-parameter -Werror`
dance for a stub that genuinely ignores its arguments. No syscalls,
no wire bytes; the supervisor's get_peer_cred still reads
SO_PEERCRED on the AF_UNIX accept the way it always did.

### 3. `pid1/emacs-init.c`: Femacs binding

The `Fpid1_client_auth_handshake` callback accepts arity 1 or 2.
Arity 1 is the legacy path (NONCE defaults to all-zero); arity 2 is
the slice-4 path with the real nonce. The transition window keeps
`rpc-client.el` on main from breaking while the side branch ships.

NONCE arg validation: probe with
`copy_string_contents(env, args[1], NULL, &need)`; require
`need == 17` (16 bytes + trailing NUL the emacs ABI appends). Any
other length signals `pid1-error: nonce len: Invalid argument`.

```
emacs_value cah = env->make_function(env, 1, 2,
    Fpid1_client_auth_handshake,
    "Run the client-side auth handshake for an open RPC socket FD. "
    "Optional NONCE is a 16-byte unibyte string [...]. "
    "On Linux this is a no-op (SO_PEERCRED is server-side; NONCE "
    "is ignored).  On Hurd this performs the rendezvous-port + "
    "auth_user_authenticate dance against the gnumach auth server. "
    "Return t.",
    NULL);
pid1_defalias(env, "pid1-client-auth-handshake", cah);
```

### 4. `emacs-init/core/rpc-client.el`: caller (deferred)

Today rpc-client.el calls `(pid1-client-auth-handshake fd)` with
arity 1. The Hurd-side end-to-end multi-user flow needs the arity-2
form with the nonce the supervisor wrote on accept. On Linux the
arity-1 form continues to work (the binding accepts both). The
caller update is part of the v0.8 supervisor-side wire change and
moves with that ship.

### 5. Build verification on main

```
$ cd pid1 && make clean && make PORT=linux STATIC=0
$ make PORT=linux STATIC=0 pid1-module.so
```

Both targets build clean with the existing `-Wall -Wextra -Wpedantic
-Werror` flag set. The `(void)nonce` cast keeps `-Wunused-parameter`
quiet; no other warnings.

### 6. Freeze test on main (Linux)

`iso-build/freeze-tests/freeze-test-port-hurd.el` grows
`freeze-test-port-hurd-client-handshake`, which checks:

  1. The binding is `fbound`.
  2. `func-arity` returns `(1 . 2)`.
  3. Calling with a 1-byte nonce signals an error (proves the
     length-check path is wired).

```
$ emacs -Q --batch \
    --eval "(define-error 'pid1-error \"PID1 supervision error\")" \
    --eval "(module-load (expand-file-name \"pid1/pid1-module.so\"))" \
    -L iso-build/freeze-tests \
    -l iso-build/freeze-tests/freeze-test-port-hurd.el \
    --eval "(message \"%S\" (freeze-test-port-hurd-client-handshake))"
freeze-test-port-hurd: port-hurd/client-handshake -> pass
pass
```

End of SPEC.

## Result

**PASS (Linux dev host).**  Hurd VM end-to-end via
`tests/hurd-client-handshake.c` pending VM runner.

The Linux freeze-test confirms the binding shape; the Linux module
builds clean under `-Werror`; the slice-3 freeze-tests
(`freeze-test-port-hurd-publish-auth-port` and
`freeze-test-port-hurd-auth-drain`) continue to pass with the new
binding loaded. The Hurd-side end-to-end harness exists at
`tests/hurd-client-handshake.c` and will run on the next Hurd VM
exercise; the PASS markers are `child slice4_handshake_ok=1` and
`parent slice4_handshake_ok=1`.

## Slice 4 phase breakdown

### Phase 4a: fix `S_fsys_getroot`

The slice-3 body used:

```
*file = ports_get_right(auth_port_obj);
*filePoly = MACH_MSG_TYPE_MAKE_SEND;
```

`ports_get_right` returns the bare kernel port-name without bumping
libports' user-ref count. `MAKE_SEND` then asks the kernel to mint a
fresh send descriptor for a name with no user-ref backing; on this
gnumach build the MIG reply marshaller silently drops the descriptor
and the client's `file_name_lookup` blocks forever.

Slice 4 phase 4a body:

```
*file = ports_get_send_right(auth_port_obj);
*filePoly = MACH_MSG_TYPE_MOVE_SEND;
```

`ports_get_send_right` mints a fresh user-ref against the
libports-managed receive right; `MOVE_SEND` consumes that ref on the
reply, transferring ownership cleanly. Do NOT `mach_port_deallocate`
the name afterwards; the marshaller deallocated our side. The same
pattern is documented in `libports-cookbook.md` ("publish a singleton
service port").

Defence in depth: on the EOPNOTSUPP error path (auth_port_obj NULL),
write defaults for `*file`, `*filePoly`, `*do_retry`, and
`retry_name[0]` before returning so a buggy libdiskfs cannot
dereference uninitialised state.

### Phase 4b: drain segfault hygiene

Two interacting bugs in the slice-3 drain pump:

  1. `MACH_RCV_LARGE` was set with no retry path. The kernel kept
     oversize messages queued and the drain batch never made progress.
  2. `out_msg` was not memset per-iteration. After the first dispatch,
     a stale `msgh_remote_port` from the previous reply could line up
     with a send-once descriptor the kernel destroyed on the previous
     send; the second send segfaulted inside gnumach.

Slice 4 phase 4b fixes:

  - Drop `MACH_RCV_LARGE`. gnumach destroys the oversize message and
    the next iteration sees a fresh queue. Every verb we support fits
    well under the 8 KiB stack buffer.
  - memset both `in_msg` and `out_msg` at the top of every iteration.
    Explicitly re-zero `out_msg.hdr.msgh_remote_port` after the memset
    as belt-and-braces.
  - Do NOT `mach_port_deallocate` the reply's remote port after the
    send mach_msg even on send error. The kernel destroys the
    send-once descriptor on every error code that touches the port
    table; double-dropping is the canonical drain crash mode.

### Phase 4c: client-side body

`hurd_client_auth_handshake(int fd, const uint8_t nonce[16])`:

  1. `file_name_lookup("/servers/geos-auth", 0, 0)` -> auth_send.
     EINVAL on NULL nonce; the lookup propagates the underlying errno
     on failure (typically ENOENT if the translator is not published).
  2. `mach_port_allocate(MACH_PORT_RIGHT_RECEIVE)` + `mach_port_insert_right(MAKE_SEND)`
     to mint the rendezvous receive-right + send-right pair.
  3. Hand-roll `submit_nonce` request with `msgh_id = 90001`,
     `MACH_MSGH_BITS(COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX`, a
     rendezvous `MOVE_SEND` descriptor in the legacy `mach_msg_type_t`
     format gnumach parses, and the 16-byte nonce.
  4. `mach_msg(MACH_SEND_MSG | MACH_SEND_TIMEOUT)` against auth_send.
  5. `auth_user_authenticate(self_auth, rendez_rcv, MAKE_SEND, &newport)`.
     The supervisor's `S_geos_auth_submit_nonce` matches with
     `auth_server_authenticate(self_auth, inp->rendez, ...)` and extracts
     the caller's uid/gid.

The fd arg is ignored (`(void)fd`). Errno table:
KERN_RESOURCE_SHORTAGE -> ENOMEM, KERN_NO_ACCESS / KERN_PROTECTION_FAILURE -> EACCES,
MACH_SEND_INVALID_DEST -> ENOENT, MACH_SEND_TIMED_OUT -> EAGAIN.

### Phase 4d: end-to-end harness

`tests/hurd-client-handshake.c` (~570 lines). Mirrors port_hurd.c's
publish + demuxer chain + slice-4-fixed `S_fsys_getroot` + drain pump,
plus a `client_handshake` function that mirrors the new
`hurd_client_auth_handshake`. Forks: child runs the client side and
writes status via pipe; parent drains messages and checks the
`pending_auth` fingerprint changes (proves submit_nonce reached the
table without leaking uid/gid through a side channel).

PASS markers:
  - `child  OK file_name_lookup returned <hex>`
  - `child  OK submit_nonce sent`
  - `child  OK auth_user_authenticate kr=0x<N>`
  - `child  slice4_handshake_ok=1`
  - `parent OK drained submit_nonce; pending_auth fingerprint changed`
  - `parent slice4_handshake_ok=1`
  - exit 0

Build (Hurd VM):

```
(cd ../pid1 && make PORT=hurd STATIC=0 fsys_S.h fsysServer.boot.o)
gcc -Wall -Wextra -Werror -I../pid1 \
    -o hurd-client-handshake hurd-client-handshake.c \
    ../pid1/fsysServer.boot.o \
    -lports -lfshelp -lhurduser -lmachuser
```

### Phase 4e: freeze test

`iso-build/freeze-tests/freeze-test-port-hurd.el` grows
`freeze-test-port-hurd-client-handshake`. On Linux with the module
loaded it asserts arity `(1 . 2)` and that a short nonce signals an
error. On Hurd it records `skip` with a pointer to the end-to-end
harness, because the in-process call would block on file_name_lookup
unless a supervisor is published in the same process.

Dev-host run:

```
$ emacs -Q --batch \
    --eval "(define-error 'pid1-error \"PID1 supervision error\")" \
    --eval "(module-load (expand-file-name \"pid1/pid1-module.so\"))" \
    -L iso-build/freeze-tests \
    -l iso-build/freeze-tests/freeze-test-port-hurd.el \
    --eval "(message \"publish: %S\" (freeze-test-port-hurd-publish-auth-port))" \
    --eval "(message \"drain:   %S\" (freeze-test-port-hurd-auth-drain))" \
    --eval "(message \"client:  %S\" (freeze-test-port-hurd-client-handshake))"
freeze-test-port-hurd: port-hurd/publish-auth-port -> (skip . "geos-kernel != 'hurd")
publish: (skip . "geos-kernel != 'hurd")
freeze-test-port-hurd: port-hurd/auth-drain -> pass
drain:   pass
freeze-test-port-hurd: port-hurd/client-handshake -> pass
client:  pass
```

## Blueprint entries added / updated

In the side-branch agent's hurd-gotchas catalog (kept under the
agent state directory, not shipped):

  - `fsys_getroot reply does not unblock client file_name_lookup`:
    updated from "Suspected cause / Not yet root-caused" to RESOLVED
    with the slice-4 phase-4a fix. Lifecycle invariant called out:
    `ports_get_send_right` for hand-back send rights;
    `ports_get_right` for own-bookkeeping kernel-name use only.

  - `drain segfault when MACH_RCV_LARGE is set without a retry path`:
    new entry describing the two interacting bugs (MACH_RCV_LARGE
    without retry, missing per-iteration memset) and the three-part
    fix (drop the flag, double-memset, do not deallocate reply send-once
    rights even on error).

## What slice 4 does NOT cover

  - Real `auth_server_authenticate` on the supervisor side. The slice-3
    `S_geos_auth_submit_nonce` body writes sentinel uid/gid
    `(uint32_t)-1` into the pending_auth row; slice 5 replaces that
    with a real call to `auth_server_authenticate` against the
    rendezvous so the row reflects the actual client credentials.
  - elisp-side rpc-client.el caller update to pass the real nonce.
    The arity-2 binding is in place; the caller still passes arity 1.
    Cuts in with the v0.8 supervisor wire change.
  - rpc-server.el supervisor-side "write 16-byte nonce on accept" step.
    Same v0.8 supervisor wire change.

## Files touched

  - `pid1/port_layer.h`: slot signature + docstring grew NONCE arg.
  - `pid1/port_linux.c`: `linux_client_auth_handshake` accepts NONCE,
    casts to `(void)`.
  - `pid1/port_hurd.c`: phase 4a `S_fsys_getroot` MOVE_SEND fix; phase
    4b drain hygiene; phase 4c `hurd_client_auth_handshake` body;
    forward-declarations hoisted so the client body can reference
    `GEOS_AUTH_NONCE_LEN`, `GEOS_AUTH_SUBMIT_NONCE_MSGID`, and
    `struct submit_nonce_request`.
  - `pid1/emacs-init.c`: `Fpid1_client_auth_handshake` accepts arity
    1 or 2; arity-2 path validates a 16-byte unibyte nonce string;
    `make_function` arity grew `(1, 2)`.
  - `tests/hurd-client-handshake.c`: new ~570-line end-to-end harness.
  - `iso-build/freeze-tests/freeze-test-port-hurd.el`: new
    `freeze-test-port-hurd-client-handshake` plus header doc update.
  - (agent state) hurd-gotchas catalog: fsys_getroot entry RESOLVED,
    drain segfault entry added.
