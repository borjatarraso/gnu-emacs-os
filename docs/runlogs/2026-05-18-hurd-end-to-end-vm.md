<!-- SPDX-License-Identifier: FSFAP -->

# 2026-05-18: v0.8 design-2.2 slice 5 end-to-end PASS on Debian Hurd VM

Follow-on to `2026-05-18-hurd-end-to-end-multi-user.md`. That receipt
shipped the slice 5 code with VM verification deferred ("no Hurd qcow2
staged locally"); this run closes that gap on the canonical Debian
Hurd 0.9 VM image at `/home/overdrive/hurd-vm/debian-hurd-amd64-
20260314.img` (host run from a snapshot, ssh on 127.0.0.1:2222).

## Result

**PASS.** All three handshake markers fire and the harness exits 0
inside the 8-second wall budget. Two production bugs in `port_hurd.c`
were diagnosed and fixed on the way: a wire-layout misdeclaration in
`struct submit_nonce_request` and a missing reply-header setup in
`geos_auth_demuxer`. The test harness mirrored both bugs; both were
fixed in lockstep.

## PASS markers (verbatim from a clean run)

```
parent OK publish: idempotency EBUSY-as-expected
child  OK file_name_lookup returned 0xe
child  OK submit_nonce sent
child  OK auth_user_authenticate kr=0x0
child  slice4_handshake_ok=1
parent OK drained submit_nonce; pending_auth fingerprint changed
        (1469598103934665603 -> 1610606804295165329);
        drain saw 1 fsys_getroot
parent slice4_handshake_ok=1
parent OK pending_auth row uid=0 gid=0 (real, not sentinel);
        harness euid=0 egid=0
parent slice5_handshake_ok=1
```

`row uid=0 gid=0` because the harness ran as root on the Hurd VM; the
PASS gate is "not the slice-3 sentinel `(uint32_t)-1`", which a real
`auth_server_authenticate` call passes.

## Wedge diagnosis

The slice-5 ship marked the harness as "wedges >60s after one stdout
line". Diagnostic stderr prints in the harness pinpointed two
sequential failures:

### Bug 1: `geos_auth_demuxer` calls the routine pointer, not the wrapper

The MIG-generated `fsysServer.c` exports two demuxer layers:

  - `fsys_server_routine(InHeadP)`: a `static __inline` in
    `fsys_S.h` that returns the routine pointer for the message's
    `msgh_id` (NULL if out of range).
  - `fsys_server(InHeadP, OutHeadP)`: the `mig_external boolean_t`
    wrapper in `fsysServer.c` that initialises the reply header
    (`msgh_bits = MACH_MSGH_BITS(reply_bits, 0)`, `msgh_size = sizeof
    reply`, `msgh_remote_port = InP->msgh_reply_port`,
    `msgh_local_port = NULL`, `msgh_seqno = 0`, `msgh_id = InP->
    msgh_id + 100`), looks up the routine, and invokes it.

The wrapper is what does the reply-header setup. The bare routine
sets only `RetCode` + any data fields and trusts the wrapper to have
filled the header. The slice-3 demuxer in `port_hurd.c` (and the
matching mirror in `tests/hurd-client-handshake.c`) called the
routine pointer directly, leaving `outp->msgh_remote_port` at the
memset-zero `MACH_PORT_NULL` we set before calling the demuxer. The
per-tick drain's reply-send guard
(`MACH_PORT_VALID(out_msg.hdr.msgh_remote_port) &&
out_msg.hdr.msgh_size > 0`) saw a non-zero size but a NULL port and
silently swallowed the reply. The client's `file_name_lookup` blocked
forever waiting for a reply that nobody sent.

The slice-3 harness (`hurd-publish-auth-port.c`) PASSED with this bug
present because it only checked `fsys_getroot_calls > 0` (drain saw
the request), never that the client received the reply. The slice-4
runlog inherited the same false positive. Slice 5's harness extension
is the first that actually requires the client to USE the returned
port; it caught the bug.

Fix: declare `extern boolean_t fsys_server(...)` in `port_hurd.c`
(the header doesn't export it) and call the wrapper instead of the
routine pointer. Mirror in the harness.

### Bug 2: `struct submit_nonce_request` port slot is 4 bytes; kernel reads 8

MIG-generated message structs declare port descriptors as
`mach_port_name_inlined_t` (an 8-byte union of `{uint32_t name;
uintptr_t kernel_port_do_not_use;}`) with `msgt_size = 64`. The slot
is 8 bytes wide on 64-bit Hurd; the kernel reads exactly that many
bytes when interpreting a port descriptor.

Our hand-rolled `struct submit_nonce_request` declared the port slot
as bare `mach_port_t` (a 4-byte `unsigned int`) with `msgt_size = 8 *
sizeof(mach_port_t)` (32). The struct compiled clean, the send
returned `MACH_SEND_INVALID_DEST = 0x1000000f` on every attempt
because the kernel was reading 8 bytes (the 4-byte port name + 4
bytes of trailing padding from the following `mach_msg_type_t`) and
interpreting the 64-bit blob as a port name that did not exist in our
task's port table.

Fix: declare the slot as `mach_port_name_inlined_t` (writing through
`.name`) and set `msgt_size = 64`. Mirror in the harness.

## Verification

  - Hurd build: `make PORT=hurd STATIC=0` clean (the warning about
    Makefile mtime in the future is a known VM clock-skew artefact,
    not a build error).
  - Linux build: `make` clean on a Linux dev host.
  - Module build: `make pid1-module.so` clean on the same host.
  - Harness run: `./hurd-client-handshake` exits 0 with all three
    PASS markers in under 1 second of wall (the 30-second internal
    deadline in the harness was never approached).

## Gotchas added

Two new entries appended to the agent-state hurd-gotchas catalog
(kept under the agent state directory, not shipped):

  - "fsys_server boolean wrapper is what sets up the reply header;
    the routine pointer alone leaves msgh_remote_port at zero."
  - "hand-rolled MIG message structs need mach_port_name_inlined_t
    for port slots, not bare mach_port_t."

Both carry the slice-5 trace path so the next time a custom MIG verb
goes silently wedged the lookup is one grep.

## Memory + matrix

  - `MEMORY.md` line for the slice-5 PASS flip pending; replaces the
    "VM-verify deferred" parenthetical from the partial-ship entry.
  - The PARTIAL header in `2026-05-18-hurd-end-to-end-multi-user.md`
    flips to PASS with a back-link to this runlog.
  - `docs/HURD_PORT.md` matrix rows for `port->get_peer_cred` and
    `port->client_auth_handshake` keep their YES; this run confirms
    them on a live VM.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
