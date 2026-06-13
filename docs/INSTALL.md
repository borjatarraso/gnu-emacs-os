<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->

# installing GNU/Emacs Operating System (GEOS)

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Written and maintained by Borja Tarraso <borja.tarraso@member.fsf.org>.

Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts.
A copy of the license is included in the section entitled "GNU
Free Documentation License".

This document covers the v1.0.0 release.  GEOS runs on a Linux host
via a Guix-built qcow2, and on canonical Debian GNU/Hurd 0.9 via
the `iso-build/hurd-image-reroll.sh` derivative.  I have tested
both in QEMU.  Real desktop-class hardware testing has been done
on a small set of x86_64 laptops.  If you put this on a laptop
and it eats your filesystem I will take the bug report but I will
not be surprised.

## what you need

  - A Linux host with KVM available (`/dev/kvm` readable by your user).
  - Guix installed, daemon running. Any version Guix itself supports
    `time-machine` on works, the channel pin does the rest.
  - About 8 GB of free space in `/gnu/store` for the build closure.
    The ISO itself is 1.57 GB.
  - QEMU with `qemu-system-x86_64`.

I build on a Fedora 43 host with a stock `guix` installation. Other
hosts should work, the Guix daemon hides the host distribution from
the build.

## the channel pin

The current pin is Guix commit
`230aa373f315f247852ee07dff34146e9b480aec`, carried forward unchanged
from v0.1 through v1.0.0. This is non-negotiable inside a release. The ISO is reproducible byte-for-byte (modulo
kernel build-id) against that pin and only against that pin. Bumping
it is a release-cut concern, not a per-patch one.

The pin lives in two files that must agree:

  - `guix-system/channels.scm`
  - `iso-build/channels.scm`

Both contain a `%guix-pin` binding, so a `grep -R %guix-pin` is the
sanity check.

## building the ISO

From the repo root:

```
cd iso-build
guix time-machine -C channels.scm -- \
    system image -L .. build.scm
```

The `-L ..` puts the repo root on `%load-path` so `build.scm` can find
`guix-system/system.scm`. Without it the build fails with a "cannot
find" error from `build.scm` itself, which is the failure mode I want.

The build takes about thirty minutes on a cold cache, two minutes on a
warm one. The final line of output is a `/gnu/store/...-image.iso`
path. That is the ISO.

For reference, my last build produced:

```
/gnu/store/1qljm6g1lhfdcybl5zzaji781q5qk3ah-image.iso  (1.57 GB)
```

If you get a different store hash with the same pin, something has
drifted. File a bug, do not just shrug and ship.

## booting the ISO

There is a harness script:

```
./iso-build/qemu-harness.sh /gnu/store/1qljm6g...-image.iso
```

It runs:

```
qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -cpu host \
    -smp 2 \
    -vga virtio \
    -display gtk \
    -device qemu-xhci,id=xhci \
    -device usb-tablet,bus=xhci.0 \
    -serial mon:stdio \
    -boot d \
    -cdrom <ISO>
```

A few notes on those flags. 2 GB of RAM is the floor. With less, Emacs
starts swapping during `exwm-enable` and the boot looks hung. `-vga
virtio` is mandatory: the operating-system record's xorg config binds
the modesetting driver against `/dev/dri/card0`, which only exists when
the guest sees a virtio_gpu device. `-vga std` will boot but Xorg dies
at AddScreen and you get a black window. The usb-tablet on a dedicated
xhci bus gives an absolute pointer (no pointer-grab dance) and lands
on `/dev/input/event4` where xorg-modesetting.conf is configured to
find it. Without it the X session has a keyboard but no mouse.
`-serial mon:stdio` is how you see PID 1's writes to `/dev/console` in
your terminal, which is the only debug surface during early boot.

Boot takes about eleven seconds from `qemu` invocation to the EXWM
splash. The first thing you see on the kernel framebuffer is the boot
log. The second thing is Emacs.

## boot modes: UI vs console

GEOS supports two boot modes. The mode is picked at GRUB time via the
`geos.mode=` kernel cmdline token, which PID 1 reads from
`/proc/cmdline` before it spawns Xorg.

  - `geos.mode=ui` (the default, baked into the image's
    `kernel-arguments`, also what you fall back to if the token is
    absent or malformed). PID 1 spawns Xorg with the modesetting
    driver against `/dev/dri/card0`, then spawns Emacs with
    `DISPLAY=:0` so Emacs comes up as an X client and EXWM grabs the
    root window. `s-&` launches X clients, the frame is fullscreen.
    This is the standard graphical session.
  - `geos.mode=console`. PID 1 skips Xorg entirely and spawns Emacs
    on `/dev/console` with `TERM=linux`. No X server, no EXWM, no
    GUI. The session is the kernel framebuffer console with Emacs
    filling it. `M-x eshell` for the shell, all the system buffers
    (`*processes*`, `*network*`, `*journal*`, `*services*`,
    `*disks*`, `*packages*`) work exactly like they do in UI mode.
    This is the right mode for a serial-console headless box, an SSH-
    equivalent session, or just doing all your work in a framebuffer
    Emacs.

