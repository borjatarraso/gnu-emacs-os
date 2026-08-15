---
ep_version: 1
project: emacs-os
title: GNU/Emacs Operating System (GEOS)
status: PAUSED
last_touched: 2026-07-11
last_touched_text: 11 July 2026
section: top
category: tech
generated: 2026-08-15
ep_locked: false   # set true and this file is never regenerated
---

# GNU/Emacs Operating System (GEOS)

> The Operating System based on GNU/Emacs

🟠 **PAUSED** · last touched **11 July 2026** (last commit)

---

## What this is

Maintainer: Borja Tarraso &lt;borja.tarraso@member.fsf.org&gt;

An operating system where Emacs is the userland and Emacs is PID 1. Short name is GEOS, full name is GNU/Emacs Operating System; the rest of this document uses GEOS.

The interactive shell is eshell. There is no Shepherd. There is no systemd. The first userspace process the kernel starts is a small C program that becomes Emacs and then loads itself back as an Emacs dynamic module, so the supervisor lives inside the supervised process. Every system concept (`top`, `ip a`, `journalctl`, `df`, `apt`) is a buffer with a major mode and a refresh timer.

This is v1.0.0. Emacs is PID 1 on both Linux and canonical Debian GNU/Hurd 0.9, end-to-end through a multi-user EXWM session.  As far as I know, this is the first project where GNU/Emacs runs as PID 1 with Hurd support of this depth.  Per-release notes in [CHANGELOG.md](CHANGELOG.md).

That builds the host-side binaries (`pid1/`, `shstub/`), then runs `guix time-machine` against the pinned channel to produce a qcow2, then boots it under QEMU/KVM. First build is large (~8 GB into `/gnu/store`); subsequent ones are seconds.

For a headless smoke pass:

You need a Linux host with KVM and Guix installed. Boot to a usable EXWM frame takes about eleven seconds. Full instructions in [docs/INSTALL.md](docs/INSTALL.md). The why is in [docs/MANIFESTO.md](docs/MANIFESTO.md), and the manifesto is the document I would actually rather you read first. The picture is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (three zoom levels, including the dual-kernel Linux + Hurd seam).

For Hurd: on a fresh Debian GNU/Hurd 0.9 image, run `install/hurd-bootstrap.sh` as root and reboot. The full recipe (apt prereqs, build, rollback path, init.args format) is in [docs/HURD_BOOT.md](docs/HURD_BOOT.md).

## Start here

- [`README.md`](README.md) — what the project is, in its own words
- [`CLAUDE.md`](CLAUDE.md) — working agreement for a session in this repo

## Run it

```bash
cd ~/claude/emacs-os
make                                  # Makefile default target
```

## The rest of it

**Directories**

- `docs/` — 23 entries
- `emacs-init/` — 7 entries
- `guix-system/` — 7 entries
- `install/` — 1 entry
- `iso-build/` — 14 entries
- `pid1/` — 5 entries
- `shstub/` — 3 entries

**Other documentation**

- [`CHANGELOG.md`](CHANGELOG.md)
- [`plan.txt`](plan.txt)

**`docs/`** holds 100 files.

**Build / config**: `Makefile`

---

## Ownership

<img src="https://www.cortex-university.com/static/brand/lince-logo.png" alt="Lince" width="96" height="96" align="left" style="margin-right:16px" />

**GNU/Emacs Operating System is proudly part of Lince.**

| Company ID | Headquarters |
|---|---|
| 3015071-2 | Helsinki, Finland |

Part of the LINCE company · © All rights reserved


<sub>Standard entry-point card (`index.ep.md`, format v1) — generated 2026-08-15 by Lynx Factory. Regenerating overwrites this file unless `ep_locked: true`.</sub>
