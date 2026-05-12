# GEOS user guide

Day to day use of GNU/Emacs Operating System (GEOS). Assumes you have
already booted the image (see `docs/INSTALL.md` for that). The point of
this document is to answer "I am at the EXWM splash, now what".

Maintainer: Borja Tarraso <borja.tarraso@member.fsf.org>

## the model in two sentences

The whole OS is one Emacs process. `M-x` is the universal verb; every
system concept is a buffer.

If you remember nothing else from this guide: when you would normally
reach for a terminal command, instead think of which buffer would show
the same data, and `M-x` your way there.

## the very first things to learn

```
M-x eshell                open an eshell. there is no other shell.
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

The shell is eshell. There is no bash, no dash, no zsh; `/bin/sh` is a
50 line C stub that forwards `sh -c "<cmd>"` to an eshell evaluation
via `emacsclient`. This is by design and it is not changing.

What you can do in eshell that you cannot in bash:

  - `(+ 1 2)`. eshell evaluates Lisp at the prompt.
  - pipes that pass Lisp values, not just text bytes.
  - `*foo*`-style buffer-redirection: `ls > #<buffer foo>`.
  - `M-x` from the prompt: just type `find-file` and hit enter.

What you cannot do that you might miss:

  - heredocs. eshell does not have them.
  - `$(())` arithmetic. use `(+ ...)`.
  - process substitution (`<(cmd)`). use a temp buffer.

If a Guix package post-install script depends on a real POSIX shell
feature, the workaround lives in `guix-system/exceptions.scm`; the
list is short.

## the system-concept buffers

Each one is a `special-mode` derivative, read-only by default,
auto-refreshing on a short timer. Press `g` to refresh on demand,
`q` to bury the buffer.

### `*processes*`

The kernel process table, parsed from `/proc/[0-9]+/stat`. Columns:
PID, state, RSS, command. Kill with `k` (sends SIGTERM), force-kill
with `K` (SIGKILL). `RET` on a row opens that PID's `/proc/<pid>/`
directory in dired.

### `*network*`

Interfaces with addresses, link state, RX/TX counters, plus the
routing table from `/proc/net/route`. The OS only brings up loopback
automatically; for anything else use `pid1-set-address` directly from
elisp until the DHCP work lands (Phase B of the v0.4 plan). The buffer
refreshes every two seconds.

### `*journal*`

A live tail of `/dev/kmsg` (kernel ring buffer) via a `dd` subprocess
supervised by core/supervise.el. `f` follows the tail, `F` stops
following, `/` prompts for a substring filter.

### `*services*`

The supervised-process registry from `core/supervise.el`. Every
service registered with `defservice` (the journal follower today,
DHCP and friends as Phase B of v0.4 lands) shows up here with its
restart policy, restart count, and last-death timestamp. `r`
requests an immediate restart. `D` deregisters (the supervisor will
not respawn it). Xorg is supervised by PID 1 directly, not by this
registry, because it has to come up before Emacs.

### `*disks*`

Block devices from `/proc/partitions` plus mounts from
`/proc/mounts`. No shell-out to `df` or `lsblk`.

### `*packages*`

The active Guix profile, rendered from the on-disk manifest. Read-only;
to actually change package state you reconfigure the system (the
`*reconfigure*` buffer is item 3 of the v0.4 plan, see
`docs/v04-plan.md`).

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
image. There is no in-system `M-x customize-system` yet (item 3 of
the v0.4 plan, see `*reconfigure*` in `docs/v04-plan.md`).

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
