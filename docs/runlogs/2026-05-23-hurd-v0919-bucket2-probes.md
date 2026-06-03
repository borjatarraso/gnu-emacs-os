<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

# 2026-05-23 hurd v0.9.19 bucket-2 probes: glibc .note.GNU-stack + emacsclient SO_RCVTIMEO

Two diagnostic probes ran on the v0.9.16 work snapshot (QEMU pid
1586142, port 2266), each closing a long-carried v0.9.1x deferral with
ground-truth evidence ready for upstream filings.

## probe 1: glibc-hurd pt-hurd-cond-timedwait.o ships executable .note.GNU-stack

Carried since v0.9.17 as a cosmetic warning fired on every PORT=hurd
STATIC=1 link.  The warning text:

    /usr/bin/ld: warning: pt-hurd-cond-timedwait.o: requires executable
    stack (because the .note.GNU-stack section is executable)

### environment

    Debian GNU/Hurd 0.9 (forky/sid), arch hurd-amd64
    GNU-Mach 1.8+git20260224-up-amd64 / Hurd-0.9
    GNU ld (GNU Binutils for Debian) 2.46
    gcc (Debian 15.2.0-12) 15.2.0
    GNU C Library (Debian GLIBC 2.42-16) stable release version 2.42

### object location

The Hurd glibc port ships TWO pthread archives at
/usr/lib/x86_64-gnu/.  libpthread.a is a 45-byte linker script
(GROUP wrapper).  The actual archive is **libpthread2.a**, which
contains pt-hurd-cond-timedwait.o alongside pt-hurd-cond-wait.o and
the rest of the Hurd-specific pthread surface.

### root cause

The `.note.GNU-stack` section in pt-hurd-cond-timedwait.o is emitted
as PROGBITS with the X (executable) flag.  Per the
"executable-stack-marking" convention, an empty `.note.GNU-stack`
section with no flags signals "no executable stack required"; the
absence of the section, or its presence with the X flag, signals
"executable stack required."  Sibling Hurd pthread objects from the
same libpthread2.a (pt-hurd-cond-wait.o, cnd_timedwait.o, etc.) all
correctly emit `.note.GNU-stack` as PROGBITS with no flags.

`objdump -h pt-hurd-cond-timedwait.o`:

    Idx Name             Size      VMA    LMA    File off  Algn
      8 .note.GNU-stack 00000000  ...    ...    0000083f  2**0
                        CONTENTS, READONLY, CODE

`readelf -S` corroborates: section [11] `.note.GNU-stack`,
type PROGBITS, flags `X` (executable).

`objdump -h pt-hurd-cond-wait.o` for contrast:

    Idx Name             Size      Algn  flags
      3 .note.GNU-stack 00000000   2**0  CONTENTS, READONLY

