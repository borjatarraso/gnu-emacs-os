# pid1/Makefile, builds the standalone PID 1 binary and the emacs
# dynamic module from the same emacs-init.c source.
#
# default target stays `emacs-init` so the existing system.scm gexp
# (which shells out to plain `make`) is undisturbed. `make module`
# produces pid1-module.so. `make all` builds both.

CC      ?= gcc
# -static is the right thing for production (PID 1 should not depend on
# any shared library showing up in /lib), but it requires libc.a on the
# build host. set STATIC=0 to drop it during local compile-checks. the
# module target ignores this on purpose: a .so loaded into emacs must
# share emacs's libc, static linking it would be an ABI mistake.
STATIC  ?= 1
ifeq ($(STATIC),1)
STATIC_FLAG := -static
else
STATIC_FLAG :=
endif

# hardening defaults.  -Werror so a fresh toolchain warning blocks
# build instead of being lost in the noise (PID 1 must be clean).
# -fstack-protector-strong + -D_FORTIFY_SOURCE=2 are the standard
# distro hardening pair.  -O2 is required for FORTIFY to do anything.
# -fno-strict-aliasing because we do interpret raw byte buffers from
# /proc and would rather be slow than miscompiled.
#
# stack-protector pulls in __stack_chk_fail from libssp; with
# -static we need libssp.a available on the build host.  glibc
# folds __stack_chk_fail into libc.a so this works out of the box
# on any sane glibc system; on musl-static you would need to link
# -lssp_nonshared explicitly.  guix's gcc-toolchain ships libssp
# so the production build path is fine.
CFLAGS  ?= -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 \
           -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
           -fno-strict-aliasing
LDFLAGS ?=
PREFIX  ?= /
SBINDIR ?= $(PREFIX)/sbin

# locate emacs-module.h. probe order matters: prefer the active guix
# shell (GUIX_ENVIRONMENT) when present, then the booted guix system
# profile, then fedora's /usr/include, then pkg-config as last resort.
# the guix-shell branch is what the module build wants, since the .so
# must dlopen inside the booted guix image; building against fedora
# headers risks pulling glibc C23-isms (_Float32x, MS_NOUSER) that
# -Werror -Wpedantic refuses, and yields a libcrypt.so.2 DT_NEEDED
# with no RUNPATH that the booted system cannot resolve.
EMACS_MODULE_H_SHELL  := $(GUIX_ENVIRONMENT)/include
EMACS_MODULE_H_GUIX   := /run/current-system/profile/include
EMACS_MODULE_H_FEDORA := /usr/include
ifneq ($(GUIX_ENVIRONMENT),)
ifneq ($(wildcard $(EMACS_MODULE_H_SHELL)/emacs-module.h),)
EMACS_MODULE_INC := -I$(EMACS_MODULE_H_SHELL)
endif
endif
ifndef EMACS_MODULE_INC
ifneq ($(wildcard /run/current-system),)
ifneq ($(wildcard $(EMACS_MODULE_H_GUIX)/emacs-module.h),)
EMACS_MODULE_INC := -I$(EMACS_MODULE_H_GUIX)
endif
endif
endif
ifndef EMACS_MODULE_INC
ifneq ($(wildcard $(EMACS_MODULE_H_FEDORA)/emacs-module.h),)
EMACS_MODULE_INC := -I$(EMACS_MODULE_H_FEDORA)
else ifneq ($(wildcard $(EMACS_MODULE_H_GUIX)/emacs-module.h),)
EMACS_MODULE_INC := -I$(EMACS_MODULE_H_GUIX)
else
EMACS_MODULE_INC := $(shell pkg-config --cflags-only-I emacs 2>/dev/null)
endif
endif

MODULE_CFLAGS := -std=c11 -Wall -Wextra -Wpedantic -Werror -O2 \
                 -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
                 -fno-strict-aliasing \
                 -fPIC -DPID1_MODULE $(EMACS_MODULE_INC)