To pick the mode at boot, hit `e` at the GRUB menu, find the line that
starts with `linux /gnu/store/...`, and replace `geos.mode=ui` with
`geos.mode=console` (or vice versa) at the end of that line. Press
`Ctrl-x` (or `F10`) to boot. The choice persists for that boot only;
the next reboot reverts to whatever the GRUB entry has baked in. To
make the choice permanent, edit the token in `kernel-arguments` in
`guix-system/system.scm` and rebuild the image.

The boot log echoes the chosen mode as one of:

```
pid1: geos.mode=console, skipping Xorg, emacs on /dev/console
pid1: geos.mode=ui, will spawn Xorg + EXWM
```

A missing or unrecognized value defaults to UI. An unknown value
also logs a warning so you can see what the operator typed.

## fast iteration with the qcow2 image

For development I build a qcow2 instead of an ISO. The qcow2 boots
faster and has a writable root, so I can edit `init.el`, restart Emacs
with `C-x C-c` (the C wrapper respawns it), and see the change in the
same VM session.

```
cd guix-system
guix time-machine -C channels.scm -- \
    system image -t qcow2 system.scm
```

Last good qcow2:

```
/gnu/store/vm6rsd5a9ifr63a3c74isc1zbxvadrrl-image.qcow2
```

Boot it the same way the harness boots the ISO, swap `-cdrom` for
`-drive file=...,format=qcow2` and drop `-boot d`.

## installing GEOS onto a real disk (the MVP wizard)

GEOS now ships an in-Emacs install wizard. It is the v0.4 item 3 MVP:
it does NOT partition disks. The operator is expected to pre-
partition the target from a Guix live ISO (one ext4 partition is
enough for a non-encrypted install), then boot GEOS from any working
medium (qcow2, USB stick, network boot) and run the wizard.

Pre-partitioning from a Guix live ISO:

```
parted /dev/sda mklabel msdos
parted /dev/sda mkpart primary ext4 1MiB 100%
parted /dev/sda set 1 boot on
```

Reboot into GEOS. Then:

```
M-x install
```

The `*install*` buffer walks five states:

  1. `:welcome`, press `RET` to start, `q` to bail.
  2. `:disk-pick`, `n`/`p` navigate, `g` refresh,
     `RET` picks. Disks with a mounted partition are flagged `MNT`
     and refused.
  3. `:part-pick`, same navigation, `RET` picks a partition.
     Mounted partitions are refused.
  4. `:format-confirm`, `y` to format the partition as ext4 with
     label `geos-root` and proceed, `n` to back up.
  5. `:format` → `:mount` → `:copy` → `:grub` → `:done`. The wizard
     spawns `mkfs.ext4`, `pid1-mount`s the new partition at
     `/mnt/install`, copies `/gnu/store`, `/var/guix`, and
     `/run/current-system` with `cp -a`, then runs `grub-install`
     and `grub-mkconfig`. On `:done` press `r` to reboot.

Total wall-clock time is dominated by the copy step. A ~6 GB closure
takes a couple of minutes on SATA, half an hour on USB 2.

Per-step output streams into hidden work buffers
(`*install:mkfs:DEVICE`*, `*install:copy*`, `*install:grub*`) for
debugging. On any failure the wizard moves to `:error`, names the
failing step, and lets you press `RET` to restart at `:welcome`.

The wizard does not partition. It does not write an ESP. It does
not encrypt. Partition-from-scratch and the UEFI/ESP layout are
v0.4.1. LUKS is a separate manual flow, documented next.

## installing with an encrypted root (LUKS)

Bare-metal GEOS can boot from a LUKS-encrypted root. The flow piggy-
backs on Guix's stock initrd, which already knows how to prompt on
`/dev/console` for a passphrase and unlock a `mapped-device`. No
custom initrd helper is required.

The exact edits to `guix-system/system.scm` live in
`guix-system/system-luks-snippet.scm`. The high-level steps:

1. Boot a Guix live ISO on the target hardware.

2. Format the target partition as LUKS2 and record its UUID:

   ```
   cryptsetup luksFormat --type luks2 /dev/sdaN
   cryptsetup luksUUID /dev/sdaN
   ```

3. Open it once so you can put a filesystem inside:

   ```
   cryptsetup open /dev/sdaN geos-root
   mkfs.ext4 -L geos-root /dev/mapper/geos-root
   ```

