<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
# GEOS architecture

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Written and maintained by Borja Tarraso <borja.tarraso@member.fsf.org>.

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".

<!-- voice: first person singular, lowercase, no em-dashes. -->

A bird's-eye look at how GNU/Emacs Operating System (GEOS) is laid
out. Three zoom levels: the whole system, the major subsystems, and
the dual-kernel detail that lets the same userland run on Linux today
and on the GNU Hurd next.

If you have not read it yet, `MANIFESTO.md` says why this exists.
`INTERNALS.md` is the contributor-oriented walkthrough. This file is
the picture.

## Level 1, the whole thing in one diagram

The OS is one Emacs process supervised by a tiny C front-end that
became Emacs through `execve`. The kernel sits underneath; nothing
above the kernel is not Elisp or the few C files that proxy syscalls
into Elisp.

```
+--------------------------------------------------------------+
|  the user                                                    |
|  (M-x, eshell, EXWM-grabbed X clients, all in buffers)       |
+----------------------------+---------------------------------+
                             |
                             v
+--------------------------------------------------------------+
|  Emacs (the userland)                                        |
|    +-------------------------+   +------------------------+  |
|    | system-concept buffers  |   |  EXWM (X11 WM)         |  |
|    |   *processes* *network* |   |  exwm-config.el        |  |
|    |   *journal*   *services*|   +------------------------+  |
|    |   *disks*     *packages*|                               |
|    |   *users*     *audio*   |   +------------------------+  |
|    +-------------------------+   |  panic.el (error trap) |  |
|    +-------------------------+   +------------------------+  |
|    | core/                   |                               |
|    |   panic state supervise |   +------------------------+  |
|    |   network hostname port |   |  pid1-module.so (Elisp |  |
|    |   power                 |   |   bindings to syscalls)|  |
|    +-------------------------+   +-----------+------------+  |
+----------------------------------------------|---------------+
                                               |
                                               | dlopen + emacs_module_init
                                               v
+--------------------------------------------------------------+
|  pid1 binary (the supervisor)                                |
|    main():  mount /proc /sys /dev /run /tmp; lo up;          |
|             hostname; spawn Xorg; execve emacs               |
|    loop:    waitpid; respawn emacs; respawn Xorg (capped)    |
+----------------------------+---------------------------------+
                             |   |
            port_caps        |   |   /bin/sh -> shstub
        (function-ptr table) |   |   (50-line C stub that
                             |   |    forwards to emacsclient)
                             v   v
+--------------------------------------------------------------+
|  the kernel (Linux today, GNU Hurd next)                     |
+--------------------------------------------------------------+
```

