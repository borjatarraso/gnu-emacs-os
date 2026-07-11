<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# GEOS user guide

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Written and maintained by Borja Tarraso <borja.tarraso@member.fsf.org>.

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".

Day to day use of GNU/Emacs Operating System (GEOS). Assumes you have
already booted the image (see `docs/INSTALL.md` for that). The point of
this document is to answer "I am at the EXWM splash, now what".

## the model in two sentences

The whole OS is one Emacs process. `M-x` is the universal verb; every
system concept is a buffer.

If you remember nothing else from this guide: when you would normally
reach for a terminal command, instead think of which buffer would show
the same data, and `M-x` your way there.

## the very first things to learn

```
M-x eshell                open an eshell (the interactive shell).
M-x processes             *processes* buffer (top-equivalent).
M-x network               *network* buffer (ip-equivalent).
M-x journal               *journal* buffer (dmesg follower).
M-x services              *services* buffer (supervised processes).
M-x disks                 *disks* buffer (df + lsblk equivalent).
M-x packages              *packages* buffer (Guix manifest).
M-x geos-poweroff         shut the box down. there is no /sbin/poweroff.
M-x geos-reboot           restart the box.
C-h k <key>               what does this key do.
C-h f <fn>                show the source of a function.
C-g                       interrupt anything that is wedging the OS.
```

## EXWM keys

These are the only window-manager keys; everything else is regular
Emacs.

```
s-w                       prompt for a workspace by index, jump there.
s-0 .. s-3                jump to workspace N directly.
s-&                       launch a program by exec. no shell.
s-r                       reset EXWM input mode (for X11 apps that
                          eat your keys, e.g. a web browser).
```

The frame is fullscreen by design; there is no floating window
manager. If you want a side-by-side layout, use Emacs windows
(`C-x 2`, `C-x 3`) and put X11 clients in them.

## the shell question

The interactive shell is eshell. It is what you type into and it is the
login shell. A real POSIX shell also lives on the system as `/bin/sh`,
so `./configure`, `make`, and stock GNU packages build the normal way;
eshell is the shell you use, the POSIX shell is what build scripts run
under. (Earlier releases pointed `/bin/sh` at an eshell-forwarding
stub. That broke stock builds and it is being retired.)

What you can do in eshell that you cannot in bash:

  - `(+ 1 2)`. eshell evaluates Lisp at the prompt.
  - pipes that pass Lisp values, not just text bytes.
  - `*foo*`-style buffer-redirection: `ls > #<buffer foo>`.
  - `M-x` from the prompt: just type `find-file` and hit enter.

What eshell does not do (reach for `/bin/sh` when you need these):

  - heredocs. eshell does not have them.
  - `$(())` arithmetic. use `(+ ...)`.
  - process substitution (`<(cmd)`). use a temp buffer.

If you actually need a POSIX shell feature, `/bin/sh` is a POSIX shell,
so run it there. The old `guix-system/exceptions.scm` list (packages
whose post-install scripts the eshell stub could not run) exists to be
emptied now that `/bin/sh` is real.

## the system-concept buffers

Each one is a `special-mode` derivative, read-only by default,
auto-refreshing on a short timer. Press `g` to refresh on demand,
`q` to bury the buffer.

### `*processes*`

The kernel process table, parsed from `/proc/[0-9]+/stat`. Columns:
PID, state, RSS, command. Kill with `k` (sends SIGTERM), force-kill
with `K` (SIGKILL). `RET` on a row opens that PID's `/proc/<pid>/`
directory in dired. Bound to `C-c e p`.

Lives in both the supervisor TTY and the per-user emacs. `/proc` is
world-readable so the user-side renderer walks the same kernel data
the supervisor does, no RPC indirection. A user can signal their own
pids; the kernel rejects the rest. The pid-1 guard refuses to
signal init from this buffer regardless of who owns it.

### `*network*`

