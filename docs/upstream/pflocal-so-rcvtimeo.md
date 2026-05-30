<!-- upstream deferral, drafted 2026-05-30, covers HURD_PORT.md row 293 -->

# pflocal returns ENOPROTOOPT for SO_RCVTIMEO; emacsclient prints one stderr line per connect

## summary

every emacsclient invocation against an emacs daemon on Debian
GNU/Hurd 0.9 prints

    /usr/bin/emacsclient.emacs: setsockopt: Protocol not available

once on stderr, then proceeds correctly. the eval result lands on
stdout, exit code is 0, behaviour is functionally fine. the warning
is noise, not a bug in emacs (the call site is defensive), and not a
bug in the AF_UNIX socket we hand to it (the socket works for read
and write).

the underlying gap is that pflocal, the Hurd translator that backs
AF_UNIX, does not implement SO_RCVTIMEO on its socket-option path.
glibc's strerror text for ENOPROTOOPT on Hurd is "Protocol not
available", which is what shows up in the stderr line.

i am the GEOS author. this file is my upstream-ready writeup of two
remediation paths. neither needs a change in the GEOS repo.

## ground truth (how i confirmed the call site)

receipt: `docs/runlogs/2026-05-23-hurd-v0919-bucket2-probes.md`
probe 2.

emacsclient on the canonical Hurd image links against exactly one
setsockopt:

    nm -D --undefined-only /usr/bin/emacsclient.emacs | grep setsockopt
    U setsockopt@GLIBC_2.38

strace is not installed on the canonical image, so i broke on
setsockopt with gdb and printed the arguments. one call fired before
the warning landed:

    setsockopt called: fd=3 level=65535 optname=4102

decoded against `/usr/include/x86_64-gnu/bits/socket.h:377`:

    level   = 65535 = 0xFFFF = SOL_SOCKET
    optname =  4102 = 0x1006 = SO_RCVTIMEO

i.e. emacsclient is bounding how long it waits for a reply from the
server on the AF_UNIX socket. pflocal returns ENOPROTOOPT, emacs
prints the warning via its `message` helper, and continues. the
read still succeeds because the kernel-side default behaviour
(block until data arrives) is what we want anyway when the timeout
cannot be installed.

## remediation path (a): two-line emacsclient.c patch

cheapest fix. ships in emacs 31 if accepted.

the call site is in `lib-src/emacsclient.c`, in the routine that
connects the client socket and sets the receive timeout. the patch
suppresses the perror when errno is ENOPROTOOPT; on platforms that
do implement the option the path is unchanged.

draft patch against GNU Emacs master:

```diff
--- a/lib-src/emacsclient.c
+++ b/lib-src/emacsclient.c
@@
   struct timeval tv;
   tv.tv_sec  = MINIBUF_WAIT_SECONDS;
   tv.tv_usec = 0;
-  if (setsockopt (s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0)
-    message (true, "%s: setsockopt: %s\n", progname, strerror (errno));
+  /* Hurd's pflocal does not implement this option; the timeout is
+     best-effort, the warning is noise.  Suppress only the
+     ENOPROTOOPT case so a real failure on Linux still surfaces.  */
+  if (setsockopt (s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0
+      && errno != ENOPROTOOPT)
+    message (true, "%s: setsockopt: %s\n", progname, strerror (errno));
```

rationale, in commit-message shape:

    the SO_RCVTIMEO setsockopt is an optimisation: it caps how long
    the client waits for the server reply on the local socket.  on
    platforms that do not implement the option the client still
    works correctly (the read blocks until the server replies or
    the kernel tears the socket down).  Hurd's pflocal returns
    ENOPROTOOPT here.  the existing code surfaces every error from
    setsockopt as a stderr line, so on Hurd every emacsclient
    invocation prints "setsockopt: Protocol not available" with no
    operational consequence.  suppress the message in the
    ENOPROTOOPT branch only; other errors still surface.

i would file this against `bug-gnu-emacs@gnu.org` with a one-paragraph
intro, the patch inline, and a pointer to the runlog above as the
"how i found it" trail.

## remediation path (b): pflocal learns SO_RCVTIMEO

correct fix, harder. lives in upstream Hurd, not GEOS.

scope sketch, written for a hurd hacker who has not seen the gap:

  - pflocal's socket-option dispatch is in `hurd/pflocal/socket.c`
    (alternately io.c depending on the cut).  today it handles a
    short list of SOL_SOCKET options and returns EOPNOTSUPP /
    ENOPROTOOPT for everything else.
  - SO_RCVTIMEO is per-socket state, a `struct timeval` that
    bounds the recv() path.  the implementation has to add a
    field to the per-socket state, parse the optval as a
    `struct timeval`, and honour it on the server-side recv path
    that pflocal already runs to multiplex AF_UNIX traffic
    through Mach IPC.
  - the tricky bit is timeout semantics across the Mach IPC
    boundary.  Linux's recv() with SO_RCVTIMEO returns EAGAIN
    when the timer expires; pflocal's Mach-shaped reply has to
    map that back to the libc errno.  pflocal already does
    similar translation for non-blocking IO, so the precedent
    exists.
  - SO_SNDTIMEO would land in the same patch by symmetry.

this is FSF / GNU Hurd territory.  i would file as an issue on
`bug-hurd@gnu.org` with the pointer to path (a) as the immediate
workaround so future emacs users on Hurd stop seeing the stderr
noise even before pflocal grows the feature.

## suggested upstream destinations

  - path (a): `bug-gnu-emacs@gnu.org` (patch submission, target
    emacs 31).
  - path (b): `bug-hurd@gnu.org` (feature request against pflocal,
    no patch attached; the issue body should reference path (a) so
    the two threads stay linked).

## status in GEOS

no in-repo code change.  per the no-premature-abstraction rule,
wrapping every emacsclient call to filter stderr is the wrong
trade for one cosmetic line.  HURD_PORT.md row 293 carries the
"deferred-upstream" verdict with a pointer to the bucket-2 probe
receipt cited above.