What every box does, in two lines or less:

  - **the user**: types `M-x`, sees buffers. The shell is eshell.
  - **system-concept buffers**: every concept a Unix user would
    reach a CLI for (top, ip a, dmesg, df, apt) is a buffer.
  - **EXWM**: turns X11 windows into Emacs buffers.
  - **panic.el**: catches every Elisp error before it can kill
    Emacs (and therefore the OS).
  - **core/**: the always-on Elisp foundation. State persistence,
    service supervision, the port-layer accessor, error trap.
  - **pid1-module.so**: same C source as the pid1 binary, compiled
    with `-DPID1_MODULE`. Exposes mount, reboot, hostname, peer-
    credential lookup, network ioctls as Elisp functions.
  - **pid1 binary**: PID 1. The supervisor of Emacs.
  - **port_caps**: the function-pointer struct that lets the same
    pid1 source run on two kernels.
  - **shstub**: `/bin/sh` is a tiny stub that forwards `sh -c`
    into eshell via `emacsclient`. No bash, no dash, no busybox.

## Level 2, the major subsystems

Same drawing, expanded. Each region is a directory; each arrow is a
real call path you can grep for.

### Boot path

```
firmware -> GRUB -> kernel -> initrd
                                |
                                v
                         /sbin/init   (Linux: pid1 binary)
                                |     (Hurd: /hurd/startup -> /sbin/init)
                                |
            +-------------------+-------------------+
            v                                       v
       do_mount() x6                          link_current_system()
       (proc sys dev run tmp                  (parse /proc/cmdline
        devpts)                                gnu.system=, symlink)
            |
            v
       port->bring_up_lo()       set_hostname_at_boot()
            |                             |
            v                             v
       sigaction(SIGCHLD)         read_geos_mode()
            |                             |
            +---------------+-------------+
                            v
                     xorg_bring_up()   (UI mode only)
                            |
                            v
                     spawn_emacs()
                            |
                            v
                     supervisor loop:
                       waitpid(-1)
                       respawn emacs
                       respawn Xorg (capped 5/60s)
```

### Inside Emacs, load order

The `-l` chain in the boot gexp dictates this. Earlier files are
dependencies of later ones.

```
emacs --batch -l early-init.el \
              -l core/panic.el \
              -l core/state.el \
              -l core/power.el \
              -l core/use-package-shim.el \
              -l core/port.el          <- the kernel branch knob
              -l core/network.el \
              -l core/hostname.el \
              -l core/supervise.el \
              -l buffers/network.el \
              -l user/multimon.el \
              -l user/fonts.el \
              -l user/input.el \
              -l user/exwm-config.el \
              -l user/userland/*.el \   (8 use-package blocks)
              -l buffers/*.el \         (concept buffers)
              -l services/*.el \        (defservice consumers)
              -l core/boot-marker.el    (supervise-finalize)
```

### Supervisor RPC (v0.6 item 3, v0.7 item 4)

```
   per-user emacs (login session)
            |
            | make-network-process :family local
            |    :service /run/geos/super.sock
            v
   +-------------------------------+
   | supervisor (pid1-as-emacs)    |
   |   Fpid1_rpc_listen creates    |
   |     AF_UNIX socket mode 0600  |
   |   Fpid1_rpc_poll on a 200ms   |
   |     timer:                    |
   |     - accept4 client          |
   |     - port->get_peer_cred()   |
   |        |                      |
   |        +-- Linux: SO_PEERCRED |
   |        +-- Hurd:  ENOSYS,     |
   |             soft-refuse + log |
   |             once per boot     |
   |     - dispatch verb           |
   +-------------------------------+
            |
            v
   verbs:  ping  journal-tail  services-list  reboot  poweroff
```

### State persistence

```
/var/emacs/                           (ext4 with label "geos-var",
                                        tmpfs fallback)
   journal/      *journal* RPC client snapshot
   packages/     guix manifest readout cache
   network/      DHCP leases, last static config
   users/        passwd db + per-user dotfiles
   services/     supervise.el restart counters
   dotfiles/     per-user emacs init
   audit.log     login hardening trail (v0.6 item 5)
```

`state-write` is tmpfile + rename + `pid1-fsync-dir`. The parent
fsync is what makes the rename atomic across crash.

## Level 3, the dual-kernel seam

This is the architectural piece that separates GEOS from any other
"Emacs as desktop" project: the same userland boots on Linux and
on the GNU Hurd. The whole story lives in three places.

### The C seam: `port_caps`

```c
/* pid1/port_layer.h */
struct port_caps {
    const char *kernel_name;                 /* "linux" or "hurd" */
    int  (*mount)(const char *src, const char *tgt,
                  const char *type, unsigned long flags,
                  const char *opts);
    int  (*set_hostname)(const char *name, size_t len);
    int  (*bring_up_lo)(void);
    int  (*set_address)(const char *ifname,
                        const char *addr, int prefixlen);
    int  (*set_route_default)(const char *gateway,
                              const char *ifname);
    int  (*reboot)(int cmd);                 /* RB_AUTOBOOT etc */
    int  (*suspend)(const char *target);     /* "mem", "disk" */
    int  (*get_peer_cred)(int fd, int *uid_out, int *pid_out);
};
extern struct port_caps *port;
```

The boot wires the active backend before any port-> call:

```c
/* pid1/emacs-init.c, main() */
port = &port_linux_impl;       /* or &port_hurd_impl under PORT=hurd */
port_require_or_abort();       /* loud crash on a missing slot */
```

`port_require_or_abort` walks every slot in the struct and aborts
with a `/dev/console` message if any is NULL. That converts a
silent footgun (forgot to register a new slot in the Hurd backend)
into a noisy boot failure.

### The Elisp seam: `core/port.el`

```elisp
;; emacs-init/core/port.el
(defvar geos-kernel
  (intern (or (getenv "GEOS_KERNEL") "linux"))
  "Kernel this Emacs is running on.  'linux or 'hurd.")
