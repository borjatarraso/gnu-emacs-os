;;; v0.7 implementation plan
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- voice: first person singular, lowercase, no em-dashes. -->

# GEOS v0.7 plan

v0.6 shipped multi-user on top of a still-monolithic-WM supervisor.
PID 1 emacs still calls `(exwm-enable)` at boot and owns the X
connection; the per-user emacs is an X client.  the trust-boundary
goal of v0.6 item 1 was hit for userland buffers (a stuck regex in
notes-buffer-refresh now stalls the per-user emacs, not PID 1) but
NOT for the window manager.  v0.7 finishes that handover and rolls
up the catch-up deferrals (IBus, audio) that have been sliding since
v0.2 and v0.4 respectively.

By the end of v0.7 the supervisor calls `exwm-enable` only when no
session is running (the *login* surface) and tears down the X
connection across a successful login; the user-emacs is the WM for
the duration of the session.  IBus is the default input method;
audio promotes from the preview corner of user/userland/ into the
docs proper.

## Effort summary

| #  | Item                                       | Size   | Weeks (mid) | Depends on |
|----|--------------------------------------------|--------|-------------|------------|
|  1 | EXWM handover to user-emacs                | Large  | 2.0         | none       |
|  2 | input methods (IBus / quail proper)        | Medium | 1.0         | none       |
|  3 | audio promotion (ALSA wrapper -> docs)     | Small  | 0.5         | none       |
|  4 | supervisor views over RPC                  | Medium | 1.0         | v0.6 #3    |
|  5 | Hurd side branch -> CI green               | Large  | 3.0         | none       |

Total realistic v0.7 budget ex Hurd: ~4.5 person-weeks.  the Hurd
track stays parallel.

## Recommended ordering

Phase A (1.5-2 weeks): item 1.  this is the v0.6 leftover and the
load-bearing piece of v0.7.  no other item depends on it, but the
display-release story is the open risk for the whole release.

Phase B (1.5 weeks): items 2 and 3.  small drop-ins that ship as
soon as item 1 has shaken out.  IBus is medium because the i18n
plumbing is real; audio is small because the wrapper already lives
under user/userland/audio.el.

Phase C (1 week): item 4.  supervisor *services* / *journal* /
*processes* over the item-3 RPC channel so logged-in users can read
them without dropping to the supervisor TTY.  this is the v0.6 risk
section's "decision (a) is a v0.7 candidate" cashed in.

Phase D (best-effort): item 5.  Hurd remains its own track on a side
branch; v0.7's job is to keep it building and start running smoke-
tests on it.

A clean v0.7 release ships A + B + C, notes Hurd progress in the
release notes, tags 5 as preview only if the side branch boots.

---

## Item 1. EXWM handover to user-emacs

v0.6 item 1 trimmed scope and left `exwm-config.el`, `multimon.el`,
`fonts.el`, `input.el` supervisor-side.  the supervisor still calls
`(exwm-enable)` at boot; the per-user emacs is an X client.  this
item finishes the handover.

after this ships: a runaway regex in the user's EXWM keybinding can
only stall the per-user emacs, not PID 1.  the supervisor's frame is
fully released across a successful login and rebuilt when *login*
re-appears.

**Files to touch (existing):**
- `emacs-init/user/exwm-config.el` (no move; the file already lives
  under user/, just stops being loaded supervisor-side).
- `emacs-init/user/multimon.el`, `fonts.el`, `input.el` (same: stop
  loading supervisor-side, start loading from user-init.el).
- `emacs-init/init.el` (drops the wm requires).
- `emacs-init/user/user-init.el` (grows the WM chain: panic,
  exwm-config, multimon, fonts, input, then userland).
- `emacs-init/core/session.el` (session-spawn closes the supervisor's
  X display after a successful spawn; session-end re-opens it for
  *login*).
- `guix-system/system.scm` (extra-special-file chain for user-init.el
  picks up the WM files).

