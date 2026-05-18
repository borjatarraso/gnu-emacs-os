# tests/

Focused C probes that answer single design-uncertainty questions for
GEOS subsystems.  Not unit tests for the elisp userland (those live
under iso-build/freeze-tests/) and not the QEMU smoke gates (those
live under iso-build/).  These are short standalone programs that
either say `OK` or `FAIL: <reason>` on stdout, with an exit code to
match.  Each one targets a specific "does the kernel actually do
what the manpage implies" risk that a design doc flagged as the
biggest unknown for its milestone.

## hurd-pflocal-cmsg.c

Answers: does Hurd's pflocal (AF_UNIX) translator pass Mach port
rights through `SCM_RIGHTS` ancillary data on `sendmsg`/`recvmsg`
without corruption or silent drop?

This is the design-uncertainty risk listed in section 6 of
docs/v08-hurd-peer-cred-design.md.  The recommended design 2.1
routes the client's rendezvous port to the supervisor through this
exact cmsg path; if pflocal's ancillary data path does not deliver a
live send right, the design falls back to alternative 2.2 (parallel
Mach channel published at `/run/geos/super.auth`).

### Build (Hurd only)

    gcc -Wall -Wextra -Werror -o hurd-pflocal-cmsg hurd-pflocal-cmsg.c

(`-lmach` is NOT needed on Debian GNU/Hurd 0.9: glibc bundles the
user-side Mach RPC stubs.)

### Run

Run as any user.  No setuid required, no `/hurd/` translator install,
no pid1 dependency.

    ./hurd-pflocal-cmsg

### Interpreting the output

  - `OK`, exit 0: pflocal passes Mach port rights through SCM_RIGHTS
    correctly.  The v0.8 peer-cred design can proceed with
    alternative 2.1 (the recommended path).
  - `FAIL: <reason>`, exit 1: pflocal's cmsg path is broken in the
    way named by the reason string.  The v0.8 design falls back to
    alternative 2.2 (parallel Mach channel for the auth handshake;
    AF_UNIX retains the sexp byte stream).

### Verdict on Debian GNU/Hurd 0.9 (2026-05-18)

`FAIL: sendmsg returned -1 (errno=1073741833 Bad file descriptor)`
on every socket type.  pflocal's SCM_RIGHTS handler treats payload
integers as file descriptors (looking them up in the sender's
`io_t` table) rather than as bare Mach port names.  v0.8 design
pivoted to alternative 2.2.  Full receipt:
`docs/runlogs/2026-05-18-hurd-pflocal-cmsg-fail.md`.

## hurd-mach-sidechannel.c

Answers: does the auth dance (`auth_user_authenticate` on the
client side, `auth_server_authenticate` on the supervisor side)
complete cleanly on this Hurd build when both sides share a Mach
rendezvous port?

This is the load-bearing question for design 2.2 (the alternative
the project pivoted to after `hurd-pflocal-cmsg.c` failed).  The
inter-task transport (sending the rendezvous port from one task
to another via a parallel Mach channel) is standard Hurd IPC and
not what this probe targets; the probe isolates the
"does the auth-server rendezvous protocol even work" question by
running both sides in the same task across two pthreads.

### Build (Hurd only)

    gcc -Wall -Wextra -Werror -pthread -o hurd-mach-sidechannel \
        hurd-mach-sidechannel.c

### Run

Any user works; root will see `euid=0`.

    ./hurd-mach-sidechannel

### Interpreting the output

  - `OK auth euid=N (neuids=M)`, exit 0: the auth dance returns
    KERN_SUCCESS on both sides and the server reads back the
    expected effective uid set.  Design 2.2 stands; only the
    inter-task transport remains to wire up.
  - `FAIL: ...`, exit 1: the auth dance does not complete on this
    Hurd; the design needs another pivot (likely a libports-based
    /servers/geos-auth translator, much heavier).

### Verdict on Debian GNU/Hurd 0.9 (2026-05-18)

`OK auth euid=0 (neuids=1)`.  Design 2.2 viable.  Full receipt:
`docs/runlogs/2026-05-18-hurd-mach-sidechannel-auth.md`.

### Why these probes are Hurd-only

Both probes use `<mach.h>` and `<hurd.h>`, which only exist on a
Hurd glibc toolchain.  On a Linux host the build fails at the
preprocessor and that is the intended behavior: no Linux
equivalent makes sense.  Neither probe has a Makefile target in
the Linux build of `pid1/`.
