# v0.8 design: Hurd peer-credential lookup over the supervisor RPC

Maintainer: Borja Tarraso <borja.tarraso@member.fsf.org>

A design doc, not an implementation.  The supervisor RPC channel
(`/run/geos/super.sock`, AF_UNIX SOCK_STREAM) authenticates the
caller through `port->get_peer_cred`.  On Linux that resolves to
`getsockopt(SO_PEERCRED)`, which the kernel snapshots at the peer's
`connect(2)` instant and returns as `struct ucred`.  Hurd's
`pflocal` translator (which provides AF_UNIX) has no SO_PEERCRED
analogue, so today `hurd_get_peer_cred` returns `ENOSYS` and
`Fpid1_rpc_poll` refuses every client; multi-user login on Hurd is
impossible until this gap closes.

This doc proposes a Mach-native peer-cred handshake that fits the
existing wire format, walks through three design alternatives,
picks one, and lists the concrete code changes plus the test plan.

## 0. Why SO_PEERCRED has no Hurd analogue

`pflocal` is implemented in user space as a Hurd translator that
proxies `read`/`write`/`accept` over a pair of Mach ports.  The
"who is on the other end" question is genuinely harder on Hurd
than on Linux:

  - Linux gives the kernel knowledge of every credential of every
    task (uid/gid live in `struct cred`); `SO_PEERCRED` is a
    cheap dictionary lookup.
  - On Hurd, credentials are themselves Mach ports.  The
    `auth_t` capability held by a task IS the task's credential
    set; there is no global registry mapping pid -> uid.
    pflocal cannot answer "who is the other end" because the
    other end's identity is a port pflocal doesn't have.

The native idiom is for the client to volunteer its `auth_t`,
and for the server to bounce that capability off the auth server
to extract uid/gid.  See `<hurd/auth.h>` and pflocal's RPC list
(`<hurd/io.defs>`); the same idiom is what `/hurd/term` uses to
identify the controlling user of a tty.

## 1. The Hurd auth model in one paragraph

Every Hurd task holds an `auth_t` capability.  Calling
`auth_user_authenticate(auth_t, rendezvous_port)` on the auth
server returns nothing useful by itself; it just installs a
pending authentication keyed on the rendezvous port.  The
"server" side then calls `auth_server_authenticate(auth_t,
rendezvous_port, ...)` and the auth server matches the two ends,
returning the client's effective and available uid/gid sets to
the server.  The rendezvous port is the meeting point: only the
client and the server share it, so neither side can be spoofed
without holding the port.  This is the same shape POSIX
file-passing takes on Hurd, just specialized to credentials.

The supervisor's own `auth_t` comes from `getauth()` (libc, returns
the process's current auth port).  pid1 is started by the gnumach
bootstrap path with the privileged auth port; the supervisor
emacs inherits it across `execve`.

## 2. Three candidate designs

### 2.1 Rendezvous-port handshake at connect time (RECOMMENDED)

Extend the wire format with a single prefix message at connect
time: before the existing 4-byte-length + sexp payload, the
client sends one Mach port right (its rendezvous port for the
auth dance).  The supervisor receives the port via the AF_UNIX
auxiliary-port channel that pflocal provides (the Hurd
`SCM_RIGHTS`-equivalent), calls
`auth_server_authenticate(getauth(), rendez, ...)` to get
uid/gid, and from there the wire format is unchanged.