**Files to create (new):**
- `emacs-init/core/x-display.el`: the supervisor side of the
  display-release dance.  defun `x-display-release' tears down the
  supervisor's frame and closes :0; `x-display-reclaim' opens it
  again for *login*.  panic-handled, idempotent.

**C-side work:** none.  the dynamic module is unchanged; the X
display is a user-space connection.

**Elisp-side work:**
- supervisor boot path: start Xorg (unchanged), but do NOT call
  exwm-enable.  open a minimal frame on :0 for *login* only.
- session-spawn: after pid1-spawn-as-uid returns the child pid,
  call x-display-release.  the supervisor goes "headless" for the
  duration of the session; *login* is no longer drawn.
- session-end (and the poller's auto-teardown path on observed
  child exit): call x-display-reclaim, then session--present-login.
- user-init.el: requires exwm-config, multimon, fonts, input
  BEFORE the userland chain.  user-emacs calls exwm-enable.
- the *login* frame contract: supervisor owns the frame ONLY
  between sessions (and at boot).  during a session the user-emacs
  is the WM.

**Guix-side work:**
- the `geos-user-init` manifest grows entries for the WM files.
- the system profile is unchanged (emacs-exwm was already there).

**Risks and unknowns:**
- EXWM does not document a "release the display" path.  the
  prototype probably means killing the supervisor's X connection by
  exiting its frame and calling `x-close-connection :0'.  if EXWM
  has bookkeeping that does not survive that, we may need an EXWM
  patch.  budget time for a spike before committing.
- the *login* surface needs an X frame and a font.  fonts.el moves
  to user-side, so the supervisor's frame uses whatever the kernel
  console font provides.  acceptable for a username prompt; ugly
  but not broken.
- a wedged user-emacs that never calls exwm-enable would leave the
  display in a no-WM state.  the supervisor's poller already
  observes child-exit; add a "child alive but X still unmanaged
  after 5s" detector that re-presents *login* on the supervisor's
  side as a recovery path.

**Test plan:**
- new `freeze-tests.el` case: after session-spawn, assert
  `(frame-list)` on the supervisor is empty (no X frames open).
- new case: after session-end, assert the supervisor reclaimed
  :0 and *login* is drawn again.
- smoke-test: add a marker `wm: handover complete' that the
  supervisor emits AFTER session-spawn returns and the display is
  released.  fail if the marker does not appear inside 5s.
- manual: QEMU pass, login as tester, alt-tab inside the user's
  EXWM, logout, login again, second user gets a fresh WM (no
  buffers leaked, no keymap bleed).

**Estimated complexity:** Large (1.5-2 weeks).

---

## Item 2. input methods (IBus / quail proper)

deferred since v0.2 phase 5c.  v0.5c shipped quail with rfc1345 and
nothing more.  v0.7 makes IBus the default for users who need
non-latin scripts, with quail kept as the fallback for environments
that cannot run IBus (the install-time partition wizard, freeze-
test harness, console mode).

**Files to touch (existing):**
- `emacs-init/user/input.el` (becomes a two-mode chooser: ibus when
  available, quail otherwise).
- `guix-system/system.scm` (add ibus + the input-method packages).

**Files to create (new):**
- none.  input.el is the natural home.

**C-side work:** none.

**Elisp-side work:**
- a new `geos-input-method' user option, set to `:auto' by default.
  `:auto' picks IBus under X with `(getenv "DISPLAY")` non-nil,
  falls back to quail otherwise.
- `:ibus' forces IBus; `:quail' forces quail; both are debuggable.
- per-user persistence: the choice writes to /var/emacs/users/NAME/
  input.eld so a relogin remembers.  load on user-init.el chain.

**Guix-side work:**
- ibus + ibus-libpinyin (for the canonical CJK round-trip).
- the daemon must run as the per-user emacs's child, not as a
  session-wide systemd unit.  GEOS has no systemd; ibus-daemon
  spawns from user-init.el via make-process under supervise.el so
  the crashloop cap applies.