Interfaces with addresses, link state, RX/TX counters, plus the
routing table from `/proc/net/route`. The OS brings up loopback
automatically; press `s` for static IPv4 (prompts for address and
gateway, ioctls through `pid1-set-address` + `pid1-set-route-default`)
or `d` for DHCP (one-shot `dhcpcd` via `make-process`). The buffer
refreshes every two seconds.

### `*journal*`

The supervisor's elisp audit log: every RPC event, every supervised-
service state change, every `panic-handle` landing. Tails the
supervisor's `*Messages*` buffer over the v0.7 item 4 RPC channel.
Refreshes every 3 seconds; `g` forces an immediate fetch. Bound to
`C-c e j`.

Keys: `g` refresh, `+` ask for 100 more lines (cap 500, the
supervisor-side clamp), `-` 100 fewer (floor 10), `q` bury. Prefix
arg to `C-c e j` (e.g. `C-u 500 C-c e j`) sets the line count at
open time.

When the supervisor is unreachable (RPC socket gone, timeout) the
header flips to "RPC down" and the last good snapshot stays visible
below an error line. The timer keeps polling; once the supervisor
returns, the next tick repaints.

Note: this is NOT the kernel ring buffer (`/dev/kmsg`). That lives
only on the supervisor side today; a future RPC verb can lift it
user-side without disturbing this view.

### `*services*`

The supervised-process registry from `core/supervise.el`. Every
service registered with `defservice` (journal-kmsg, the DHCP
one-shot, Xorg on Linux and Xvfb on the Hurd apt-image flavor,
sshd on Hurd, plus whatever else userland registers) shows up
here with its restart policy, restart count, and last-death
timestamp. `r`
requests an immediate restart. `D` deregisters (the supervisor will
not respawn it). Xorg is supervised by PID 1 directly, not by this
registry, because it has to come up before Emacs.

User-side rendering as of v0.7 item 4: bound to `C-c e s`. The
client polls the supervisor's `services-list` RPC verb every 3
seconds and shows name, status, pid, kind, restart count, uptime.
Read-only on the user side: `r` and `D` work only from the
supervisor's TTY because they mutate the registry. When the RPC is
down the buffer keeps the last good snapshot visible and flips its
header to "RPC down".

### `*disks*`

Block devices from `/proc/partitions` plus mounts from
`/proc/mounts`. No shell-out to `df` or `lsblk`.

### `*packages*`

The active Guix profile, rendered from the on-disk manifest. Read-only;
to actually change package state you reconfigure the system through
the `*reconfigure*` buffer (`M-x reconfigure`).

### `*users*`

The live UI for `/etc/passwd` and `/etc/shadow`. Columns: user, uid,
gid, home, shell, pw (set / locked), login (per-uid session count).
Keys:

```
a   add a user. prompts for name, uid (default next free), gid,
    home, shell, and password. password is read twice and stored
    via the libcrypt hash; an empty password leaves the account
    locked.
d   delete the user on the current line. refuses uid 0. offers to
    remove the home directory (default n: a stale dir is cheap, a
    home dir lost to a typo is not).
p   set the password for the user on the current line.
u   clear the lockout file for the user on the current line.
    v0.6 item 5.3: 10 bad login attempts against one username inside
    5 minutes write /var/emacs/lockouts/NAME with a :locked-until
    expiry; this key unlocks early.
g   refresh.
q   bury.
```

### `*audio*`

The ALSA mixer surface. Open it with `M-x audio` or `C-c e a`. The
header line shows the default card, the default mixer control, the
last commanded volume, and the count of playback streams visible in
`/proc/asound/pcm`. The body lists every card from
`/proc/asound/cards` as `index  model`; RET on a row makes that card
the default sink for subsequent volume actions.

Keys:

```
+/= volume up 5%. fires amixer -c CARD sset CONTROL N% via
    make-process. the header reflects the commanded value;
    there is no readback (a per-tick amixer get is a fork per
    tick, no thanks).
-   volume down 5%.
m   mute toggle. amixer sset ... toggle.
n   cycle the default card to the next visible one. wraps.
RET pick the card on the current line as the default sink.
g   refresh (re-read /proc/asound/cards and pcm).
q   bury.
```

Defaults: control `Master`, card `default` (whatever the kernel
chose as card 0). The defcustom is `audio-default-control` /
`audio-default-card` if a USB card only exposes `PCM` and not
`Master`.

The `*audio*` buffer runs in the per-user emacs, not the supervisor:
a stuck amixer call (e.g. an unresponsive USB card) stalls one
user-session, not PID 1. Volume does not persist across logout; ALSA
state lives under `/var/lib/alsa/` and a future ergonomic pass
folds it into per-user state.

## logging in and out

The first thing on screen at boot is `*login*`. Type the username,
RET, type the password, RET. On success the supervisor spawns a
per-user Emacs and the *login* surface flips to "session active as
NAME pid N"; press `q` to log out, which sends SIGTERM and returns
to the username prompt.

Defenses on the *login* surface:

  - Global throttle: 5 bad attempts inside 60 seconds locks the
    buffer for the rest of the window. Mashing `r` to retry eats
    the same rate limit (5 second sit-for stall per attempt once
    the cap trips).
  - Per-user lockout: 10 bad attempts against ONE username inside
    5 minutes writes `/var/emacs/lockouts/NAME` with a 15 minute
    expiry. The verify path refuses without hashing while the
    lockout is active. An admin can clear it via the `u` key in
    *users*, or the user can wait it out.
  - Last-login footer: the username prompt shows
    `last login: NAME @ TIMESTAMP` from the most recent successful
    record in the audit log. A fresh image with no auth log yet
    shows nothing.

### concurrent sessions

GEOS can host more than one logged-in user at a time. Workspace
0 belongs to the supervisor (this is where *login* draws); each
logged-in user lands on their own EXWM workspace, starting at 1
and counting up. The cap is three concurrent users (workspaces
1, 2, 3). Past that, a fourth login spawns without a workspace
stamp and the per-user window lands on whatever workspace EXWM
picks; log somebody out first.

The session-active view of *login* prints the workspace number
under `child pid`. When that line says `(unassigned, EXWM hook
has not fired yet)`, the supervisor has not yet seen the X
window land; this is a sub-second race on a real boot, longer
under heavy load.

Keys on the session-active view:

  - `q`  log out THIS session (SIGTERM, then return to the
         username prompt).
  - `n`  start a fresh login WITHOUT ending the current session.
         The prior user keeps running on their workspace; the
         multi-session footer lists them so you remember.
  - `s`  switch to a running session's workspace. Auto-picks
         when only one other session is live; otherwise prompts
         with completion against the running registry.

