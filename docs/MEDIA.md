<!-- SPDX-License-Identifier: FSFAP -->

# Media inventory and provenance

Every binary media file under version control is listed here with its
origin and license. The repository carries no third-party media; all
images are original work by the maintainer.

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
covers every image listed below. A license notice cannot be embedded
in a PNG, so the copyright and license of each image are stated here,
and again in a README in the same directory as the file
(`docs/img/README.md` for the logos, `docs/runlogs/README.md` for the
screenshots), so an image copied out of the tree alone still carries
its notice. All of the images are released under the all-permissive
license (SPDX: FSFAP): copying and distribution of these images, with
or without modification, are permitted in any medium without royalty
provided the copyright notice and this notice are preserved. The same
notice text is in the "license" section at the end of this file.

## Logos

| File                    | Description                                          | Origin                                                                 | License            |
| ---                     | ---                                                  | ---                                                                    | ---                |
| `docs/img/logo.png`     | Primary project logo, "editor on silicon".           | Original work by Borja Tarraso, 2026. Created from scratch in GIMP.    | FSFAP              |
| `docs/img/logo-256.png` | 256x256 variant of `logo.png` for the README header. | Scaled-down derivative of `logo.png` produced by `convert -resize`.    | FSFAP              |
| `docs/img/logo-128.png` | 128x128 variant for embedded contexts and favicons.  | Scaled-down derivative of `logo.png` produced by `convert -resize`.    | FSFAP              |

The logos contain no third-party trademarks, fonts, or stock-image
elements. The wordmark "GEOS" and the visual motif are original.
The chip silhouette is geometric, drawn from scratch; it depicts no
real product.

## Screenshots

The runlogs directory carries serial-console screenshots captured
from QEMU sessions of GEOS itself on canonical Debian GNU/Hurd 0.9.
Every pixel originates from the GEOS image under test or from
GRUB/Hurd boot output displayed by that image. There is no
third-party UI in any frame.

| File                                                              | Description                                                                                                 | Origin                                                                | License            |
| ---                                                               | ---                                                                                                         | ---                                                                   | ---                |
| `docs/runlogs/2026-05-18-hurd-pid1-boot-screen.png`               | Serial-console capture of the v0.8 Hurd image booting `emacs-init` as PID 1.                                | Captured by Borja Tarraso from QEMU running an image he built.        | FSFAP              |
| `docs/runlogs/2026-05-18-hurd-pid1-emacs-spawn-screen.png`        | Serial-console capture of the supervised Emacs spawn message on the same image.                             | Captured by Borja Tarraso from QEMU running an image he built.        | FSFAP              |
| `docs/runlogs/2026-05-18-hurd-pid1-reboot-rpc-screen.png`         | Serial-console capture of the `host_reboot` Mach RPC path taking down the system.                           | Captured by Borja Tarraso from QEMU running an image he built.        | FSFAP              |
| `docs/runlogs/2026-05-18-hurd-pid1-reboot-aftertype-screen.png`   | Serial-console capture of the post-reboot console output during the same verification cycle.                | Captured by Borja Tarraso from QEMU running an image he built.        | FSFAP              |

The screenshots include text emitted by gnumach and the Hurd
servers under the FSF's copyright; that text is reproduced under
fair-use / de-minimis principles for verification documentation and
does not constitute redistribution of any covered work.

## Policy for new media

Any new binary media file must be added to the table above in the same
commit that introduces the file, and its copyright and license notice
added to the README in the directory where the file lives. If a
contribution carries third-party media, the upstream license must be
listed and a copy of the license text must be added under
`docs/licenses/<media-file>/` before the file can be merged.

The pre-publication check is: every entry in `git ls-files | grep
-Ei '\.(png|jpg|jpeg|gif|svg|webp)$'` must appear in a row above.

## license

Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

Copying and distribution of this file, with or without modification,
are permitted in any medium without royalty provided the copyright
notice and this notice are preserved.  This file is offered as-is,
without any warranty.
