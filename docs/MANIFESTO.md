<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# GNU/Emacs Operating System (GEOS)

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Written and maintained by Borja Tarraso <borja.tarraso@member.fsf.org>.

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".

I have been using Emacs since 2006. Most of what I do on a computer
already happens inside it: code, mail, IRC, news, git, shell, PDFs,
the calendar, the file manager. The pattern of my day is "switch to
Emacs, do the thing, switch back to whatever the OS makes me put up
with for the bits Emacs cannot reach". This project is me getting
tired of that last clause.

So I built an operating system where Emacs is the userland and Emacs
is PID 1. Short name is GEOS, full name is GNU/Emacs Operating
System; the rest of this document uses GEOS.

## the thesis

Emacs is not an editor that runs on an OS. Emacs IS the OS.

The kernel (Linux today, the Hurd if I live long enough) provides
hardware abstraction. Everything above the kernel is Elisp. Process
supervision, the shell, the window manager, the network UI, the
package manager UI, the journal, the disk inspector, all of it lives
in buffers, written in the same language, evaluable at runtime,
introspectable with `C-h f`.

The first userspace process the kernel starts is a tiny C program
that mounts the pseudo-filesystems, reaps zombies, sets the hostname,
and then `execve`s Emacs. The same C source compiles a second time as
an Emacs dynamic module, loaded by `early-init.el`, so the supervision
code lives inside the Emacs process itself. There is no Shepherd. There
is no systemd. There is no `/etc/init.d`. The supervisor is Elisp and
the supervisor is the thing being supervised. If that sentence makes
you uncomfortable, good, it should.

## why

Because every OS I have used pretends my workflow ends at the prompt.
GNOME wants me in nautilus. KDE wants me in konsole. macOS wants me
in Finder. I do not want to be in any of those. I want to be in a
buffer. I want `M-x` to be the universal verb of my computer.

Because the Unix philosophy was right about composition and wrong
about boundaries. The shell pipeline is a Lisp expression with worse
syntax and no debugger. Once you accept that, the question stops being
"how do I integrate Emacs better with my system" and starts being "why
is there anything outside of Emacs at all".

Because Stallman sketched something like this years ago, in a footnote,
and I wanted to see if it was actually possible. Turns out it almost is.

## the shell, and where i changed my mind

Eshell is the interactive shell. It is the login shell, it is what
`M-x` reaches for, it is what you type into. It has lambdas and hash
tables and a debugger and structured data, and it is the same thing I
get everywhere else in Emacs. That part of the thesis is not moving.

The part that moved: for a long time `/bin/sh` here was a 50 line C
stub that turned `sh -c "<cmd>"` into an `emacsclient` call routed
through eshell, and I told myself that was the point, that I did not
want a POSIX shell on my system at all. That was wrong, and building
GNU software is what showed me it was wrong. `./configure` is a POSIX
shell script. `make` runs its recipes through `/bin/sh`. If `/bin/sh`
is not a real POSIX shell then GNU Hello does not build, autoconf does
not run, and the "operating system" cannot do the most ordinary job a
GNU system has, which is compile a GNU package from source. An OS that
cannot build its own software is a demo, not an OS.

So `/bin/sh` is a real POSIX shell now. Eshell stays exactly where it
was, as the shell I live in; the POSIX shell sits underneath for
scripts and builds, the way it does on any other system. The
distinction I actually care about was never "no POSIX shell exists", it
was "the interactive and administrative surface is Emacs". That
distinction survives intact. I just stopped pretending the build
toolchain could run inside eshell.

The old exceptions list in `guix-system/exceptions.scm` (packages whose
post-install scripts wanted heredocs or `$(())` the stub could not give
them) exists to be deleted now. A real `/bin/sh` has the right mouth
shape for all of it.

## the failure mode I accept

Emacs is single threaded.

A stuck regex in any code path stalls the OS. A slow TRAMP connection
stalls the OS. A runaway `while t` stalls the OS. The panic buffer
catches errors raised through `condition-case`, and the supervisor
restarts services that die, but neither of those mechanisms saves you
from a tight loop in C-level code or a network call with no timeout.

This is a known design constraint, not a bug. I am not going to fight
it by introducing threads or async runtimes or any of the patterns that
would turn this project into something other than what it is. If I
wanted concurrency I would not have started with Emacs.

What I do instead: every long-running operation goes through
`make-process` with a sentinel. Every regex on user input has a length
cap. Every network call has an explicit timeout. The `*panic*` buffer
gets the most aggressive test suite in the repo (`/freeze-test`), and
every release blocks on it surviving deliberate abuse including a
literal `(kill-emacs)` call.

I lose maybe one session a week to a freeze I have to recover from in
QEMU. I am fine with that ratio. You may not be. That is a real reason
to not use this OS.

