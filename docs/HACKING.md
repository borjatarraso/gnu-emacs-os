<!-- SPDX-License-Identifier: FSFAP -->

# hacking on GEOS

Maintainer-side notes. External contributors should read
`docs/CONTRIBUTING.md`; this file is for the person sitting in the
maintainer chair.

## dual-remote sync, GitHub and Savannah

GEOS publishes to two forges. Savannah is the canonical upstream;
GitHub is the read-only mirror for discoverability. Both must hold
identical refs at all times.

The cheap way is to overload `origin` with two push URLs. One `git
push origin <ref>` then writes to both forges in a single command.

Setup, run once after Savannah approval lands the SSH access:

```
git remote set-url origin git@git.savannah.nongnu.org:/srv/git/geos.git
git remote set-url --add --push origin git@git.savannah.nongnu.org:/srv/git/geos.git
git remote set-url --add --push origin git@github.com:borjatarraso/gnu-emacs-os.git
```

After that:

```
git remote -v
# origin  git@git.savannah.nongnu.org:/srv/git/geos.git (fetch)
# origin  git@git.savannah.nongnu.org:/srv/git/geos.git (push)
# origin  git@github.com:borjatarraso/gnu-emacs-os.git (push)
```

Day-to-day:

```
git push origin main           # writes to both
git push origin --tags         # writes tags to both
git push origin hurd           # writes the side branch to both
```

`git fetch origin` reads only from the first URL, which is what
you want; Savannah is canonical. If GitHub ever drifts ahead (it
should not, but a webhook'd commit from the web UI could in
principle), reconcile by re-pushing the Savannah HEAD to GitHub.

### what a divergent push looks like

If the two forges diverge, the push prints two blocks of progress.
A failure on one forge does NOT roll back the other; git's
multi-pushURL is best-effort, not atomic. Recovery:

  - if Savannah accepted, GitHub rejected: re-run `git push origin
    main` to retry just the rejected URL; remove the accepted URL
    temporarily with `git remote set-url --delete --push origin
    <accepted-url>` if necessary.
  - if GitHub accepted, Savannah rejected: same shape, swap the
    URLs. Savannah is canonical so this is the worse case; reach
    out to a Savannah admin if it persists.

### signed tags travel via --tags

Every release tag is GPG-signed (key `4FD9DE401BD9C40C`). A tag
push needs `--tags` or `--follow-tags`; ordinary branch pushes do
NOT include tags. After cutting a release, the two commands are:

```
git push origin main
git push origin --tags
```

Both write to both forges per the multi-pushURL config.

## attribution-scan over commit history

The repo enforces zero references to AI tooling, vendor names,
and machine-generation markers, not just at HEAD but across all
commit messages, tag annotations, and historical blobs. The
local `/attribution-scan` covers HEAD; the four-pass historical
sweep below covers the rest. Run it before any forge migration
or any squash that would rewrite history publicly.

The exact regex and exclude list live in the local rules
directory's scan tooling, plus the GitHub Action workflow at
`.github/workflows/checks.yml` (the workflow stores the regex
base64-encoded so it does not trip its own scan). The four passes
are, in shape:

  - PASS 1: `rg -i -e $REGEX .` against the working tree, with
    the rules-file exclude list.
  - PASS 2: `git log --all --pretty=format:'%H%n%B%n---' | rg -i
    -e $REGEX` against every commit message.
  - PASS 3: iterate `git tag`, dump each tag's contents with
    `git for-each-ref`, pipe to `rg -i -e $REGEX`.
  - PASS 4: iterate `git rev-list --all --objects`, `git cat-file
    -p` each blob, `grep -iEn $REGEX` each, prefix matches with
    the path; same exclude list as PASS 1.

A clean run = zero output on every pass. If any pass hits, fix
with `git filter-repo --replace-text REPLACEMENTS --replace-message
REPLACEMENTS` before publishing.

## releasing

Cut a release on Linux side first, verify in QEMU, then Hurd
side, then tag.

```
# 1. ensure clean
git status
./iso-build/smoke-test.sh
# 2. update CHANGELOG.md, README.md state line
# 3. commit
git commit -s -S -m "vX.Y: <one-line summary>"
# 4. tag
git tag -s vX.Y -m "$(cat <<'EOF'
vX.Y: <summary>

<body explaining the release, what works, what does not>
EOF
)"
# 5. push to both forges
git push origin main
git push origin --tags
```

For Hurd-side releases that ship on the `hurd` branch only,
substitute `hurd` for `main`. Tag from whichever branch is the
release head.

## emergency: rewriting history publicly

If a commit, blob, or tag annotation leaks something that must
not be on the public mirrors:

  1. Identify the offending object with the four-pass sweep
     above.
  2. Write a `replacements.txt` for `git filter-repo` (see the
     attribution-scan recovery notes in this file).
  3. Run `git filter-repo --force --replace-text replacements.txt
     --replace-message replacements.txt`.
  4. Filter-repo removes the `origin` remote as a safety net.
     Re-add it: `git remote add origin <savannah-url>` plus the
     two `set-url --add --push` lines above.
  5. Re-sign every tag (filter-repo invalidates signatures).
     The reusable script lives under `iso-build/resign-tags.sh`.
  6. Force-push: `git push --force origin main`, `git push
     --force origin hurd`, `git push --force --tags origin`.

This is destructive to anyone who has already cloned. Send a
heads-up before, not after. After force-push, anyone with a
clone needs to re-clone or `git reset --hard origin/main`.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
