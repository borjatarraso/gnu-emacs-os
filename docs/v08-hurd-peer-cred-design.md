<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

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

## 3. Recommended design: 2.2 (parallel Mach channel)

### 3.0 Verdict (added 2026-05-18)

The 2.1 SCM_RIGHTS-cmsg design described in 3.1-3.4 below is
**retired**.  The probe at `tests/hurd-pflocal-cmsg.c` ran on
Debian GNU/Hurd 0.9 and returned EBADF (`0x40000009`) on every
`sendmsg` with an SCM_RIGHTS cmsg, on every socket type.  Reason:
pflocal's SCM_RIGHTS handler treats payload integers as file
descriptors (looking them up in the sender's `io_t` table) rather
than as bare Mach port names.  A freshly-allocated rendezvous
port has no fd backing, so the lookup fails.  Full receipt:
`docs/runlogs/2026-05-18-hurd-pflocal-cmsg-fail.md`.

Active design is alternative 2.2 from section 2: a parallel Mach
channel for the auth handshake, separate from the AF_UNIX RPC
socket.  Mechanics:

  - Supervisor at startup publishes a long-lived service Mach
    port via the file-system rendezvous convention (a translator
    at `/servers/geos-auth` or an on-disk dump of the port via
    `file_set_translator`).  Linux backend has no equivalent
    plumbing; the slot is hurd-only.
  - Client allocates a rendezvous port locally, sends its name
    to the supervisor *through that long-lived Mach channel*
    (one Mach RPC, not through pflocal), then issues the
    AF_UNIX RPC for the verb.  The supervisor matches the two
    by a per-connection nonce in the first AF_UNIX payload.
  - `auth_server_authenticate` / `auth_user_authenticate` run
    on the rendezvous port exactly as in 3.1; only the *hand-off*
    of the rendezvous port name moves.

Sections 3.1-3.4 are kept verbatim below as the historical
record of the 2.1 attempt and the questions it answered.  They
should not be read as a current implementation contract.

### 3.1 Wire change (historical, 2.1)

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

### 3.2 Server side (historical, 2.1)

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

### 3.3 Client side (historical, 2.1)

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

### 3.4 What about the Linux path? (historical, 2.1; still accurate)

Untouched.  `rpc-client.el`'s top-level send sees a Hurd kernel
and routes through `rpc-client--send-with-auth-prefix-hurd`; on
Linux it routes through the existing
`rpc-client--send-bytes-linux` that just writes the 4-byte
length + payload.  No ABI change for Linux clients, no risk of
regressing the v0.6 RPC verbs.

### 3.5 2.2 implementation outline (added 2026-05-18)

What the auth dance works against is settled: the side-channel
probe at `tests/hurd-mach-sidechannel.c` reached `KERN_SUCCESS`
on both halves and the auth server returned the calling task's
euid (receipt:
`docs/runlogs/2026-05-18-hurd-mach-sidechannel-auth.md`).  The
only remaining question is *how the rendezvous port travels from
the client task to the supervisor task*, since pflocal SCM_RIGHTS
is out and the probe ran intra-process.

#### 3.5.1 How the supervisor publishes its auth port

Two viable transports, both standard Mach IPC; the hurd-porter
spike picks one in the first slice.

**Option A: passive translator at `/servers/geos-auth`.**  pid1
calls `file_set_translator` on `/servers/geos-auth` at supervisor
startup; the supervisor itself responds to the `fsys_getroot` /
`io_identity` RPCs by returning a send right to a long-lived auth
receive port.  Clients call `file_name_lookup("/servers/geos-auth",
0, 0)` and get a send right wired straight to the supervisor.

Pros: Hurd-canonical, survives `exec(2)` for free, no special
parent-child coupling needed.  Cons: bootstrap-order question
(the translator must be alive before the first client login,
which is fine since pid1 is also the first translator setter on
the box).

**Option B: parent-inherited send right via
`task_set_special_port`.**  pid1 already spawns every interactive
session; before `task_resume` on each child, pid1 calls
`task_set_special_port(child_task, TASK_BOOTSTRAP_PORT,
auth_send_right)`.  Children retrieve it via
`task_get_bootstrap_port` at session-init time.

Pros: zero filesystem state, port travels in-band with task
creation.  Cons: overwrites the bootstrap port that glibc-hurd
expects to point at the proc server; libc internals may break in
non-obvious ways.  Mitigation would be to use a non-standard
special-port slot, but those are sparse and Mach-version-
sensitive.

**Pick:** Option A.  The libc-bootstrap risk in Option B is the
exact class of bug that wastes weeks in QEMU.  Translator
publication is the conservative choice and matches how the rest
of GEOS exposes long-lived services (`/run/geos/super.sock` is
already an AF_UNIX rendezvous; `/servers/geos-auth` is the Mach
counterpart).  Hurd-porter starts with the translator stub.

#### 3.5.2 Per-connection nonce protocol

The supervisor must match an inbound Mach auth message to the
AF_UNIX RPC connection it authenticates.  Without a binding the
auth result could be stolen by a second client racing the first.
The match-key is a 16-byte random nonce minted by the supervisor.

Connection lifecycle on Hurd:

```
client                              supervisor
  |  connect("/run/geos/super.sock") |
  |--------------------------------->|
  |  accept(); mint nonce N (16 B)  |
  |   from /dev/urandom              |
  |<---------------------------------|
  |  N (16 raw bytes, NO length     |
  |  prefix, exactly one read)       |
  |                                  |
  |  file_name_lookup(/servers/      |
  |   geos-auth) -> auth_send         |
  |  mach_port_allocate(RECEIVE)     |
  |   -> rendez_rcv;                 |
  |  mach_port_insert_right(MAKE_    |
  |   SEND) -> rendez_send           |
  |  mach_msg send: header carries  |
  |   N + rendez_send (MOVE_SEND)    |
  |--------------------------------->|
  |                                  |  mach_msg recv from
  |                                  |   /servers/geos-auth queue;
  |                                  |   match N to pending conn;
  |                                  |   auth_server_authenticate(
  |                                  |    getauth(), rendez_recv'd,
  |                                  |    MOVE_SEND, newport_rcv,
  |                                  |    MAKE_SEND, &euids, ...)
  |                                  |  -> store euid/egid on conn
  |  auth_user_authenticate(         |
  |   getauth(), rendez_rcv,         |
  |   MAKE_SEND on send-right name,  |
  |   &newport_returned)             |
  |  (matches the server-side dance) |
  |                                  |
  |  4-byte BE length + sexp         |
  |--------------------------------->|
  |  Fpid1_rpc_poll consumes; uid    |
  |   from earlier auth step is the  |
  |   verb's caller identity.        |
```

Linux path is bit-for-bit unchanged (no nonce, no Mach step,
SO_PEERCRED at accept).  The nonce step is gated on
`geos-kernel-hurd-p` both client- and server-side.

#### 3.5.3 Why hand-rolled mach_msg, not MIG

A MIG-generated `geos_auth.defs` would be cleaner but adds a
fourth toolchain dependency to the pid1 build (MIG itself plus
the generated `_server.c` / `_user.c` pair) and forces a
Makefile change on the hurd branch.  The auth-channel RPC is
exactly one message type carrying `(nonce[16], rendez_send_right)`,
small enough to write by hand using GNU Mach's legacy inline
`mach_msg_type_t` descriptor format (the same format the
side-channel probe used to call `auth_*_authenticate`).  v0.9
can revisit MIG when a second auth-channel verb shows up; YAGNI
until then.

#### 3.5.4 Supervisor receive without threads

`Fpid1_rpc_poll` already runs on a 200 ms tick from the emacs
main loop.  Add a `mach_msg(MACH_RCV_MSG | MACH_RCV_TIMEOUT,
timeout=0, ...)` on the geos-auth receive port at the top of
each tick; the call is non-blocking when the queue is empty and
returns `MACH_RCV_TIMED_OUT` cheaply.  When it returns a message,
extract the nonce + rendezvous send right, run
`auth_server_authenticate` (synchronous; sub-millisecond on a
warm auth server), and update the matching AF_UNIX connection's
pending-uid slot.  The AF_UNIX side of `Fpid1_rpc_poll` then
sees the slot populated and proceeds with the sexp read.

Single-threaded; matches hard rule 5.  Worst case: a malicious
client floods `/servers/geos-auth` with bogus nonces and the
supervisor spends tick budget on `mach_msg` returns.  Mitigation
in a later slice: per-tick cap on auth messages drained (e.g.
16), spillover stays queued for the next tick.

#### 3.5.5 File-by-file change list

  - `pid1/port_layer.h`: add `publish_auth_port(void)` slot to
    `port_caps`.  Linux returns 0 (no-op); Hurd opens the
    translator and stashes the auth-receive-port name in a
    file-static slot.
  - `pid1/port_linux.c`: `linux_publish_auth_port` = no-op
    returning 0.
  - `pid1/port_hurd.c`: rewrite `hurd_get_peer_cred` per 3.5.2
    (read 16-byte nonce, look up matching pending-auth entry,
    return cached uid/gid).  Rewrite `hurd_client_auth_handshake`
    per 3.5.2 (read nonce off fd, `file_name_lookup`
    `/servers/geos-auth`, allocate rendezvous, `mach_msg` send
    with the hand-rolled descriptor block, `auth_user_authenticate`,
    deallocate everything on every exit branch).  Add
    `hurd_publish_auth_port` that runs `file_set_translator` and
    spawns the per-tick drain helper.  Add a static pending-auth
    table keyed by nonce, with TTL eviction (drop entries older
    than 5 s; an abandoned handshake should never wedge).
  - `pid1/emacs-init.c`: call `port->publish_auth_port` once at
    supervisor startup, before the first `Fpid1_rpc_poll` tick.
    Add a `Fpid1_drain_auth_channel` helper bound from elisp,
    or fold the drain into `Fpid1_rpc_poll` directly (simpler;
    do that).
  - `emacs-init/core/rpc-server.el`: on Hurd, send 16 raw bytes
    immediately after `pid1-unix-accept` and stash the nonce on
    the connection state alist; require the pending-auth slot
    populated before dispatching the sexp.  On Linux,
    unchanged.
  - `emacs-init/core/rpc-client.el`: on Hurd, after
    `pid1-unix-connect`, call `pid1-unix-recv-exactly fd 16`
    for the nonce, then `pid1-client-auth-handshake fd nonce`.
    The handshake binding's signature gains a `bytes` arg
    (currently `int fd -> t`; becomes `int fd, bytes nonce -> t`).
    On Linux the handshake is the existing no-op.

#### 3.5.6 Slicing

Five commits, in order, each one mergeable on its own:

  1. **port-seam expand**: add `publish_auth_port` slot; Linux
     no-op + Hurd ENOSYS body.  Bind `pid1-publish-auth-port`
     from emacs.  No behavior change.
  2. **translator stub**: `hurd_publish_auth_port` opens the
     translator at `/servers/geos-auth`, allocates the receive
     port, returns 0.  Add a freeze-test that asserts
     `/servers/geos-auth` exists after supervisor startup on
     Hurd VM.
  3. **nonce + drain**: extend `Fpid1_rpc_poll` with the
     per-tick `mach_msg` drain; add the pending-auth table;
     server-side `rpc-server.el` writes the 16-byte nonce on
     accept.  Freeze-test: bogus Mach client sends garbage,
     supervisor does not crash, ticks stay under budget.
  4. **client handshake**: rewrite `hurd_client_auth_handshake`
     to read nonce, look up translator, allocate rendezvous,
     send mach_msg with nonce + rendezvous, run
     `auth_user_authenticate`.  Update
     `Fpid1_client_auth_handshake` to take the nonce arg.
     Freeze-test: real client connects, supervisor populates
     uid slot, ping verb returns under root and under lambda.
  5. **end-to-end multi-user**: rewrite `hurd_get_peer_cred` to
     consult the pending-auth table.  Run the v0.6 multi-user
     login dance on Hurd VM; capture runlog; flip the
     HURD_PORT.md matrix rows for `get_peer_cred` and
     `client_auth_handshake` to YES.

Slice 1 is pure scaffolding (zero behavior change); the rest are
each a VM-verify cycle.  Estimated effort: 2-3 sessions for
slices 1-3, then a longer session for slices 4-5 since they
share a debugging surface.

#### 3.5.7 Slice 2 transport finding and slice 3 pivot (added 2026-05-18)

Slice 2 landed at hurd branch `d6716cc` and the standalone
verification harness `tests/hurd-publish-auth-port.c` does
allocate a fresh receive port, insert a send right, create the
empty `/servers/geos-auth` file node, and call
`file_set_translator(passive_flags=0, active_flags=FS_TRANS_SET
| FS_TRANS_FORCE, 0, NULL, 0, recv, MACH_MSG_TYPE_COPY_SEND)`
with `KERN_SUCCESS`.  Idempotency works (second call returns
`-1/EBUSY`).  Receipt: `docs/runlogs/2026-05-18-hurd-publish-
auth-port.md`.

The gotcha: a subsequent `file_name_lookup("/servers/geos-auth",
0, 0)` (and even `O_NOTRANS`) returns the bare file-node port,
not a send right routed through our active translator.  Both
lookups yield identical port names, which proves the active
translator is silently bypassed by the lookup path.  The cause is
not a bug in `file_set_translator`; it is the Hurd model.  A
translator is a *server process* that owns a port and answers the
`fsys` protocol; `file_set_translator` records that a translator
exists, but lookup only routes to it if the kernel can talk to a
process at the other end of the recorded port.  We installed a
bare receive port with no demuxer behind it, so libdiskfs falls
through to returning the file node directly.

This invalidates the slice 3 plan as originally written.  The
"per-tick mach_msg drain" cannot be a drain on the receive port
slice 2 created; the port is unreachable from
`file_name_lookup`-using clients.

**Slice 3 pivot**: implement a minimal libports-based fsys
server.  This is the canonical Hurd publication mechanism; every
translator under `/hurd/` (auth, proc, exec, pflocal, pfinet)
does this.  Concrete shape:

  - `hurd_publish_auth_port` allocates a `ports_bucket_t`, creates
    a port class for the auth receive right, and creates a single
    port object in that bucket.  Drop the bare
    `mach_port_allocate` + `file_set_translator` pair: libports
    owns the receive right now.
  - Bind the translator at `/servers/geos-auth` via the same
    `file_set_translator` call but pass the libports-owned send
    right as the active port.  libdiskfs will route
    `file_name_lookup` traffic to this port because libports keeps
    a demuxer running.
  - Add a `Fpid1_rpc_poll` hook that calls
    `ports_manage_port_operations_one_thread` with a non-blocking
    receive timeout (or, since the supervisor is single-threaded,
    a single `mach_msg(MACH_RCV_TIMEOUT=0)` followed by manual
    dispatch into the libports demuxer).  Two messages to drain
    per tick: `fsys_getroot` from libdiskfs (return the auth send
    right) and our own `geos_auth_submit_nonce` (read the 16-byte
    nonce + rendezvous port from the client).
  - Per-connection nonce table is unchanged from §3.5.2; only the
    delivery path moves from "bare receive port" to "libports
    bucket".

The rejected alternative was wrapping `settrans -aP /servers/
geos-auth /hurd/geos-auth-server` from the supervisor.  That
would shell out (forbidden by hard rule 1, no shell except
eshell) and would also require a separate
`/hurd/geos-auth-server` binary, which defeats the "supervisor
is the auth server" simplicity that 2.2 was chosen for in the
first place.

Link deps on Hurd grow by one: `-lports` after `-lhurduser
-lhurd -lmach`.  Update `pid1/Makefile` and the pid1 owner-doc
when slice 3 lands.

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
