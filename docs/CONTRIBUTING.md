# contributing to GEOS

GNU/Emacs Operating System (GEOS) accepts patches. The process is
small but strict; this document is the whole of it.

Maintainer: Borja Tarraso <borja.tarraso@member.fsf.org>

## scope

If you are not sure your change is in scope, open an issue first and
describe what you want to do. Some classes of change I will probably
say no to:

  - adding a real POSIX shell. Not happening. See `MANIFESTO.md`.
  - adding a Shepherd service. Service supervision is Elisp; if you
    need a service, register it with `core/supervise.el`.
  - introducing threads or async runtimes. Single-threaded Emacs is
    the cost of admission.
  - Wayland anything. EXWM is X11 by definition.

Things I will almost certainly say yes to:

  - bug fixes with a reproducer.
  - new system-concept buffers (run `/buffer-it` to scaffold one).
  - portability fixes for hardware I do not have.
  - documentation that makes a confused reader less confused.

## developer certificate of origin

Every commit must carry a `Signed-off-by` trailer. This is the same
DCO the Linux kernel uses. By signing off, you assert that you wrote
the patch (or have the right to submit it under the same license) and
that you accept the public record of your authorship.

Add the trailer with `git commit -s`. The message will end with:

```
Signed-off-by: Your Name <your.email@example.com>
```

The name and email must match a real, reachable identity. Patches with
fictional sign-offs will be returned.

## GPG signing

Commits to `main` are GPG-signed. To sign your patches:

```
git commit -s -S
```

I sign with the key at the bottom of `AUTHORS` (fingerprint
`4491 8A01 3087 BBF8 4D41  C229 4FD9 DE40 1BD9 C40C`). If you do not
already have a GPG key, generate one with `gpg --full-generate-key`,
publish it to `keys.openpgp.org`, and add the signing config to your
local clone:

```
git config user.signingkey <your-keyid>
git config commit.gpgsign true
```

Do not enable signing globally if you contribute to other projects
that do not require it; scope it to this clone.

## the local gates

Every patch must pass these scans before I will merge it. They run
fast; run them locally before you push.

### `/attribution-scan`

Greps for forbidden tokens (vendor names, machine-generation markers,
marketing-flavored phrasing). Empty output is pass. The repo is one
author by policy (see `AUTHORS`); patches that introduce attribution
noise are rejected without comment.

### `/no-shell-check`

Greps for code paths that invoke a POSIX shell from C, Elisp, or
Scheme. Empty output is pass. The list of documented exceptions
lives in `guix-system/exceptions.scm` and the `shstub/` directory
itself, which is the whole point of the stub.

### `/ricer-check`

Invokes the skeptic reviewer against `emacs-init/`. Catches:

  - `use-package` blocks without a `:comment` justification.
  - packages added but never invoked.
  - keybindings that conflict with EXWM defaults.
  - defvars without docstrings.
  - files over 500 lines (split candidates).

`/ricer-check` is advisory for warnings, blocking for errors. If the
skeptic flags something, address it or argue it back in the patch
description.

### `/smoke-test`

Boots a qcow2 headlessly with the serial console wired to a tmpfile
and waits for the pid1 + userland sentinel markers. Catches the
class of regression where a silent xorg.conf parse error leaves the
session dark. Run it after any change to `pid1/`, `guix-system/`, or
anything Xorg-adjacent.

```
./iso-build/smoke-test.sh                # build then test
./iso-build/smoke-test.sh /path/to.qcow2 # test existing image
```

Exit codes: 0 pass, 1 fail (with marker and last 30 serial lines
printed), 2 timeout.

### `/freeze-test`

Loads `iso-build/freeze-tests.el` inside a booted VM and runs the
abuse suite (runaway `(while t)`, catastrophic regex, slow network,
broken TRAMP, literal `(kill-emacs)`). Confirms the panic buffer
keeps the OS interactive. Required to pass before any release tag.

## style

Voice rules apply to every committed artifact (code, comments, commit
messages, documentation, error strings, configuration files):

  - lowercase first person singular in prose
  - no em-dashes (use commas, parentheses, or two sentences)
  - no marketing rhythm; no "X but also Y" inflation
  - no machine-generation artifacts; no vendor mentions; no
    co-author trailers other than your DCO sign-off
  - comments read like something written at 1 AM while debugging,
    opinions and the occasional profanity are fine where they fit
  - two-sentence paragraphs are fine

