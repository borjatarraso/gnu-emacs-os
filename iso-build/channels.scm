;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
;;;
;;; This file is part of GEOS.
;;;
;;; GEOS is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; GEOS is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GEOS.  If not, see <https://www.gnu.org/licenses/>.
;; channels.scm, the pinned channel set the ISO is built against.
;;
;; this is a verbatim copy of the channel pin in
;; ../guix-system/channels.scm, kept here so the iso-build directory
;; is a self-contained reproducibility unit. someone with just this
;; directory and a guix daemon can run:
;;
;;   guix time-machine -C channels.scm -- \
;;       system image -L .. build.scm
;;
;; and get a byte-identical (modulo the kernel's build-id) ISO.
;;
;; bumping this pin: do it in lockstep with guix-system/channels.scm.
;; the two files MUST agree, otherwise the ISO drifts away from the
;; qcow2 dev image and "works on my qcow" stops implying "works on
;; the ISO". both files carry %guix-pin so a grep -R %guix-pin
;; surfaces any drift. last bumped: 2026-05-06, captured via
;; `guix describe -f channels' on the build host.

(define %guix-pin
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