```

`pid1` splices `GEOS_KERNEL=<port->kernel_name>` into emacs's envp,
so the elisp side never has to call out to `uname -s` and can branch
deterministically. Files that have to do something kernel-specific
(`core/network.el`, `core/state.el`, `buffers/disks.el`,
`install/disk.el`, `user/userland/uname.el`,
`services/journal-tail.el`, `buffers/journal.el`,
`user/userland/audio.el`, `buffers/audio.el`) factor their Linux
bodies into `*-linux` helpers and dispatch through `geos-kernel`.
Hurd arms either degrade (nil, banner) or signal
`geos-port-unimplemented` until a real backend lands.

### Where the kernels actually differ

| Surface             | Linux               | Hurd                       |
|---------------------|---------------------|----------------------------|
| mount               | `mount(2)`          | `fshelp_start_translator` + `file_set_translator` |
| reboot              | `reboot(RB_*)`      | `host_reboot` Mach RPC     |
| hostname            | `sethostname(2)`    | `sethostname(2)` (POSIX)   |
| bring up loopback   | `SIOCSIFFLAGS`      | pfinet `SIOCSIFFLAGS`      |
| set address         | `SIOCSIFADDR`+      | pfinet, ifname normalized  |
|                     |                     |  bare `eth0` -> `/dev/eth0`|
| set default route   | `SIOCADDRT` rtentry | pfinet `SIOCADDRT ifrtreq_t`|
| suspend             | `/sys/power/state`  | ENOSYS forever             |
| peer credentials    | `SO_PEERCRED`       | ENOSYS, supervisor soft-refuses |
| socket timeouts     | `SO_{RCV,SND}TIMEO` | pflocal returns ENOPROTOOPT, tolerated |
| network device naming| bare `eth0`        | devnode `/dev/eth0`        |
| `/proc`             | linux procfs        | `/hurd/procfs` translator  |
| init mechanism      | `init=` kernel cmdline | `/hurd/startup` execs `/sbin/init`, no init= |

### Build matrix

```
make -C pid1                       Linux build (default)
make -C pid1 PORT=hurd             Hurd build (side branch)
make -C pid1 STATIC=0 module       dynamic module variant
                                   (the .so loaded by Emacs)

link line under PORT=linux:        -lcrypt
link line under PORT=hurd:         -lcrypt -lfshelp -lhurduser -lmachuser

