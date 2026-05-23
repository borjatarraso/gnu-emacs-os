;;; hurd-essentials.el --- essential Hurd daemons under supervise.el -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>

;; two daemons GEOS cannot afford to lose on a Hurd VM (sshd, syslogd),
;; parked under the supervisor so they come back across `(pid1-reboot)`
;; without an operator logging in to nudge them, plus the one-shot
;; static eth0 bring-up that gets pfinet onto the QEMU SLIRP network so
;; sshd is actually reachable from the host.
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
;; why static eth0 (NOT dhclient): on Debian GNU/Hurd 0.9 the pfinet
;; translator is already settrans'd at /servers/socket/2 by the base
;; image, but nothing in the default boot path actually configures an
;; address on eth0 once /etc/init.d/networking is bypassed (pid1
;; replaced /sbin/init, so the rc.d chain is gone).  without an
;; address, no inbound packet can reach sshd, even though sshd's
;; socket is on 0.0.0.0:22.  slice 6 VM verify proved sshd binds
;; correctly but the QEMU SLIRP host-forward could not complete the
;; three-way handshake.  slice 8 tried `/sbin/dhclient -d eth0' under
;; supervise.el; slice 9 breadcrumbs proved dhclient spawns clean
;; (registers pid, no sentinel exit) but emits ZERO DHCP protocol
;; chatter on stderr, because Linux dhclient's BPF/raw-socket path
;; expects a Linux netlink-style eth0 device that pfinet does not
;; present in the same shape.  slice 10 drops the dhclient defservice
;; entirely and uses the pid1 module's set_address / set_route_default
;; verbs directly, with the QEMU SLIRP fixed assignment (10.0.2.15/24
;; via 10.0.2.2).  this is on purpose: the QEMU user-mode SLIRP server
;; always hands out exactly these addresses, so a fixed config is
;; equivalent to DHCP for the VM-verify boot path and avoids the
;; userland-DHCP-on-Hurd rabbit hole.
;;
;; for a bare-metal Hurd deployment with a real DHCP server on the
;; wire, the operator overrides `network-interface-config' in their
;; site init (or before /var/emacs is mounted, via the args-file) and
;; this hurd-essentials.el call becomes a no-op for eth0 because the
;; static-address pre-check sees the operator's intent and yields.
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
(require 'panic)

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

;; v0.9.14 follow-on #1 from
;; docs/runlogs/2026-05-22-v0914-live-kmsg-probe.md: on Debian GNU/Hurd
;; 0.9 the canonical inetutils-syslogd config does not route
;; user-process LOG_KERN messages into /var/log/kern.log.  syslog spec
;; says kern facility is reserved for the kernel side, so syslogd
;; demoting user-side kern.* to user.* is per spec.  for the GEOS
;; journal-kmsg pipeline i want a unified view though: anything a user
;; runs with `logger -p kern.info "..."' should land in *journal* the
;; same way real kernel messages do, because *journal* is the one
;; place an operator looks.
;;
;; the fix is a one-line override into /etc/inetutils-syslog.conf
;; saying `kern.* /var/log/kern.log'.  this is operator-owned
;; configuration, so the write is strictly additive: read the file,
;; bail if the exact line is already there, otherwise append.  never
;; truncate, never rewrite other lines.
;;
;; the override is written at file-load time, BEFORE supervise-autostart
;; runs from supervise-finalize, so on a cold boot syslogd starts with
;; the override already in place and no SIGHUP is needed.  the SIGHUP
;; path below covers the hot-reload case where the operator re-loads
;; hurd-essentials.el against a live system with syslogd already up.
;;
;; the helpers are defined at top level (not inside the hurd gate)
;; because the byte-compiler does not recognise defuns inside a top
;; level `when' as known functions and warns; the actual call sites are
;; the only thing that needs the gate.  on Linux these helpers are
;; defined but never reached.
(defconst hurd-essentials--syslog-conf "/etc/inetutils-syslog.conf"
  "Path of the inetutils-syslogd config we patch for kern.* routing.")

(defconst hurd-essentials--syslog-kern-line "kern.*    /var/log/kern.log"
  "Exact line we ensure is present in `hurd-essentials--syslog-conf'.
Four spaces between selector and action; inetutils-syslogd's parser
accepts any run of whitespace as the field separator (tab or spaces),
i pin one canonical byte sequence so the idempotency check is a
plain string search rather than a tokenize-and-compare.  if an
operator hand-wrote the same logical line with a tab instead, the
appender below will add a second copy; that is benign (syslogd
honors duplicate selector/action lines as one) and the operator can
delete one if it bothers them.")

(defun hurd-essentials--syslog-conf-has-kern-override-p ()
  "Return non-nil iff the kern.* override is already present.
Reads `hurd-essentials--syslog-conf' if it exists.  a missing file
counts as absent (the appender will create a one-line file in that
case).  all I/O routed through panic-handle on file-error so a
permission denied or transient mount glitch does not crash the
supervisor."
  (and (file-exists-p hurd-essentials--syslog-conf)
       (condition-case err
           (with-temp-buffer
             (insert-file-contents hurd-essentials--syslog-conf)
             (save-excursion
               (goto-char (point-min))
               (search-forward hurd-essentials--syslog-kern-line nil t)))
         (file-error
          (panic-handle err 'hurd-essentials--syslog-conf-has-kern-override-p)
          ;; pretend the line is present so the appender is a no-op;
          ;; we already logged the read failure, no reason to
          ;; immediately retry the same path as a write.
          t))))

(defun hurd-essentials--ensure-syslog-conf-kern-override ()
  "Idempotently append the kern.* override to inetutils-syslog.conf.
No-op if the exact line is already present.  appends (creating the
file if missing) otherwise.  never truncates and never touches other
lines; this file is operator-owned.  file-error during the append is
panic-handled so the supervisor stays up."
  (cond
   ((hurd-essentials--syslog-conf-has-kern-override-p)
    (supervise--console
     "hurd-essentials: syslog.conf kern.* override already present, no write"))
   (t
    (condition-case err
        (progn
          ;; trailing newline so the file ends clean and a future
          ;; append from another tool lands on a fresh line.  the
          ;; 'append flag here is the load-bearing piece: even if the
          ;; file already has content we trust nothing about its
          ;; final byte and just append our line + newline.
          (write-region
           (concat hurd-essentials--syslog-kern-line "\n")
           nil hurd-essentials--syslog-conf 'append 'nomsg)
          (supervise--console
           "hurd-essentials: appended kern.* override to %s"
           hurd-essentials--syslog-conf))
      (file-error
       (panic-handle err 'hurd-essentials--ensure-syslog-conf-kern-override)
       (supervise--console
        "hurd-essentials: syslog.conf kern.* override append FAILED %S"
        err))))))

(defun hurd-essentials--maybe-sighup-syslogd ()
  "Send SIGHUP to a running hurd-syslogd so it re-reads the config.
If the service is not registered, not running, or has no pid (e.g.
the override was written during file-load before supervise-finalize
started anything), this is a no-op: the override will be picked up
at first start, the contract holds.  pid1-kill would be nicer for
consistency with the rest of the supervisor, but no such binding
exists in the pid1 module yet; signal-process is the boring fallback
that has been load-bearing in session-end (core/session.el) since
v0.6, so the precedent is solid."
  (let* ((svc (and (boundp 'supervise--registry)
                   (hash-table-p supervise--registry)
                   (gethash 'hurd-syslogd supervise--registry)))
         (pid (and svc (supervise-service-pid svc))))
    (cond
     ((not (and (integerp pid) (fboundp 'signal-process)))
      (supervise--console
       "hurd-essentials: skip SIGHUP, syslogd not running (pid=%S)" pid))
     (t
      (condition-case err
          (progn
            (signal-process pid 'HUP)
            (supervise--console
             "hurd-essentials: SIGHUP sent to syslogd pid=%d" pid))
        (error
         (panic-handle err 'hurd-essentials--maybe-sighup-syslogd)
         (supervise--console
          "hurd-essentials: SIGHUP to syslogd pid=%d FAILED %S"
          pid err)))))))

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

  (hurd-essentials--ensure-syslog-conf-kern-override)
  (hurd-essentials--maybe-sighup-syslogd)

  (condition-case _
      (let ((write-region-inhibit-fsync t))
        (write-region
         "hurd-essentials: defservice hurd-sshd + hurd-syslogd registered\n"
         nil "/dev/console" 'append 'nomsg))
    (error nil))

  ;; slice 10 (v0.9.12): static eth0 bring-up for the QEMU SLIRP path.
  ;; the two pid1 module verbs we need (`pid1-set-address' and
  ;; `pid1-set-route-default') are exported from emacs-init.c whenever
  ;; PID1_MODULE_PATH was set in our env, so they are present on a
  ;; supervised OS boot but absent under plain `emacs -Q' on a dev
  ;; host.  the fboundp guard turns this into a strict no-op in the
  ;; dev case.
  ;;
  ;; address/mask/gateway are hard-coded to QEMU SLIRP's user-mode
  ;; default subnet (10.0.2.0/24, gw 10.0.2.2, guest 10.0.2.15).  if
  ;; the operator runs a real DHCP server (e.g. bare metal or a custom
  ;; QEMU netdev) they override `network-interface-config' before
  ;; reaching this file, AND they set `geos-hurd-static-eth0' to nil
  ;; in their site init so this block stops trying.  the defcustom
  ;; lives here, not in core/network.el, because the QEMU SLIRP
  ;; constants are a Hurd-side concern and pollute the core defcustom
  ;; if they live there.
  (defcustom geos-hurd-static-eth0 t
    "Non-nil to statically configure eth0 with QEMU SLIRP defaults.
Set to nil in site init when the Hurd guest is on a network with a
real DHCP server, or to t and override the address constants below
when the SLIRP defaults are wrong.  effect is read once at boot when
services/hurd-essentials.el loads."
    :group 'network
    :type 'boolean)

  ;; slice 11 (v0.9.12): settrans /hurd/pfinet onto /servers/socket/2
  ;; BEFORE the static address ioctl.  on Debian GNU/Hurd 0.9 the base
  ;; image ships pfinet as a passive translator declared in
  ;; /etc/network/interfaces, but the rc.d chain that actually starts
  ;; it lives downstream of /sbin/init and never runs once pid1
  ;; replaces /sbin/init.  slice 10 VM-verify caught this: the bind
  ;; point /servers/socket/2 was a plain 0-byte file, no translator
  ;; attached, so pid1-set-address opened it, got back a port to a
  ;; non-translator inode, and the SIOCSIFADDR ioctl surfaced as
  ;; ENODEV = "No such device".
  ;;
  ;; the settrans here mirrors what /etc/init.d/hurd would have done:
  ;; force-attach pfinet to the canonical SLIRP iface (/dev/eth0) so
  ;; the subsequent ioctl path through /servers/socket/2 actually
  ;; reaches a live pfinet.  -fgap = force, goaway any existing
  ;; translator, active+passive (start now AND register passively so
  ;; the auto-restart machinery brings it back on demand).
  ;;
  ;; slice 11 passed JUST `-i /dev/eth0' to pfinet and settrans returned
  ;; exit=5 after netdde successfully registered its IRQ delivery port:
  ;; pfinet refused to attach without a full address spec, then the
  ;; subsequent pid1-set-address ioctl could not find a translator on
  ;; /servers/socket/2.  slice 12 passes the full SLIRP address shape
  ;; inline (-a/-m/-g) so pfinet attaches cleanly, matching the
  ;; canonical Debian GNU/Hurd 0.9 installer incantation.  the
  ;; pid1-set-address call below then becomes a reconcile/verify step:
  ;; the ioctl asserts the same address we just told settrans about,
  ;; so on a healthy boot it is either a no-op (kernel already has the
  ;; intended value) or surfaces EEXIST (also fine, our condition-case
  ;; treats it as success).  bare-metal Hurd with real DHCP still
  ;; benefits from this settrans step: operator sets
  ;; `geos-hurd-static-eth0' nil so the address ioctl is skipped, then
  ;; runs their own dhcp client against the now-live pfinet (and
  ;; ideally overrides the address args here too via a defcustom in a
  ;; follow-up slice once a bare-metal deployment actually appears).
  (when (and (file-executable-p "/bin/settrans")
             (file-executable-p "/hurd/pfinet"))
    (supervise--console
     "hurd-essentials: settrans /hurd/pfinet -i /dev/eth0 -a 10.0.2.15 -m 255.255.255.0 -g 10.0.2.2")
    (let ((exit (condition-case err
                    (call-process "/bin/settrans" nil nil nil
                                  "-fgap" "/servers/socket/2"
                                  "/hurd/pfinet"
                                  "-i" "/dev/eth0"
                                  "-a" "10.0.2.15"
                                  "-m" "255.255.255.0"
                                  "-g" "10.0.2.2")
                  (error
                   (supervise--console
                    "hurd-essentials: settrans pfinet FAILED %S" err)
                   -1))))
      (supervise--console "hurd-essentials: settrans pfinet exit=%S" exit)))

  (when geos-hurd-static-eth0
    (condition-case err
        (cond
         ((not (fboundp 'pid1-set-address))
          (supervise--console
           "hurd-essentials: eth0 static skipped, pid1-set-address unbound"))
         (t
          (supervise--console
           "hurd-essentials: eth0 static 10.0.2.15/24 gw 10.0.2.2")
          (funcall (symbol-function 'pid1-set-address) "eth0" "10.0.2.15" 24)
          (when (fboundp 'pid1-set-route-default)
            (condition-case gw-err
                (funcall (symbol-function 'pid1-set-route-default)
                         "10.0.2.2" "eth0")
              (error
               ;; gateway add raises with EEXIST on a re-apply (e.g.
               ;; pid1-reboot then this file reloads).  do not panic
               ;; the supervisor over an idempotency case; log and
               ;; continue.
               (supervise--console
                "hurd-essentials: eth0 gateway add: %S (continuing)"
                gw-err))))
          (supervise--console "hurd-essentials: eth0 static OK")))
      (error
       (supervise--console "hurd-essentials: eth0 static FAILED %S" err)))))

(provide 'hurd-essentials)
;;; hurd-essentials.el ends here
