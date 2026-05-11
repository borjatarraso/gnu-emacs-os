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

# locate emacs-module.h. probe order matters: prefer guix when this is
# a guix system (so a stale fedora emacs-devel does not shadow the
# pinned guix emacs), otherwise fall through to fedora's /usr/include,
# otherwise ask pkg-config. a guix system is detected by the presence
# of /run/current-system, not by the existence of the include dir
# alone.
EMACS_MODULE_H_GUIX   := /run/current-system/profile/include
EMACS_MODULE_H_FEDORA := /usr/include
ifneq ($(wildcard /run/current-system),)
ifneq ($(wildcard $(EMACS_MODULE_H_GUIX)/emacs-module.h),)
EMACS_MODULE_INC := -I$(EMACS_MODULE_H_GUIX)
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
# -lcrypt is libxcrypt on guix; needed by Fpid1_crypt.  module-only,
# the standalone PID 1 has no crypt path.
MODULE_LDFLAGS := -shared
MODULE_LIBS    := -lcrypt

.PHONY: all default module clean install

default: emacs-init

all: emacs-init pid1-module.so

module: pid1-module.so

emacs-init: emacs-init.c
	$(CC) $(CFLAGS) $(STATIC_FLAG) -o $@ $< $(LDFLAGS)

# the module is loaded into a running emacs; do not pass -static, do
# not link any helper objects, just one translation unit -> .so.
pid1-module.so: emacs-init.c
	$(CC) $(MODULE_CFLAGS) $(MODULE_LDFLAGS) -o $@ $< $(MODULE_LIBS)

install: emacs-init
	install -d $(DESTDIR)$(SBINDIR)
	install -m 0755 emacs-init $(DESTDIR)$(SBINDIR)/emacs-init

clean:
	rm -f emacs-init pid1-module.so *.o
