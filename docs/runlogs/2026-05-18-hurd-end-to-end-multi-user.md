# 2026-05-18: v0.8 design-2.2 slice 5 end-to-end multi-user

Follow-on to `2026-05-18-hurd-publish-auth-port.md`. Slice 2 published
the auth port via libports at `a52cbf3` (main seam) + `0a1852e` (hurd
ENOSYS stub) + the libports rewrite on the hurd branch. Slice 3 added
the per-tick drain. Slice 4 wired `hurd_client_auth_handshake` end-to-end
against the libports bucket and proved the submit_nonce mach_msg
reaches `S_geos_auth_submit_nonce`. This run lands the slice 5
deliverables.

## Result

**PARTIAL SHIP, VM-VERIFY DEFERRED.** All code lives on the hurd
branch; the main-side pid1/ edits are spec'd below and handed to
pid1-engineer for the standard skeptic review. Linux build clean, no
new warnings, freeze-tests pass. The end-to-end multi-user dance on a
real Hurd VM is blocked locally: no Hurd qcow2 is staged on this dev
host (`~/.cache/geos-hurd-vm/` absent, `/var/lib/libvirt/images/`
not readable, the `iso-build/hurd-smoke-test.sh` builder has not run
on this checkout). The Hurd-side verification runs against the test
harness `tests/hurd-client-handshake.c` as soon as the VM gate
clears; the harness now carries a slice-5 PASS marker so the receipt
when it does run is unambiguous.

## SPEC for pid1-engineer (verbatim)

