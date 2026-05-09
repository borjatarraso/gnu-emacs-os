;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; channels.scm, pinned channels for GNU/Emacs Operating System (GEOS).
;;
;; reproducibility is a hard rule. %guix-pin below is the literal
;; commit. workflow when bumping:
;;
;;   1. on a known-good build host, run: guix describe -f channels
;;   2. copy the (commit "...") line for the guix channel into this file
;;   3. update %guix-pin and the "last bumped" date
;;
;; do this every time the channel is bumped. the cost of forgetting
;; the pin is non-reproducible builds, which means a "works on my
;; machine" OS, which is the exact thing this project refuses to be.
;; an earlier draft used `(error ...)` as a sentinel until the pin was
;; written; the sentinel is gone now that the pin is real, but the
;; convention stays: never commit a placeholder.

(define %guix-pin
  ;; pinned commit from `guix describe` on the build host. bump this
  ;; intentionally, never silently. last bumped: 2026-05-06.
  "230aa373f315f247852ee07dff34146e9b480aec")

(list (channel
       (name 'guix)
       (url "https://git.savannah.gnu.org/git/guix.git")
       (branch "master")
       (commit %guix-pin)
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