**Risks and unknowns:**
- ibus-daemon expects a DBus session bus.  v0.6 has no DBus
  anywhere.  decision: add dbus-launch under user-init.el and let
  ibus-daemon find its bus there; the bus lives only inside the
  user-emacs's process group.
- the daemon's socket lives under /run/user/UID/, which has to be
  laid down with the right ownership by the supervisor (we already
  do this for /var/emacs/users/NAME/; the same pid1-chown pattern
  applies).

**Test plan:**
- freeze-test: load input.el, force `:auto' under a stubbed
  `(getenv "DISPLAY")` -> ":0", assert ibus is selected; stub to
  nil, assert quail.
- manual: login as tester, type japanese via IBus, logout, login
  again, assert the IBus state is preserved (or cleanly reset, the
  spec says reset).

**Estimated complexity:** Medium (1 week).

---

## Item 3. audio promotion (ALSA wrapper -> docs)

`emacs-init/user/userland/audio.el` exists as a make-process wrapper
around amixer/aplay (the preview from v0.4 item 8).  v0.7 promotes
it: USER_GUIDE gets an audio section, the keybindings move under
`C-c e a *', and the `*audio*' buffer becomes a first-class system-
concept buffer alongside *network*, *processes*, etc.

**Files to touch (existing):**
- `emacs-init/user/userland/audio.el` (refactor to special-mode
  buffer; today it is a thin command set with no buffer surface).