The active-sessions footer (on both the username prompt and the
session-active view) lists every 'running session with name,
pid, and workspace. Empty registry prints no footer (no "0
sessions" noise on a fresh boot).

A logout of one user does NOT disturb the others: only that
user's child receives SIGTERM, only that user's workspace
becomes free for reuse, and *login* re-appears only when no
session remains running. The freed workspace is sticky on
relogin: if the same user comes back before the slot is
reassigned, they land on their old workspace number.

### the audit log

Every login outcome appends one sexp line to
`/var/emacs/journal/auth.log`. Shape:

```
((time . "2026-05-12T10:00:00Z") (user . "alice") (result . :ok))
((time . "2026-05-12T10:00:01Z") (user . "alice") (result . :fail)
 (reason . :wrong-password))
```

Reasons used today: `:wrong-password`, `:throttled`, `:locked-out`,
`:spawn-failed`, `:spawn-raised`. To investigate after the fact:

```
M-x find-file RET /var/emacs/journal/auth.log RET
```

On a tmpfs root the file vanishes on reboot; the *journal* header
prints `state: tmpfs` so you know. For persistence across reboots,
format a partition as ext4 with label `geos-var`.

## file management

`M-x dired` for the current directory, `C-x C-f /path/` to open one.
EXWM does not bundle a separate file manager because dired already
covers everything a file manager would. `M-x dired-jump` (`C-x C-j`)
opens dired on the current buffer's file.

## mail, news, web, git

```
M-x notmuch               mail.
M-x erc                   IRC.
M-x eww                   web browser.
M-x magit-status          git, in the current repo.
```

These are real packages with their own documentation; `C-h i d m
<name> RET` for the manual.

## the panic buffer

When something raises an Elisp error, the message lands in `*panic*`
instead of dying or popping a backtrace. To inspect:

```
M-x panic-show            jump to the *panic* buffer.
g                         clear the buffer.
```

The buffer is also where boot-marker writes its sentinels; if a smoke
test failed you can grep here for `geos:` lines.

If `*panic*` is empty after a session you spent debugging something,
that is not necessarily a clean session: an error caught by an
explicit `condition-case` will only land here if the handler called
`panic-handle`. Reach for `*Messages*` if you suspect a swallowed
error.

## the freeze you will eventually hit

Emacs is single threaded. A stuck regex, a TRAMP call to a black hole,
a runaway `(while t)` will wedge the entire OS until either:

  - you hit `C-g` and the loop honors it, or
  - the watchdog (anything wrapped in `with-timeout`) fires, or
  - you reset the QEMU window from the host.

There is no way around this short of writing a different OS. The
panic buffer mitigates the case where elisp raises an error; it does
not save you from a tight loop in C-level code. See `MANIFESTO.md`
section "the failure mode I accept".

When this happens to me on bare hardware (it has not yet), I will plug
in a USB serial and reach in via the `*journal*` buffer over there. I
do not have a better answer.

## boot modes

Two modes, picked at GRUB time:

  - `geos.mode=ui`. The default. Xorg + EXWM. What you want on a
    laptop or desktop with a screen.
  - `geos.mode=console`. No Xorg. Emacs on the kernel framebuffer
    console with `TERM=linux`. What you want on a serial-console
    headless box.

Edit the kernel cmdline at the GRUB menu (press `e`, find the line
starting `linux /gnu/store/...`, change the token, `Ctrl-x` to boot)
to switch for one boot. To make it permanent, edit `kernel-arguments`
in `guix-system/system.scm` and rebuild the image.

## shutting down

```
M-x geos-poweroff         sync, reboot(2) with RB_POWER_OFF.
M-x geos-reboot           sync, reboot(2) with RB_AUTOBOOT.
```

Both go through the pid1 dynamic module, which holds `CAP_SYS_BOOT`.
There is no `/sbin/poweroff` to call out to, no socket protocol, no
`sudo`. The supervisor is Emacs; the answer to "shut down" lives in
this Emacs.

If `geos-poweroff` returns nil, the call did not reach the syscall;
check `*panic*`. Most likely the dynamic module did not load
(`PID1_MODULE_PATH` was empty in the env, which only happens if you
ran emacs by hand outside the boot path).

## customizing

There is no `~/.emacs.d/init.el` for you. The userland is the boot
gexp; to change it you edit a file in `emacs-init/` and rebuild the
image. The `*reconfigure*` buffer (`M-x reconfigure`) is
the in-system path for `guix system reconfigure`-style changes.

For one-off tweaks during a session, `M-x eval-expression` (`M-:`) and
write some Lisp. The change lasts until the next reboot.

## getting help

`C-h` is your friend. In particular:

```
C-h k <key>               describe a key chord.
C-h f <function>          describe a function (with source).
C-h v <variable>          describe a variable.
C-h i                     the Info browser. emacs's manual is here.
```

For GEOS-specific things, the source under `emacs-init/` is the
documentation. Every file starts with a one-line description and
inline comments explain the why.

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
