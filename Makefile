# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
#
# This file is part of GEOS.
#
# GEOS is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# GEOS is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with GEOS.  If not, see <https://www.gnu.org/licenses/>.
#
# top-level Makefile.  it follows the GNU Makefile Conventions (standard
# directory variables, DESTDIR, the standard target set) and recurses
# into the two C components, pid1/ (the emacs-init binary) and shstub/
# (the /bin/sh build stub).  run ./configure first to produce config.mk;
# a bare `make` without configuring still works off the defaults below.
#
# the bootable system image is a separate build path (a pinned Guix
# channel on Linux, iso-build/hurd-image-reroll.sh on Hurd).  this
# Makefile is the conventional ./configure && make && make install
# surface for the C parts, which is what the GNU standards ask for.

# configure writes config.mk; include it if present.  the ?= defaults
# below fill in anything an unconfigured tree is missing so `make` works
# out of the box for a quick compile.
-include config.mk

PACKAGE       ?= geos
VERSION       ?= 1.0.2
CC            ?= gcc
STATIC        ?= 1

prefix        ?= /usr/local
exec_prefix   ?= $(prefix)
bindir        ?= $(exec_prefix)/bin
sbindir       ?= $(exec_prefix)/sbin
libexecdir    ?= $(exec_prefix)/libexec
datarootdir   ?= $(prefix)/share
datadir       ?= $(datarootdir)
sysconfdir    ?= $(prefix)/etc
localstatedir ?= $(prefix)/var
mandir        ?= $(datarootdir)/man
infodir       ?= $(datarootdir)/info
docdir        ?= $(datarootdir)/doc/$(PACKAGE)

DESTDIR ?=

INSTALL         ?= install
INSTALL_PROGRAM ?= $(INSTALL)
STRIP           ?= strip

# what to hand down to the component Makefiles.  CC and STATIC always go
# down; the user build variables only go down when they were actually
# set, so an unset CFLAGS leaves each component's hardened -Werror flags
# alone instead of blanking them.
FORWARD = CC='$(CC)' STATIC='$(STATIC)'
ifneq ($(strip $(CFLAGS)),)
FORWARD += CFLAGS='$(CFLAGS)'
endif
ifneq ($(strip $(CPPFLAGS)),)
FORWARD += CPPFLAGS='$(CPPFLAGS)'
endif
ifneq ($(strip $(LDFLAGS)),)
FORWARD += LDFLAGS='$(LDFLAGS)'
endif

distdir = $(PACKAGE)-$(VERSION)

.PHONY: all build-pid1 build-shstub install installdirs install-strip \
        uninstall clean mostlyclean distclean maintainer-clean \
        check installcheck dist TAGS info dvi ps pdf html \
        install-info install-html install-dvi install-ps install-pdf

.DEFAULT_GOAL := all

# ---- build ----------------------------------------------------------

all: build-pid1 build-shstub

build-pid1:
	$(MAKE) -C pid1 emacs-init $(FORWARD)

build-shstub:
	$(MAKE) -C shstub sh $(FORWARD)

# ---- install --------------------------------------------------------

installdirs:
	$(INSTALL) -d $(DESTDIR)$(sbindir) $(DESTDIR)$(bindir)

install: all installdirs
	$(MAKE) -C pid1 install DESTDIR='$(DESTDIR)' SBINDIR='$(sbindir)' $(FORWARD)
	$(MAKE) -C shstub install DESTDIR='$(DESTDIR)' BINDIR='$(bindir)' $(FORWARD)

install-strip: install
	$(STRIP) $(DESTDIR)$(sbindir)/emacs-init $(DESTDIR)$(bindir)/sh

uninstall:
	rm -f $(DESTDIR)$(sbindir)/emacs-init $(DESTDIR)$(bindir)/sh

# ---- clean ----------------------------------------------------------

mostlyclean clean:
	$(MAKE) -C pid1 clean
	$(MAKE) -C shstub clean
	rm -f conftest*

distclean: clean
	rm -f config.mk config.status config.log

maintainer-clean: distclean
	@echo 'maintainer-clean: this removes files that may need special'
	@echo 'tools to rebuild; distclean already removed the generated'
	@echo 'build configuration.'

# ---- test -----------------------------------------------------------

# the standalone emacs-init is PID 1 and the sh stub forwards into a
# running emacs, so neither can be executed on a build host in
# isolation.  check therefore verifies the artifacts built and are
# executable; the full boot behaviour is exercised by the QEMU
# smoke-test and freeze-test suites under iso-build/.
check: all
	@test -x pid1/emacs-init || { echo 'check: pid1/emacs-init missing or not executable' >&2; exit 1; }
	@test -x shstub/sh || { echo 'check: shstub/sh missing or not executable' >&2; exit 1; }
	@echo 'check: build artifacts present and executable.'

installcheck:
	@echo 'installcheck: no runtime tests at install time; boot behaviour'
	@echo 'is verified by the QEMU smoke-test and freeze-test suites.'

# ---- distribution ---------------------------------------------------

dist:
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
	  echo "dist: writing $(distdir).tar.gz"; \
	  git archive --format=tar.gz --prefix=$(distdir)/ -o $(distdir).tar.gz HEAD; \
	else \
	  echo 'dist: not a git checkout; the release tarball is built from a' >&2; \
	  echo 'dist: tagged commit.  configure and build from a git clone.' >&2; \
	  exit 1; \
	fi

# ---- documentation --------------------------------------------------

# the manuals are Markdown under docs/ today and the GNU-standard
# Texinfo build is in progress (see the GNU evaluation submission).  the
# doc-format targets are present per the conventions and are no-ops
# until the Texinfo sources land.
info dvi ps pdf html:
	@echo '$@: the manuals are Markdown today; the Texinfo build is in'
	@echo '$@: progress and these targets will produce real output then.'

install-info install-html install-dvi install-ps install-pdf:
	@:

TAGS:
	@if command -v etags >/dev/null 2>&1; then \
	  etags pid1/*.c pid1/*.h shstub/*.c && echo 'TAGS written'; \
	else \
	  echo 'TAGS: etags not found; skipping'; \
	fi
