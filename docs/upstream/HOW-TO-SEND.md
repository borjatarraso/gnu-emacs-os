<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->

<!-- operator runbook for filing the four upstream-deferred items -->

# How to send the four upstream filings

This is the one-page recipe for getting items 1-4 of the v0.9.24
upstream-deferral bucket actually filed.  Seven emails plus one
attached `.patch` file.  Run through them in the order below so the
cross-references between threads (emacs filing pointing at hurd
filing, debian filing pointing at gnumach filing) stay coherent.

## Files

  emails/01-pflocal-emacs-patch.txt          -> bug-gnu-emacs@gnu.org
  emails/02-pflocal-hurd-rfc.txt             -> bug-hurd@gnu.org
  emails/03-pfinet-counters-rfc.txt          -> bug-hurd@gnu.org
  emails/04-audio-rfc-hurd.txt               -> bug-hurd@gnu.org
  emails/05-audio-packaging-debian.txt       -> debian-hurd@lists.debian.org
  emails/06-xorg-evdev-debian.txt            -> debian-hurd@lists.debian.org
  emails/07-xorg-gnumach-kbd.txt             -> bug-hurd@gnu.org

  patches/0001-emacsclient-suppress-ENOPROTOOPT-from-SO_RCVTIMEO.patch
    (attach to email 01)

## Order

1. **Email 01** first.  This is the only one with a real working
   patch.  bug-gnu-emacs is debbugs-backed; once it lands you get
   a bug number `bug#NNNNN` you can reference from email 02.

2. **Email 02** second, *with the bug#NNNNN from email 01 quoted in
   the body* so the pflocal-vs-emacs threads stay linked.  Easiest
   is to wait one day after sending 01 so the bug number is
   assigned and visible in the debbugs archive.

3. **Email 03** third.  Standalone, no cross-reference needed.

4. **Email 04** fourth.  Standalone RFC.  Mention in the body that
   email 05 (packaging side) is filed in parallel.

5. **Email 05** fifth.  Cross-reference email 04 in the body (the
   bug-hurd RFC is the upstream side of the same gap).

6. **Email 06** sixth.  Cross-reference email 07 in the body.

7. **Email 07** seventh.  Cross-reference email 06 in the body.

## Mail-client mechanics

Each file uses the same shape:

```
To: <list address>
Subject: <subject line>
From: Borja Tarraso <borja.tarraso@member.fsf.org>

---8<---  body below this line  ---8<---

<body>
```

Two ways to send:

- **mu4e / notmuch / gnus**: `C-x m`, paste the To / Subject / From
  into the headers, paste the body below the `--text follows this
  line--` separator, `C-c C-c` to send.
- **mutt / aerc / plain `mail`**: pipe the body in stdin,
  `--subject=...`, `From:` in the body header.  e.g.
  `mutt -s "$(grep ^Subject: emails/01-...txt | cut -d' ' -f2-)" \
        bug-gnu-emacs@gnu.org < <(sed '1,/^---8<---/d' emails/01-...txt)`

For email 01 the patch is a separate file; attach it (`a` in mutt
after composing the body) or paste inline below the body with a
`Patch follows:` header (debbugs picks both up).

## Patch path alternative for emacs (email 01)

If you would rather go through git format-patch + `git send-email`
than paste the diff inline:

  cd /path/to/emacs.git
  git checkout master && git pull
  # apply by hand or copy the hunk from
  # docs/upstream/patches/0001-...patch into lib-src/emacsclient.c
  git add lib-src/emacsclient.c
  git commit -F docs/upstream/patches/0001-...patch
  # (or write the same commit message by hand)
  git format-patch -1 -o /tmp/
  git send-email --to=bug-gnu-emacs@gnu.org /tmp/0001-*.patch

`git send-email` is the canonical emacs-side workflow; the inline
paste in email 01 is just the lower-friction alternative for
operators who do not have a configured msmtp / sendmail / etc.

## MR / PR alternative routes

Where a list-post email is not the cultural fit, the upstream
equivalents are:

  emails 02 / 03 / 04 / 07  (bug-hurd, the Hurd side)
    Savannah tracker: https://savannah.gnu.org/bugs/?group=hurd
    Open a "Submit New" item; paste the email body as the
    description, the same subject as the summary.  Reaches the
    same maintainers; bug-hurd@gnu.org is mirrored into the
    tracker activity stream.

  emails 05 / 06  (debian-hurd, packaging side)
    Salsa MR against the affected source package.  For email 05
    the relevant repo is the debian-installer / live-build tasks
    on salsa.debian.org/installer-team or similar; the list post
    is the right first step because the maintainers decide which
    package the bundle change belongs in.  For email 06 the repo
    is salsa.debian.org/xorg-team/driver/xserver-xorg-input-evdev
    (one-line debian/control change for the Architecture list,
    once the shim translator exists).
    For a Debian BTS report (canonical for "this package has a
    bug on hurd-amd64") see `reportbug --bts=debian` against the
    affected source package; this is the alternative to the
    debian-hurd list post.

## Signing

GPG-sign the outbound emails if you have a key.  bug-gnu-emacs
ignores signatures; bug-hurd archives them; debian-hurd appreciates
them.  Either path works without signing.

## After sending

Update HURD_PORT.md and the four `docs/upstream/*.md` drafts with
the resulting bug numbers / message-ids so future-you can find the
threads.  Sketch:

    Filed-at: https://debbugs.gnu.org/cgi/bugreport.cgi?bug=NNNNN
    Message-Id: <YYYYMMDDHHMMSS.borja.tarraso@member.fsf.org>

These belong in the existing `filed-by:` block at the bottom of
each `docs/upstream/*.md` draft.

## Status fields after sending

Move the row in HURD_PORT.md from "deferred-upstream" to
"deferred-upstream (filed bug#NNNNN, YYYY-MM-DD)" once the bug
number is in hand.