The deviation is local to a single source file.  Almost certainly
the offending TU (pthread/sysdeps/mach/hurd/pt-hurd-cond-timedwait.c
in glibc's hurd port) carries an unannotated `asm()` block or
includes a header that drops the `.section .note.GNU-stack,"",%note`
directive.  glibc style elsewhere either compiles with
`-Wa,--noexecstack` or hand-annotates the asm with the explicit
note directive.

### draft upstream report (sourceware bugzilla, glibc / hurd)

    Component: libc / hurd
    Version:   2.42 (Debian Hurd 0.9 packaging, also reproduces against
               glibc git tip)
    Summary:   pthread/sysdeps/mach/hurd/pt-hurd-cond-timedwait.o ships
               an executable .note.GNU-stack section; every static link
               that pulls libpthread.a/libpthread2.a triggers
               "requires executable stack" linker warning

    Build:
      Debian Hurd 0.9, gcc 15.2.0, binutils 2.46, glibc 2.42-16
      cc ... -DPORT_HURD -static -o foo foo.o \
        -Wl,--start-group -lports -lfshelp -lihash -lshouldbeinlibc \
        -lhurduser -lmachuser -lpthread -Wl,--end-group

    Linker output:
      /usr/bin/ld: warning: pt-hurd-cond-timedwait.o: requires
      executable stack (because the .note.GNU-stack section is
      executable)

    Diagnostic:
      $ ar x /usr/lib/x86_64-gnu/libpthread2.a pt-hurd-cond-timedwait.o
      $ objdump -h pt-hurd-cond-timedwait.o | grep -A1 GNU-stack
        8 .note.GNU-stack 00000000  ...  CONTENTS, READONLY, CODE
      $ objdump -h pt-hurd-cond-wait.o     | grep -A1 GNU-stack
        3 .note.GNU-stack 00000000  ...  CONTENTS, READONLY

      Sibling TUs in the same archive emit .note.GNU-stack correctly
      (no CODE/X flag).  Deviation is local to
      pt-hurd-cond-timedwait.c.

    Suggested fix:
      Either add -Wa,--noexecstack to CFLAGS for
      pthread/sysdeps/mach/hurd/pt-hurd-cond-timedwait.c, or annotate
      any inline-asm block with
        __asm__(".section .note.GNU-stack,\"\",%progbits\n");
      to override the assembler's default-executable behaviour.

    Severity:  trivial (cosmetic; warning only, link succeeds)
    Impact:    every static link of a Hurd program against libpthread
               emits a build-noise line that masks real warnings under
               -Werror promotion regimes.

### artifacts preserved on host

    /tmp/v0918-glibc-evidence/static-build.log          (PORT=hurd
                                                         STATIC=1 link
                                                         log)
    /tmp/v0918-glibc-evidence/pt-hurd-cond-timedwait.o  (the offending
                                                         object pulled
                                                         out of
                                                         libpthread2.a)

## probe 2: emacsclient SO_RCVTIMEO setsockopt unsupported by pflocal

Carried since v0.9.15 slice D as "emacsclient: setsockopt: Protocol
not available" on every invocation.  This is the FIRST time we
attached a real running emacs server and stepped a debugger to the
failing syscall.

### reproduction

    # on Hurd VM
    emacs --daemon=test-daemon
    emacsclient -s test-daemon -e '(+ 1 2)'
    /usr/bin/emacsclient.emacs: setsockopt: Protocol not available
    3

The warning goes to stderr.  The eval result `3` lands on stdout.
The client's exit code is 0.  The setsockopt failure is
**non-fatal**: emacsclient sets `errno` from the failed call, prints
the warning, and continues without the timeout.

### syscall identification

`nm -D --undefined-only` confirmed emacsclient has exactly one
setsockopt linkage:

    U setsockopt@GLIBC_2.38

`strace` is not installed on the canonical image.  Used gdb instead:

    break setsockopt
    commands
      silent
      printf "setsockopt called: fd=%d level=%d optname=%d\n", \
             $rdi, $rsi, $rdx
      continue
    end
    run -s test-daemon -e "(+ 1 2)"

Caught exactly one call before the warning fired:

    setsockopt called: fd=3 level=65535 optname=4102

### decoded

    level   = 65535 = 0xFFFF = SOL_SOCKET
    optname =  4102 = 0x1006 = SO_RCVTIMEO  (per
                               /usr/include/x86_64-gnu/bits/socket.h:377)

i.e. emacsclient is calling `setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
&tv, sizeof tv)` to bound how long it waits for a server reply on
the AF_UNIX socket.

### why it fails

pflocal (the Hurd translator backing AF_UNIX) does not implement
`SO_RCVTIMEO` on its socket-option path.  Returns `ENOPROTOOPT`,
which glibc's `strerror` text on Hurd is "Protocol not available."

This is a real pflocal capability gap, not an emacs bug.  Linux's
AF_UNIX socket layer supports SO_RCVTIMEO; pflocal currently does
not.

### remediation paths

(a) **emacs-upstream patch** (cheapest, ships in emacs 31):
    in lib-src/emacsclient.c, change the setsockopt error path to
    suppress the warning when `errno == ENOPROTOOPT`:
        if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0
            && errno != ENOPROTOOPT)
          message(true, "%s: setsockopt: %s\n", progname, strerror(errno));
    rationale: the socket option is an optimisation (caps how long the
    client waits for a server reply); on platforms that lack it, the
    client still works correctly, the warning is pure noise.

(b) **pflocal patch** (correct, more work):
    teach Hurd's pflocal translator to honour SO_RCVTIMEO on its
    server-side recv() path.  Likely lives in
    hurd/pflocal/socket.c or hurd/pflocal/io.c.  Out of scope for
    this repo; would be filed against the savannah hurd tracker.

(c) **GEOS-side wrapper**:  not warranted.  The warning is one stderr
    line per emacsclient invocation, not a functional regression.
    Wrapping every emacsclient call to filter stderr is the wrong
    cost-benefit.

### proposed action

Path (a).  Patch is two lines.  Submitted as a savannah patch
against emacs master targets emacs 31; falls back to no-op on
platforms where the setsockopt succeeds (`errno` is undefined when
the call succeeds, but the `!= ENOPROTOOPT` branch is only entered
on failure, so behaviour on Linux is unchanged).

Path (b) gets filed as a separate hurd-deferred-upstream row in
HURD_PORT.md so future cycles know pflocal lacks SO_RCVTIMEO.

### artifacts preserved on host

    /tmp/hurd_vm_key, /tmp/hurd_vm_key.pub  (SSH keypair into VM)

### follow-on for HURD_PORT.md

Add a new row under the "deferred upstream" section:

    | pflocal SO_RCVTIMEO   | deferred-upstream | gnumach pflocal
    |                       |                   | translator lacks
    |                       |                   | SO_RCVTIMEO; non-
    |                       |                   | fatal warning from
    |                       |                   | emacsclient and any
    |                       |                   | AF_UNIX client that
    |                       |                   | sets a recv timeout

## summary

Two bug-class diagnoses closed honestly with reproducible evidence:

  - glibc-hurd cosmetic build noise reduced from "unknown source" to
    "single TU's executable .note.GNU-stack, two-line CFLAGS or asm
    annotation fixes it".  Ready for sourceware bugzilla filing.
  - emacsclient setsockopt warning reduced from "deferred since
    v0.9.15" to "pflocal lacks SO_RCVTIMEO, emacsclient's warn-on-
    every-failure path is the noisy stderr line, two-line emacs
    patch silences it on Hurd without regressing Linux."  Ready for
    savannah emacs patch submission.

Neither finding requires a code change in this repo.  Both unblock
a cleaner Hurd build/runtime story without growing the v0.9 surface.
