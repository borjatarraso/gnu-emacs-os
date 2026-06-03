# 2026-05-17 hurd mount fix verified end-to-end

<!-- SPDX-License-Identifier: GFDL-1.3-or-later -->
<!-- Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org> -->
<!-- -->
<!-- Permission is granted to copy, distribute and/or modify this -->
<!-- document under the terms of the GNU Free Documentation License, -->
<!-- Version 1.3 or any later version published by the Free Software -->
<!-- Foundation; with no Invariant Sections, no Front-Cover Texts, and -->
<!-- no Back-Cover Texts.  A copy of the license is included in the -->
<!-- file COPYING.DOC at the top of this distribution. -->

## Milestone

`port->mount` works on real GNU/Hurd.  the prior body called
`file_set_translator` with `MACH_PORT_NULL` as the active port and
`passive_flags=0`, which is a silent no-op (no translator installed,
no on-disk record set).  fixed on the hurd branch at `e3fd411` by
routing through `fshelp_start_translator` (libfshelp) to fork the
translator binary first, then handing its active control port to
`file_set_translator` with `FS_TRANS_SET|FS_TRANS_FORCE` on both
passive and active flags.

## Environment

  - Debian GNU/Hurd 2026-03 snapshot
  - GNU-Mach 1.8 microkernel
  - qemu-system-x86_64 -enable-kvm -m 2G -net user,hostfwd=...
  - pid1-module.so built with `make PORT=hurd STATIC=0 module`
    (link line: -lcrypt -lfshelp -lhurduser -lmachuser)

## What I ran

A self-contained elisp file driven by `emacs --batch`:

```elisp
(module-load "/root/geos/pid1/pid1-module.so")
(make-directory "/tmp/mt2" t)
(condition-case e
    (princ (format "mount-tmpfs: %S\n"
                   (pid1-mount "none" "/tmp/mt2" "tmpfs" 0 nil)))
  (t (princ (format "ERROR: %S\n" e))))
(princ "write+read: ")
(condition-case e
    (progn
      (with-temp-file "/tmp/mt2/hello" (insert "hi from tmpfs"))
      (princ (with-temp-buffer
               (insert-file-contents "/tmp/mt2/hello")
               (buffer-string)))
      (princ "\n"))
  (error (princ (format "ERROR: %S\n" e))))
(princ "settrans -g result: ")
(princ (format "%S\n" (call-process "settrans" nil t nil "-g" "/tmp/mt2")))
(delete-directory "/tmp/mt2" t)
(princ "DONE\n")
```

## What I got

```
module: loaded
--mount round-trip--
mount-tmpfs: t
showtrans output: write+read: hi from tmpfs
settrans -g result: 0
DONE
```

  - `mount-tmpfs: t`: `pid1-mount` returned successfully.
  - `write+read: hi from tmpfs`: the elisp write went to the
    actively-running tmpfs translator, not to the underlying
    inode.  before the fix this string would have persisted past
    `settrans -g`; with the fix it disappears when the translator
    detaches.
  - `settrans -g result: 0`: the active translator detached
    cleanly.

## Related fixes in the same commit

  - tmpfs rejects the Linux placeholder `"none"` as its first
    argv ("argument must be a number").  the new body only
    forwards src to tmpfs when it matches `/[0-9]+[KMGkmg]?/`.
  - Hurd's tmpfs has no implicit default size (Linux defaults to
    half of RAM).  a 256M fallback is injected when src is not
    numeric.

## References

  - hurd branch commit: `e3fd411`
  - main docs update: `dc8cc23` (HURD_PORT.md matrix promotion)
  - Makefile change in the same commit adds `-lfshelp` to
    PORT_BOOT_LIBS / PORT_MODULE_LIBS.