Strengths:

  - Mirrors Linux's "credentials snapshot at the connect instant"
    semantic.  A setuid race between connect and the first sexp
    write cannot fool the supervisor, because the rendezvous
    binds to the connecting task identity.
  - One round trip per connection.  No effect on the steady-state
    poll cost.
  - Uses only documented Hurd surfaces (`<hurd/auth.h>`,
    `<hurd/socket.h>`'s ancillary-data path).  No mach_msg-by-
    hand layer in pid1.

Weaknesses:

  - Wire-format change.  rpc-client.el (and any future client)
    has to send the prefix port; on Linux that prefix is empty,
    so the elisp dispatcher has to branch on `geos-kernel'.
    Bounded change, but a real one.
  - Requires linking the supervisor module against `-lhurduser`
    (already done on the hurd branch) plus pulling in
    `auth_server_authenticate` from glibc.

### 2.2 Parallel Mach RPC channel for auth, AF_UNIX for payload

Open a Mach port that doubles as the supervisor's "auth listener"
(`mach_port_allocate` + `mach_port_insert_right`).  Publish the
port name in `/run/geos/super.auth` (file containing the printed
port-name string) so clients can `file_name_lookup` and IPC into
it.  Clients send their rendezvous port over the Mach channel,
get a uid/gid token back, then attach the token to subsequent
AF_UNIX sexp requests.

Strengths:

  - AF_UNIX wire format stays a literal byte stream; only the
    handshake moves to Mach.
  - Cleanly separates capability transport from sexp transport.

Weaknesses:

  - Two channels to keep alive instead of one; doubles the
    connection lifecycle code (more places to leak ports or
    fds).
  - Token replay: the uid/gid token sent over AF_UNIX is not
    cryptographically tied to the AF_UNIX peer.  A second
    client on the same machine could observe the token if the
    socket permissions ever loosened.  Requires an HMAC layer
    or per-connection nonce.
  - More code; more surface for skeptic to block.

### 2.3 Out-of-band proc(8) lookup, no client cooperation

When pflocal accepts a connection, it can call
`io_server_routine`'s peer-discovery RPC to learn the peer's
task port.  From the task port, query the proc server for the
owning uid via `proc_getprocinfo`.

Strengths:

  - Client side is unchanged.  rpc-client.el stays untouched.

Weaknesses:

  - pflocal does NOT actually expose the peer's task port to the
    accepting side today; this would need a pflocal patch
    upstream first.  GEOS does not ship pflocal, so this is a
    multi-year coordination problem.
  - Even if pflocal exposed it, proc_getprocinfo returns the
    task's owner-uid, not its effective uid, so setuid/setgid
    binaries would authenticate as the wrong identity.

Rejected: too far outside our control and gets the wrong
semantic.

## 3. Recommended design: 2.1 with explicit failure paths

### 3.1 Wire change

Today (Linux and the ENOSYS-Hurd path):

```
client: [4-byte BE length N] [N bytes sexp]
server: [4-byte BE length M] [M bytes sexp reply]
```

After the change (Hurd only; Linux path untouched):

```
client: [1 Mach port right via sendmsg ancillary data]
        [4-byte BE length N] [N bytes sexp]
server: [4-byte BE length M] [M bytes sexp reply]
```

The Mach port right travels in `SCM_RIGHTS`-equivalent ancillary
data on the AF_UNIX socket.  pflocal exposes this through the
standard `sendmsg(2)`/`recvmsg(2)` cmsg interface, so the elisp
client uses the existing emacs `process-send-string` plus a small
C helper that calls `sendmsg` with the cmsg attached.

The Linux backend ignores the prefix.  `port_linux.c`'s
`linux_get_peer_cred` continues to use `SO_PEERCRED`, which has
no concept of an inbound cmsg.  `rpc-client.el` branches on
`geos-kernel-hurd-p` and only sends the prefix on Hurd; on Linux
the byte stream is bit-identical to today's traffic.

### 3.2 Server side

New `port_hurd.c::hurd_get_peer_cred(fd, &uid, &gid)`:

  1. Allocate a buffer for one cmsg of size `CMSG_SPACE(sizeof
     mach_port_t)`.
  2. `recvmsg(fd, &msg, MSG_PEEK | MSG_CMSG_CLOEXEC)`.  PEEK
     because the supervisor's existing `rpc_read_full` will
     consume the length prefix; the cmsg comes attached to the
     first byte of payload so PEEK leaves the byte stream
     intact for the existing reader.
  3. Walk `CMSG_FIRSTHDR` looking for `cmsg_level == SOL_SOCKET`
     and `cmsg_type == SCM_PORT` (Hurd's port-rights ancillary
     type; on glibc-hurd this name is exposed in
     `<sys/socket.h>` after the 2024 Hurd userland refresh.
     If the name differs on Debian Hurd 0.9, fall back to the
     numeric constant from `<hurd/socket.h>`).
  4. Extract the `mach_port_t` rendezvous from the cmsg payload.
  5. `auth_t self = getauth();` (cached statically; one call
     per supervisor lifetime).
  6. `kern_return_t kr = auth_server_authenticate(self, rendez,
     MACH_MSG_TYPE_MOVE_SEND, MACH_PORT_NULL,
     MACH_MSG_TYPE_COPY_SEND, &euid_buf, &n_euid, &auid_buf,
     &n_auid, &egid_buf, &n_egid, &agid_buf, &n_agid);`
  7. On `KERN_SUCCESS`, write `euid_buf[0]` to `*uid_out` and
     `egid_buf[0]` to `*gid_out`.  Empty effective-set means
     "nobody"; set errno to EACCES and return -1.
  8. `mach_port_deallocate(mach_task_self(), rendez);`
     Deallocate the four uid/gid arrays via `vm_deallocate`.
  9. Translate any non-KERN_SUCCESS via `__hurd_fail` (already
     the file-wide convention) and return -1.

Caching: per-fd cache keyed on the accepted-fd value.  The cache
entry is invalidated on `close`.  Re-handshakes are not free
(an RPC to the auth server), but the existing
`Fpid1_rpc_poll` calls `get_peer_cred` exactly once per
connection (a client opens, sends, closes), so caching at this
layer adds no value today.  Leave it out; a future
keepalive-connection design can revisit.

### 3.3 Client side

Earlier drafts of this doc proposed three separate Femacs
bindings (`pid1-make-rendezvous-port`, `pid1-sendmsg-with-port`,
`pid1-auth-user-authenticate`) so the elisp dispatcher could
own the rendezvous-port lifecycle with `unwind-protect`.  That
split has been collapsed to a single binding to keep the ABI
surface minimal and to put port lifecycle in C where the
audit-pass can read it as one block:

  - **Port-layer slot:** `port_caps.client_auth_handshake(int
    fd)`.  Linux backend returns 0 (no-op: SO_PEERCRED is a
    server-side query, the client has nothing to do).  Hurd
    backend allocates a rendezvous port, calls
    `sendmsg(fd, ...)` with a 1-byte placeholder payload plus
    one cmsg carrying the rendezvous port as `SCM_PORT`-equivalent
    ancillary data, then calls `auth_user_authenticate
    (getauth(), rendez, ...)` to register the client side of
    the dance.  Every exit path deallocates `rendez` via
    `mach_port_deallocate`.
  - **Femacs binding:** `pid1-client-auth-handshake fd -> t`.
    Trivial wrapper that calls `port->client_auth_handshake(fd)`
    and signals `pid1-error` with errno on failure.
  - **rpc-client.el dispatch:** an earlier draft of this
    section assumed a `pid1-process-fd` helper could pull the
    fd out of an emacs network-process.  It cannot: the public
    emacs module API (`emacs-module.h`) treats elisp values as
    opaque `emacs_value`, and `XPROCESS(proc)->infd` is not
    module-reachable.  /proc/self/fd walking is fragile on
    Linux and unavailable on GNU Mach.  Re-opening a second
    socket fails on Hurd because the auth server pairs
    credentials with the connection (a different `connect(2)`
    is a different identity from the auth server's view).
    Decision: bypass `make-network-process` entirely.  Add five
    Femacs bindings (`pid1-unix-connect path -> fd`,
    `pid1-unix-send fd bytes -> n`, `pid1-unix-recv fd nmax
    timeout-ms -> bytes`, `pid1-unix-recv-exactly` thin
    wrapper, `pid1-unix-close fd -> t`) that wrap
    `socket(AF_UNIX, SOCK_STREAM)` / `connect` / `send` /
    `recv` / `close`.  Rewrite `geos-rpc` to use them; the
    handshake then runs on a fd pid1 owns from `socket()` to
    `close()`.  Net code reduction in `rpc-client.el` (the
    `recv-buf` machinery, `accept-process-output` loop, and
    sentinel all go away); blast radius is contained because
    `geos-rpc` is the single chokepoint every RPC verb routes
    through.

Trade-off accepted: lose `accept-process-output` integration
during the blocking recv.  Today's `geos-rpc--read-bytes` loop
already does no redisplay, and the kernel-level `SO_RCVTIMEO`
gives the same hard ceiling as the elisp-side deadline.  The
recv becomes uninterruptible by `C-g`, but the single-thread
reality is already a documented project constraint (hard rule 5,
"the single-thread reality of Emacs is acknowledged").

### 3.4 What about the Linux path?

Untouched.  `rpc-client.el`'s top-level send sees a Hurd kernel
and routes through `rpc-client--send-with-auth-prefix-hurd`; on
Linux it routes through the existing
`rpc-client--send-bytes-linux` that just writes the 4-byte
length + payload.  No ABI change for Linux clients, no risk of
regressing the v0.6 RPC verbs.

## 4. Failure modes and defence in depth

  - Client sends the prefix port but the port is not a valid
    rendezvous (random port allocation, or stale port from a
    crashed process): `auth_server_authenticate` returns
    `MACH_RCV_INVALID_NAME`; the supervisor translates to
    EACCES, refuses the client, closes the fd.  rpc-server.el's
    existing reject-handler logs to *panic*.
  - Client sends no prefix at all (old client, or a probing
    attacker): `recvmsg` returns 0 cmsgs; supervisor refuses
    with EACCES.
  - Auth server is unreachable (boot-time race): the supervisor
    gets `MACH_SEND_INVALID_DEST` and returns EAGAIN to
    `Fpid1_rpc_poll`.  The poller treats EAGAIN the same way it
    treats "no pending connection" today (return Qnil, retry on
    the next 200ms tick), so the boot tolerates a brief auth
    server hiccup.
  - Effective uid set is empty: the auth server returned no
    identity for this task (commonly a daemon that called
    `setauth` to an unprivileged port).  Refuse with EACCES.
    The supervisor never accepts an empty cred set as "uid 0".
  - Port leak: every codepath that touches `rendez` runs through
    `unwind-protect` (elisp side) or a single `mach_port_
    deallocate` in the error path (C side).  Each port-allocate
    must be paired with a deallocate on every exit branch; the
    skeptic review will check this.

## 5. Testing plan

### 5.1 Freeze-tests on Linux dev host

Skip-class: the Hurd-arm freeze tests under
`iso-build/freeze-tests/freeze-test-port-hurd.el` will not be
able to call the new bindings (no Mach RPCs on the dev host).
They emit a `'skip` row, same shape as today's port-hurd
sub-checks.  No new dev-host gate.

### 5.2 Boot-time gate on the Hurd VM

Add `iso-build/hurd-smoke-test.sh` step that:

  1. Boots the Hurd VM with the new pid1.
  2. Runs `emacs --batch --load /etc/geos/init.el -eval
     '(pid1-rpc-call (quote (ping)))'` as user `lambda` (uid
     1000, non-root).
  3. Asserts the reply is `(pong)`.
  4. Repeats as `root`.
  5. Asserts that a client sending the prefix port for a
     different task (a forged port allocated in the test
     harness) gets EACCES, not pong.

Smoke marker: `geos: rpc-peer-cred-hurd ok` (new).

### 5.3 Multi-user login gate

`buffers/login.el` already drives the v0.5/v0.6 login dance over
the RPC channel.  Once the peer-cred lookup works, the existing
multi-user gate (passwd verify, session spawn, workspace
isolation) is expected to pass on Hurd unchanged.  A green run
of the v0.6 login freeze-tests under `geos-kernel = 'hurd`
closes the multi-user gate on Hurd.

## 6. Risks and open questions

  - **Debian Hurd 0.9's pflocal cmsg coverage.**  Hurd's
    `SCM_RIGHTS`-equivalent for Mach port rights is documented
    but rarely exercised; pflocal's ancillary-data path may
    have bugs that surface only at real load.  Mitigation:
    write a focused C test (`tests/hurd-pflocal-cmsg.c`) that
    sends a port over pflocal and reads it back in the same
    process before wiring pid1 to depend on it.
  - **gnumach's auth server lifetime.**  If the auth server is
    restarted mid-supervisor (today this should never happen on
    Hurd; the auth server is a bootstrap singleton), our cached
    `getauth()` capability would become invalid.  Mitigation:
    re-call `getauth()` on `MACH_SEND_INVALID_DEST` once before
    surfacing the failure.
  - **Wire-format versioning.**  The Hurd prefix is implicit
    today (presence-detected via cmsg walk).  If we ever extend
    the prefix (e.g. send a session-cookie too), we need a
    versioning byte.  Punt until a second prefix field actually
    appears; YAGNI.
  - **Backport to v0.7.x?**  No.  This is a v0.8 multi-user gate
    and ships there.  The v0.7.x line keeps the ENOSYS path; a
    Hurd installer that needs multi-user uses v0.8.

## 7. Implementation order

1. **ABI seam on main + hurd branch:** add the
   `client_auth_handshake` slot to `port_caps`, Linux backend
   returns 0 (no-op), Hurd backend returns ENOSYS.  Add the
   `Fpid1_client_auth_handshake` Femacs binding (calls
   through `port->client_auth_handshake`).  No behavior change
   in `rpc-client.el` yet; this is pure scaffolding.
2. **pflocal cmsg test:** write `tests/hurd-pflocal-cmsg.c`,
   run on the Hurd VM, confirm port rights round-trip through
   pflocal cleanly.  If they do not, this design fails and we
   fall back to 2.2 (parallel Mach channel).
3. **Server-side hurd_get_peer_cred body:** implement the
   `recvmsg` + `auth_server_authenticate` sequence.  Add a
   focused freeze-test on the VM.
4. **Client-side hurd_client_auth_handshake body:** allocate
   rendezvous port, `sendmsg` with 1-byte placeholder + cmsg
   port, `auth_user_authenticate`, deallocate on every exit.
   Hurd-only; the Linux no-op stays.
5. **rpc-client.el wiring:** add five Femacs bindings
   (`pid1-unix-connect`, `pid1-unix-send`, `pid1-unix-recv`,
   `pid1-unix-recv-exactly`, `pid1-unix-close`) that own the
   AF_UNIX fd lifecycle.  Rewrite `geos-rpc` to use them
   instead of `make-network-process`; the handshake call
   slots in after `pid1-unix-connect` and before the first
   `pid1-unix-send`.  Linux: cheap no-op handshake.  Hurd:
   real rendezvous dance.  Wire format on the bytes unchanged
   on both kernels.
6. **End-to-end smoke:** boot the Hurd VM, run the
   multi-user login dance, capture runlog.
7. **HURD_PORT.md matrix update:** `get_peer_cred` row flips
   from "ENOSYS" to "YES on YYYY-MM-DD".

Estimated effort: 1-2 weeks of VM-iterating work, dominated by
step 2 (pflocal cmsg coverage is the unknown) and step 6 (every
multi-user code path on Hurd is first-touch for this milestone).

## 8. Out of scope

  - Capability-based authorization (caller holds a token
    granting verb X).  GEOS's authorization layer is in elisp
    (rpc-server.el verb dispatcher); this design only fixes
    the authentication primitive.
  - Cross-machine RPC.  The supervisor socket is unix-domain,
    local only.  A networked RPC variant is not in scope for
    v0.8 or v0.9.
  - Kerberos / GSSAPI.  GEOS has no plans for either; the auth
    server is the authority and that is the whole identity
    stack.

For the broader Hurd port status see
[HURD_PORT.md](HURD_PORT.md).  For the original spike that
established the port surface see
[v04-item11-hurd-spike.md](v04-item11-hurd-spike.md).