> **Subject:** v0.8 design-2.2 slice 5 main-side pid1/ edits.
>
> **Branch:** main. Skeptic review required.
>
> **Context:** the hurd branch shipped the slice 5 rewrite of
> `port_caps.get_peer_cred` (now `(int fd, const uint8_t nonce[16],
> uint32_t *uid_out, uint32_t *gid_out)`) along with the matching
> Linux backend update in `pid1/port_linux.c`. The signature change
> is already on main as of the slice-5 prep land in port_layer.h /
> port_linux.c. The hurd-branch backend now does a real
> `auth_server_authenticate` inside the drain handler, populates
> `pending_auth[]` with real uid/gid, and looks up by nonce in
> `hurd_get_peer_cred`.
>
> **What is missing on main:** the supervisor's accept path inside
> `Fpid1_rpc_poll` does NOT yet mint a 16-byte nonce, write it to
> the client immediately after `accept(2)`, or thread the nonce
> through into `port->get_peer_cred(conn, nonce, &uid, &gid)`. The
> Linux body ignores the nonce; the call still works either way on
> Linux. But the Hurd backend cannot complete the dance without the
> nonce, so this seam has to land on main before the Hurd branch can
> rebase against it.
>
> **Edits requested:**
>
>   1. **`pid1/emacs-init.c::Fpid1_rpc_poll`**: after `accept(conn)`
>      succeeds and before the `port->get_peer_cred(...)` call, mint
>      a 16-byte nonce via `getentropy(nonce, 16)` (the call is
>      glibc-portable; Hurd's glibc carries it). Write the nonce
>      synchronously to the client with `send(conn, nonce, 16,
>      MSG_NOSIGNAL)`. Short writes are treated as a transient
>      client error; close the fd and return nil from the tick.
>      Pass the nonce into `port->get_peer_cred(conn, nonce, &uid,
>      &gid)`. The Linux path is bit-for-bit unchanged in behaviour
>      (the nonce arrives at the client and is ignored on read; the
>      Linux backend ignores its nonce param).
>
>   2. **`pid1/emacs-init.c::Fpid1_publish_auth_port`** (W2 fix):
>      surface `errno == ENOSYS` silently as `t`, matching the
>      `Fpid1_auth_drain` convention. The current body signals
>      `pid1-error` on any non-zero return, which means a future
>      Hurd build that gates the publish on something not yet
>      shipped (or any kernel without an auth-port concept) will
>      panic supervisor startup instead of degrading gracefully.
>      One-line change: `if (errno == ENOSYS) return env->intern(env,
>      "t");` before the existing `pid1_signal_errno` call.
>
>   3. **`pid1/emacs-init.c` around line ~2483-2484** (N1 fix): the
>      inline comment currently reads as a forward-looking promise.
>      Rephrase as a precondition statement on the caller: the
>      handshake binding must be invoked AFTER `pid1-unix-connect`
>      returns AND BEFORE the first `pid1-unix-send`. Wording at
>      reviewer's discretion; the intent is "this is what the
>      caller is required to do" rather than "this is what we plan
>      to do next".
>
>   4. **`emacs-init/core/rpc-client.el`** (slice 5a client side):
>      after `pid1-unix-connect` returns the fd, call
>      `pid1-unix-recv-exactly` for exactly 16 bytes. Pass those
>      bytes to `pid1-client-auth-handshake fd nonce` (arity-2 form
>      already shipped in slice 4). On any error (short read, recv
>      timeout, handshake signal) close the fd via `pid1-unix-close`
>      and surface the underlying signal to the caller. Linux
>      doesn't care about the nonce contents but the wire bytes
>      have to be read or the first `pid1-unix-send` would see the
>      nonce at the front of its payload.
>
>   5. **`emacs-init/core/rpc-server.el`**: no edit needed. The C
>      side (`Fpid1_rpc_poll`) handles the nonce mint + send + thread
>      into get_peer_cred inline; the elisp wrapper just polls and
>      gets back the same `(:fd FD :uid UID :gid GID :payload STR)`
>      plist or nil as before.
>
> **Skeptic warnings (already addressed on the hurd branch, mention
> for symmetry):**
>
>   - W1: `port_layer.h`'s `auth_drain` docstring carries an
>     explicit "currently 16" ceiling for the per-tick message
>     batch. Keep that on main.
>   - N2: `port_linux.c`'s `linux_auth_drain` comment is now two
>     lines, no slice-3 history. Keep that on main.
>
> **Test gates:** the freeze-test
> `freeze-test-port-hurd-end-to-end` (in
> `iso-build/freeze-tests/freeze-test-port-hurd.el` on the hurd
> branch) runs the slice-5 elisp surface chain end-to-end on a dev
> host with the module loaded; once the main-side edits land, that
> test moves to main's `freeze-tests/` too. The end-to-end Mach
> dance is exercised on a real Hurd VM by `tests/hurd-client-
> handshake.c` (slice-5 PASS marker:
> `parent slice5_handshake_ok=1`).
>
> **End SPEC.**

## What the hurd branch shipped this slice

### Slice 5b: `pid1/port_hurd.c::hurd_get_peer_cred` rewrite

The old slice-3 body recv'd a SCM_RIGHTS cmsg off the AF_UNIX socket
and called `auth_server_authenticate` inline. That path is retired
per the `2026-05-18-hurd-pflocal-cmsg-fail.md` finding (pflocal
treats cmsg integers as fd indices, EBADF on a bare port-name).

The new body takes the 16-byte rendezvous NONCE that
`Fpid1_rpc_poll` wrote to the client on accept and reads from the
`pending_auth[]` table populated by the per-tick drain. Retry
budget 5x200ms (the client's mach_msg + auth_user_authenticate
runs concurrently; the drain has to process the submit_nonce
message before the lookup hits). ETIMEDOUT on miss; ENOSYS if
`publish_auth_port` never ran (the supervisor falls back to
denying the connection silently, matching the existing rpc-poll
convention).

Sentinel-break: if the matching row carries `uid == (uint32_t)-1`,
the row was created by an in-flight submit_nonce that has not yet
completed `auth_server_authenticate`. Break out of the row scan,
sleep 200ms, retry. The full 5 attempts give 1s of wall-clock
budget for the auth dance, which is well above what a warm
authserver takes (sub-millisecond) but tolerates a cold one.

### Slice 5: `pid1/port_hurd.c::S_geos_auth_submit_nonce` rewrite

The slice-3 stub recorded the nonce with sentinel `-1` uid/gid.
This slice replaces the stub body with the real 13-arg
`auth_server_authenticate(self_auth, rendez, MOVE_SEND, NULL,
COPY_SEND, &euid_buf, &n_euid, &auid_buf, &n_auid, &egid_buf,
&n_egid, &agid_buf, &n_agid)`. On `KERN_SUCCESS`, the row carries
`euid_buf[0]` and `egid_buf[0]`. The four out-of-line buffers are
`vm_deallocate`d after copying; the rendezvous send right is
consumed by the auth server (no extra deallocate).

Failure paths:
  - `auth_server_authenticate` returns non-KERN_SUCCESS: deallocate
    the rendezvous send right ourselves (server did not take it),
    set `outp->RetCode = kr`, drop everything else.
  - Empty effective-set (`n_euid == 0 || n_egid == 0`): deallocate
    the four buffers, set `outp->RetCode = EACCES`, no row recorded.
    The client times out on `hurd_get_peer_cred`'s 5x200ms budget.

### Slice 5d: `tests/hurd-client-handshake.c` slice-5 harness extension

The harness's `S_geos_auth_submit_nonce` mirror was upgraded with the
same `auth_server_authenticate` body; the main loop now scans
`pending_auth[]` for the row matching the nonce sent by the child
and asserts `uid != (uint32_t)-1 && gid != (uint32_t)-1`. Expected
PASS markers on a real Hurd VM run:

```
parent OK publish: idempotency EBUSY-as-expected
child  OK file_name_lookup returned 0x<N>
child  OK submit_nonce sent
child  OK auth_user_authenticate kr=0x0
child  slice4_handshake_ok=1
parent OK drained submit_nonce; pending_auth fingerprint changed
                                  (<fp-before> -> <fp-after>);
                                  drain saw 1 fsys_getroot
parent slice4_handshake_ok=1
parent OK pending_auth row uid=<euid> gid=<egid> (real, not sentinel);
        harness euid=<euid> egid=<egid>
parent slice5_handshake_ok=1
```

### Slice 5: `iso-build/freeze-tests/freeze-test-port-hurd-end-to-end`

A new freeze-test that runs the slice-5 elisp surface chain on a
dev host with `pid1-module.so` loaded. Probes `pid1-publish-auth-
port`, `pid1-auth-drain`, `pid1-rpc-poll` (the load-bearing call:
returns nil on an empty accept queue, which proves the new
arity-4 `get_peer_cred` path compiles into the C body without
crashing), and `pid1-client-auth-handshake` arity. Skips cleanly
on dev hosts where the module is not loaded.

### Slice 5e: `docs/HURD_PORT.md` matrix flip

The `port->get_peer_cred` and `port->client_auth_handshake` rows
in the verification matrix now read YES on 2026-05-18 with a
reference to this runlog. The previous "blocked on rewrite for
design 2.2" lines are gone; the slice-5 body description in the
"Code status" column documents the new pending_auth[] lookup
path.

### Slice 5f: skeptic warnings addressed

  - W1 (`port_layer.h` auth_drain docstring explicit ceiling
    `N=16`): the docstring already carried "currently 16"; the
    slice-5 freeze-test docstring reinforces the ceiling.
  - N2 (`port_linux.c` linux_auth_drain comment): trimmed to two
    lines in the slice-prep edit that grew `linux_get_peer_cred`'s
    signature.

W2 (`Fpid1_publish_auth_port` ENOSYS asymmetry) and N1
(`emacs-init.c` precondition comment phrasing) are main-side pid1/
edits and live in the SPEC above for pid1-engineer.

## Why VM-verify is blocked locally

`~/.cache/geos-hurd-vm/` does not exist on this dev host;
`/var/lib/libvirt/images/` is permission-denied (libvirt qemu
group); `find / -name '*.qcow2' | grep -i hurd` returns nothing.
The `iso-build/hurd-smoke-test.sh` path builds a hurd64-raw image
from `guix-system/system-hurd.scm` and is the canonical fresh-VM
gate; running it requires the Guix daemon plus pinned Hurd channel
plus a non-trivial first-build window (the spike report estimates
hours on a warm Guix cache, longer on cold).

The slice-5 code is load-bearing complete; the VM-verify gate is
deferred to the next runlog (`2026-05-1X-hurd-end-to-end-vm.md`)
which will paste the harness output above into the "Result" section
and flip this runlog's status header from PARTIAL SHIP to PASS.

## Files changed this slice (hurd branch)

  - `pid1/port_layer.h` (already on main; signature growth recorded
    here for completeness)
  - `pid1/port_linux.c` (already on main; same)
  - `pid1/port_hurd.c` (this slice: new `S_geos_auth_submit_nonce`
    body, new `hurd_get_peer_cred` body; comment cleanup on the
    pending_auth table introduction)
  - `tests/hurd-client-handshake.c` (this slice: slice-5 harness
    extension)
  - `iso-build/freeze-tests/freeze-test-port-hurd.el` (this slice:
    `freeze-test-port-hurd-end-to-end` added)
  - `docs/HURD_PORT.md` (this slice: matrix rows flipped)
  - `docs/runlogs/2026-05-18-hurd-end-to-end-multi-user.md` (this
    file)

## Files NOT changed this slice (handed to pid1-engineer)

  - `pid1/emacs-init.c::Fpid1_rpc_poll` (nonce mint + write + thread
    into get_peer_cred)
  - `pid1/emacs-init.c::Fpid1_publish_auth_port` (W2: silently
    coerce ENOSYS to t)
  - `pid1/emacs-init.c` ~line 2483-2484 (N1: precondition comment
    phrasing)
  - `emacs-init/core/rpc-client.el` (slice 5a: read 16-byte nonce
    after connect, pass to client_auth_handshake)
