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

    gcc -Wall -Wextra -Werror -o hurd-pflocal-cmsg hurd-pflocal-cmsg.c -lmach

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

### Why this is Hurd-only

The probe links against `-lmach`, which only exists on a Hurd glibc
toolchain.  On a Linux host the build fails at link time and that is
the intended behavior: no Linux equivalent run makes sense (Linux
SCM_RIGHTS passes file descriptors, not Mach port rights; the
question being answered does not apply).  There is no Makefile target
for this file in the Linux build of `pid1/`.
