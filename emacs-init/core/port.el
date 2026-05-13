;;; port.el --- kernel-portability seam for the elisp data layer -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; companion to pid1/port_layer.h on the C side.  the pid1 port layer
;; abstracts syscalls (mount, reboot, ioctl-via-pfinet, ...) so the
;; supervisor can run on linux today and on hurd later without forking
;; the binary.  this file does the same job at the elisp layer: every
;; buffer that reads /proc or /sys is reading a linux-only surface,
;; and a hurd port needs a branch point on the read side too.
;;
;; the contract is intentionally small.  one defvar (`geos-kernel'),
;; two predicates (`geos-kernel-linux-p', `geos-kernel-hurd-p'), one
;; helper for "this code path is not implemented here"
;; (`geos-port-unimplemented').  consumers branch on the predicate at
;; the data-source layer, NOT at the render layer: the *network*
;; buffer must not care which kernel it is on; only the function that
;; pulls interface counters does.
;;
;; what this file does NOT do: it does not provide adapters for every
;; data source.  there is no `geos-port-read-mounts' here.  i tried
;; that shape and it pushed every consumer into a defgeneric-style
;; protocol that read worse than a single `cond' in each call site.
;; the linux paths are by far the bulk of the code and pulling them
;; behind a one-method protocol just hides where the linux-isms live.
;; instead, consumers branch inline with `(cond ((geos-kernel-linux-p)
;; ...) ((geos-kernel-hurd-p) ...))` and the linux arm is the existing
;; code, verbatim.  zero-behavior-change on linux is the whole point
;; of step 2.
;;
;; the GEOS_KERNEL env var is the source of truth.  pid1 will export
;; it at boot once the hurd port lands (step 4 of the work order in
;; docs/v04-item11-hurd-spike.md).  for now nothing exports it; we
;; default to 'linux and that is the only value any consumer ever
;; sees.  TODO(hurd): pid1 exports GEOS_KERNEL=linux on linux and
;; GEOS_KERNEL=hurd on hurd, both as part of the per-process env
;; passed to emacs.  the export is intentionally NOT in this file: a
;; userland change should not require touching pid1 just to flip the
;; default.

(require 'panic)

(defvar geos-kernel
  (intern (or (getenv "GEOS_KERNEL") "linux"))
  "Symbol naming the running kernel.
read from the GEOS_KERNEL environment variable at load time and
interned.  pid1 sets this in the child env once the hurd port has
landed; until then GEOS_KERNEL is unset on every boot we ship and
this defvar resolves to \\='linux.

valid values today: \\='linux, \\='hurd.  any other value still
works mechanically (every predicate just returns nil and consumers
fall through to `geos-port-unimplemented'), but the boot will be a
parade of \"feature X not implemented on kernel Y\" entries in
*panic*, which is the right loud-failure mode for an unknown
kernel.

this is a defvar, not a defconst: a dev session can `setq' it to
\\='hurd to exercise the hurd code paths against the linux backend
without rebooting.  obviously the hurd arms will mostly call
`geos-port-unimplemented' on linux because the kernel surfaces
they want are not there; this is a developer affordance, not a
supported boot mode.")

(defun geos-kernel-linux-p ()
  "Return non-nil if the running kernel is linux."
  (eq geos-kernel 'linux))

(defun geos-kernel-hurd-p ()
  "Return non-nil if the running kernel is hurd."
  (eq geos-kernel 'hurd))

(defun geos-port-unimplemented (feature)
  "Route a \"not implemented on this kernel\" event through panic-handle.
FEATURE is a short symbol or string naming the affected concept,
e.g. \\='disks-buffer, \\='install-wizard.  the message lands in
*panic* with the current `geos-kernel' value so a post-mortem can
tell which kernel the surface failed on.

returns nil so callers can use `(or (linux-path) (geos-port-
unimplemented \\='thing))' to fall through cleanly.  does NOT
signal: the whole point of routing through panic-handle is that
one missing-feature event must not abort the rest of the boot."
  (panic-handle
   (list 'port-unimplemented feature geos-kernel)
   (cons 'geos-port-unimplemented feature))
  nil)

;; consumer notes, kept here so the next reader can see the whole
;; portability picture in one place:
;;
;;   - core/network.el reads /proc/net/dev and /proc/net/route.  on
;;     hurd, the natural source is the pfinet translator at
;;     /servers/socket/2; the parser layer needs a hurd adapter that
;;     populates the same plist shape.  branch lives in network.el at
;;     `network-read-proc-net-dev' and `network-read-proc-net-route'.
;;
;;   - core/state.el `state--detect-mode' reads /proc/mounts to decide
;;     whether /var is ext4 or tmpfs.  hurd has a different mount-list
;;     surface (procfs translator approximates this; walking /servers
;;     is the alternative).  branch lives in `state--detect-mode'.
;;
;;   - buffers/processes.el reads /proc/<pid>/status.  hurd's procfs
;;     translator approximates the linux /proc layout so the existing
;;     reader is expected to work; column ordering may differ on hurd
;;     and the renderer notes the assumption.
;;
;;   - buffers/disks.el reads /sys/block.  hurd has no sysfs; the
;;     buffer's data-source layer detects hurd and renders an
;;     unimplemented message via `geos-port-unimplemented'.
;;
;;   - install/disk.el also reads /sys/block.  install wizard is not
;;     load-bearing for the hurd spike; the entry refuses with a
;;     clear error on hurd, no branched implementation.
;;
;;   - early-init.el reads /proc/cmdline.  hurd's procfs translator
;;     exposes /proc/cmdline too, so the existing reader works as-is.
;;     no branch needed.
;;
;;   - user/userland/uname.el reads /proc/sys/kernel/{ostype,osrelease,
;;     version,hostname} to synthesize the eshell `uname' output.  the
;;     hurd procfs translator does not expose those four nodes (only
;;     /proc/<pid>/* and a handful of summary nodes).  branch lives in
;;     `geos--uname': linux arm reads /proc as before, hurd arm
;;     synthesizes from Emacs built-ins (`system-name',
;;     `emacs-build-time', literal "GNU"/"0.9" placeholders).  the
;;     placeholder release will get a real source once the side-branch
;;     port wires a Mach-RPC equivalent.
;;
;;   - services/journal-tail.el spawns `dd if=/dev/kmsg' under
;;     supervise.el.  /dev/kmsg is linux-only; on hurd the service is
;;     still registered (so M-x services renders the same row across
;;     kernels) but with :autostart nil so the supervisor never spawns
;;     the dd.  v0.8 will replace this with a hurd-native source (a
;;     mach-rpc verb against the kernel log server).  branch lives at
;;     the supervise-register call, conditioned on
;;     `geos-kernel-linux-p'.
;;
;;   - user/userland/audio.el reads /proc/asound/cards for the
;;     ALSA card list.  hurd has no ALSA; the branch lives in
;;     `audio-list-cards' (linux arm reads /proc/asound/cards;
;;     hurd arm routes `geos-port-unimplemented' and returns
;;     nil).  buffers/audio.el's `audio-buffer--render' branches
;;     up front to `audio-buffer--render-hurd' which draws a
;;     "not implemented on kernel X" banner with no /proc reads.
;;     v0.8 will replace this with a Hurd-native audio path
;;     (likely an OSS-style /dev/audio translator or a Mach-RPC
;;     verb against a future sound server).
;;
;;   - buffers/journal.el has a fallback in-buffer dd spawner
;;     `journal-buffer--start-kmsg' for the dev-host case where the
;;     supervisor is not running.  on hurd the spawner branches up
;;     front: routes a clean `geos-port-unimplemented' for
;;     'journal-kmsg, drops a "no /dev/kmsg on this kernel" banner
;;     into the buffer, and returns nil.  panic + messages tails are
;;     unaffected and keep flowing.

(provide 'port)
;;; port.el ends here