Lowercase commit subjects, no `feat:` / `fix:` / `chore:` prefixes.
Reference an issue if there is one. Sign-off and GPG-sign every
commit (`git commit -s -S`).

### Elisp

  - Lexical binding on every file:
    ```
    ;;; filename.el --- one-line description -*- lexical-binding: t -*-
    ;;; SPDX-License-Identifier: GPL-3.0-or-later
    ```
  - `use-package` with a `:comment "why"` for every package.
  - No global state outside `defvar` with a docstring.
  - Errors go through `panic-handle`, never bare `error`.
  - No `shell-command`, `shell-command-to-string`, or `call-process`
    with a `/bin/sh` wrapper. Use `make-process` directly.
  - Buffer modes derive from `special-mode` unless there is a real
    reason not to. Read-only by default.
  - Project keybindings live under `C-c e <something>`.
  - Long-running services register with `core/supervise.el`.

### C (pid1, shstub, dynamic module)

  - C11. No GNU extensions unless necessary.
  - Every syscall checked, errno reported via `console()` to
    `/dev/console` (gated on `#ifndef PID1_MODULE`).
  - No `malloc` in PID 1 hot paths; allocate at startup, reuse.
  - Each function has a one-line comment stating its invariants.
  - `static` everything that does not need to escape the
    translation unit.
  - The PID 1 binary and the dynamic module compile from the same
    source, gated by `-DPID1_MODULE`. Do not let those two branches
    diverge in any externally observable behavior.

### Scheme (Guix)

  - Follow the Guix style guide (`(use-modules ...)`, two-space
    indent, no tabs).
  - Pin channels; never use `--with-latest`.
  - Local files referenced by the operating-system record must
    exist on disk before the build runs (Guix dereferences them at
    expansion time, not at gexp evaluation).

### Commit messages

  - Lowercase the subject. No `feat:`, `fix:`, `chore:` prefixes.
  - Subject under 72 columns. One blank line. Body wraps at 72.
  - The body explains the why, not the what; the diff is the what.
  - Reference an issue if there is one (`closes #N`).
  - Sign-off + GPG sig (`git commit -s -S`).

Example:

```
hostname: apply /etc/hostname from PID 1 at boot

Guix bakes the hostname into /etc/hostname via the
(host-name "lambda") field, but with no Shepherd we have nothing
that calls sethostname(2) on it. Wire it through the dynamic module
so /proc/sys/kernel/hostname matches the file before any userland
reads it.

Signed-off-by: Borja Tarraso <borja.tarraso@member.fsf.org>
```

## per-area owners

Different parts of the tree have different review expectations.

```
pid1/                     skeptic mandatory before merge.
emacs-init/core/          skeptic mandatory before merge.
emacs-init/user/          EXWM and userland; regressions are
                          user-visible. smoke + freeze required.
emacs-init/buffers/       new buffers go through /buffer-it.
guix-system/              channel pin must agree across the two
                          channels.scm files.
shstub/                   shell-out exceptions documented inline.
docs/                     voice rules above; lowercase everything.
```

## what to put in your patch description

  - what the patch does (one paragraph).
  - why (the motivating bug, regression, or feature gap).
  - how you verified it: which tests passed, which VM you booted, what
    you saw.
  - any followups you noticed but did not address.

The smaller the patch, the easier it is to merge. A patch that does
one thing and explains why is always preferred over a patch that does
five things and shrugs.

## reporting bugs without a patch

Open an issue with:

  - the exact ISO or qcow2 store hash.
  - the QEMU invocation that reproduced it (or the hardware specs if
    bare metal).
  - the `*panic*` buffer contents at the time of the bug.
  - the last 30 lines of `/dev/console` output (`/var/log/messages`
    is not a thing on this system; the kernel ring buffer is the log).
  - what you expected, what you got, and one of the two if you cannot
    decide which is wrong.

Without those four items I cannot do anything useful.

## license

GEOS is GPL-3.0-or-later. By submitting a patch under DCO sign-off
you agree your contribution ships under the same license. SPDX
headers on every new file are mandatory; copy them from a neighboring
file in the same directory.

Welcome.
