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
# Linux bodies live in port_linux.c.  the Hurd port (side branch)
# adds port_hurd.c with the same shape and an alternate build line.
COMMON_SRCS := emacs-init.c port_linux.c
COMMON_HDRS := port_layer.h

# per-TU object files.  the boot and module builds need distinct
# names because the module build adds -DPID1_MODULE -fPIC and uses
# its own CFLAGS; sharing a single .o between the two would silently
# pick whichever was built last (W4, skeptic review 2026-05-12).
BOOT_OBJS   := emacs-init.boot.o port_linux.boot.o
MODULE_OBJS := emacs-init.mod.o port_linux.mod.o

.PHONY: all default module clean install

default: emacs-init

all: emacs-init pid1-module.so

module: pid1-module.so

# boot-path objects.  static-friendly, no PIC, no module ifdef.
%.boot.o: %.c $(COMMON_HDRS)
	$(CC) $(CFLAGS) -c -o $@ $<

emacs-init: $(BOOT_OBJS)
	$(CC) $(CFLAGS) $(STATIC_FLAG) -o $@ $(BOOT_OBJS) $(LDFLAGS)

# module objects.  -fPIC and -DPID1_MODULE come from MODULE_CFLAGS so
# the same .c files compile differently from the boot variant.
%.mod.o: %.c $(COMMON_HDRS)
	$(CC) $(MODULE_CFLAGS) -c -o $@ $<

# the module is loaded into a running emacs; do not pass -static, do
# pass -fPIC (already in MODULE_CFLAGS).  link the per-TU objects so
# the resulting .so carries both port_linux_impl and the Fpid1_*
# bindings.
pid1-module.so: $(MODULE_OBJS)
	$(CC) $(MODULE_CFLAGS) $(MODULE_LDFLAGS) -o $@ $(MODULE_OBJS) $(MODULE_LIBS)

install: emacs-init
	install -d $(DESTDIR)$(SBINDIR)
	install -m 0755 emacs-init $(DESTDIR)$(SBINDIR)/emacs-init

clean:
	rm -f emacs-init pid1-module.so *.o