source under PORT=linux:           emacs-init.c + port_linux.c
source under PORT=hurd:            emacs-init.c + port_hurd.c
```

`port_hurd.c` lives only on the `hurd` side branch. Anything from
main that breaks the Hurd build is a side-branch fix, not a main
rollback.

### Verification ladder

Three rungs, because lying to yourself about a port is easy.

```
+-------------------------------------+
| YES on YYYY-MM-DD                   |  invoked on a running kernel,
|                                     |  observed to do the right thing
+-------------------------------------+
| builds on Hurd YYYY-MM-DD           |  compiles + links, ldd -r clean,
|                                     |  body NOT exercised against the
|                                     |  live Mach RPC server
+-------------------------------------+
| NO                                  |  never touched a real kernel
+-------------------------------------+
```

The current per-slot promotion table is `docs/HURD_PORT.md`.
Each promotion to "YES on YYYY-MM-DD" is backed by a sanitized
verification receipt under `docs/runlogs/`. As of 2026-05-17:
mount, set_hostname, bring_up_lo, set_address, set_route_default,
get_peer_cred have all been promoted to YES; reboot still reads
"builds on Hurd 2026-05-17" because the test is destructive to
the VM and is gated on the boot-as-PID-1 milestone.

### What still differs at the OS level

  - **boot mechanism**: Linux uses GRUB + `init=/sbin/init` kernel
    cmdline. Hurd uses GRUB + a multiboot module chain (pci-arbiter,
    acpi, rumpdisk, ext2fs, exec), and `/hurd/startup` is PID 1
    unconditionally; user-mode init is whatever `/hurd/startup`
    `execve`s, which on a stock Debian Hurd is `/sbin/init`. To
    boot emacs-init on Hurd, the install path is "replace
    `/sbin/init`", not "edit the kernel cmdline".
  - **pseudo-filesystem mounts**: Linux pid1 mounts proc/sys/devtmpfs/
    devpts. Hurd has none of those as filesystems; `/proc` is a
    translator (`/hurd/procfs`), `/dev` is real, `/sys` does not
    exist. The Hurd boot path has to skip these or treat the
    syscalls as no-ops.
  - **EXWM**: Hurd ships Xorg but no modesetting DRM analogue.
    The v1.x apt-image flavor of the re-rolled Hurd image runs
    EXWM 0.33 over Xvfb (see v0.9.10); native Xorg on Hurd
    real hardware is tracked separately and is deferred-upstream.
  - **suspend**: Hurd has no analogue. `port->suspend` returns
    ENOSYS forever; the `*audio*` buffer's mixer is the only
    user-facing place that cares, and it degrades to a banner.

## Where to read next

  - `MANIFESTO.md`: the thesis.
  - `INTERNALS.md`: contributor walkthrough, every file in load order.
  - `HURD_PORT.md`: per-slot verification matrix.
  - `HURD_BOOT.md`: what a Hurd-VM operator runs to verify the port.
  - `STATE_LAYOUT.md`: the persistence contract.
  - `ROADMAP.md`: what is unfinished and why.
  - `runlogs/`: dated verification receipts per milestone.

# GNU Free Documentation License

Version 1.3, 3 November 2008

Copyright (C) 2000, 2001, 2002, 2007, 2008 Free Software Foundation,
Inc. <https://fsf.org/>

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.

## 0. PREAMBLE

The purpose of this License is to make a manual, textbook, or other
functional and useful document "free" in the sense of freedom: to
assure everyone the effective freedom to copy and redistribute it,
with or without modifying it, either commercially or noncommercially.
Secondarily, this License preserves for the author and publisher a way
to get credit for their work, while not being considered responsible
for modifications made by others.

This License is a kind of "copyleft", which means that derivative
works of the document must themselves be free in the same sense. It
complements the GNU General Public License, which is a copyleft
license designed for free software.

We have designed this License in order to use it for manuals for free
software, because free software needs free documentation: a free
program should come with manuals providing the same freedoms that the
software does. But this License is not limited to software manuals; it
can be used for any textual work, regardless of subject matter or
whether it is published as a printed book. We recommend this License
principally for works whose purpose is instruction or reference.

## 1. APPLICABILITY AND DEFINITIONS

This License applies to any manual or other work, in any medium, that
contains a notice placed by the copyright holder saying it can be
distributed under the terms of this License. Such a notice grants a
world-wide, royalty-free license, unlimited in duration, to use that
work under the conditions stated herein. The "Document", below, refers
to any such manual or work. Any member of the public is a licensee,
and is addressed as "you". You accept the license if you copy, modify
or distribute the work in a way requiring permission under copyright
law.

A "Modified Version" of the Document means any work containing the
Document or a portion of it, either copied verbatim, or with
modifications and/or translated into another language.

A "Secondary Section" is a named appendix or a front-matter section of
the Document that deals exclusively with the relationship of the
publishers or authors of the Document to the Document's overall
subject (or to related matters) and contains nothing that could fall
directly within that overall subject. (Thus, if the Document is in
part a textbook of mathematics, a Secondary Section may not explain
any mathematics.) The relationship could be a matter of historical
connection with the subject or with related matters, or of legal,
commercial, philosophical, ethical or political position regarding
them.

The "Invariant Sections" are certain Secondary Sections whose titles
are designated, as being those of Invariant Sections, in the notice
that says that the Document is released under this License. If a
section does not fit the above definition of Secondary then it is not
allowed to be designated as Invariant. The Document may contain zero
Invariant Sections. If the Document does not identify any Invariant
Sections then there are none.

The "Cover Texts" are certain short passages of text that are listed,
as Front-Cover Texts or Back-Cover Texts, in the notice that says that
the Document is released under this License. A Front-Cover Text may be
at most 5 words, and a Back-Cover Text may be at most 25 words.

A "Transparent" copy of the Document means a machine-readable copy,
represented in a format whose specification is available to the
general public, that is suitable for revising the document
straightforwardly with generic text editors or (for images composed of
pixels) generic paint programs or (for drawings) some widely available
drawing editor, and that is suitable for input to text formatters or
for automatic translation to a variety of formats suitable for input
to text formatters. A copy made in an otherwise Transparent file
format whose markup, or absence of markup, has been arranged to thwart
or discourage subsequent modification by readers is not Transparent.
An image format is not Transparent if used for any substantial amount
of text. A copy that is not "Transparent" is called "Opaque".

Examples of suitable formats for Transparent copies include plain
ASCII without markup, Texinfo input format, LaTeX input format, SGML
or XML using a publicly available DTD, and standard-conforming simple
HTML, PostScript or PDF designed for human modification. Examples of
transparent image formats include PNG, XCF and JPG. Opaque formats
include proprietary formats that can be read and edited only by
proprietary word processors, SGML or XML for which the DTD and/or
processing tools are not generally available, and the
machine-generated HTML, PostScript or PDF produced by some word
processors for output purposes only.

The "Title Page" means, for a printed book, the title page itself,
plus such following pages as are needed to hold, legibly, the material
this License requires to appear in the title page. For works in
formats which do not have any title page as such, "Title Page" means
the text near the most prominent appearance of the work's title,
preceding the beginning of the body of the text.

The "publisher" means any person or entity that distributes copies of
the Document to the public.

A section "Entitled XYZ" means a named subunit of the Document whose
title either is precisely XYZ or contains XYZ in parentheses following
text that translates XYZ in another language. (Here XYZ stands for a
specific section name mentioned below, such as "Acknowledgements",
"Dedications", "Endorsements", or "History".) To "Preserve the Title"
of such a section when you modify the Document means that it remains a
section "Entitled XYZ" according to this definition.

The Document may include Warranty Disclaimers next to the notice which
states that this License applies to the Document. These Warranty
Disclaimers are considered to be included by reference in this
License, but only as regards disclaiming warranties: any other
implication that these Warranty Disclaimers may have is void and has
no effect on the meaning of this License.

## 2. VERBATIM COPYING

You may copy and distribute the Document in any medium, either
commercially or noncommercially, provided that this License, the
copyright notices, and the license notice saying this License applies
to the Document are reproduced in all copies, and that you add no
other conditions whatsoever to those of this License. You may not use
technical measures to obstruct or control the reading or further
copying of the copies you make or distribute. However, you may accept
compensation in exchange for copies. If you distribute a large enough
number of copies you must also follow the conditions in section 3.

You may also lend copies, under the same conditions stated above, and
you may publicly display copies.

## 3. COPYING IN QUANTITY

If you publish printed copies (or copies in media that commonly have
printed covers) of the Document, numbering more than 100, and the
Document's license notice requires Cover Texts, you must enclose the
copies in covers that carry, clearly and legibly, all these Cover
Texts: Front-Cover Texts on the front cover, and Back-Cover Texts on
the back cover. Both covers must also clearly and legibly identify you
as the publisher of these copies. The front cover must present the
full title with all words of the title equally prominent and visible.
You may add other material on the covers in addition. Copying with
changes limited to the covers, as long as they preserve the title of
the Document and satisfy these conditions, can be treated as verbatim
copying in other respects.

If the required texts for either cover are too voluminous to fit
legibly, you should put the first ones listed (as many as fit
reasonably) on the actual cover, and continue the rest onto adjacent
pages.

If you publish or distribute Opaque copies of the Document numbering
more than 100, you must either include a machine-readable Transparent
copy along with each Opaque copy, or state in or with each Opaque copy
a computer-network location from which the general network-using
public has access to download using public-standard network protocols
a complete Transparent copy of the Document, free of added material.
If you use the latter option, you must take reasonably prudent steps,
when you begin distribution of Opaque copies in quantity, to ensure
that this Transparent copy will remain thus accessible at the stated
location until at least one year after the last time you distribute an
Opaque copy (directly or through your agents or retailers) of that
edition to the public.

It is requested, but not required, that you contact the authors of the
Document well before redistributing any large number of copies, to
give them a chance to provide you with an updated version of the
Document.

## 4. MODIFICATIONS

You may copy and distribute a Modified Version of the Document under
the conditions of sections 2 and 3 above, provided that you release
the Modified Version under precisely this License, with the Modified
Version filling the role of the Document, thus licensing distribution
and modification of the Modified Version to whoever possesses a copy
of it. In addition, you must do these things in the Modified Version:

-   A. Use in the Title Page (and on the covers, if any) a title
    distinct from that of the Document, and from those of previous
    versions (which should, if there were any, be listed in the
    History section of the Document). You may use the same title as a
    previous version if the original publisher of that version
    gives permission.
-   B. List on the Title Page, as authors, one or more persons or
    entities responsible for authorship of the modifications in the
    Modified Version, together with at least five of the principal
    authors of the Document (all of its principal authors, if it has
    fewer than five), unless they release you from this requirement.
-   C. State on the Title page the name of the publisher of the
    Modified Version, as the publisher.
-   D. Preserve all the copyright notices of the Document.
-   E. Add an appropriate copyright notice for your modifications
    adjacent to the other copyright notices.
-   F. Include, immediately after the copyright notices, a license
    notice giving the public permission to use the Modified Version
    under the terms of this License, in the form shown in the
    Addendum below.
-   G. Preserve in that license notice the full lists of Invariant
    Sections and required Cover Texts given in the Document's
    license notice.
-   H. Include an unaltered copy of this License.
-   I. Preserve the section Entitled "History", Preserve its Title,
    and add to it an item stating at least the title, year, new
    authors, and publisher of the Modified Version as given on the
    Title Page. If there is no section Entitled "History" in the
    Document, create one stating the title, year, authors, and
    publisher of the Document as given on its Title Page, then add an
    item describing the Modified Version as stated in the
    previous sentence.
-   J. Preserve the network location, if any, given in the Document
    for public access to a Transparent copy of the Document, and
    likewise the network locations given in the Document for previous
    versions it was based on. These may be placed in the "History"
    section. You may omit a network location for a work that was
    published at least four years before the Document itself, or if
    the original publisher of the version it refers to
    gives permission.
-   K. For any section Entitled "Acknowledgements" or "Dedications",
    Preserve the Title of the section, and preserve in the section all
    the substance and tone of each of the contributor acknowledgements
    and/or dedications given therein.
-   L. Preserve all the Invariant Sections of the Document, unaltered
    in their text and in their titles. Section numbers or the
    equivalent are not considered part of the section titles.
-   M. Delete any section Entitled "Endorsements". Such a section may
    not be included in the Modified Version.
-   N. Do not retitle any existing section to be Entitled
    "Endorsements" or to conflict in title with any Invariant Section.
-   O. Preserve any Warranty Disclaimers.

If the Modified Version includes new front-matter sections or
appendices that qualify as Secondary Sections and contain no material
copied from the Document, you may at your option designate some or all
of these sections as invariant. To do this, add their titles to the
list of Invariant Sections in the Modified Version's license notice.
These titles must be distinct from any other section titles.

You may add a section Entitled "Endorsements", provided it contains
nothing but endorsements of your Modified Version by various
parties—for example, statements of peer review or that the text has
been approved by an organization as the authoritative definition of a
standard.

You may add a passage of up to five words as a Front-Cover Text, and a
passage of up to 25 words as a Back-Cover Text, to the end of the list
of Cover Texts in the Modified Version. Only one passage of
Front-Cover Text and one of Back-Cover Text may be added by (or
through arrangements made by) any one entity. If the Document already
includes a cover text for the same cover, previously added by you or
by arrangement made by the same entity you are acting on behalf of,
you may not add another; but you may replace the old one, on explicit
permission from the previous publisher that added the old one.

The author(s) and publisher(s) of the Document do not by this License
give permission to use their names for publicity for or to assert or
imply endorsement of any Modified Version.

## 5. COMBINING DOCUMENTS

You may combine the Document with other documents released under this
License, under the terms defined in section 4 above for modified
versions, provided that you include in the combination all of the
Invariant Sections of all of the original documents, unmodified, and
list them all as Invariant Sections of your combined work in its
license notice, and that you preserve all their Warranty Disclaimers.

The combined work need only contain one copy of this License, and
multiple identical Invariant Sections may be replaced with a single
copy. If there are multiple Invariant Sections with the same name but
different contents, make the title of each such section unique by
adding at the end of it, in parentheses, the name of the original
author or publisher of that section if known, or else a unique number.
Make the same adjustment to the section titles in the list of
Invariant Sections in the license notice of the combined work.

In the combination, you must combine any sections Entitled "History"
in the various original documents, forming one section Entitled
"History"; likewise combine any sections Entitled "Acknowledgements",
and any sections Entitled "Dedications". You must delete all sections
Entitled "Endorsements".

## 6. COLLECTIONS OF DOCUMENTS

You may make a collection consisting of the Document and other
documents released under this License, and replace the individual
copies of this License in the various documents with a single copy
that is included in the collection, provided that you follow the rules
of this License for verbatim copying of each of the documents in all
other respects.

You may extract a single document from such a collection, and
distribute it individually under this License, provided you insert a
copy of this License into the extracted document, and follow this
License in all other respects regarding verbatim copying of that
document.

## 7. AGGREGATION WITH INDEPENDENT WORKS

A compilation of the Document or its derivatives with other separate
and independent documents or works, in or on a volume of a storage or
distribution medium, is called an "aggregate" if the copyright
resulting from the compilation is not used to limit the legal rights
of the compilation's users beyond what the individual works permit.
When the Document is included in an aggregate, this License does not
apply to the other works in the aggregate which are not themselves
derivative works of the Document.

If the Cover Text requirement of section 3 is applicable to these
copies of the Document, then if the Document is less than one half of
the entire aggregate, the Document's Cover Texts may be placed on
covers that bracket the Document within the aggregate, or the
electronic equivalent of covers if the Document is in electronic form.
Otherwise they must appear on printed covers that bracket the whole
aggregate.

## 8. TRANSLATION

Translation is considered a kind of modification, so you may
distribute translations of the Document under the terms of section 4.
Replacing Invariant Sections with translations requires special
permission from their copyright holders, but you may include
translations of some or all Invariant Sections in addition to the
original versions of these Invariant Sections. You may include a
translation of this License, and all the license notices in the
Document, and any Warranty Disclaimers, provided that you also include
the original English version of this License and the original versions
of those notices and disclaimers. In case of a disagreement between
the translation and the original version of this License or a notice
or disclaimer, the original version will prevail.

If a section in the Document is Entitled "Acknowledgements",
"Dedications", or "History", the requirement (section 4) to Preserve
its Title (section 1) will typically require changing the actual
title.

## 9. TERMINATION

You may not copy, modify, sublicense, or distribute the Document
except as expressly provided under this License. Any attempt otherwise
to copy, modify, sublicense, or distribute it is void, and will
automatically terminate your rights under this License.

However, if you cease all violation of this License, then your license
from a particular copyright holder is reinstated (a) provisionally,
unless and until the copyright holder explicitly and finally
terminates your license, and (b) permanently, if the copyright holder
fails to notify you of the violation by some reasonable means prior to
60 days after the cessation.

Moreover, your license from a particular copyright holder is
reinstated permanently if the copyright holder notifies you of the
violation by some reasonable means, this is the first time you have
received notice of violation of this License (for any work) from that
copyright holder, and you cure the violation prior to 30 days after
your receipt of the notice.

Termination of your rights under this section does not terminate the
licenses of parties who have received copies or rights from you under
this License. If your rights have been terminated and not permanently
reinstated, receipt of a copy of some or all of the same material does
not give you any rights to use it.

## 10. FUTURE REVISIONS OF THIS LICENSE

The Free Software Foundation may publish new, revised versions of the
GNU Free Documentation License from time to time. Such new versions
will be similar in spirit to the present version, but may differ in
detail to address new problems or concerns. See
<https://www.gnu.org/licenses/>.

Each version of the License is given a distinguishing version number.
If the Document specifies that a particular numbered version of this
License "or any later version" applies to it, you have the option of
following the terms and conditions either of that specified version or
of any later version that has been published (not as a draft) by the
Free Software Foundation. If the Document does not specify a version
number of this License, you may choose any version ever published (not
as a draft) by the Free Software Foundation. If the Document specifies
that a proxy can decide which future versions of this License can be
used, that proxy's public statement of acceptance of a version
permanently authorizes you to choose that version for the Document.

## 11. RELICENSING

"Massive Multiauthor Collaboration Site" (or "MMC Site") means any
World Wide Web server that publishes copyrightable works and also
provides prominent facilities for anybody to edit those works. A
public wiki that anybody can edit is an example of such a server. A
"Massive Multiauthor Collaboration" (or "MMC") contained in the site
means any set of copyrightable works thus published on the MMC site.

"CC-BY-SA" means the Creative Commons Attribution-Share Alike 3.0
license published by Creative Commons Corporation, a not-for-profit
corporation with a principal place of business in San Francisco,
California, as well as future copyleft versions of that license
published by that same organization.

"Incorporate" means to publish or republish a Document, in whole or in
part, as part of another Document.

An MMC is "eligible for relicensing" if it is licensed under this
License, and if all works that were first published under this License
somewhere other than this MMC, and subsequently incorporated in whole
or in part into the MMC, (1) had no cover texts or invariant sections,
and (2) were thus incorporated prior to November 1, 2008.

The operator of an MMC Site may republish an MMC contained in the site
under CC-BY-SA on the same site at any time before August 1, 2009,
provided the MMC is eligible for relicensing.

## ADDENDUM: How to use this License for your documents

To use this License in a document you have written, include a copy of
the License in the document and put the following copyright and
license notices just after the title page:

        Copyright (C)  YEAR  YOUR NAME.
        Permission is granted to copy, distribute and/or modify this document
        under the terms of the GNU Free Documentation License, Version 1.3
        or any later version published by the Free Software Foundation;
        with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
        A copy of the license is included in the section entitled "GNU
        Free Documentation License".

If you have Invariant Sections, Front-Cover Texts and Back-Cover
Texts, replace the "with … Texts." line with this:

        with the Invariant Sections being LIST THEIR TITLES, with the
        Front-Cover Texts being LIST, and with the Back-Cover Texts being LIST.

If you have Invariant Sections without Cover Texts, or some other
combination of the three, merge those two alternatives to suit the
situation.

If your document contains nontrivial examples of program code, we
recommend releasing these examples in parallel under your choice of
free software license, such as the GNU General Public License, to
permit their use in free software.