4. Mount `/dev/mapper/geos-root` at `/mnt`. Copy your edited
   `system.scm` (with the three edits from
   `system-luks-snippet.scm`: `mapped-devices`, `file-systems`
   pointing at `/dev/mapper/geos-root`, and `initrd-modules`
   extended with `dm-crypt aes aes_generic xts sha256_generic`).

5. Replace `LUKS-UUID-HERE` in `mapped-devices` with the UUID you
   captured in step 2.

6. Run `guix system init /mnt/etc/system.scm /mnt`. This populates
   `/gnu/store` on the new root, writes the bootloader, and exits.

7. Reboot. GRUB hands off to the kernel, the initrd prompts you for
   the LUKS passphrase on `/dev/console`, the mapper device opens,
   root mounts, PID 1 (`emacs-init`) takes over.

Caveats:

  - Detached headers are out of scope for v0.4. The header stays on
    the encrypted partition.
  - Passphrase only. No key-file, no escrow, no TPM-sealed unlock.
  - On a libre-only laptop with no AES-NI the boot is slower but
    workable. XTS-AES at 256 bits is the default.
  - Unlocking additional LUKS volumes (data partitions, external
    drives) from inside running GEOS is a v0.5 follow-up. v0.4 only
    covers the root.
  - The bare-metal install wizard (v0.4 item 3 MVP) handles the
    non-encrypted flow now. LUKS layering on top of it is v0.5: the
    wizard would need a passphrase prompt and a `cryptsetup
    luksFormat` step before `mkfs.ext4`. For LUKS in v0.4, steps
    2-6 above stay manual.

QEMU smoke tests do NOT exercise this path. `system.scm` ships
without `mapped-devices` so the headless test stays simple. The
LUKS path is opt-in by edit.

## what to do once it boots

You land in EXWM with a single Emacs frame, four virtual workspaces,
and an xterm started as a smoke-test canary on workspace 0. Useful
keys:

```
s-w               switch workspace by index
s-0..s-3          jump to workspace N
s-&               launch a program (no shell, just exec)
s-r               reset EXWM input mode if an X11 app eats your keys
M-x network       open the *network* buffer
M-x processes     open the *processes* buffer
M-x geos-poweroff sync, reboot(2) with RB_POWER_OFF, qemu exits
M-x geos-reboot   sync, reboot(2) with RB_AUTOBOOT
```

`M-x eshell` is the shell. There is no other shell. If you instinctively
type `bash` and hit enter, the shstub will route it back into another
eshell, which is funny once and annoying after that. From eshell,
`uname -a` prints `GEOS lambda <release> <version> <machine> GNU/Emacs
(Linux)`. The kernel's compile-time `Linux` string stays correct in the
parens at the end; nothing in the profile calls `uname(2)` for
user-visible output.

Power off the VM with `M-x geos-poweroff`. There is no
`/sbin/poweroff`, no `sudo`, no socket protocol. The supervisor IS
Emacs, so the answer to "shut down" lives in this Emacs and goes
straight to `reboot(2)`. The QEMU window closes when the syscall
succeeds.

## verifying the build

Two scripts run before any commit, three before any release:

  - `/attribution-scan` greps the repo for forbidden tokens. Empty
    output means pass.
  - `/no-shell-check` greps for code paths that invoke a POSIX shell.
    Empty output means pass. The documented exceptions are listed in
    `guix-system/exceptions.scm`.

`/smoke-test` boots a qcow2 headlessly with the serial console wired
to a tmpfile and greps for pid1, userland, /var, state, and supervise
success markers (plus a failure-marker fast-fail set). Catches the
class of regression that wedged v0.3 boot once already (an xorg.conf
parse error -> Xorg respawn loop -> no DISPLAY -> EXWM never came
up). Run it after any change to `pid1/`, `guix-system/`, or anything
Xorg-adjacent. Implementation lives at `iso-build/smoke-test.sh`;
exit codes are 0 pass, 1 fail (with the matched marker and the last
30 serial lines printed), 2 timeout.

`/freeze-test` runs the abuse suite against a booted VM (runaway loops,
catastrophic regex, a literal `(kill-emacs)` call, a service that
trips the supervise.el respawn cap) and confirms the panic buffer
keeps the OS interactive.

## known broken things

  - Real hardware. Not tested. Part of the v0.4 meta-task.
  - Audio. The kernel modules are present but nothing in Elisp talks
    to them yet. v0.4 item 8.
  - Bluetooth. Punted to v0.5+.
  - Wayland. Not in scope. EXWM is X11 by definition.
  - Multi-user. The system has one user, named `me`. v0.4 item 4.

## reporting a bug

`/freeze-test` output, `*panic*` buffer contents, the exact ISO store
hash, and the QEMU invocation that reproduced it. I cannot do anything
useful without all four.

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