# PORT_DEFS is appended below once the PORT block has set it.
# libcrypt (libxcrypt) is needed by Fpid1_crypt.  module-only, the
# standalone PID 1 has no crypt path.  build inside `guix shell
# gcc-toolchain libxcrypt make` so the resulting .so picks up
# libxcrypt from the store; we then bake libxcrypt's own store path
# into RUNPATH (via `guix build libxcrypt`) so dlopen inside the
# booted guix image can resolve libcrypt.so.N off a path that
# actually exists in the image (the guix-shell profile dir, which
# LIBRARY_PATH points at during build, does NOT exist in the booted
# image).  building on the bare host (fedora) yields a .so with a
# NEEDED for libcrypt.so.2 and no RUNPATH, which dlopen inside the
# guix image cannot resolve and module-load fails with
# "libcrypt.so.2: cannot open shared object".
MODULE_LDFLAGS := -shared
MODULE_LIBS    := -lcrypt
# LIBXCRYPT_STOREPATH: caller may pass it in (e.g. from a guix-build
# wrapper running outside the pure shell), or we shell out to `guix
# build libxcrypt` from inside the shell.  pure `guix shell` strips
# guix itself, so the env-var path is the working one in CI; the
# shell-out is a convenience for non-pure shells on a dev host.
ifndef LIBXCRYPT_STOREPATH
ifneq ($(GUIX_ENVIRONMENT),)
LIBXCRYPT_STOREPATH := $(shell guix build libxcrypt 2>/dev/null)
endif
endif
ifneq ($(LIBXCRYPT_STOREPATH),)
MODULE_LDFLAGS += -Wl,-rpath,$(LIBXCRYPT_STOREPATH)/lib
endif

