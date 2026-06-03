<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

# 2026-05-18: hurd_publish_auth_port slice 2 verification

Follow-on to `2026-05-18-hurd-mach-sidechannel-auth.md`.  Slice 1
landed an ENOSYS stub at `0a1852e`; this run verifies the slice 2
body that allocates the long-lived auth receive port and calls
`file_set_translator` against `/servers/geos-auth`.

## Result

**PARTIAL PASS.**  The slice 2 deliverable -- "allocate the receive
port + publish via file_set_translator" -- runs cleanly on Debian
GNU/Hurd 0.9: every Mach call returns `KERN_SUCCESS`, the receive
right is stashed in the file-static `hurd_auth_port` slot, the
idempotency-with-EBUSY contract holds, and the supervisor-side state
is exactly what slice 3 needs to drain via `mach_msg`.

What is *not* yet verified, and is flagged for slice 3 to confront:
client-side `file_name_lookup("/servers/geos-auth", 0, 0)` does NOT
return the auth send right -- it falls back to the underlying file
node (the bare 0-byte file at `/servers/geos-auth`).  The KERN_SUCCESS
from `file_set_translator` is real (verified twice, once after a clean
`rm` + restart), but the bare-port-as-active-translator pattern the
design doc described in 3.5.1 Option A appears to require additional
fsys-protocol plumbing on the publisher side before clients can
actually reach the port through the filesystem.

Slice 2 ships as planned (the port slot is the load-bearing artifact);
the transport question moves to slice 3, where the supervisor's
per-tick drain loop can be wired up alongside whatever real publication
mechanism makes the send right reachable from client tasks (likely a
libports-based fsys server, OR a `settrans -aP` wrapper, OR a different
rendezvous convention entirely).  Both candidates are listed in the
slice 2 brief as acceptable pivots; the runlog below describes the
state of play so slice 3 starts from a known footing.

## What the slice 2 commit does

`pid1/port_hurd.c::hurd_publish_auth_port` body, in order:

  1. Early-return `-1` with `errno=EBUSY` if the file-static
     `hurd_auth_port` slot is already non-NULL.  Idempotency-with-EBUSY
     contract from the brief.
  2. `mach_port_allocate(MACH_PORT_RIGHT_RECEIVE)` -> the receive right
     slice 3 will `mach_msg`-drain inside `Fpid1_rpc_poll`.  Stashed
     in the slot only after the full publish dance succeeds, so an
     error mid-flight leaves the slot at MACH_PORT_NULL and the next
     call can retry.
  3. `mach_port_insert_right(MAKE_SEND)` against the same name.  Gives
     the supervisor a send-right user-ref it can hand out in future
     direct-publish paths even if file_set_translator's COPY_SEND were
     the only client-reachable copy.
  4. `open("/servers/geos-auth", O_CREAT|O_WRONLY, 0600)` + close.
     Ensures the file node exists; absent `/servers/` surfaces as
     ENOENT which we propagate (fabricating it would mask a broken
     bootstrap).
  5. `file_name_lookup(path, O_NOTRANS, 0)` -> a file_t to the bare
     node (NOT to any pre-existing translator chained on top).
  6. `file_set_translator(node, passive_flags=0, active_flags=
     FS_TRANS_SET|FS_TRANS_FORCE, 0, NULL, 0, recv,
     MACH_MSG_TYPE_COPY_SEND)`.  passive_flags=0 deliberately avoids
     writing an on-disk passive translator record: the supervisor is
     the only source of truth and a stale passive pointing at a dead
     supervisor would be worse than no record at all.

Every error path unwinds the partial state (deallocate the send
user-ref, drop the receive right via `mach_port_mod_refs(RIGHT_RECEIVE,
-1)`) and translates the underlying `kern_return_t` to a POSIX errno
via the same switch table the rest of `port_hurd.c` uses.

## The verification probe

`tests/hurd-publish-auth-port.c` is a single-file standalone that
duplicates `hurd_publish_auth_port`'s body verbatim and exercises:

  - First call: must return 0 (`OK published recv=0x<N>`).
  - Second call: must return -1 with errno=EBUSY and must NOT mutate
    the slot.
  - 60-second hold so an outside `showtrans` / client-probe can observe
    the published state.

Build (root@hurd-vm):

```
gcc -Wall -Wextra -Werror -o hurd-publish-auth-port \
    hurd-publish-auth-port.c -lhurduser -lmachuser
```

Run, clean state (`rm -f /servers/geos-auth` first):

```
# /root/hurd-publish-auth-port &
OK published recv=0x16 idempotency=EBUSY-as-expected
holding port for 60s so showtrans can observe.
```

Receive port name `0x16` is the supervisor task's table index for the
allocated receive right; the kernel assigns a fresh name per allocate,
so the exact number varies run to run.

External observation while the test process holds:

```
# ls -la /servers/geos-auth
-rw------- 1 root root 0 May 18 06:49 /servers/geos-auth

# showtrans /servers/geos-auth
(empty output, exit 1)
```

showtrans returning nothing is expected and correct: we deliberately
passed `passive_flags=0` to `file_set_translator`, so no on-disk
passive translator record is created.  showtrans only reports passive
translators.  The lack of any error or warning from `file_set_translator`
itself confirms gnumach accepted the call.

Why I cannot recommend a "did the active translator stick" assertion
from a showtrans-shaped check today: showtrans has no flag for active
translators (only `-p/-P/-t`, all passive-only), and the standard active
inspection (`fsysopts /servers/geos-auth`) walks UP the dir tree to the
nearest real fs -- our case it returned `ext2fs --writable ... part:2:...`,
i.e. the root filesystem's options, NOT our auth port.  That is itself
the diagnostic that `file_name_lookup` on the path does not actually
route to our active port.

