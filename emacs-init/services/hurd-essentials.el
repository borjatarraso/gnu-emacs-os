;;; hurd-essentials.el --- essential Hurd daemons under supervise.el -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>

;; two daemons GEOS cannot afford to lose on a Hurd VM, parked under
;; the supervisor so they come back across `(pid1-reboot)` without an
;; operator logging in to nudge them.
;;
;; why sshd: the canonical way i exercise a Hurd boot is over ssh from
;; the host.  if sshd dies (or the operator pkills it by accident in a
;; debug session) and nothing brings it back, the VM is bricked from
;; my point of view even though the kernel is fine.  :restart 'always
;; covers the "clean exit" case too, because on this host a clean sshd
;; exit means somebody fat-fingered something.
;;
;; why syslogd: v0.9.6's journal-kmsg source on Hurd tails
;; /var/log/kern.log, and that file only grows because syslogd is
;; draining /dev/klog into it.  if syslogd dies, *journal* silently
;; stops scrolling and the next kernel event is invisible.  same
;; :restart 'always reasoning as sshd.  the package name in apt is
;; `inetutils-syslogd' but it installs the binary at /usr/sbin/syslogd
;; (no `inetutils-' prefix); v0.9.11 had the package name in the
;; :command path by mistake and slice 6 VM verify caught the gap.
;;
;; design contract: this file is a strict no-op on Linux.  the entire
;; defservice block is wrapped in `(when (eq geos-kernel 'hurd) ...)`
;; at top level because defservice has registry side effects via
;; puthash, and a Linux boot must not end up with services pointing at
;; /usr/sbin/sshd from a Debian Hurd image that does not exist on the
;; running system.  on Linux, requiring this file evaluates the guard,
;; hits nil, and returns without touching `supervise--registry'.
;;
;; not in scope here: wiring this file into guix-system/system.scm so
;; it actually loads on boot.  that's a separate slice the orchestrator
;; will pick up.

(require 'supervise)
(require 'port)

;; v0.9.12 slice 5 diagnostic.  /dev/console writes (not just messages)
;; so the breadcrumb survives into the serial log even when *Messages*
;; is invisible.  the file-load breadcrumb is unconditional; the gate-
;; passed breadcrumb fires only when geos-kernel is 'hurd.  writes are
;; wrapped in condition-case so a write failure cannot abort the load.
(condition-case _
    (let ((write-region-inhibit-fsync t))
      (write-region
       (format "hurd-essentials: file loaded, geos-kernel=%S\n" geos-kernel)
       nil "/dev/console" 'append 'nomsg))
  (error nil))

(when (eq geos-kernel 'hurd)
  (condition-case _
      (let ((write-region-inhibit-fsync t))
        (write-region
         "hurd-essentials: geos-kernel=hurd gate passed, registering services\n"
         nil "/dev/console" 'append 'nomsg))
    (error nil))

  ;; sshd's /run/sshd privsep chroot dir is recreated by pid1
  ;; (emacs-init.c, after the /run tmpfs mount, #ifdef PORT_HURD).
  ;; doing it in C means it lands deterministically before emacs even
  ;; starts, sidestepping any elisp file-load-order or Hurd-mach-RPC
  ;; quirk that an emacs-side (make-directory ...) might hit at top
  ;; level.  see the comment in emacs-init.c for the v0.9.11 Round 6/7
  ;; receipt.  caught 2026-05-21.

  (defservice hurd-sshd
    ;; -D keeps sshd in the foreground so supervise.el's sentinel
    ;; sees the real exit; -e routes log output to stderr so the
    ;; hidden work buffer captures it instead of it disappearing
    ;; into syslog (which would be circular: syslogd is the OTHER
    ;; thing we are supervising here).
    ;;
    ;; :restart 'on-crash, not 'always.  skeptic 2026-05-21 caught
    ;; the foot-gun in 'always: sshd has legitimate clean-exit paths
    ;; (host-key regen on first boot, SIGTERM from shutdown, a future
    ;; sshd-reloads-config-and-re-execs).  'always would thrash on
    ;; those and could trip the 5-in-60s throttle to 'held, leaving
    ;; the one daemon i use to reach the box stuck.  'on-crash still
    ;; catches the actual failure mode (signal exit or non-zero
    ;; status from a pflocal weirdness) and pkill is SIGTERM, so the
    ;; "operator killed it" case is covered too.
    :command ("/usr/sbin/sshd" "-D" "-e")
    :restart on-crash
    :autostart t
    :buffer " *supervise:hurd-sshd*"
    :env nil)

  (defservice hurd-syslogd
    ;; --no-detach is syslogd's equivalent of sshd -D: stay attached so
    ;; the sentinel can actually watch us.  no -e equivalent because
    ;; syslogd's own job is to be the sink, so whatever it writes to
    ;; stderr stays in the work buffer and does not get reflected into
    ;; its own log.  binary path is /usr/sbin/syslogd (no
    ;; `inetutils-' prefix; that is the package name only).
    :command ("/usr/sbin/syslogd" "--no-detach")
    :restart always
    :autostart t
    :buffer " *supervise:hurd-syslogd*"
    :env nil)

  (condition-case _
      (let ((write-region-inhibit-fsync t))
        (write-region
         "hurd-essentials: defservice hurd-sshd + hurd-syslogd registered\n"
         nil "/dev/console" 'append 'nomsg))
    (error nil)))

(provide 'hurd-essentials)
;;; hurd-essentials.el ends here
