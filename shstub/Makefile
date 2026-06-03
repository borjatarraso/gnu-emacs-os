# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
# shstub/Makefile, builds the /bin/sh replacement.
#
# this is the smallest C in the repo. one translation unit, no link
# dependencies beyond libc. the binary lands at shstub/sh and is
# installed to /bin/sh on the target system. STATIC=1 is mandatory
# for shipped builds because /bin/sh is invoked before any dynamic
# linker config is in place; STATIC=0 exists so i can compile-check
# on dev hosts that lack glibc-static.

CC      ?= gcc
STATIC  ?= 1
ifeq ($(STATIC),1)
STATIC_FLAG := -static
else
STATIC_FLAG :=
endif

CFLAGS  ?= -std=c11 -Wall -Wextra -Wpedantic -O2
LDFLAGS ?=
PREFIX  ?= /
BINDIR  ?= $(PREFIX)/bin

.PHONY: all clean install

all: sh

sh: sh.c
	$(CC) $(CFLAGS) $(STATIC_FLAG) -o $@ $< $(LDFLAGS)

# install replaces /bin/sh on the target. do not run this on a dev
# host unless you know what you are doing; it will brick anything
# that expects a real shell.
install: sh
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 sh $(DESTDIR)$(BINDIR)/sh

clean:
	rm -f sh