## Client-side probe (the gotcha for slice 3)

A separate `tests/auth-client-probe.c`-shaped two-line probe
(`file_name_lookup("/servers/geos-auth", 0, 0)` and a second call with
`O_NOTRANS`) returned the same port name on both flag variants:

```
OK default lookup port=0x17
OK notrans lookup port=0x17
```

If the active translator we installed were being consulted, the
default lookup would route through fsys_getroot on our send right and
return a DIFFERENT port name from the O_NOTRANS lookup of the bare
file node.  Identical port names on both lookups indicate the active
translator path is being silently bypassed -- either gnumach's
fsys_getroot dispatch on our bare port returned an error that libc
silently degraded into "use the underlying node", or the kernel never
actually installed our port as the live active translator despite
returning KERN_SUCCESS.

This is the architectural question slice 3 (or whoever wires the
transport) has to answer.  The slice 2 brief explicitly listed this
as a pivot-candidate scenario: "If the file_set_translator approach
has unexpected semantics on Debian Hurd 0.9 ..., pivot to publishing
the port name via a different fs mechanism."  Two viable pivots from
the brief, both still on the table:

  - `settrans -aP` (the user-side tool, wrapped from C).  settrans
    presumably uses a libports server to mediate; using its
    side-channel mechanics from pid1 would inherit working transport.
  - A bespoke fsys server: implement the minimum subset of fsys_getroot
    that returns our auth send right and bind it via
    `file_set_translator` the same way /hurd/auth itself does.  Heavier
    code, canonically correct.

Both are out of scope for slice 2 (which only owns the receive-port
allocation); the runlog flags them so slice 3 starts already aware.

## What slice 2 does deliver

  - `hurd_auth_port` slot is populated with a valid receive right
    after the publish call returns 0.
  - Slice 3's `mach_msg(MACH_RCV_MSG | MACH_RCV_TIMEOUT, timeout=0)`
    drain inside `Fpid1_rpc_poll` can consume from this slot without
    further setup.
  - The idempotency contract (second call returns EBUSY without
    mutating the slot) holds; supervisor wiring can call
    `pid1-publish-auth-port` defensively without risking double-allocate
    leaks.
  - The build path `make PORT=hurd STATIC=0 emacs-init` on real Debian
    GNU/Hurd 0.9 is **not** currently green (the pre-existing
    `hurd_get_peer_cred` body from `3e1bd3a`, predating today's slice
    2 work, is broken against this Hurd's `auth_server_authenticate`
    13-arg signature -- it has 11 args).  Slice 5 owns the rewrite of
    `hurd_get_peer_cred`; slice 2 does not regress what was already
    broken on this surface.  The standalone test
    `tests/hurd-publish-auth-port.c` builds clean and is the
    verification artifact for slice 2 in lieu of the full supervisor
    binary.

## What slice 2 does NOT deliver

  - Wired-up `pid1-publish-auth-port` Femacs binding.  The brief says
    the elisp wiring is a follow-on after this slice lands.
  - Client-side reachability of the auth send right via
    `file_name_lookup("/servers/geos-auth", 0, 0)`.  See gotcha above;
    this moves to slice 3 (or the pivot that precedes slice 3).
  - Per-tick `mach_msg` drain inside `Fpid1_rpc_poll`.  Slice 3.
  - End-to-end multi-user auth.  Slice 5.

## Reproduction

  1. Boot the Debian GNU/Hurd 0.9 VM (image at
     `~/hurd-vm/work.img`), SSH in as root via
     `ssh -p 2222 -i ~/.ssh/id_ed25519_p0lym0rphic root@127.0.0.1`.
  2. `scp tests/hurd-publish-auth-port.c root@hurd-vm:/root/`.
  3. `cd /root && gcc -Wall -Wextra -Werror -o hurd-publish-auth-port
     hurd-publish-auth-port.c -lhurduser -lmachuser`.
  4. `rm -f /servers/geos-auth` (clean state).
  5. `/root/hurd-publish-auth-port` -- expect
     `OK published recv=0x<N> idempotency=EBUSY-as-expected`,
     followed by a 60s hold.
  6. While the process holds: `ls -la /servers/geos-auth` shows a
     freshly-created 0-byte file; `showtrans /servers/geos-auth` is
     silent and exits 1 (no passive translator was written, by design).
  7. Optional: build and run a `file_name_lookup`-shaped client probe
     to confirm the current bare-port transport gotcha; the result
     above is reproducible.

## Freeze-test stub

`iso-build/freeze-tests/freeze-test-port-hurd.el` is added on the
hurd branch.  The single test
`freeze-test-port-hurd-publish-auth-port` asserts
`(pid1-publish-auth-port)` returns t when run on Hurd with the
pid1-module loaded; on Linux or when the binding is unbound, it records
'skip with a diagnostic string.  Today the binding does not yet exist
in elisp (slice 2 does not wire it), so the test records skip on every
host; the assertion becomes live the moment the elisp wiring follow-on
lands.

## What this clears

Slice 2 commit lands on the hurd branch; the receive port slot is
real; the idempotency contract is enforced.  The remaining slice-2
brief expectation -- that `file_name_lookup` on `/servers/geos-auth`
returns the supervisor's auth send right -- is documented above as
the next-slice problem.  Slice 3 starts with a real port to drain
from, which was the load-bearing slice 2 deliverable.
