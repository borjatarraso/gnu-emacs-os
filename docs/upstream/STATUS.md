<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->
<!-- voice: first person singular, lowercase, no em-dashes. -->

# upstream filings: status

snapshot of where the eight emails in `emails/` stand after hitting
their lists.  pair this with `HOW-TO-SEND.md` (the recipe for
filing) to understand the full lifecycle.  last updated 2026-06-01.

short summary: all eight on-list.  of the eight: one (01
emacsclient) closed with an accept-and-broaden verdict; one (06
evdev) closed with a no-engagement; one (08 ext2fs pager
assertion) just sent today, awaiting on-list response; the other
five drew substantive on-list reactions earlier in this cycle.
no GEOS-side code change is required by anything received so
far.  the reactions unlock future work but do not force
present-day work.

this file deliberately stays at the level of "where does the thread
stand and what does it mean for GEOS".  the actual on-list
exchanges live in the public archives; I link them per thread
below.  I do not reproduce email content (mine or anyone else's)
in this file.  per-message detail with IDs and labels lives in
operator notes outside the repo.

## per-thread

### 01 emacsclient SO_RCVTIMEO patch

  - list: bug-gnu-emacs
  - debbugs entry: https://debbugs.gnu.org/cgi/bugreport.cgi?bug=81160
  - archive: https://lists.gnu.org/archive/html/bug-gnu-emacs/2026-05/

  why I filed it: silencing a long-carried emacsclient warning
  on hurd (single stderr line per invocation, functionally
  correct, just noisy).  the patch ships as
  `patches/0001-emacsclient-suppress-ENOPROTOOPT-from-SO_RCVTIMEO.patch`.

  state: CLOSED 2026-05-31 by Paul Eggert.  the on-list verdict
  agreed with the suppression intent and broadened the fix:
  POSIX says SO_RCVTIMEO might not work and does not specify the
  errno value, so the right shape is to ignore the error
  unconditionally rather than match a specific errno.  Eggert
  installed that broader form on master and closed the bug.

  GEOS impact: none.  the fix lands in emacs upstream; GEOS uses
  system emacs, so we inherit it the moment our emacs package
  rolls forward.  no in-tree carry needed.

### 02 pflocal SO_RCVTIMEO

  - list: bug-hurd
  - archive: https://lists.gnu.org/archive/html/bug-hurd/2026-05/

  why I filed it: the same ENOPROTOOPT that 01 silences at the
  client also lives at the translator: pflocal does not
  implement SO_RCVTIMEO at all.  filing the gap upstream makes
  the longer-term fix possible.

  what came back relocated the layer: the prerequisite work
  lives one layer deeper than the original report assumed.

  what I did: acknowledged the layer correction on-list and
  declined to take the lower-layer slot on a near horizon.  01
  is the immediate noise-suppression path; this thread is the
  long-horizon translator fix.

  GEOS impact: none.  GEOS does not depend on SO_RCVTIMEO on
  the hurd side today; the only consumer was emacsclient and
  that is handled in 01.

### 03 pfinet per-iface counters

  - list: bug-hurd
  - archive: https://lists.gnu.org/archive/html/bug-hurd/2026-05/

  why I filed it: no per-interface byte / packet counter RPC
  exists on pfinet today, which blocks any real "rates" or
  "errors" surface on `*network*`.

  what came back steered me off the linux-flavored ioctl shape
  the original report named, toward a BSD-shaped surface.

  what I did: agreed on the pivot on-list, scoped the two BSD
  candidates with a provisional preference for the one with
  the smaller new surface, and raised two open design questions
  before drafting anything.  a follow-up reaction gave a
  concrete patch shape: implement a BSD-defined ioctl in pfinet
  and have glibc's getifaddrs consume it, rather than adding a
  new MIG routine.  ball is technically in my court but my
  reply already declined the patch slot near-term, so silence
  is the current state; no further follow-up planned unless I
  pick up the slot.

  GEOS impact: none today.  `core/network.el` hurd arm reads
  `/proc/route` and surfaces routes and interfaces but not
  counters.  if pfinet eventually grows the BSD-shaped data
  block, that *unlocks* a stats column in `*network*`; it does
  not force a present-day change.

### 04 audio translator design

  - list: bug-hurd
  - archive: https://lists.gnu.org/archive/html/bug-hurd/2026-05/
  - faq cross-reference: https://www.gnu.org/software/hurd/faq/audio.html

  why I filed it: hurd has no native audio translator; the FAQ
  is one sentence pointing at rumpsound; without a backend
  there is nothing for `*audio*` to surface.  the RFC was to
  open a design discussion.

  what came back pointed at an existing proof-of-concept jack
  backend for an intel pci audio card, on a public forge.

  what I did: read the repo (work lives on a feature branch,
  early stage, CI failed on the latest commit), sent a
  follow-up with two narrow technical questions on the IPC
  shape and the CI state, and offered a small FAQ cross-link
  patch once the branch reaches a testable state.

  what came back (2026-06-01): substantive reply from Damien
  on both questions.  IPC shape will be standard JACK: jack
  clients connect as-is via libjack, jackd in userspace, with
  a shm path still to be resolved.  CI state is "very
  incomplete at this point"; design direction is to rewrite
  the core to drop ALSA bloat and use a delay-locked loop
  calibrated by audio IRQs to track HW pointers at sub-sample
  accuracy, scheduling transfers on a hi-res timer for correct
  latency reporting (credits Paul Davis for the DLL idea).
  The FAQ cross-link offer was not addressed.

  GEOS impact: none today.  `user/userland/audio.el` hurd arm
  returns nil and renders "no cards visible" cleanly.  the
  reply concretizes the future-work shape: when the PoC reaches
  a usable state, the unlocked work in the hurd arm is a
  libjack client (because the IPC is unmodified libjack), not a
  custom RPC.  the FAQ patch stays parked until there is
  something publishable to link to.  audio remains deferred-
  upstream per HURD_PORT.md row 285.

### 05 pulseaudio in live image

  - list: debian-hurd
  - archive: https://lists.debian.org/debian-hurd/2026/05/

  why I filed it: live-image task suggestion to bundle
  pulseaudio so a new user has a working audio userland on
  hurd-amd64 by default.

  what came back was a pointer to the FAQ: there is no backend
  for pulseaudio to bind below on hurd today, so the bundling
  does not change the user-visible state.

  what I did: confirmed I read the FAQ entry on-list, withdrew
  the bundling ask, and pointed at the jack PoC in 04 above as
  the place to watch for actual motion.  thread effectively
  closed from my side.

  GEOS impact: none.  the v1.x apt-image flavor knob
  (`d0b33e4`) already documents the pulseaudio install path
  for users who want it.

### 06 evdev / libinput on hurd-amd64

  - list: debian-hurd
  - archive: https://lists.debian.org/debian-hurd/2026/05/

  why I filed it: the debian-installer-hurd `xorg` task is
  unsatisfiable on hurd-amd64 because the evdev / libinput
  input drivers do not exist for this port; this surfaces as a
  silent install regression for users picking the X11 task.

  what came back confirmed there is no debian-hurd path
  forward on this; the relevant interfaces are not provided
  by the port.  thread closed without further engagement.

  GEOS impact: none.  GEOS uses Xvfb on hurd (no keyboard /
  pointer hardware path), so kbd_drv.so + /dev/cons are not
  on the load-bearing surface.  see 07 below for the related
  gap if we ever switch to native xorg.

### 07 gnumach KDSKBMODE on /dev/cons/kbd

  - list: bug-hurd
  - archive: https://lists.gnu.org/archive/html/bug-hurd/2026-05/
  - debian install doc cited:
    https://www.debian.org/ports/hurd/hurd-install

  why I filed it: a previous VM probe on an older 0.9 baseline
  saw `kbd_drv.so` fail at the `KDSKBMODE` ioctl on
  `/dev/cons/kbd`, which framed the report as a gnumach ioctl
  gap.

  what came back confirmed the original report was filed
  against the wrong layer on the newer canonical baseline:
  with hurd console running, `/dev/cons/kbd` resolves to a
  proper char device and Xorg attaches the keyboard driver
  cleanly.  the gnumach ioctl path the original report named
  is obsolete on the newer baseline.

  while reproducing the working setup on a fresh canonical
  image I initially saw what looked like a second gap and
  raised three follow-up questions about a possibly-missing
  install doc prerequisite, a chrdev major change between
  baselines, and the hurd-console enable default.  the
  subsequent reactions corrected my diagnostic approach
  (`fsysopts` shows active translators, `showtrans` shows only
  passive ones) and noted that the enable default is already
  flipped on the latest preinstalled image, plus a follow-up
  recommendation to test on hurd-i386 before assuming
  doc-level issues exist.

  what I did: re-probed with `fsysopts` and confirmed the
  premise of my report does not hold on the current image
  (`/dev/vcs` is the directory with the active `/hurd/console`
  translator and is correctly empty for now; `/dev/cons` is
  just a regular file on the rootfs; `ENABLE='true'` is
  already the default).  withdrew the gnumach ask on-list and
  noted that any real amd64-specific issue I find on
  hurd-i386 later will be filed fresh against the right layer
  rather than reviving this thread.  thread closed from my
  side.

  GEOS impact: conditional, refined.  the corrected probe
  surfaced that `/etc/init.d/hurd-console` exists and is
  marked executable on the canonical image but is not
  autostarted in the GEOS supervisor flow (we supervise pid1,
  emacs, sshd, syslogd; not hurd-console).  if we ever flip
  from Xvfb to native xorg on hurd, `services/hurd-essentials.el`
  would need to also supervise the hurd-console daemon so
  `/dev/vcs` gets populated with `kbd`/`mouse` children.  not
  v0.9.x scope.  separately: running the install-doc manual
  `console -d vga ... -c /dev/vcs` form on top of an
  already-attached `/hurd/console` translator on `/dev/vcs`
  destabilizes the supervised emacs (the existing translator
  is its tty); a future hurd-console supervisor entry must
  avoid double-launch.

### 08 ext2fs file_pager_write_pages assertion

  - list: bug-hurd
  - archive: https://lists.gnu.org/archive/html/bug-hurd/2026-06/
  - body: `emails/08-ext2fs-pager-blk-assertion.txt`
  - send notes (operator-only): `emails/08-SEND.txt`

  why I filed it: while trying to bake the v1.x apt-image flavor
  with a boot-time `settrans -fg /var` to expose persistent
  `/var/lib/dpkg`, apt-install of around 14 MB of packages onto
  the underlying ext2fs reproducibly trips
  `ext2fs: ../../ext2fs/pager.c:455: file_pager_write_pages:
  Assertion 'blk' failed` and wedges the rootfs.  the boot-time
  detach is incompatible with apt-install under canonical until
  this assertion is fixed.

  state: SENT 2026-06-01, awaiting on-list response.  the body
  was scrubbed of every downstream-project reference before
  sending, per filing policy; what went out is the public,
  upstream-clean text in `emails/08-ext2fs-pager-blk-assertion.txt`.
  GEOS-side work for the present is the revert of the boot-time
  detach (commit 5e19fd9), the move of the detach into
  `iso-build/apt-image-verify.sh`'s pre-P1 step so dpkg-query
  still surfaces persistent state on the verify path (3f72960),
  and the move of the same detach into the bake's own ssh
  session in `iso-build/hurd-image-reroll.sh` step 8a-pre
  (24b555b + f0020c8) so the v1.x apt-image flavor re-rolls
  end-to-end for the current 5-package manifest.

  GEOS impact: short term, apt-image flavor is dpkg-queryable on
  the verify path but not safely apt-installable beyond the bake
  manifest.  long term, fixing this assertion unblocks the boot-
  time detach and a fully apt-mutable hurd-amd64 flavor.

## adjacent signal

worth noting even though it is not a reply to any of my filings:

  - a parallel new patch in the pfinet socket-option surface
    landed on bug-hurd around the same time, adding rudimentary
    SO_TIMESTAMP support to pfinet.  signal: the same upstream
    surface that owns 02 (pflocal SO_RCVTIMEO) and 03 (pfinet
    counters) is taking patches right now; if that patch lands
    cleanly, its shape is a useful template for the eventual
    pflocal SO_RCVTIMEO patch.

## what to do with this file

update per-thread when the state moves (new on-list reaction,
follow-up sent, thread closed), or when a reaction implies actual
GEOS-side work (today: none).  keep it at this granularity; do
not paste email bodies in here, mine or anyone else's.  the
public archive links above are the source of truth for the
exchanges themselves.
