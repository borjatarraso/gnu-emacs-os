;;; v0.6 implementation plan
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- voice: first person singular, lowercase, no em-dashes. -->

# GEOS v0.6 plan

v0.5 shipped per-user login on top of a still-monolithic supervisor:
the privileged PID 1 emacs hosts EXWM and every userland buffer, and
the per-user child has exactly one defun (`geos-logout`). v0.6
finishes that decoupling. By the end of this release the supervisor
owns supervision and nothing user-visible; the user-emacs owns the
window, the editor surface, and every workspace concept that used to
sit on the supervisor side of the boundary.

The 9 items below fall into three coherent bundles. Items 1 to 4 are
load-bearing and ship as v0.6 proper. Items 5 to 7 are ergonomic
catch-up from deferrals as far back as v0.2; they ship as v0.6 if
they fit, v0.7 if they slip. Items 8 and 9 are best-effort tracks
that interleave whenever.

## Effort summary

| #  | Item                                  | Size   | Weeks (mid) | Depends on |
|----|---------------------------------------|--------|-------------|------------|
|  1 | userland migration into user-emacs    | Large  | 2.0         | none       |
|  2 | per-user dotfiles persistence         | Small  | 0.5         | 1          |
|  3 | supervisor RPC channel                | Large  | 2.0         | 1          |
|  4 | *users* buffer polish + add/del/passwd| Small  | 0.5         | none       |
|  5 | login hardening + audit trail         | Medium | 1.0         | none       |
|  6 | concurrent sessions (workspace-split) | Medium | 1.5         | 1, 3       |
|  7 | input methods (IBus / quail proper)   | Medium | 1.0         | none       |
|  8 | audio (ALSA wrapper, promoted)        | Medium | 1.0         | none       |
|  9 | Hurd side branch alive + CI'd         | Large  | 3.0         | none       |

Total realistic v0.6 budget ex Hurd: ~9.5 person-weeks. With item 9
it slips into v0.7 territory; treat 9 as a separate branch tag, not
a release blocker.

## Recommended ordering

Phase A (decoupling, 4-5 weeks): items 1, 2, 3. After A the
supervisor is a thin process: it watches /proc for child exits,
serves an RPC for privileged operations, and shows only the *login*
buffer plus its own *services* / *journal* / *processes* views. The
user-emacs hosts dired, eshell, magit, eww, notes, the userland
buffers, and (eventually) ibus. This is the load-bearing v0.6 work.

Phase B (multi-user UX, 2-3 weeks): items 4, 5, 6. These all flow
from the Phase A shape. Phase A makes "the user-emacs goes away and
*login* comes back" the normal lifecycle, so the audit trail and the
workspace-split second user fall out naturally.

Phase C (catch-up, 2 weeks): items 7, 8. IBus has been deferred
since v0.2 phase 5c. Audio has been deferred since v0.4 item 8.
Neither blocks anything; they ship when room exists.

Phase D (best-effort): item 9. Hurd is its own track on a side
branch; v0.6 just keeps it building.

A clean v0.6 release ships A + B, tags 7 and 8 as preview, and notes
9's side-branch SHA in the release notes.

---

## Item 1. userland migration into the user-emacs

The user-init.el header already names this as the v0.6 foothold.
Today everything under `emacs-init/userland/` (files.el, git.el,
mail.el, notes.el, pdf.el, shell.el, web.el, chat.el, uname.el)
loads into the supervisor. EXWM lives there too. The boundary is in
the wrong place: a runaway regex in `M-x notes-buffer-refresh` can
stall PID 1.

**Scope trim landed mid-cycle (commit 1f3c485 landed 1.2 with this
shape):** the userland chain (dired/eshell/uname/magit/eww/notmuch/
erc/org/pdf-tools) ships user-side in v0.6.  EXWM, multimon, fonts,
and input stay supervisor-side and SLIP to v0.7.  the trust-boundary
argument the plan opened with still holds: the user-emacs has no
`pid1-*` access, every userland buffer that could stall PID 1 now
stalls the per-user emacs only.  the user-emacs-owns-the-WM goal
ships when somebody is ready to prototype EXWM's release-the-
display story (no documented path; that was the open risk this
section called out).