- `docs/USER_GUIDE.md` (new audio section under "system-concept
  buffers").
- `emacs-init/init.el` or user-init.el (autoload `*audio*' as M-x
  audio-buffer).

**Files to create (new):**
- none.

**C-side work:** none.  alsa is user-space.

**Elisp-side work:**
- `*audio*' buffer: lists output devices, mixer volumes per channel,
  active stream count from /proc/asound.  refresh on `g'.
- key table on the buffer: `+'/`-' volume up/down, `m' mute toggle,
  `n' next sink, `q' bury.
- supervise.el entry: none.  audio is user-state, no daemon.

**Guix-side work:**
- alsa-utils is already on the system profile; nothing changes.

**Risks and unknowns:**
- volume persistence across reboot is alsa-state.dat, which lives
  under /var/lib/alsa/.  v0.7 punts: read at boot via amixer, do
  not restore.  the user re-sets volume on each login.  a v0.8
  ergonomic pass can fold it into per-user state.

**Test plan:**
- freeze-test: make-process to a stub amixer, assert audio-buffer
  parses the canned output.
- manual: login, M-x audio-buffer, mute, unmute, change volume,
  logout.

**Estimated complexity:** Small (0.5 weeks).

---

## Item 4. supervisor views over RPC

v0.6 item 1's risk section noted that the supervisor still owns
*services*/*journal*/*processes* after the userland handover, and a
logged-in user has no way to see them without dropping to the
supervisor TTY.  the decision was (b) for v0.6 (accept the gap), (a)
for v0.7 (expose over RPC).  v0.7 cashes that in.

**Files to touch (existing):**
- `emacs-init/core/rpc.el` or wherever v0.6 item 3 put the RPC
  server (522d6ef).  new verbs: services-list, journal-tail,
  processes-list.
- `emacs-init/user/userland/` (new client-side buffer modes that
  call the RPC instead of reading state directly).

**Files to create (new):**
- `emacs-init/user/userland/services-client.el`: *services* buffer
  on the user side, rendered from a services-list RPC.
- ditto for journal-client.el and processes-client.el.

**C-side work:** none.  the RPC channel is AF_UNIX, shipped in v0.6.

**Elisp-side work:**
- the existing supervisor-side buffers (services.el, journal.el,
  processes.el) become BOTH renderers AND RPC servers: their state
  is the source of truth, the client buffer just asks for the
  current snapshot.
- a read-only `geos-rpc-call VERB ARGS' helper on the user side,
  panic-handled, with a sensible timeout (250ms; the supervisor is
  not allowed to wedge a user).
- the client buffers refresh on a timer (3s, same cadence as the
  child-exit poller) plus an explicit `g' key.

**Guix-side work:**
- none.  v0.6 already laid down /run/geos/super.sock.

**Risks and unknowns:**
- the supervisor's *journal* buffer holds the full kernel ring read
  from /dev/kmsg.  shipping the entire tail over RPC every refresh
  is wasteful.  ship a `since-seq SEQ' arg so the client only
  fetches new entries; this is the v0.6 item 3 RPC's existing
  shape, just reused.
- access control: the RPC channel is per-uid (the socket's mode is
  0660 owned by root:wheel today).  *services*/*journal* should be
  readable by every user; *processes* exposes pids of other users'
  programs, which is fine on linux (everyone reads /proc) but worth
  documenting.

**Test plan:**
- freeze-test: install a fake supervise registry, call the new RPC
  verb, assert the wire shape matches.
- manual: login, open *services*, see the supervisor's services
  list update live; logout; the buffer in another user's session
  keeps working.

**Estimated complexity:** Medium (1 week).

---

## Item 5. Hurd side branch -> CI green

v0.4 item 11 closed the feasibility spike with a 6-8 week estimate
on a side branch (project_v04_item11_hurd_spike.md).  v0.6 did not
touch it.  v0.7's contribution is: keep the side branch building
against current main, and stand up enough CI to run the boot smoke-
test on a Hurd-flavored qcow2.

scope-wise this is exactly the Phase D promise from v0.6 ("v0.7
keeps it building").  the heavy port work continues on the side
branch; main only sees CI plumbing.

**Files to touch (existing):**
- `iso-build/smoke-test.sh` (grow a `--hurd' flag that switches the
  system.scm input).
- `.github/workflows/` or wherever CI lives (today: probably
  nothing; v0.7 may need to create it).

**Files to create (new):**
- `iso-build/smoke-test-hurd.sh` if the wrapper grows too long.
- `docs/HURD_PORT.md` summarizing the port status, what works,
  what does not.

**C-side work:** lives on the side branch.  pid1's port_layer.h is
the boundary; main never grows a port_hurd.c here.

**Elisp-side work:** none on main.  the side branch keeps its
system-hurd.scm and its mach RPC plumbing.

**Risks and unknowns:**
- gnumach on QEMU is slow.  CI budget per Hurd smoke-test will be
  10x linux.  start with weekly only.
- the Hurd image may not build at all against today's main; the
  first commit on this item is "rebase the side branch and report
  what blew up."  that is a multi-day rebase, not an afternoon.

**Test plan:**
- a smoke-test pass on the Hurd qcow2 that boots to a PID 1 line.
  the marker is `pid1: hurd port up' rather than the linux markers.
- the linux smoke-test stays canonical for releases; the Hurd one
  is best-effort, runs nightly, does not block.

**Estimated complexity:** Large (3 weeks for the rebase + plumbing;
the port itself is on the side branch and not counted here).

---

## Cross-cutting concerns

**display ownership across boot, login, logout:** item 1 is where
this gets resolved.  expect a long debugging tail; budget for it.

**rpc surface area:** items 1, 4 both touch the v0.6 item 3 RPC.
keep a flat verb table; add `rpc-info' as a discovery verb so a
user-side client can ask "what verbs do you serve?"

**multi-user fairness:** v0.6 capped at 3 concurrent users.  v0.7
does not raise that cap; the WM handover changes the dynamics of
who-owns-the-display and the right time to revisit is after the
handover has shaken out, not now.

**docs voice:** USER_GUIDE additions stay in first-person singular,
lowercase commit messages, no em-dashes.  the rule is unchanged.

**release predicate:** A + B + C done, item 1 verified on QEMU
(handover happens, *login* comes back cleanly), all freeze-tests
green, smoke-test green, attribution-scan green.  tag v0.7 only
after a fresh-boot pass.
