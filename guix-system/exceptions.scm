;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; exceptions.scm, documented deviations from the GNU/Emacs Operating
;; System (GEOS) hard rules, kept in one file so I can grep for
;; "exception:" and see every shortcut still in flight.  each entry
;; has a phase that closes it.  an exception that outlives its phase
;; is a bug.

;; exception: bash-as-/bin/sh
;; rule violated: GEOS hard rule 1, "no shell other than eshell".
;; reason: %base-packages drops bash into the system profile, which
;;   provides /bin/sh via the activation-service-type symlink chain.
;;   guix's own activation script and many %base-services snippets
;;   shell-out to /bin/sh during early boot, so removing bash before
;;   phase 3 (shstub) ships would brick activation. since the
;;   emacs-init-boot-service execs PID 1 BEFORE activation runs, none
;;   of those shell-outs actually fire on a healthy boot, but the
;;   shepherd-fallback path in the boot script (the one that runs if
;;   our execl fails) still expects /bin/sh.
;; closure: phase 3 ships shstub/sh, exposes it via extra-special-file
;;   at /bin/sh, and we drop bash from %base-packages by overriding
;;   the package set. when phase 3 lands, delete this entry.
;; tracked since: 2026-05-06.

;; this file is loaded for documentation, not for build effects. it
;; deliberately exports nothing.

(define-module (exceptions)
  #:export ())
