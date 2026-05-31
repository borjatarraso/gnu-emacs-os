<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- voice: first person singular, lowercase, no em-dashes. -->

# upstream filings: status

snapshot of where the seven emails in `emails/` stand after hitting
their lists.  pair this with `HOW-TO-SEND.md` (the recipe for
filing) to understand the full lifecycle.  last updated 2026-05-31.

short summary: all seven landed, six drew at least one substantive
on-list reaction, one closed without further engagement.  no
GEOS-side code change is required by anything received so far.
the reactions unlock future work but do not force present-day work.

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

  state: routed for review, awaiting verdict.

  GEOS impact: none.  the patch lands in emacs upstream when
  accepted; GEOS uses system emacs, so we inherit the fix.  if
  rejected, the existing "deferred-upstream" stance on
  HURD_PORT.md row 298 stands.

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
  the smaller new surface, and raised two open design
  questions before drafting anything.  awaiting answer.

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
  patch once the branch reaches a testable state.  awaiting
  answer.

  GEOS impact: none today.  `user/userland/audio.el` hurd arm
  returns nil and renders "no cards visible" cleanly.  when
  the PoC reaches a usable state the unlocked future work is a
  libjack-shaped backend in the hurd arm.  audio remains
  deferred-upstream per HURD_PORT.md row 285.

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
  image I found a second gap: the manual invocation the debian
  install doc spells out runs as a live process with no error
  but does not populate `/dev/cons` on the current baseline;
  the chrdev nodes never appear across two fresh ephemeral
  boots.

  what I did: acknowledged the layer correction on-list,
  committed to withdraw the gnumach ask once the rest is
  clear, and raised three questions about whether the install
  doc is missing a prerequisite step, whether the chrdev major
  change between baselines is deliberate, and whether the
  hurd-console enable default should flip.  awaiting answer.

  GEOS impact: conditional.  if a missing setup step is
  confirmed, it could be pre-run from
  `install/hurd-bootstrap.sh`, but only if we want native xorg
  on real keyboard hardware.  today Xvfb sidesteps the entire
  /dev/cons surface, so this is "unlocked future work" if we
  ever flip from Xvfb to native xorg on hurd.

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
