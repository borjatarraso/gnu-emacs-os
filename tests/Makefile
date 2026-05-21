# tests/Makefile, builds the Hurd-only design-uncertainty probes.
#
# convention: every probe is a single .c that says "OK"/"PASS" on
# stdout (exit 0) or "FAIL: <reason>" on stdout (exit 1).  no test
# framework, no test runner, no expected-output files.  these are
# answers-to-design-questions, not unit tests.
#
# the unit tests live under iso-build/freeze-tests/ and run inside
# the booted emacs.  the QEMU smoke gate lives under iso-build/.
# this Makefile is purely the C-probe build, invoked by hand from a
# Hurd dev VM or by the v0.9.9 verification runlog.
#
# default `make` builds nothing; pick a PORT explicitly:
#   make -C tests PORT=hurd            -> every Hurd-only probe
#   make -C tests PORT=hurd pdeath     -> just the pdeath probe
# Linux is not a supported PORT here because every probe in this
# directory uses <mach.h> / <hurd.h>.  asking for PORT=linux is a
# fast loud failure.

PORT ?= hurd
ifneq ($(PORT),hurd)
$(error tests/Makefile: PORT=$(PORT) not supported; only PORT=hurd has any probes here)
endif

CC      ?= gcc
CFLAGS  ?= -std=c11 -Wall -Wextra -Werror -O2 -fno-strict-aliasing
LDFLAGS ?=

# Hurd link line.  identical to pid1/Makefile's PORT_BOOT_LIBS for
# the slot-dispatch reuse case (the pdeath probe links port_hurd.c
# directly and therefore needs the same libs that pid1's PORT=hurd
# build pulls in).
#
# -lpthread (here as -pthread for the driver flag) is named on every
# link line that touches port_hurd.c or any probe that calls
# pthread_create directly.  pid1/Makefile now also names -lpthread
# explicitly on its PORT=hurd link lines; the historical claim that
# libports' NEEDED chain pulled libpthread transitively at link time
# stopped being true on Debian GNU/Hurd 0.9's binutils 2.45-ish +
# gcc 15.2.0 toolchain (see the comment over PORT_BOOT_LIBS in
# pid1/Makefile for the full forensic).
PORT_LIBS := -lports -lfshelp -lhurduser -lmachuser
PTHREAD   := -pthread

.PHONY: all clean pdeath sidechannel pflocal-cmsg client-handshake publish-auth-port

all: pdeath sidechannel pflocal-cmsg client-handshake publish-auth-port

# the v0.9.9 dead-name watcher probe.  links port_hurd.c directly
# (NOT through pid1-module.so) so the slot dispatches without an
# elisp emacs in the address space.  uses PID1_TEST_HELPER as a
# distinguishing macro in case a future port_hurd.c body wants to
# tweak its behaviour under the probe; today nothing keys off it,
# but defining it documents intent.
#
# port_hurd.c's hurd_auth_drain references the MIG-generated
# fsys_server_routines / fsys_server symbols (the v0.8 design-2.2
# auth translator demuxer).  pid1/Makefile generates fsysServer.c /
# fsys_S.h from /usr/include/x86_64-gnu/hurd/fsys.defs; we mirror
# that rule here so the probe link does not fail with
# "undefined reference to fsys_server_routines / fsys_server".  the
# mig invocation matches pid1/Makefile's verbatim (same -DSEQNOS,
# same /dev/null discard for the unused user side).
fsysServer.c fsys_S.h: /usr/include/x86_64-gnu/hurd/fsys.defs
	mig -DSEQNOS \
	    -sheader fsys_S.h \
	    -server fsysServer.c \
	    -header /dev/null \
	    -user /dev/null \
	    /usr/include/x86_64-gnu/hurd/fsys.defs

pdeath: hurd-pdeath-probe
hurd-pdeath-probe: hurd-pdeath-probe.c ../pid1/port_hurd.c ../pid1/port_layer.h fsysServer.c fsys_S.h
	$(CC) $(CFLAGS) $(PTHREAD) -DPORT_HURD -DPID1_TEST_HELPER \
	    -I../pid1 -I. \
	    -o $@ hurd-pdeath-probe.c ../pid1/port_hurd.c fsysServer.c \
	    $(LDFLAGS) $(PORT_LIBS)

# pre-existing probes; one rule each so a make-all is honest about
# what gets built when the Hurd toolchain is present.
sidechannel: hurd-mach-sidechannel
hurd-mach-sidechannel: hurd-mach-sidechannel.c
	$(CC) $(CFLAGS) $(PTHREAD) -o $@ $< $(LDFLAGS)

pflocal-cmsg: hurd-pflocal-cmsg
hurd-pflocal-cmsg: hurd-pflocal-cmsg.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

client-handshake: hurd-client-handshake
hurd-client-handshake: hurd-client-handshake.c
	$(CC) $(CFLAGS) $(PTHREAD) -o $@ $< $(LDFLAGS) $(PORT_LIBS)

publish-auth-port: hurd-publish-auth-port
hurd-publish-auth-port: hurd-publish-auth-port.c
	$(CC) $(CFLAGS) $(PTHREAD) -o $@ $< $(LDFLAGS) $(PORT_LIBS)

clean:
	rm -f hurd-pdeath-probe hurd-mach-sidechannel hurd-pflocal-cmsg \
	      hurd-client-handshake hurd-publish-auth-port \
	      fsysServer.c fsys_S.h
