;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; build.scm, the iso9660 image entry point for GNU/Emacs Operating
;; System (GEOS).
;;
;; this file is the FILE argument to `guix system image'. it loads
;; the operating-system record from ../guix-system/system.scm and
;; wraps it in the built-in iso9660 image-type. evaluating this file
;; returns an <image> record, which is exactly what
;; `guix system image' will turn into an .iso under /gnu/store.
;;
;; usage from this directory:
;;
;;   guix time-machine -C channels.scm -- \
;;       system image -L .. build.scm
;;
;; the -L .. is needed so the (load ...) below resolves the
;; ../guix-system/system.scm path when guix sets cwd to a build
;; sandbox. -t is NOT passed: the image-type is baked into the
;; <image> record we return, so guix uses it as-is.
;;
;; channel pinning lives in channels.scm next to this file. that pin
;; is the entire reproducibility story for the ISO; without it the
;; closure drifts every time a substitute is rebuilt upstream. never
;; build the ISO without `guix time-machine -C channels.scm'.

(use-modules (gnu image)
             (gnu system)
             (gnu system image))

(define %emacs-os
    ;; load the operating-system record verbatim. (load ...) returns
    ;; the value of the last form, and system.scm ends in the
    ;; (operating-system ...) record, so this binding IS that record.
    ;;
    ;; the path is anchored to the location of THIS file. we cannot
    ;; rely on (current-filename), guix's system loader uses
    ;; primitive-load which leaves it #f. instead we walk %load-path
    ;; for ./guix-system/system.scm; -L .. on the guix invocation
    ;; puts the repo root on %load-path, so the search resolves
    ;; whether the user runs from iso-build/ or from the repo root.
    (load (or (search-path %load-path "guix-system/system.scm")
              (error "build.scm: cannot find guix-system/system.scm \
on %load-path; pass -L <repo-root> to guix system image"))))

(define %iso-image-type
    ;; built-in. lookup-image-type-by-name walks %image-types in
    ;; (gnu system image) and returns the iso9660 entry. if guix ever
    ;; renames it (it will not, this name is in the manual) the
    ;; lookup returns #f and the image-type-constructor below will
    ;; loudly explode, which is the failure mode I want.
    (lookup-image-type-by-name 'iso9660))

;; the value of this file, an <image> record. guix system image
;; consumes this directly: no `-t' flag, no extra wrapping.
((image-type-constructor %iso-image-type) %emacs-os)