# shared sources.  port_layer.h is the kernel-portability seam; the
# Linux bodies live in port_linux.c, the Hurd bodies in port_hurd.c.
# the PORT variable picks one or the other at build time; the two
# backends are NEVER linked into the same binary.
#
# PORT=linux (default): the Linux backend.  identical to pre-step-4
# behaviour.  every existing build path (iso-build, dev-vm.sh, the
# host smoke-test) keeps working with no flag change.
#
# PORT=hurd: the Hurd backend.  swaps port_linux.c for port_hurd.c,
# adds -DPORT_HURD so emacs-init.c picks the &port_hurd_impl symbol
# (and so port_layer.h reveals the extern declaration), and skips
# the libcrypt link line (the Hurd module build will need a separate
# libxcrypt-on-hurd dance, not in step 4).
#
# this lives in pid1/Makefile (not in the system.scm gexp) because
# the choice is a property of the C toolchain, not of the operating-
# system record: a cross-build of pid1/ for Hurd is what
# guix-system/system-hurd.scm would invoke before the disk-image
# build, and that call has to be able to swap PORT cleanly.
PORT ?= linux
ifeq ($(PORT),hurd)
PORT_SRC  := port_hurd.c
PORT_DEFS := -DPORT_HURD
# Hurd link dependencies for port_hurd.c.  on Debian GNU/Hurd
# (libhurd-dev / hurd-dev) the user-side libraries are split as:
#   -lhurduser : Hurd userland RPC stubs (file_set_translator,
#                file_name_lookup, the pfinet ioctl mux entry points)
#   -lmachuser : Mach RPC stubs (host_reboot, mach_port_deallocate,
#                mach_host_self, mach_task_self)
#   -lfshelp   : the libfshelp helpers; we use fshelp_start_translator
#                to fork+exec a translator binary (e.g. /hurd/tmpfs)
#                and hand its bootstrap port to file_set_translator.
#                without this the mount call attaches the translator
#                record but never starts an active process.
# the historical names -lhurd / -lmach are NOT present as standalone
# .so files on a modern Debian Hurd toolchain; everything they used to
# carry is folded into glibc itself (the Hurd glibc IS the Hurd kernel
# interface, much like vDSO on Linux carries fast-path syscalls).
# ordering: -lfshelp before the user-stub libs so libfshelp's UND refs
# (fshelp_start_translator_long calls into libhurduser/libmachuser
# entry points internally) resolve forward.  the dynamic linker
# chases libfshelp's NEEDED of libports / libihash / libpthread /
# libshouldbeinlibc transitively, so we do not name those explicitly.
#
# the pfinet networking verbs (bring_up_lo / set_address /
# set_route_default) go through plain socket() + ioctl() in glibc, so
# they do NOT add a third-party dep here: glibc's ioctl mux in
# sysdeps/mach/hurd/ioctl.c is what translates SIOC* into the pfinet
# RPCs, and that mux ships inside libc itself on a Hurd glibc.  no
# -lpfinet, no separate stub library.
#
# the Linux build path never sees these libs: the link line below is
# scoped to PORT=hurd only.  attribute-style "ldflags += ..." would
# work too but the explicit assignment is harder to misread when the
# v0.8 cross-toolchain runner picks this up.
# slice 3 of v0.8 design-2.2 adds -lports: libports is the canonical
# Hurd library for translator bookkeeping (port_bucket, port_class,
# port_info; the no-senders / dead-name notification plumbing).  the
# slice 3 hurd_publish_auth_port body calls ports_create_bucket /
# ports_create_class / ports_create_port / ports_get_send_right /
# ports_notify_server; hurd_auth_drain reads auth_bucket->portset
# directly.  libports' own NEEDED transitively pulls libihash and
# libpthread.  ordering: -lports before -lfshelp because libfshelp's
# helpers in turn call into libports.
PORT_BOOT_LIBS   := -lports -lfshelp -lhurduser -lmachuser
PORT_MODULE_LIBS := -lports -lfshelp -lhurduser -lmachuser
# generated MIG sources for the fsys subsystem.  slice 3 needs an
# fsys_server() demuxer so libdiskfs's fsys_getroot request (issued by
# every file_name_lookup("/servers/geos-auth", ...)) reaches our
# fsys_getroot user stub at port_hurd.c.  -DMIG_EOPNOTSUPP=EOPNOTSUPP
# tells MIG to emit weak default-EOPNOTSUPP bodies for every fsys
# routine we do NOT implement (fsys_goaway, fsys_syncfs, ...), so the
# link line stays one-stub-per-implementation without per-routine
# stub clutter.  user side discarded into /dev/null because we do
# not call any fsys RPC ourselves; we only serve them.
PORT_GEN_SRCS    := fsysServer.c
PORT_GEN_HDRS    := fsys_S.h
fsysServer.c fsys_S.h: /usr/include/x86_64-gnu/hurd/fsys.defs
	mig -DSEQNOS \
	    -sheader fsys_S.h \
	    -server fsysServer.c \
	    -header /dev/null \
	    -user /dev/null \
	    /usr/include/x86_64-gnu/hurd/fsys.defs
else ifeq ($(PORT),linux)
PORT_SRC  := port_linux.c
PORT_DEFS :=
# Linux backend has no extra link deps; everything it needs is in
# libc (or, for the module, libcrypt added below).
PORT_BOOT_LIBS   :=
PORT_MODULE_LIBS :=
PORT_GEN_SRCS    :=
PORT_GEN_HDRS    :=
else
$(error pid1/Makefile: PORT must be linux or hurd, got $(PORT))
endif

# the per-TU stem (port_linux / port_hurd) drives the .o filenames so
# a `make PORT=linux` followed by `make PORT=hurd` does not get
# confused about which backend a stale port_*.boot.o belongs to.
PORT_STEM := $(basename $(PORT_SRC))

CFLAGS         += $(PORT_DEFS)
MODULE_CFLAGS  += $(PORT_DEFS)

COMMON_SRCS := emacs-init.c $(PORT_SRC)
COMMON_HDRS := port_layer.h $(PORT_GEN_HDRS)