what 1.1+1.2 shipped:
- `emacs-init/wm/` -> `emacs-init/user/` (4 files moved).
- `emacs-init/userland/` -> `emacs-init/user/userland/` (11 files
  moved).
- supervisor's `-l` chain dropped 10 entries (every userland file
  except audio, which buffers/audio.el still requires).
- `user-init.el` grew a chain loader: panic.el, use-package-shim,
  9 userland packages, audio, verifier.
- 12 `extra-special-file` entries lay everything at `/etc/geos/
  core/...` and `/etc/geos/user/userland/...`.

what slips to v0.7 (called out here so v0.7's planner doesn't
re-litigate it):
- `exwm-config.el`, `multimon.el`, `fonts.el`, `input.el` stay
  supervisor-side.
- supervisor still calls `(exwm-enable)` at boot; per-user emacs
  is an X client.
- the *login* frame and the user-emacs frame share the supervisor's
  display, which is fine for single-user; concurrent-session item 6
  is unaffected.

the rest of this section describes the ORIGINAL scope including the
EXWM handover, kept for the v0.7 planner.

**Files to touch (existing):**
- `emacs-init/user/user-init.el` (becomes the chain loader; today
  it has one defun and one keybinding).
- `emacs-init/init.el` (drops the userland chain entries; the
  supervisor stops loading the userland files).
- `emacs-init/wm/exwm-config.el` (moves to the user-emacs side of
  the boundary; the supervisor no longer requires exwm).
