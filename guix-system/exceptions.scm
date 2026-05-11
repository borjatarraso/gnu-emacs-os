;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; exceptions.scm, documented deviations from the GNU/Emacs Operating
;; System (GEOS) hard rules, kept in one file so I can grep for
;; "exception:" and see every shortcut still in flight.  each entry
;; has a phase that closes it.  an exception that outlives its phase
;; is a bug.

;; exception: dhcpcd-as-dhcp-client
;; rule violated: GEOS hard rule 1, "no shell other than eshell" (we
;;   shell out to an external binary, even though dhcpcd is itself a C
;;   program and not a shell); also the spirit of "every system concept
;;   is a buffer in elisp", since DHCP is a system concept and the
;;   client is not in elisp.
;; reason: a from-scratch RFC2131 client in elisp would need raw
;;   socket support that emacs does not expose, plus DHCP option
;;   parsing, plus lease-time bookkeeping.  not v0.4-sized.  dhcpcd
;;   is the smallest C client in (gnu packages admin), we pin it via
;;   system.scm and strip its non-IP-getter ambitions at spawn time:
;;     services/dhcp.el passes -1 -q -B -K --nohook resolv.conf
;;                            --nohook ntp.conf
;;   so dhcpcd runs as a one-shot ioctl driver, exits after BOUND, and
;;   never touches our resolv.conf.  the spawn itself is sentinel-
;;   driven via make-process so the supervisor does not block on the
;;   DHCP convergence window.
;; closure: replace with a native elisp client once we have a pid1
;;   raw-socket helper.  v0.5 work.
;; tracked since: 2026-05-11.

;; exception: bash-in-system-profile
;; rule violated: GEOS hard rule 1, "no shell other than eshell".
;; reason: %base-packages still drops bash into the system profile.
;;   we cannot strip it without rewriting %base-packages, and the
;;   guix build infrastructure (package phases, activation scripts
;;   embedded in store items, `guix system reconfigure' on the
;;   booted system) hard-depends on /gnu/store/.../bin/bash existing
;;   somewhere reachable.  what we DO own is /bin/sh: phase 3's
;;   shstub binary is laid down by the boot gexp as a crash-safe
;;   symlink swap (system.scm, emacs-init-boot-service) before
;;   execl(emacs-init).  every posix-shaped /bin/sh callsite goes
;;   through the stub now.  bash stays as inert bits, never on the
;;   default PATH of an interactive eshell prompt.
;; closure: drop %base-packages entirely once we have an audit pass
;;   confirming nothing in the boot chain reaches /gnu/store bash.
;;   that audit is post-v0.3.
;; tracked since: 2026-05-06.  partial closure: 2026-05-10.

;; this file is loaded for documentation, not for build effects. it
;; deliberately exports nothing.

(define-module (exceptions)
  #:export ())