## what is in GEOS today (v1.0.0)

  - PID 1 is a C binary that becomes Emacs and then loads itself back
    in as an Emacs module so the reaper, the mount helper, the
    hostname call, the reboot syscall, and the signal handlers live
    inside the Emacs process.
  - The panic buffer catches every uncaught Elisp error and refuses to
    let Emacs exit. The freeze-test suite abuses it on every release.
  - eshell is the interactive shell. `/bin/sh` is a POSIX shell so
    stock `./configure` and `make` builds work; the earlier
    eshell-forwarding stub is being retired (see "the shell, and where
    i changed my mind" above). `uname -a` reads
    `GEOS lambda <release> ... GNU/Emacs (Linux)` on Linux and
    `GNU/Emacs (Hurd)` on canonical Debian GNU/Hurd 0.9.
  - EXWM with the modesetting Xorg driver. Real keyboard and mouse in
    QEMU on Linux. EXWM 0.33 over Xvfb on canonical Debian GNU/Hurd
    0.9 (`v0.9.10`). X11 windows are buffers. Console mode
    (`geos.mode=console`) is also supported for headless boxes.
  - `M-x geos-poweroff` and `M-x geos-reboot` go through `reboot(2)`
    on Linux and `host_reboot` via `get_privileged_ports` on Hurd,
    both via the pid1 module. There is no `/sbin/poweroff` to call;
    the supervisor IS Emacs and the answer to "shut down" lives in
    elisp.
  - Persistent state under `/var/emacs/`: atomic writes via tmpfile
    + rename + `pid1-fsync-dir`, ext4 (`geos-var` label) or tmpfs
    fallback. The contract is `docs/STATE_LAYOUT.md`.
  - First-class service supervision in Elisp: `core/supervise.el`
    with the `defservice` macro, restart policies, a rolling 60s
    respawn cap, and persisted restart counters.
  - Multi-user: SO_PEERCRED-on-Linux + `auth_server_authenticate`
    peer-cred handshake on Hurd; login audit, throttle, lockout,
    last-login footer, concurrent sessions with isolation.
  - System concepts have buffers: `*processes*`, `*network*`,
    `*journal*`, `*services*`, `*disks*`, `*packages*`, `*users*`,
    `*audio*`, `*install*`. Each has a major mode, sensible
    keybindings, and a refresh timer.
  - End-to-end SSH on canonical Debian GNU/Hurd 0.9 (`v0.9.12`):
    `host ssh -p 2266 root@127.0.0.1` opens an interactive session
    against the supervised emacs.
  - Install wizard live-verified on Hurd (`v0.9.23`): `mkfs.ext4`
    and `grub-install` end-to-end PASS through the elisp wrappers
    on canonical Hurd against a second IDE disk.
  - Port seam (`port_caps`): every Linux-only syscall in `pid1/`
    routes through a function-pointer struct with `port_linux.c`
    and `port_hurd.c` backends. STATIC=1 builds inline the
    supervisor primitives into a statically linked `emacs-init`
    binary with zero dynamic deps.
  - The whole thing builds reproducibly from a pinned Guix channel
    on Linux and rolls into a derivative of the canonical Debian
    GNU/Hurd 0.9 image via `iso-build/hurd-image-reroll.sh`.

## what is not in GEOS yet

Real desktop-class hardware (testing has been QEMU + a small set
of x86_64 laptops). Audio on Hurd waits on either a native
`/hurd/audio*` translator or pulseaudio with a working sink (the
v1.x apt-image flavor bundles pulseaudio userland; real-hardware
audio on Hurd is deferred-upstream because Hurd ships no ALSA or
OSS translator). Bluetooth. Anything Wayland.

These are real and tracked. v0.1 proved the thesis that Emacs as
PID 1, no Shepherd, no shell, actually holds together. v0.2
through v0.7 fleshed out the Linux daily driver (input, multi-user,
EXWM polish, supervisor RPC). v0.8 through v0.9.24 ported pid1
and the userland to canonical Debian GNU/Hurd 0.9 end-to-end. v1.0.0
is the state declaration: Emacs as PID 1 on both kernels, multi-user
EXWM session on both, every row of `docs/HURD_PORT.md` YES modulo
two upstream-translator gaps documented in-tree.

## relationship to GNU

Guix System is the base. Linux-libre is the kernel. The userland tools
that I do call out from Elisp (`ip`, `ps`, `df` for parsing, never for
display) come from GNU coreutils and iproute2 in the Guix profile.

I am not affiliated with the FSF or with the Guix project. I am a user
of both. If anyone there wants to fold pieces of this work upstream I
would be happy to talk. If they want to tell me the whole approach is
heretical I will listen and then keep building.

## who this is for

People who already live in Emacs and want to stop pretending the rest
of the system is a separate concern. People who think a reproducible
desktop is worth more than a polished one. People who can read a
backtrace and are not scared off by the words "kernel panic in QEMU".

If that is not you, this is not your OS. That is fine. Use what makes
you happy. I am using this.

## the name

It is GNU/Emacs Operating System, GEOS for short. The slash in
GNU/Emacs is mandatory. I am not making the joke you think I am
making. I am making a different joke that happens to land in the
same place.

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