- `guix-system/system.scm` (the `extra-special-file` chain for
  `/etc/geos/user-init.el` grows to load the migrated files; the
  supervisor's `-l` chain shrinks).
- every file under `emacs-init/userland/` keeps its code but moves
  on disk to `emacs-init/user/userland/`.

**Files to create (new):**
- `emacs-init/user/userland/README.md` is NOT created (no docs).
  The directory exists; its sibling rules file explains the rule.
- `emacs-init/user/` gains a new rules file (the
  per-directory conventions note we keep in every subtree):
  - states the rule: nothing in this tree may call `pid1-...`
    functions directly; privileged operations go through item 3's
    RPC channel.
- `emacs-init/user/exwm-config.el`: the moved exwm config.

**C-side work:** none. The dynamic module already loads in the
user-emacs because the same emacs binary is exec'd. The user-emacs
just does not `require` it.

**Elisp-side work:**
- the supervisor's init.el keeps only: panic, supervise, network,
  hostname, state, passwd, session, login, the system-concept
  buffers (processes, services, journal, network, disks, packages,
  users, install, reconfigure). It does NOT load wm/, userland/, or
  user/.
- user-init.el grows a deterministic chain loader that requires
  exwm-config, then the userland files in a documented order.
- the EXWM session is owned by the user-emacs. The supervisor runs
  headless after a login completes; it gets the X frame back only
  during *login* (which is where it had it at boot, no change).
- key handover: today Xorg starts before the supervisor, supervisor
  runs `(exwm-enable)`, supervisor owns the X connection. After
  migration, supervisor still starts Xorg (it has the privilege),
  but does NOT call `exwm-enable` at boot. On login, the user-emacs
  is the one that calls `exwm-enable` against `:0`. The supervisor
  closes its X display when it spawns the child.

**Guix-side work:**
- `system.scm` `geos-user-init` extra-special-file becomes a
  manifest of paths the user-emacs loads, produced by a gexp.
- the supervisor profile no longer needs the userland packages
  unless they have shared bits (magit's git binary, notmuch, the
  pdf reader); package list is unchanged on the system profile
  because we still want those tools available, just not loaded
  into the supervisor's emacs.

**Risks and unknowns:**
- closing the supervisor's X display cleanly: EXWM does not
  document a "release the display" path. Probably means killing the
  supervisor's X connection by exiting the frame; verify with a
  prototype before committing.
- the *login* buffer needs an X frame too. Confirm whether the
  supervisor's frame survives across user-emacs spawn-and-exit, or
  whether we re-make the frame in `session--present-login`.
- the supervisor still owns *services*/*journal*/*processes*. The
  user has no way to see them after login unless we either (a)
  expose them over the item-3 RPC, or (b) accept that those are
  "supervisor TTY" views you only see between logins. Decision: (b)
  for v0.6, (a) is a v0.7 candidate.

**Test plan:**
- new `freeze-tests.el` case: load supervisor, assert
  `(featurep 'exwm) => nil` and `(fboundp 'notes-buffer) => nil`.
- new case: spawn a user-emacs in a subprocess, assert it loads
  exwm-config + userland and the supervisor remains alive.
- smoke-test: existing `geos: emacs userland up` marker stays, but
  now fires from the user-emacs after login. Add a new marker
  `supervise: handover ready` from the supervisor that means
  "userland has been delegated to the next child".
- manual: full QEMU pass: boot -> login -> notes/files/git all work
  in user-emacs; logout; supervisor returns to *login*; login again
  as a different user; confirm the second user gets a fresh frame
  with no prior buffers leaked.

**Estimated complexity:** Large (1.5-2 weeks).

---

## Item 2. per-user dotfiles persistence

Today user-init.el loads from `/etc/geos/user-init.el`, which is a
system-managed store path; the user cannot customise it. Once item
1 lands, the user wants to set their own keybindings, packages, and
faces, and they want those settings to survive a logout.

**Files to touch (existing):**
- `emacs-init/user/user-init.el` (adds an optional load step at the
  end: read `/var/emacs/users/NAME/init.el` if present, route any
  error through panic-handle).
- `emacs-init/core/state.el` (already owns `/var/emacs/`; add a
  helper `state-user-dir (uid name)` that resolves the per-user
  state path).

**Files to create (new):**
- none.

**C-side work:**
- none. State writes from the user-emacs already work because the
  user owns `/var/emacs/users/NAME/` (item 1's spawn-as-user does
  the chown at first login).

**Elisp-side work:**
- on first login for a user, the session spawner creates
  `/var/emacs/users/NAME/` with mode 0700, owned by that uid:gid.
  Path layout: `init.el` (user-editable), `cache/` (transient),
  `eshell/` (history, aliases), `notmuch/` (database link).
- user-init.el's final form:
  - require the system chain (item 1).
  - if `/var/emacs/users/NAME/init.el` exists and is regular and
    owned by us, load it inside a condition-case routed to
    panic-handle.
  - the message line prints `userland: per-user init loaded`
    or `userland: per-user init absent`, never silently.

**Guix-side work:** none.

**Risks and unknowns:**
- a buggy per-user init.el should not wedge the login flow. The
  panic-handle path opens *panic* in the user-emacs, the supervisor
  is unaffected, the user can still log out and edit the file from
  *login* recovery (item 4 if we add that, otherwise from the
  supervisor's eshell-equivalent which the user has no access to;
  for v0.6 just document the recovery story).
- atomic writes for the per-user init.el itself: the user is
  editing this file with `find-file`, so atomicity is whatever
  emacs does (write-to-temp + rename, fine).

**Test plan:**
- freeze-tests: log in, write a value to `/var/emacs/users/tester/
  init.el` that sets `geos-test-marker`, log out, log in again,
  assert `geos-test-marker` is bound.
- error path: per-user init.el that raises -> *panic* in user-emacs
  -> kill-emacs returns to *login*.

**Estimated complexity:** Small (2-3 days).

---

## Item 3. supervisor RPC channel

After item 1 lands, the user-emacs has no privileged access. The
user still needs to install a package (writes to /gnu/store), edit
the system config (writes to /etc/geos/system.scm), reboot, or
poweroff. Today those are M-x in the supervisor. After item 1 those
M-x are gone from the user-emacs side. The fix is a tiny RPC:
user-emacs sends a verb over a unix socket, supervisor decides.

**Files to touch (existing):**
- `pid1/emacs-init.c` (open a listening AF_UNIX socket at
  `/run/geos/super.sock` mode 0660, group `geos`, before main
  loop).
- `emacs-init/init.el` (load the new core/rpc-server.el after
  panic).
- `emacs-init/user/user-init.el` (load the new core/rpc-client.el).

**Files to create (new):**
- `pid1/rpc.c` and `pid1/rpc.h`:
  - opens, binds, listens on the unix socket.
  - exposes `Fpid1_rpc_poll` to elisp; returns either nil (no
    pending request) or a plist `(:fd N :uid U :verb VERB :payload P)`.
  - `Fpid1_rpc_reply (fd status payload)` writes back a status
    word + optional payload sexp, closes fd.
  - uses SCM_CREDENTIALS for the uid; the verb is a short ASCII
    string, the payload is a length-prefixed sexp.
- `emacs-init/core/rpc-server.el`:
  - on a 200ms idle timer, calls `pid1-rpc-poll`. dispatches the
    verb to a handler table.
  - verb list for v0.6:
    - `reboot`, `poweroff` (any uid; supervisor logs the request).
    - `reconfigure SCM-PATH` (any uid; supervisor spawns
      guix system reconfigure as itself, streams output to
      *system-build*, replies with the new generation number).
    - `package-install NAME` and `package-remove NAME` (any uid;
      supervisor spawns guix package against the system profile
      with `--profile=/var/guix/profiles/system`).
    - `passwd-set USER PLAIN` (only uid 0; rejected otherwise).
    - `journal-tail N` (any uid; returns the last N lines of
      kmsg).
- `emacs-init/core/rpc-client.el`:
  - `geos-rpc (verb &rest args)`: opens
    `/run/geos/super.sock`, sends the verb, blocks until reply,
    returns the parsed sexp.
  - convenience wrappers: `geos-reboot`, `geos-poweroff`,
    `geos-package-install NAME`, etc., that user-init.el binds to
    `C-c e <key>` slots.

**C-side work:** as above. Authentication is purely
SCM_CREDENTIALS-based; no shared secret. Authorisation lives in
elisp (the verb dispatcher checks the uid before acting).

**Elisp-side work:** as above. The trust boundary is documented in
the per-directory rules file under `emacs-init/core/` (new section):
"verbs that mutate must check uid; verbs that read are open by
default; payloads from the user-emacs are untrusted sexps and must
round-trip through `read-from-string` with a max length, not
`eval`."

**Guix-side work:**
- create the `geos` group, add every user to it.
- `/run/geos` is owned by root:geos, mode 0750.

**Risks and unknowns:**
- a slow handler blocks the supervisor. Every handler must use
  `make-process` + sentinel, not synchronous spawn. The dispatcher
  itself returns a "pending JOB-ID" status; the client polls or
  the server sends an asynchronous "done JOB-ID" frame.
- payload size: sexps from the user-emacs are bounded at 64 KiB.
  Larger transfers (e.g. an installed-package list) use a file
  path in /var/emacs and a sexp pointing at it.
- replay/abuse: every verb logs `rpc: uid=U verb=V payload=...`
  to the journal. A `payload-error` panic marker triggers if
  parsing fails.

**Test plan:**
- freeze-tests: send a `journal-tail 5` from the supervisor's own
  emacs (the supervisor can be its own client over the same
  socket), assert the reply contains 5 lines.
- error path: send `passwd-set tester newpass` as uid 1000, assert
  the supervisor replies `(:error "uid 0 only")`.
- smoke-test: new marker `rpc: listening on /run/geos/super.sock`.
- manual: from the per-user emacs, `M-x geos-package-install hello`,
  watch the supervisor log the request and the user-emacs receive
  the new generation number.

**Estimated complexity:** Large (1.5-2 weeks). The protocol is
small; the work is in handler-correctness across every verb.

---

## Item 4. *users* buffer polish + interactive add/del/passwd

Today the buffer exists (`emacs-init/buffers/users.el`) and the
underlying passwd-add-user / passwd-set-password functions work,
but the interactive flow has gaps. Test runs needed `M-: (progn
(passwd-add-user ...) (passwd-set-password ...) (make-directory
...))` because the buffer's `a` key did not chain those steps. v0.6
finishes the wiring so the M-: dance is gone.

**Files to touch (existing):**
- `emacs-init/buffers/users.el` (the `a`/`p` handlers).
- `emacs-init/core/passwd.el` (add a `passwd-create-user-and-home`
  helper that bundles passwd-add-user + make-directory + chown via
  the new pid1-chown).

**Files to create (new):**
- none.

**C-side work:**
- new `Fpid1_chown (path uid gid)`: wraps `chown(2)`. Required so
  the user's home directory ends up owned by them; today the
  M-: workaround was `(set-file-modes "/home/X" 511)` which is
  0777 and a security smell.

**Elisp-side work:**
- `a` (add user): prompts for username, uid (default next free),
  gid (default = uid), home (default `/home/NAME`), shell
  (default `/bin/sh`), password (read-passwd twice). On success
  calls `passwd-create-user-and-home`. On any step fail, routes
  to panic-handle and refreshes.
- `p` (set password): prompts twice via read-passwd, applies via
  `passwd-set-password`. Refreshes.
- `d` (delete): existing flow stays; add a confirmation that names
  the home directory and asks whether to remove it too.

**Guix-side work:** none.

**Risks and unknowns:**
- /home is on the root filesystem in v0.6, not a separate /home
  partition. Chown is a single fast syscall, no recursive walks
  required; the home is freshly made.
- shadow group: /etc/shadow's mode is still 0640 in v0.5.1. With
  pid1-chown we can also set the group ownership correctly. Add
  to the same item.

**Test plan:**
- freeze-tests: invoke users-buffer-add programmatically with a
  fake minibuffer, assert /etc/passwd and /etc/shadow grow,
  /home/X exists, owned by the new uid.
- regression: confirm the v0.5.1 manual workaround (set-file-modes
  /home/X 511) is no longer needed in the QEMU exercise script.

**Estimated complexity:** Small (2-3 days).

---

## Item 5. login hardening + audit trail

The login flow is correct but has no memory. Failed attempts are
not logged anywhere durable; nothing rate-limits a user that fat-
fingers a password ten times in a row; the *journal* buffer does
not surface auth events.

**Files to touch (existing):**
- `emacs-init/buffers/login.el` (the verify path appends an audit
  line).
- `emacs-init/core/state.el` (already has the writer; add a
  helper `state-append-journal (line)` that locks-and-appends).

**Files to create (new):**
- `emacs-init/services/login-audit.el`:
  - tails `/var/emacs/journal/auth.log` into the *journal* buffer
    when the buffer is open.
  - registers a defservice so the buffer-timer pattern picks it
    up.

**C-side work:** none.

**Elisp-side work:**
- audit-log format: one sexp per line. Example:
  `((time . "2026-05-12T13:00:00Z") (user . "tester") (result . :ok))`
  or `(result . (:fail :wrong-password))` etc.
- rate limit: keep an in-memory ring of the last 5 fail timestamps
  per username. On the 6th fail inside 60s, refuse with a 5s sleep
  before showing the prompt again. `sit-for` is fine because no
  other buffer cares about the login surface during this stall.
- lockout: 10 fails in 5 minutes for a single username flips the
  user to a `:locked-until TIME` state in /var/emacs/users/NAME/
  state.sexp. Unlock = uid 0 calls `users-buffer-unlock` (new
  bind, `u`).
- the *login* buffer gets a footer line showing the last successful
  login (`last login: tester @ 2026-05-12 12:58`).

**Guix-side work:** none.

**Risks and unknowns:**
- /var/emacs is tmpfs in degraded boots, so the audit log is lost
  on reboot. Header line of *journal* shows `state: tmpfs` (item 1
  from v0.4 already wires this); the audit story degrades the same
  way.
- the rate-limit `sit-for` blocks the supervisor. Acceptable: we
  are NOT supervising a user-emacs at that point (no one is logged
  in), so the cost is a 5s freeze of the *login* buffer only.

**Test plan:**
- freeze-tests: send 6 wrong passwords, assert the 6th raised the
  rate limiter; send 10 inside 5 minutes, assert lockout.
- audit-log shape: read /var/emacs/journal/auth.log, assert sexp
  parses and `:result` field present.

**Estimated complexity:** Medium (4-6 days).

---

## Item 6. concurrent sessions (workspace-split)

Today one user can be logged in at a time. The v0.5 workspace
routing put each user-emacs on its own EXWM workspace, but the
supervisor only spawns one child at a time and the *login* buffer
replaces the running user on its own workspace, not a fresh one.

The v0.6 shape: two users can be logged in simultaneously; the
supervisor's *login* lives on workspace 0; user A's emacs lives on
workspace 1; user B's emacs lives on workspace 2; user C's lives
on workspace 3. Switch via the EXWM workspace keys (`s-1` ..
`s-3`). On logout from workspace N, the supervisor re-presents
*login* on workspace 0 (does not steal N).

**Files to touch (existing):**
- `emacs-init/core/session.el` (the session registry grows from
  one slot to N; the spawner picks the next free workspace).
- `emacs-init/buffers/login.el` (the verify path passes the chosen
  workspace to `session-spawn-as-uid`).
- `emacs-init/wm/exwm-config.el` (workspace assignment hook reads
  the registry, not the static "ws 1 always").

**Files to create (new):**
- none.

**C-side work:**
- new `Fpid1_spawn_as_uid_n` is NOT required; the existing spawn
  function is fine. The "which workspace" is a hint for EXWM, not
  a pid1 concern.

**Elisp-side work:**
- session registry: alist keyed by uid -> (pid workspace started).
- spawner: walks workspaces 1..3 looking for the first unused.
  Maxes at 3 concurrent users by default (the workspace count is
  4 today, ws 0 reserved for *login*).
- workspace assignment hook: looks up the EXWM instance class
  against the registry, returns the recorded workspace.
- logout: the poller observes the child-exit on workspace N,
  reclaims the registry slot, does NOT touch workspaces other
  than N. If no user is logged in (registry empty), re-present
  *login* on ws 0.

**Guix-side work:** none (the workspace count is configured in
exwm-config.el).

**Risks and unknowns:**
- two users sharing a single X display is the model. They cannot
  see each other's windows because each window has the correct
  uid'd emacs as its X client, but the X server itself is a single
  trust domain. v0.6 documents this in `docs/SECURITY.md`. Proper
  isolation (per-user Xorg) is v0.7+.
- the supervisor's "stop showing user A's frame, show login again"
  flow on logout needs to not disturb user B on a different
  workspace. Test by spawning two users and SIGKILLing one.
- workspace 0 being "always login" means the supervisor's other
  buffers (services, journal) need a different surface. Probably
  buried; the supervisor's TTY is for emergencies anyway after
  Phase A.

**Test plan:**
- freeze-tests: spawn two simulated logins, assert the registry
  has two entries on workspaces 1 and 2.
- manual: login as tester (ws 1), `s-0` to login, login as alice
  (ws 2), `s-1` to flip back to tester. SIGKILL tester's pid,
  confirm alice on ws 2 is unaffected and ws 1 returns to a
  "no session here" placeholder.

**Estimated complexity:** Medium (5-7 days).

---

## Item 7. input methods (IBus / quail proper)

Phase 5c deferred IBus and left `default-input-method` unchanged
because rfc1345 was missing. For users typing non-latin scripts
this is a real gap.

**Files to touch (existing):**
- `emacs-init/wm/input.el` (currently only configures the quail
  fallback, soft-fails when missing).

**Files to create (new):**
- `emacs-init/user/userland/ibus.el` (lives on the user side after
  item 1):
  - configures an IBus daemon per user-emacs as a make-process
    child, sets the relevant env vars (`GTK_IM_MODULE=ibus`,
    `XMODIFIERS=@im=ibus`, `QT_IM_MODULE=ibus`).
  - hot-swap: `M-x geos-im-set METHOD` toggles between ibus and
    the bundled emacs input methods.

**C-side work:** none.

**Elisp-side work:**
- IBus must be available in the system profile (Guix package
  `ibus`). The user-emacs spawns ibus-daemon at login and tears
  it down at logout via the make-process sentinel.
- quail proper: ensure the rfc1345 and the major non-latin
  methods (cyrillic-translit, greek, hangul, pinyin) are loadable
  in the user-emacs, falling back to ibus only when the user asks
  for something exotic.

**Guix-side work:**
- add `ibus`, `ibus-libpinyin`, `ibus-anthy`, `ibus-hangul` to
  system packages.

**Risks and unknowns:**
- IBus daemon shape: it wants a dbus socket. We do not have a
  system dbus. Spawn IBus in standalone mode (`--no-daemon`
  with our own controlling process) or vendor a per-user
  dbus-daemon that lives only for the session. The standalone
  path is preferred.

**Test plan:**
- freeze-tests: set up the quail rfc1345 method, type a sequence
  that should produce U+00E9, assert the buffer contains it.
- manual: with ibus added, `s-space` cycles between input methods
  in a user-emacs running in QEMU.

**Estimated complexity:** Medium (4-7 days).

---

## Item 8. audio (ALSA wrapper, promoted from preview)

v0.4 item 8 left audio as preview. The audio.el buffer exists but
the play/volume functions shell out to amixer/aplay via
make-process. v0.6 promotes that to a real binding so the path is
typed end-to-end.

**Files to touch (existing):**
- `emacs-init/userland/audio.el` becomes `emacs-init/user/userland/
  audio.el` (item 1 moves it) and gets the new bindings.
- `emacs-init/buffers/audio.el` keeps shape, switches its calls to
  the new functions.

**Files to create (new):**
- `pid1/alsa-module.c` (separate `.so` from the supervisor's
  pid1-module; built for the user-emacs only):
  - `alsa-list-cards () => ((CARD . NAME) ...)` from
    `/proc/asound/cards` parsed in C for speed and simplicity.
  - `alsa-set-volume CARD CONTROL LEVEL` via `snd_mixer_open` +
    `selem_set_playback_volume`.
  - `alsa-get-volume CARD CONTROL` round-trips through the same.
  - `alsa-play-file PATH` via `snd_pcm_open` + a small read-loop
    using the libsndfile wav decoder.

**C-side work:** as above.

**Elisp-side work:**
- replace every make-process call in audio.el with the new module
  function.
- `*audio*` buffer gains `RET` on a card row to set default sink
  (writes to `/var/emacs/users/NAME/asoundrc.sexp`, then loaded
  on next user-emacs spawn).

**Guix-side work:**
- alsa-utils stays in the package list for end-user `alsamixer`
  troubleshooting; we no longer shell to amixer from emacs.

**Risks and unknowns:**
- libsndfile is heavy. If too heavy, drop play-file from item 8
  and let the user spawn aplay manually. Volume is the load-
  bearing piece.

**Test plan:**
- freeze-tests: list cards, set volume to 50, read back, assert
  the read matches.
- manual: in QEMU with `-audiodev pa,id=hda -device intel-hda
  -device hda-output,audiodev=hda`, confirm the *audio* buffer
  shows the card and `M-x audio-volume 50` does not error.

**Estimated complexity:** Medium (4-6 days).

---

## Item 9. Hurd side branch alive + CI'd

The v0.4 spike concluded the Hurd port lives on a side branch.
v0.6's commitment is modest: rebase the Hurd side branch onto v0.6
main and add a CI lane that builds the Hurd image. We do NOT close
the feature gaps; we just keep the branch from rotting.

**Files to touch (existing):**
- side branch `pid1/port_layer.h`, `pid1/port_hurd.c`,
  `guix-system/system-hurd.scm` (rebase onto main).

**Files to create (new):**
- `iso-build/hurd-smoke-test.sh`:
  - boots `guix-system/system-hurd.scm` in QEMU (gnumach+hurd)
    and asserts `geos: emacs userland up` on the console.

**C-side work:**
- port_hurd.c: bring up to parity with port_linux.c for the syscalls
  touched between v0.4 and v0.6 (the new spawn-as-uid, pid1-chown
  from item 4, the rpc socket from item 3).

**Elisp-side work:**
- core/port.el (already exists per the v0.4 plan): grow the
  geos-kernel branch points to skip ibus, audio, exwm on Hurd.

**Guix-side work:**
- update the Hurd channels pin.
- iso-build target `guix system disk-image -t hurd64-raw`.

**Risks and unknowns:**
- IPC story on Hurd: the AF_UNIX rpc socket maps cleanly. SCM_
  CREDENTIALS does not; Hurd's translator-credential model is
  different. v0.6 just disables item 3's authorisation checks on
  Hurd (every verb is uid 0 in the spike kernel), documents it.
- the build matrix doubles. CI time too.

**Test plan:**
- new `iso-build/hurd-smoke-test.sh` per the file list. Minimum
  success: console emacs comes up. Userland buffers absent is
  fine.

**Estimated complexity:** Large (2-3 weeks for the rebase + CI,
not counting feature parity which is its own multi-quarter
project).

---

## Cross-cutting concerns

**voice + commits:**
- every new file follows the
  `;;; filename.el --- one-liner -*- lexical-binding: t -*-` header.
- every commit message lowercase, no prefixes, no em-dashes.
- run `/attribution-scan` and `/no-shell-check` before every commit.
- item 3's RPC log lines must not include passphrases or hashes;
  audit the journal-write paths in core/rpc-server.el explicitly.

**trust boundary:**
- the post-Phase-A invariant is: nothing in the user-emacs has the
  capability to call a pid1-... primitive. The dynamic module is
  not even loaded on that side. Every privileged operation goes
  through the unix socket, which is the only audited path.
- the per-directory rules file under `emacs-init/core/` gains a new
  "trust boundary" section enumerating the verbs the supervisor
  accepts; new verbs require a skeptic review before merge.

**single-thread reality (still):**
- item 3's handlers must be sentinel-driven, item 5's rate-limit
  may sit-for in the *login* surface only, item 6's spawn must not
  block. Same discipline as v0.4 item 2.

**budget for cuts:**
- if v0.6 slips, drop in this order:
  9 (Hurd, side branch only) ->
  8 (audio, stays preview) ->
  7 (input methods, stays preview) ->
  6 (concurrent sessions, stays single-user) ->
  5 (audit + rate-limit, stays "you can fail forever").
- the v0.6 user-visible promise is items 1 to 4: a real userland
  on the user side, persistent dotfiles, privileged ops over a
  documented RPC, a *users* buffer that doesn't need M-: to drive.
  Everything else is gravy.

;;; v06-plan.md ends here