# per-TU object files.  the boot and module builds need distinct
# names because the module build adds -DPID1_MODULE -fPIC and uses
# its own CFLAGS; sharing a single .o between the two would silently
# pick whichever was built last (W4, skeptic review 2026-05-12).
# PORT_GEN_OBJS adds the MIG-generated objects on the Hurd path
# (currently fsysServer.boot.o / fsysServer.mod.o); empty on Linux.
PORT_GEN_OBJS_BOOT := $(PORT_GEN_SRCS:.c=.boot.o)
PORT_GEN_OBJS_MOD  := $(PORT_GEN_SRCS:.c=.mod.o)
BOOT_OBJS   := emacs-init.boot.o $(PORT_STEM).boot.o $(PORT_GEN_OBJS_BOOT)
MODULE_OBJS := emacs-init.mod.o $(PORT_STEM).mod.o $(PORT_GEN_OBJS_MOD)

.PHONY: all default module clean install

# pin the default goal explicitly.  PORT=hurd registers a MIG rule
# (fsysServer.c fsys_S.h: fsys.defs) BEFORE this point in the file, and
# the first explicit rule's first target ordinarily becomes Make's
# default goal.  without this line, `make PORT=hurd` runs only the MIG
# rule and stops, which is exactly the silent-half-build footgun the
# Hurd port's slice 3 build chain has to avoid.
.DEFAULT_GOAL := default

default: emacs-init

all: emacs-init pid1-module.so

module: pid1-module.so

# boot-path objects.  static-friendly, no PIC, no module ifdef.
%.boot.o: %.c $(COMMON_HDRS)
	$(CC) $(CFLAGS) -c -o $@ $<

# MIG-generated server objects use a relaxed CFLAGS set: MIG output is
# pre-existing third-party C that the upstream Hurd makefiles compile
# without -Werror -Wpedantic.  retaining our hardening defaults on this
# generated TU would block builds on every MIG bump.  the rule applies
# to PORT_GEN_SRCS only; everything in COMMON_SRCS keeps the strict
# flags.
MIG_CFLAGS := -std=c11 -Wall -O2 -fstack-protector-strong -fno-strict-aliasing
ifeq ($(PORT),hurd)
fsysServer.boot.o: fsysServer.c fsys_S.h
	$(CC) $(MIG_CFLAGS) $(PORT_DEFS) -c -o $@ fsysServer.c
fsysServer.mod.o: fsysServer.c fsys_S.h
	$(CC) $(MIG_CFLAGS) $(PORT_DEFS) -fPIC -DPID1_MODULE $(EMACS_MODULE_INC) -c -o $@ fsysServer.c
endif

emacs-init: $(BOOT_OBJS)
	$(CC) $(CFLAGS) $(STATIC_FLAG) -o $@ $(BOOT_OBJS) $(LDFLAGS) $(PORT_BOOT_LIBS)

# module objects.  -fPIC and -DPID1_MODULE come from MODULE_CFLAGS so
# the same .c files compile differently from the boot variant.
%.mod.o: %.c $(COMMON_HDRS)
	$(CC) $(MODULE_CFLAGS) -c -o $@ $<

# the module is loaded into a running emacs; do not pass -static, do
# pass -fPIC (already in MODULE_CFLAGS).  link the per-TU objects so
# the resulting .so carries both port_linux_impl and the Fpid1_*
# bindings.
pid1-module.so: $(MODULE_OBJS)
	$(CC) $(MODULE_CFLAGS) $(MODULE_LDFLAGS) -o $@ $(MODULE_OBJS) $(MODULE_LIBS) $(PORT_MODULE_LIBS)

install: emacs-init
	install -d $(DESTDIR)$(SBINDIR)
	install -m 0755 emacs-init $(DESTDIR)$(SBINDIR)/emacs-init

clean:
	rm -f emacs-init pid1-module.so *.o fsysServer.c fsys_S.h
