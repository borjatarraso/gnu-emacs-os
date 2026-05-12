;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; system.scm, the operating-system record for GNU/Emacs Operating
;; System (GEOS).
;;
;; this is the smallest record I could get the kernel to boot with:
;; linux-libre, glibc, coreutils so install-time tooling works, and
;; emacs because emacs is the userland. shepherd-services is empty on
;; purpose, supervision belongs in elisp.
;;
;; on the "init field": guix does not expose a native init slot on
;; <operating-system>. setting init=/sbin/emacs-init via kernel-arguments
;; is ALSO not enough on its own, because the guix initrd ignores
;; init= and execs the per-system boot script under
;; /gnu/store/...-system/boot, which itself execs shepherd. so we have
;; to replace the boot script too. that is what the emacs-init-boot
;; service below does: it extends boot-service-type with a gexp whose
;; execl replaces the boot script process with /sbin/emacs-init before
;; shepherd's exec gexp ever runs. the kernel-arguments line is kept
;; as a belt-and-suspenders signal of intent.
;;
;; why this works (gexp ordering): boot-service-type collects gexps
;; from every service that extends it, then compute-boot-script
;; reverses the list. user-level extensions end up at the head of the
;; reversed list, so they run BEFORE the essential-service extensions
;; (one of which is shepherd's exec). since execl replaces the process
;; image, the shepherd gexp at the tail is dead code.

(use-modules (gnu)
             (gnu bootloader)
             (gnu bootloader grub)
             (gnu packages admin)
             (gnu packages bootloaders)
             (gnu packages disk)
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu packages fonts)
             (gnu packages glib)
             (gnu packages ibus)
             (gnu packages linux)
             (gnu packages mail)
             (gnu packages xorg)
             (gnu services)
             (gnu services base)
             (gnu system)
             (guix gexp))

;; v0.4 item 10: bootable-kernel-arguments is what builds the
;; root=<dev> + gnu.system=$out + gnu.load=$out/boot triple that
;; every Linux entry in /boot/grub/grub.cfg has to carry.  it is not
;; exported from (gnu system) (the public API is
;; operating-system-kernel-arguments, which also splices in the user
;; kernel-arguments field), but the console-mode menu-entry below has
;; to splice the SAME bootable triple in front of a DIFFERENT user
;; kernel-arguments list.  using the public getter would either
;; double-count the user args or force a second os derivation just to
;; get a clean bootable triple.  upstream itself reaches in via @@ in
;; gnu/machine/ssh.scm for exactly this reason, so the precedent is
;; there.
(define geos-bootable-kernel-arguments
    (@@ (gnu system) bootable-kernel-arguments))

(define emacs-init-binary
    ;; phase-1 PID 1 binary as a store object. referenced both by the
    ;; boot service (via store path, because the boot gexp runs before
    ;; activation creates /sbin) and by extra-special-file below (for
    ;; the convenience symlink any later tooling expects).
    ;; #:recursive? #t because the non-recursive code path adds the
    ;; file as a text blob and strips the executable bit, which makes
    ;; execl fail with EACCES at boot. recursive uses add-to-store and
    ;; preserves the +x mode set by the Makefile.
    (local-file "../pid1/emacs-init" "emacs-init" #:recursive? #t))

(define pid1-module-so
    ;; phase-2 emacs dynamic module. same source as emacs-init, built
    ;; with -DPID1_MODULE -shared. early-init.el module-loads it via
    ;; the path we pass through PID1_MODULE_PATH below.
    (local-file "../pid1/pid1-module.so" "pid1-module.so" #:recursive? #t))

(define early-init-el
    ;; loads first inside emacs. registers pid1-error, module-loads
    ;; pid1-module.so, sets up user-emacs-directory.
    (local-file "../emacs-init/early-init.el" "early-init.el"))

(define panic-el
    ;; the panic buffer + command-error-function wiring. wraps top
    ;; level so a stray (error ...) lands in *panic* instead of
    ;; killing the user-facing emacs.
    (local-file "../emacs-init/core/panic.el" "panic.el"))

(define cmdline-el
    ;; /proc/cmdline parser shared by boot-marker.el and session.el.
    ;; tiny, no deps beyond what emacs gives us; load early so any
    ;; later core file can (require 'cmdline) without ordering
    ;; anxiety. must sit between panic.el and state.el.
    (local-file "../emacs-init/core/cmdline.el" "cmdline.el"))

(define use-package-shim-el
    ;; bootstraps use-package and registers the project's :comment
    ;; keyword as a no-op so the userland files do not raise
    ;; "Unrecognized keyword: :comment" at load time. depends on
    ;; panic.el, must load before any userland/*.el.
    (local-file "../emacs-init/core/use-package-shim.el"
                "use-package-shim.el"))

(define state-el
    ;; v0.4 item 1: persistent on-disk scratchpad under /var/emacs/.
    ;; provides state-read / state-write / state-delete with crash-safe
    ;; rename-then-fsync semantics and a state-mode probe that branches
    ;; on whether pid1 mounted /var as ext4 (geos-var label) or fell
    ;; back to tmpfs.  loaded right after panic.el so every later -l
    ;; (network, hostname, buffers/, ...) can persist across reboots
    ;; without re-deriving from /proc.  the file's bottom-of-load
    ;; auto-init (gated on pid1-as-emacs-p) materialises the directory
    ;; tree before any consumer arrives.
    (local-file "../emacs-init/core/state.el" "state.el"))

(define supervise-el
    ;; v0.4 item 2: first-class service supervisor.  cl-defstruct +
    ;; defservice macro + sentinel-driven restart policy + rolling 60s
    ;; respawn throttle.  registry persists under
    ;; /var/emacs/services/registry via state-write so crash counters
    ;; survive an emacs restart.  loaded right after state-el because
    ;; supervise depends on state for persistence; loaded BEFORE any
    ;; -l file that contains a defservice (services/journal-tail.el
    ;; etc) so the macro is fbound at top-level expansion time.
    ;; supervise-finalize is invoked from boot-marker.el after every
    ;; service file has loaded; that is what restores counters and
    ;; autostarts non-held services.
    (local-file "../emacs-init/core/supervise.el" "supervise.el"))

(define power-el
    ;; thin elisp wrapper around pid1-module's pid1-poweroff and
    ;; pid1-reboot bindings. exposes M-x geos-poweroff / geos-reboot.
    ;; depends on panic.el for panic-handle, must load after it.
    (local-file "../emacs-init/core/power.el" "power.el"))

(define network-el
    ;; phase-4 core. /proc/net/dev and /proc/net/route parsers, plus
    ;; the declarative network-interface-config + bring-up hook into
    ;; pid1-bring-up-lo. requires panic, must load after panic.el.
    (local-file "../emacs-init/core/network.el" "network.el"))

(define hostname-el
    ;; reads /etc/hostname and feeds it to pid1-set-hostname.  without
    ;; this, /proc/sys/kernel/hostname stays at the kernel default
    ;; "(none)" because we shipped no Shepherd service to call
    ;; sethostname(2).  must load after panic.el.
    (local-file "../emacs-init/core/hostname.el" "hostname.el"))

(define passwd-el
    ;; phase-4 item-4 core. reads /etc/passwd, /etc/shadow, /etc/group
    ;; and atomically rewrites them via pid1-fsync-dir; hashes
    ;; passwords through the pid1-crypt module function. must load
    ;; after panic.el and state.el (atomic-write mirrors state-write).
    (local-file "../emacs-init/core/passwd.el" "passwd.el"))

(define session-el
    ;; v0.5 login plumbing.  in-memory session table keyed by tty/seat,
    ;; persisted under /var/emacs/sessions/ via state-write so logins
    ;; survive an emacs restart.  calls state-read / state-write /
    ;; state-path (state-el), supervise-register (supervise-el),
    ;; passwd-read-passwd (passwd-el) and panic-handle (panic-el), so
    ;; it MUST load after all four.  buffers/login.el and
    ;; buffers/users.el both (require 'session) for display; users.el
    ;; soft-requires it, login.el hard-requires it.
    (local-file "../emacs-init/core/session.el" "session.el"))

(define x-display-el
    ;; v0.7 item 1.1: supervisor side of the EXWM display-release dance.
    ;; provides x-display-release / x-display-reclaim, panic-handled and
    ;; idempotent.  loaded supervisor-side so M-x x-display-release is
    ;; available for in-VM experimentation before session.el wires it
    ;; into the spawn / end paths (slice 1.3).  no side effects at load
    ;; time; just defun + defvar.
    (local-file "../emacs-init/core/x-display.el" "x-display.el"))

(define user-init-el
    ;; v0.6 starter: per-user emacs userland.  this file runs INSIDE
    ;; the per-user emacs (the supervisor's child), not in the
    ;; supervisor itself.  defines geos-logout (C-c e q) for now.
    ;; future v0.6+ work moves more user-side defuns here.
    ;; session--child-argv loads it via -l /etc/geos/user-init.el;
    ;; the extra-special-file below resolves that path to this
    ;; store entry.  do NOT add to the supervisor's -l chain: the
    ;; supervisor is root and the bindings here are user-scope.
    (local-file "../emacs-init/user/user-init.el" "user-init.el"))

(define rpc-server-el
    ;; v0.6 item 3: supervisor side of the user/supervisor RPC.
    ;; binds /run/geos/super.sock, polls every 200ms, dispatches
    ;; verbs (ping, journal-tail, reboot, poweroff).  bottom-of-load
    ;; auto-start gated on pid1-as-emacs-p, so loading this file in
    ;; the supervisor boot path is enough to bring the socket up.
    ;; supervisor-side ONLY: do NOT lay this on /etc/geos/core/ for
    ;; the per-user emacs, the verb handlers call pid1-* which the
    ;; user-emacs lacks.  must load after session-el so any future
    ;; verb that touches the session table sees a finalised registry.
    (local-file "../emacs-init/core/rpc-server.el" "rpc-server.el"))

(define rpc-client-el
    ;; v0.6 item 3: user side of the user/supervisor RPC.  one-shot
    ;; client over AF_UNIX SOCK_STREAM, blocks for the reply.  defines
    ;; geos-rpc (the dispatcher) plus geos-rpc-ping / geos-rpc-journal-
    ;; tail / geos-rpc-reboot / geos-rpc-poweroff convenience commands
    ;; and binds C-c e R / C-c e P at the user-emacs level.  laid down
    ;; under /etc/geos/core/ so user-init--chain can `load' it by
    ;; absolute path.  requires 'panic, so user-init--chain orders it
    ;; AFTER panic.el.
    (local-file "../emacs-init/core/rpc-client.el" "rpc-client.el"))

(define boot-marker-el
    ;; smoke-test gate.  writes "geos: emacs userland up" to
    ;; /dev/console at load time and arms an exwm-init-hook that
    ;; writes "geos: exwm up" once the WM grabs root.  MUST be the
    ;; very last -l in the boot gexp so its load proves every
    ;; preceding -l ran.  /iso-build/smoke-test.sh greps the serial
    ;; log for these.
    (local-file "../emacs-init/core/boot-marker.el" "boot-marker.el"))

(define network-buffer-el
    ;; phase-4 buffer. *network* live view, 2s refresh timer, RET for
    ;; iface details. requires both panic and network, must load last
    ;; in the chain. (provide 'network-buffer) so future supervise.el
    ;; can require it by name.
    (local-file "../emacs-init/buffers/network.el" "network-buffer.el"))

(define exwm-config-el
    ;; phase-5a wm. requires panic to be loaded already so its handlers
    ;; can panic-handle uncaught wm errors. must come after panic.el in
    ;; the -l chain. only takes effect when emacs has DISPLAY set; on a
    ;; raw QEMU smoke test (no Xorg) the file degrades to a no-op.
    (local-file "../emacs-init/user/exwm-config.el" "exwm-config.el"))

;; phase 5c additions. these three are (require)d from exwm-config.el
;; AFTER (exwm-enable) returns, so they need to be on load-path before
;; that file evaluates. the simplest way to guarantee that is to -l
;; them BEFORE exwm-config.el in the boot gexp; loading a file with
;; provide is enough to satisfy a later require. nothing here breaks
;; the no-DISPLAY degradation path: each module's -apply guards on
;; display-graphic-p / DISPLAY before doing any work.
(define multimon-el
    (local-file "../emacs-init/user/multimon.el" "multimon.el"))
(define fonts-el
    (local-file "../emacs-init/user/fonts.el" "fonts.el"))
(define input-el
    (local-file "../emacs-init/user/input.el" "input.el"))

;; phase 5b userland files. each one wires up one user-facing package
;; via use-package. they are loaded by userland-init-el below, AFTER
;; exwm-config so the wm has the root window before any of these
;; packages spawn buffers. order inside the chain is cosmetic; nothing
;; here depends on anything else here.
(define userland-files-el
    (local-file "../emacs-init/user/userland/files.el" "userland-files.el"))
(define userland-shell-el
    (local-file "../emacs-init/user/userland/shell.el" "userland-shell.el"))
(define userland-uname-el
    ;; eshell/uname override: rebrand sysname to GEOS, keep the real
    ;; kernel visible in parens. depends on eshell being loaded so
    ;; eshell/<name> dispatch is actually consulted; load AFTER
    ;; userland-shell.el.
    (local-file "../emacs-init/user/userland/uname.el" "userland-uname.el"))
(define userland-git-el
    (local-file "../emacs-init/user/userland/git.el" "userland-git.el"))
(define userland-web-el
    (local-file "../emacs-init/user/userland/web.el" "userland-web.el"))
(define userland-mail-el
    (local-file "../emacs-init/user/userland/mail.el" "userland-mail.el"))
(define userland-chat-el
    (local-file "../emacs-init/user/userland/chat.el" "userland-chat.el"))
(define userland-notes-el
    (local-file "../emacs-init/user/userland/notes.el" "userland-notes.el"))
(define userland-pdf-el
    (local-file "../emacs-init/user/userland/pdf.el" "userland-pdf.el"))
(define userland-audio-el
    ;; v0.4 item 8 userland.  ALSA wrappers via amixer/aplay through
    ;; make-process.  must load before userland-init.el verifies the
    ;; manifest.
    (local-file "../emacs-init/user/userland/audio.el" "userland-audio.el"))
(define userland-services-client-el
    ;; v0.7 item 4.2.  user-side *services* buffer that fetches the
    ;; supervisor's registry over the v0.6 RPC channel.  ships in the
    ;; user-init chain because the supervisor still owns the registry
    ;; and the user-emacs cannot see it any other way after the v0.7
    ;; item 1.2 userland handover.
    (local-file "../emacs-init/user/userland/services-client.el"
                "userland-services-client.el"))
(define userland-init-el
    ;; thin entry point that requires each of the above. loaded LAST so
    ;; exwm has already claimed the root frame.
    (local-file "../emacs-init/user/userland/init.el" "userland-init.el"))

;; phase 6 system-concept buffers. each one shows a piece of the
;; running OS (processes, kernel log, supervised services, block
;; devices, package manifest) as a real emacs buffer. they are not
;; auto-displayed at boot; loading them just makes M-x foo work.
;; ordering: they only depend on panic.el, so anywhere after panic-el
;; in the -l chain is fine. we load them after exwm-config so an early
;; misclick on one of these popups can't fight an unsettled wm.
(define processes-buffer-el
    (local-file "../emacs-init/buffers/processes.el" "processes-buffer.el"))
(define journal-buffer-el
    (local-file "../emacs-init/buffers/journal.el" "journal-buffer.el"))
(define services-buffer-el
    (local-file "../emacs-init/buffers/services.el" "services-buffer.el"))
(define disks-buffer-el
    (local-file "../emacs-init/buffers/disks.el" "disks-buffer.el"))
(define packages-buffer-el
    (local-file "../emacs-init/buffers/packages.el" "packages-buffer.el"))
(define reconfigure-buffer-el
    (local-file "../emacs-init/buffers/reconfigure.el" "reconfigure-buffer.el"))
(define users-buffer-el
    ;; v0.4 item 4 buffer.  *users* mirrors /etc/passwd and offers
    ;; a/d/p keys backed by core/passwd.el's atomic writers.  must
    ;; load after passwd-el.
    (local-file "../emacs-init/buffers/users.el" "users-buffer.el"))
(define login-buffer-el
    ;; v0.5 login buffer.  *login* prompts user + password, verifies
    ;; via passwd-verify (passwd-el) and opens a session via session.el.
    ;; hard requires 'session, so it MUST load after session-el.
    (local-file "../emacs-init/buffers/login.el" "login-buffer.el"))
(define audio-buffer-el
    ;; v0.4 item 8 buffer, lifted user-side in v0.7 item 3.1.
    ;; *audio* lists ALSA cards and exposes volume keys; depends on
    ;; userland-audio.el.  no longer -l'd supervisor-side; the per-user
    ;; emacs loads it via user-init--chain so a stuck audio render
    ;; cannot stall PID 1.
    (local-file "../emacs-init/buffers/audio.el" "audio-buffer.el"))

;; v0.4 item 2 service definitions.  each one calls (defservice ...)
;; at top level, which registers with supervise.el's hash-table.  load
;; order: AFTER both supervise-el (the macro must be fbound) and the
;; consumer buffer file (journal-tail requires journal-buffer for the
;; record parser).  boot-marker.el's supervise-finalize call runs the
;; autostart afterwards.
(define journal-tail-service-el
    (local-file "../emacs-init/services/journal-tail.el" "journal-tail.el"))

(define dhcp-service-el
    ;; v0.4 item 5 finisher.  on-demand DHCP via dhcpcd, triggered by
    ;; `d' in the *network* buffer.  not a defservice (one-shot per
    ;; operator action, not a long-running thing), but lives under
    ;; services/ because it spawns and supervises an external binary.
    ;; loaded after network-buffer-el so `network-buffer-refresh' is
    ;; fbound when dhcp-request's sentinel calls it.
    (local-file "../emacs-init/services/dhcp.el" "dhcp.el"))

;; v0.4 item 3.  install wizard.  pure-elisp wrappers around mkfs,
;; cp, pid1-mount, grub-install and grub-mkconfig, plus a
;; *install* state-machine buffer that orchestrates them.  the
;; wizard does NOT partition; the operator pre-partitions from a
;; Guix live ISO and runs M-x install on a booted GEOS.  the four
;; install/*.el files are pure-data; install.el is the buffer.
;; loaded near the end of the chain because install.el requires
;; the four install-* features by name.
(define install-disk-el
    (local-file "../emacs-init/install/disk.el" "install-disk.el"))
(define install-mkfs-el
    (local-file "../emacs-init/install/mkfs.el" "install-mkfs.el"))
(define install-copy-el
    (local-file "../emacs-init/install/copy.el" "install-copy.el"))
(define install-grub-el
    (local-file "../emacs-init/install/grub.el" "install-grub.el"))
(define install-buffer-el
    (local-file "../emacs-init/buffers/install.el" "install-buffer.el"))

(define xorg-conf
    ;; phase-5c xorg config. picks the modesetting driver against
    ;; /dev/dri/card0 (virtio_gpu KMS device). qemu must be invoked
    ;; with -vga virtio for this to work; emacs-os.sh does that.
    ;; the old fbdev config is preserved at xorg.conf for reference,
    ;; this file is the one wired into the boot gexp.
    (local-file "xorg-modesetting.conf" "xorg.conf"))

(define shstub-sh
    ;; phase-3 /bin/sh shim. on a normal POSIX-y system /bin/sh runs
    ;; before any dynamic-linker setup, so the binary must be static.
    ;; same #:recursive? #t reasoning as emacs-init: the non-recursive
    ;; add-text-to-store path strips +x and execve fails EACCES.
    (local-file "../shstub/sh" "sh" #:recursive? #t))

(define emacs-init-boot-service
    ;; extends boot-service-type with a gexp that execs the PID 1
    ;; binary directly from its store path. critical: cannot use
    ;; /sbin/emacs-init here because the boot gexp runs before
    ;; activation-service runs the extra-special-file symlink, so /sbin
    ;; is empty at this point. the store path is hard-baked at gexp
    ;; expansion time and is available because the initrd has already
    ;; mounted the root filesystem (which holds /gnu/store).
    ;;
    ;; no environment setup, no console fiddling: emacs-init mounts
    ;; /proc /sys /dev /run /tmp and /dev/pts itself.
    ;;
    ;; argv layout (matched in emacs-init.c main()):
    ;;   [1] absolute path of the emacs binary
    ;;   [2] absolute path of pid1-module.so (set as PID1_MODULE_PATH
    ;;       in the env passed to emacs)
    ;;   [3] colon-joined Xorg spec
    ;;       "<Xorg-bin>:<xkb-bindir>:<modulepath>:<fontpath>:<conf>"
    ;;       empty string disables X (raw smoke tests). phase 5a
    ;;       populates all five fields so emacs-init.c forks Xorg
    ;;       before the supervised emacs.
    ;;   [4..] forwarded into emacs's argv. -Q so a stale ~/.emacs.d
    ;;         cannot derail boot; -l for early-init, panic, network
    ;;         and exwm-config.
    (simple-service 'emacs-init-boot
                    boot-service-type
                    ;; everything goes inside one (let () ...) so that
                    ;; the helpers we define here cannot collide with
                    ;; bindings introduced by other boot-service-type
                    ;; extensions (which all splice into the same
                    ;; top-level begin).  a future shepherd-or-similar
                    ;; extension defining its own `console-write' would
                    ;; otherwise silently shadow ours.
                    #~(let ()
                        ;; console-write: non-blocking write of MSG to
                        ;; /dev/console.  the boot script runs as PID 1
                        ;; before any reader is consuming the console
                        ;; output, so a plain blocking open + write
                        ;; could stall the entire boot if the kernel
                        ;; ring buffer were full.  open with O_NONBLOCK
                        ;; and silently drop on any error: a lost
                        ;; diagnostic is better than a wedged init.
                        ;; the inner catch is `#t' (not just
                        ;; system-error) because `display' on a non-
                        ;; string would raise wrong-type-arg and we
                        ;; would rather lose one log line than abort
                        ;; PID 1 over a future caller bug.
                        (define (console-write msg)
                          (catch #t
                            (lambda ()
                              (let* ((fd (open-fdes
                                          "/dev/console"
                                          (logior O_WRONLY
                                                  O_NONBLOCK
                                                  O_CLOEXEC)))
                                     (port (fdopen fd "w")))
                                (catch #t
                                  (lambda ()
                                    (display msg port)
                                    (force-output port))
                                  (lambda _ #f))
                                (close-port port)))
                            (lambda _ #f)))
                        ;; lay down /bin/sh -> shstub before handing
                        ;; off, because activation (which would
                        ;; normally do this via extra-special-file)
                        ;; never runs: our execl replaces the boot
                        ;; script process before activate.scm loads.
                        ;;
                        ;; crash-safe swap: write the new symlink to a
                        ;; sibling temp path and rename(2) it on top of
                        ;; /bin/sh.  rename is atomic on the same fs, so
                        ;; a crash mid-swap leaves either the old sh or
                        ;; the new one, never a missing entry.  a
                        ;; missing /bin/sh would brick eshell's shstub
                        ;; bridge and most posix expectations downstream.
                        ;;
                        ;; catch only 'system-error so unrelated bugs
                        ;; (a typo'd binding, etc.) still abort instead
                        ;; of being silently swallowed.  on EEXIST or
                        ;; perms issues we leave a breadcrumb on the
                        ;; console and continue: a previous boot may
                        ;; have already laid down the correct symlink.
                        ;; (B1, audit round-5 2026-05-10) the boot
                        ;; gexp runs BEFORE Guix activation, so /bin
                        ;; may not exist yet on a freshly-built rootfs
                        ;; (activation is what materialises the FHS
                        ;; skeleton).  symlink would then fail with
                        ;; ENOENT and the shstub bridge stays offline
                        ;; for the entire boot.  ensure /bin exists as
                        ;; a real directory first.  catch system-error
                        ;; so a parent-fs that already has /bin (or
                        ;; that has /bin as a symlink to an existing
                        ;; profile dir) does not abort us; we follow
                        ;; up with stat to check.
                        (catch 'system-error
                          (lambda () (mkdir "/bin"))
                          (lambda _ #t))
                        (let* ((bin-st (stat "/bin" #f))
                               (bin-ok (and bin-st
                                            (eq? (stat:type bin-st)
                                                 'directory))))
                          (unless bin-ok
                            ;; /bin is a symlink or missing entirely;
                            ;; the swap below will likely fail with
                            ;; EROFS or ENOTDIR.  log loudly so the
                            ;; operator can spot the cause without
                            ;; reading strace.
                            (console-write
                             "pid1: /bin is not a real directory; sh swap may fail\n")))
                        (let ((tmp "/bin/sh.geos-new"))
                          (catch 'system-error
                            (lambda ()
                              (when (file-exists? tmp)
                                (delete-file tmp))
                              (symlink #$shstub-sh tmp)
                              (rename-file tmp "/bin/sh"))
                            (lambda (key . args)
                              (console-write
                               (string-append
                                "pid1: /bin/sh swap failed: "
                                (object->string args) "\n")))))
                        ;; verify the swap landed.  if /bin/sh is
                        ;; missing, dangling, or doesn't resolve to a
                        ;; regular executable, the shstub bridge is
                        ;; broken and eshell will fail at the first
                        ;; `sh -c'.  log it; we still proceed (a
                        ;; degraded shell is better than refusing to
                        ;; boot).  `stat' with exception-flag #f
                        ;; returns #f on any error rather than
                        ;; raising, so no catch needed: dangling
                        ;; symlink, ENOENT and EPERM all fall into the
                        ;; "not a regular file" branch.
                        ;;
                        ;; (B2, audit round-5 2026-05-10) also assert
                        ;; the executable bit is set somewhere; without
                        ;; this a Makefile regression that drops +x
                        ;; passes the type check then every execve
                        ;; fails with EACCES at runtime.
                        (let ((st (stat "/bin/sh" #f)))
                          (cond
                           ((not (and st (eq? (stat:type st) 'regular)))
                            (console-write
                             "pid1: /bin/sh post-swap check failed (missing, dangling, or not a regular file)\n"))
                           ((zero? (logand (stat:perms st) #o111))
                            (console-write
                             "pid1: /bin/sh post-swap check failed (no executable bit)\n"))))
                        ;; lay down /etc/geos/user-init.el -> store path.
                        ;; same activation-bypass reason as the /bin/sh
                        ;; swap above: extra-special-file in the system
                        ;; record never materialises because Guix's
                        ;; activate.scm does not run.  the per-user
                        ;; emacs is spawned with `-l /etc/geos/user-init.el'
                        ;; from session--child-argv; if that file is
                        ;; missing emacs exits and the spawn becomes a
                        ;; zombie.  same crash-safe pattern: mkdir -p
                        ;; the parent, swap via temp + rename, log on
                        ;; failure.  /etc must exist (Guix's rootfs
                        ;; layout includes it) but /etc/geos is created
                        ;; here.
                        (catch 'system-error
                          (lambda () (mkdir "/etc/geos"))
                          (lambda _ #t))
                        (let ((tmp "/etc/geos/user-init.el.geos-new"))
                          (catch 'system-error
                            (lambda ()
                              (when (file-exists? tmp)
                                (delete-file tmp))
                              (symlink #$user-init-el tmp)
                              (rename-file tmp "/etc/geos/user-init.el"))
                            (lambda (key . args)
                              (console-write
                               (string-append
                                "pid1: /etc/geos/user-init.el swap failed: "
                                (object->string args) "\n")))))
                        ;; lay down /usr/bin/emacs -> emacs/bin/emacs.
                        ;; same activation-bypass: session--child-program
                        ;; in core/session.el hard-codes /usr/bin/emacs as
                        ;; the absolute path passed to pid1-spawn-as-uid;
                        ;; without this swap execve(2) in the child fails
                        ;; ENOENT and the per-user emacs never starts
                        ;; (login UI shows "child pid: (stubbed)" because
                        ;; the poller clears the pid on early exit).
                        ;; mkdir -p /usr and /usr/bin first because the
                        ;; rootfs Guix lays down does not include them.
                        (catch 'system-error
                          (lambda () (mkdir "/usr"))
                          (lambda _ #t))
                        (catch 'system-error
                          (lambda () (mkdir "/usr/bin"))
                          (lambda _ #t))
                        (let ((tmp "/usr/bin/emacs.geos-new"))
                          (catch 'system-error
                            (lambda ()
                              (when (file-exists? tmp)
                                (delete-file tmp))
                              (symlink #$(file-append emacs "/bin/emacs")
                                       tmp)
                              (rename-file tmp "/usr/bin/emacs"))
                            (lambda (key . args)
                              (console-write
                               (string-append
                                "pid1: /usr/bin/emacs swap failed: "
                                (object->string args) "\n")))))
                        ;; execl replaces this process.  if it returns
                        ;; or raises, the binary is missing or not
                        ;; executable, and falling through would let
                        ;; the kernel panic with a useless "init
                        ;; exited".  catch system-error so we can name
                        ;; the cause on /dev/console before exiting.
                        ;; shepherd is gone: nothing else would start
                        ;; if we just dropped through.
                        (catch 'system-error
                          (lambda ()
                            ;; (M2, audit round-5 2026-05-10) pass the
                            ;; full store path as argv[0] instead of
                            ;; the bare "emacs-init" string.  /proc/1/
                            ;; cmdline then points at the actual binary
                            ;; (helpful for debugging core dumps and for
                            ;; any future tooling that locates pid1 via
                            ;; argv[0]).  emacs-init.c does not branch
                            ;; on argv[0], so the change is invisible
                            ;; at runtime aside from /proc cosmetics.
                            (execl #$emacs-init-binary
                               #$emacs-init-binary
                               #$(file-append emacs "/bin/emacs")
                               #$pid1-module-so
                               ;; argv[3]: X server spec, colon-joined.
                               ;; phase 5c flips Xvfb -> Xorg with the
                               ;; modesetting driver against virtio_gpu
                               ;; (qemu -vga virtio). this gives real
                               ;; KMS so pixels actually land in the
                               ;; qemu sdl/gtk window instead of being
                               ;; stuck in Xvfb's in-memory framebuffer.
                               (string-append
                                #$(file-append xorg-server "/bin/Xorg")
                                ":"
                                #$(file-append xkbcomp "/bin")
                                ":"
                                ;; modulepath: Xorg accepts comma-separated
                                ;; paths. xorg-server holds the core plus
                                ;; modesetting/fb; xf86-input-evdev ships
                                ;; the evdev_drv.so out of tree, so we
                                ;; have to splice its module dir in or
                                ;; Xorg fails with "No input driver
                                ;; matching `evdev'".
                                #$(file-append xorg-server "/lib/xorg/modules")
                                ","
                                #$(file-append xf86-input-evdev
                                               "/lib/xorg/modules")
                                ":"
                                "/run/current-system/profile/share/fonts"
                                ":"
                                #$xorg-conf)
                               "-Q"
                               ;; we boot with -Q so a stale ~/.emacs.d
                               ;; can't derail us. -Q also skips
                               ;; site-lisp scanning, so the system
                               ;; profile's exwm/xelb/compat dirs are
                               ;; not on load-path here. instead of
                               ;; hardcoding versioned -L flags (which
                               ;; would break on every emacs-exwm bump)
                               ;; exwm-config.el reads /proc/cmdline,
                               ;; finds the gnu.system= profile, and
                               ;; loads its subdirs.el at run time.
                               ;; phase 5b's package.el bootstrap will
                               ;; replace that crutch with use-package.
                               "-l" #$early-init-el
                               "-l" #$panic-el
                               "-l" #$cmdline-el
                               "-l" #$state-el
                               "-l" #$supervise-el
                               "-l" #$power-el
                               "-l" #$use-package-shim-el
                               "-l" #$network-el
                               "-l" #$hostname-el
                               "-l" #$passwd-el
                               "-l" #$session-el
                               ;; v0.7 item 1.1: x-display.el ships the
                               ;; supervisor-side release / reclaim verbs
                               ;; for :0.  load after session-el so a
                               ;; future slice 1.3 can have session-spawn
                               ;; call into it.  for slice 1.1 the file is
                               ;; load-and-park: defuns are reachable from
                               ;; M-x but no caller hits them yet.
                               "-l" #$x-display-el
                               ;; v0.6 item 3: supervisor RPC server.
                               ;; loads after session-el so future verbs
                               ;; that read the session table see a
                               ;; finalised registry.  bottom-of-load
                               ;; auto-start in rpc-server.el binds
                               ;; /run/geos/super.sock and arms the
                               ;; 200ms poll timer; no separate call is
                               ;; needed from boot-marker.el.
                               "-l" #$rpc-server-el
                               "-l" #$network-buffer-el
                               ;; v0.7 item 1.2: the EXWM stack
                               ;; (exwm-config / multimon / fonts /
                               ;; input) is no longer -l'd here.  the
                               ;; per-user emacs loads them itself via
                               ;; user-init--chain.  the supervisor
                               ;; still has DISPLAY=:0 in its env (pid1
                               ;; sets it) but does NOT call exwm-enable;
                               ;; *login* draws into a plain unmanaged
                               ;; X frame between sessions, and the
                               ;; user-emacs grabs WM duties.  slice 1.3
                               ;; closes the supervisor's X connection
                               ;; across a session via x-display-release.
                               ;; v0.7 item 3.1: *audio* moved user-side.
                               ;; the supervisor no longer loads
                               ;; userland-audio or audio-buffer; the
                               ;; per-user emacs picks them up via
                               ;; user-init--chain.  a stuck audio
                               ;; render now stalls one user-emacs, not
                               ;; PID 1.
                               ;; phase 6 buffers. lazy-loaded entry
                               ;; points; touching any of these via M-x
                               ;; spins up the per-buffer timer/source.
                               ;; loading the file itself is cheap, no
                               ;; side effects beyond defun + provide.
                               "-l" #$processes-buffer-el
                               "-l" #$journal-buffer-el
                               "-l" #$services-buffer-el
                               "-l" #$disks-buffer-el
                               "-l" #$packages-buffer-el
                               "-l" #$reconfigure-buffer-el
                               "-l" #$users-buffer-el
                               "-l" #$login-buffer-el
                               ;; v0.4 item 2 services.  each defservice
                               ;; form runs at load time and populates
                               ;; supervise.el's registry.  loaded after
                               ;; the buffers/ chain so journal-tail can
                               ;; (require 'journal-buffer) for the
                               ;; record parser, before boot-marker so
                               ;; supervise-finalize sees a complete
                               ;; registry.
                               "-l" #$journal-tail-service-el
                               "-l" #$dhcp-service-el
                               ;; v0.4 item 3: the install wizard.
                               ;; load the four install/*.el helpers
                               ;; first (each (provide 's an
                               ;; install-* feature), then the buffer
                               ;; that (require)s them.  no side
                               ;; effects at load time; M-x install
                               ;; is the entry point.
                               "-l" #$install-disk-el
                               "-l" #$install-mkfs-el
                               "-l" #$install-copy-el
                               "-l" #$install-grub-el
                               "-l" #$install-buffer-el
                               ;; LAST.  boot-marker writes the
                               ;; userland-up sentinel at load time;
                               ;; reaching this -l proves every
                               ;; previous -l above also ran.  this
                               ;; file ALSO calls supervise-finalize,
                               ;; which restores persisted counters and
                               ;; autostarts every non-held service.
                               "-l" #$boot-marker-el))
                          (lambda (key . args)
                            (console-write
                             (string-append
                              "pid1: execl emacs-init failed: "
                              (object->string args) "\n"))))
                        ;; either execl raised (caught above) or it
                        ;; returned without raising (shouldn't happen,
                        ;; but be defensive).  if we exit, the kernel
                        ;; immediately panics with "init exited" and
                        ;; the user sees nothing useful.  instead,
                        ;; loop forever logging once a minute so a
                        ;; serial-console observer can read why we
                        ;; gave up.  the only escape is power cycle,
                        ;; which is also what primitive-exit would
                        ;; force, but with a noticeable trail.
                        (let loop ()
                          (console-write
                           "pid1: execl returned, init wedged; reboot to recover\n")
                          (sleep 60)
                          (loop)))))

;; v0.4 item 10: ONE binding, two GRUB menu entries.
;;
;; geos-user-kernel-arguments is the user-facing slice of the kernel
;; cmdline: console wiring, geos.mode token, panic/oops behaviour,
;; %default-kernel-arguments.  it is a procedure of one symbol (the
;; mode), so the operating-system record below can call it with 'ui
;; (the default boot) and the console-mode menu-entry below can call
;; it with 'console without either side drifting from the other.
;;
;; previously this list was inlined in the operating-system's
;; kernel-arguments field with "geos.mode=ui" hard-coded, and the
;; only way to land in console mode was to press `e' at GRUB and
;; surgically swap the token.  now the GRUB menu carries both modes
;; as first-class entries, sharing this binding so a future change
;; to (for example) panic= shows up in both menu entries instead of
;; only in the auto-generated UI one.
;;
;; on the trailing `console=' precedence: linux uses the LAST
;; console= as the primary /dev/console, so serial is last to make
;; -serial mon:stdio capture PID 1 output.  on real hardware we will
;; flip these so tty1 wins.
;;
;; phase 5c update: nomodeset and vga=0x317 are gone.  with
;; virtio_gpu loaded from initrd-modules we WANT KMS up so Xorg's
;; modesetting driver has a /dev/dri/card0 to bind.  vesafb is no
;; longer the rendering surface; virtio-gpu's drm fbcon is.
(define (geos-user-kernel-arguments mode)
    (cons* "console=tty1"
           "console=ttyS0,115200"
           (string-append "geos.mode=" (symbol->string mode))
           ;; (B3, audit round-5 2026-05-10) emacs-init.c documents
           ;; reliance on `panic=10' so the kernel reboots after a
           ;; supervisor-side _exit(127).  without panic= the kernel
           ;; locks indefinitely on the "init exited" panic and the
           ;; VM/host needs an external power cycle.  oops=panic
           ;; promotes a kernel oops to a panic so the same recovery
           ;; path catches both.
           "panic=10"
           "oops=panic"
           %default-kernel-arguments))

;; phase 5c: load virtio_gpu in the initrd so /dev/dri/card0 exists
;; before pid1 spawns Xorg. virtio_pci is needed because virtio_gpu
;; rides PCI; drm is pulled in transitively but listing it explicitly
;; documents intent. without these, modesetting would log
;; "no devices detected" and Xorg would die at AddScreen.
;;
;; psmouse + usbhid: the boot dump showed the kernel only enumerated
;; the AT keyboard (channel 0 of i8042) and not the PS/2 mouse
;; (channel 1). that is because psmouse is built as a module in the
;; default linux-libre and we have no udev to modprobe it on demand.
;; pulling it into the initrd forces the mouse to appear at
;; /dev/input/eventN by the time pid1 spawns Xorg. usbhid covers the
;; -device usb-tablet route from the qemu side, which is the more
;; reliable VM mouse path long term.
;;
;; v0.4 item 10: hoisted to a top-level binding so the
;; operating-system's initrd-modules field and the console-mode
;; menu-entry's initrd reference cannot drift.  the auto-generated
;; UI entry pulls the initrd via operating-system-initrd-file (which
;; bakes in this list); the explicit console entry references the
;; SAME initrd derivation by reading it back off base-os, so Guix
;; produces ONE initrd derivation that both grub.cfg lines point at.
(define %geos-initrd-modules
    (cons* "virtio_pci"
           "virtio_gpu"
           "drm"
           "psmouse"
           "usbhid"
           %base-initrd-modules))

;; v0.4 item 10: shared root-file-system declaration so base-os/skeleton
;; below and the final base-os agree byte-for-byte on every field
;; except `device'.  if these drift, operating-system-uuid hashes a
;; different file-system-digest than what `operating-system-for-image'
;; sees, the predicted UUID stops matching the image's actual UUID, and
;; the console-mode menu entry boots with the wrong root= and lands in
;; the initrd's emergency shell.
(define %geos-root-mount-point "/")
(define %geos-root-fs-type "ext4")

;; base-os/skeleton mirrors the os that `operating-system-for-image'
;; constructs internally as the input to root-uuid: same hostname,
;; same services, same file-systems EXCEPT the root device, which is
;; "/dev/placeholder" (the literal string upstream uses).  that lets us
;; pre-compute the same deterministic UUID upstream will compute and
;; bake it into the real base-os below as the root device, so the
;; auto-generated UI entry's initrd derivation is identical to the
;; explicit console entry's initrd derivation: ONE initrd in the
;; closure, both menu entries point at it, the v0.4 item 10 spec's
;; "same initrd" constraint holds.  base-os/skeleton is NEVER fed to
;; `guix system image' on its own; it exists only so we can hash it.
(define base-os/skeleton
  (operating-system
    (host-name "lambda")
    (timezone "Europe/Madrid")
    (locale "en_US.utf8")

    ;; v0.4 item 10: this label is what the auto-generated GRUB entry
    ;; shows.  match the explicit console entry's label style so the
    ;; menu reads as a coherent pair.
    (label "GNU/Emacs OS (UI mode, Xorg + EXWM)")

    (kernel linux-libre)

    ;; no init= here on purpose. guix's initrd ignores the kernel
    ;; cmdline init= and execs gnu.load=...boot, so any value we put
    ;; here would be a lie. the real handover happens in
    ;; emacs-init-boot-service above.
    ;;
    ;; geos.mode=ui is the default.  PID 1 reads this from /proc/cmdline
    ;; before deciding whether to spawn Xorg.  UI mode brings up Xorg +
    ;; EXWM and runs Emacs as an X client; the GRUB menu now exposes a
    ;; console-mode entry one arrow-key + Enter away that flips this token.
    (kernel-arguments (geos-user-kernel-arguments 'ui))

    (initrd-modules %geos-initrd-modules)

    ;; placeholder bootloader.  the inherited form below replaces this
    ;; with a bootloader-configuration that adds the console-mode
    ;; menu-entry on top of the auto-generated UI entry.  we cannot put
    ;; the real menu-entries here because they need to reference base-os
    ;; itself for kernel-file / initrd-file.
    (bootloader (bootloader-configuration
                  (bootloader grub-bootloader)
                  (targets '("/dev/sda"))))

    ;; root device is the literal "/dev/placeholder" because that is
    ;; exactly what `operating-system-for-image' substitutes before
    ;; calling operating-system-uuid.  matching the substitution here
    ;; means the deterministic UUID we compute below = the one upstream
    ;; computes.  the real base-os swaps this string for the UUID.
    (file-systems
     (cons (file-system
             (mount-point %geos-root-mount-point)
             (device "/dev/placeholder")
             (type %geos-root-fs-type))
           %base-file-systems))

    ;; %base-user-accounts already includes root and the system service
    ;; users (daemon, nobody, etc.). adding our own root-account record
    ;; on top of that triggers `accounts appear more than once: root'
    ;; from guix system, so we just inherit the base set verbatim.
    (users %base-user-accounts)

    ;; emacs is required, base packages are kept for the install-time
    ;; coreutils and bash (bash provides /bin/sh until phase 3 ships the
    ;; shstub binary; see exceptions.scm when that lands). nothing in
    ;; this list is meant to be a "user" package, the whole user
    ;; environment is emacs.
    ;;
    ;; phase 5a adds:
    ;;   xorg-server         the X server we fork in pid1 before emacs.
    ;;                       phase 5c uses the modesetting driver (built
    ;;                       into xorg-server) against virtio-gpu KMS, so
    ;;                       no separate xf86-video-* package is needed.
    ;;   xf86-input-evdev    input driver. opens /dev/input/event* via
    ;;                       raw ioctl, no udev required. xorg.conf
    ;;                       lists explicit InputDevice sections with
    ;;                       static device paths.
    ;;   xkbcomp             Xorg shells out to this at startup to compile
    ;;                       the keymap. without it, Xorg dies during
    ;;                       initial keymap load with "Couldn't load XKB
    ;;                       keymap, falling back to pre-XKB keymap".
    ;;   xkeyboard-config    keymap data files xkbcomp reads.
    ;;   xterm               the canary client. start-process'd from exwm
    ;;                       at the M-x prompt to verify wm is alive.
    ;;   emacs-exwm          the wm itself.
    ;; phase 5b adds:
    ;;   emacs-magit         git porcelain. magit talks to git via
    ;;                       process-file, so no shell-out from our code.
    ;;   notmuch             the C indexer + notmuch(1) cli. emacs-notmuch
    ;;                       hard-depends on the binary being on PATH.
    ;;   emacs-notmuch       the elisp UI that fronts the indexer.
    ;;   emacs-pdf-tools     PDF reader. ships the epdfinfo helper that
    ;;                       talks to poppler; Guix builds it at package
    ;;                       time so we get a working binary out of the box.
    ;; dired, eshell, eww, erc and org are in-tree on emacs 30 and need
    ;; no extra package.
    ;; phase 5c adds:
    ;;   font-google-noto             monospace + Latin coverage. the
    ;;                                emacs-init/user/fonts.el default family
    ;;                                falls back to DejaVu, which Guix
    ;;                                ships via the noto closure's deps,
    ;;                                so this package gives us both at
    ;;                                once.
    ;;   font-google-noto-emoji       emoji glyphs (color, COLR/CPAL).
    ;;                                without harfbuzz on the emacs build
    ;;                                they render as outlines, but they
    ;;                                resolve to a glyph either way.
    ;;   font-google-noto-sans-cjk    pan-CJK coverage (SC/TC/JP/KR in
    ;;                                one closure).
    (packages (cons* emacs
                     xorg-server
                     xf86-input-evdev
                     xkbcomp
                     xkeyboard-config
                     xterm
                     emacs-exwm
                     emacs-magit
                     notmuch
                     emacs-notmuch
                     emacs-pdf-tools
                     font-google-noto
                     font-google-noto-emoji
                     font-google-noto-sans-cjk
                     ;; v0.4 item 8: ALSA userland.  alsa-utils ships
                     ;; amixer (volume) and aplay (sample playback);
                     ;; alsa-lib is pulled in transitively but listed
                     ;; explicitly so a future native pid1-alsa.so
                     ;; module compiles against headers from the same
                     ;; pinned channel.  no PipeWire, no daemon: ALSA
                     ;; is the kernel API we already have.
                     alsa-utils
                     alsa-lib
                     ;; v0.7 item 2.3: IBus + the libpinyin engine for
                     ;; canonical CJK round-trip.  dbus is added because
                     ;; ibus-daemon expects a session bus; user-init.el
                     ;; will run dbus-launch under make-process and let
                     ;; ibus-daemon find DBUS_SESSION_BUS_ADDRESS in its
                     ;; environment.  no systemd, no shepherd: the
                     ;; daemon's lifetime is the per-user emacs's
                     ;; process group, which dies on logout.
                     ibus
                     ibus-libpinyin
                     dbus
                     ;; v0.4 item 5 finisher.  dhcpcd is spawned by
                     ;; services/dhcp.el on operator action (the `d'
                     ;; key in the *network* buffer).  shell-out
                     ;; exception documented in
                     ;; guix-system/exceptions.scm; closure is a v0.5
                     ;; native RFC2131 client.
                     dhcpcd
                     ;; v0.4 item 3 install wizard.  the wizard
                     ;; spawns these four binaries via make-process
                     ;; (no shell-out): mkfs.ext4 from e2fsprogs,
                     ;; mkfs.fat from dosfstools (FAT32 reserved for
                     ;; the v0.4.1 ESP), grub-install and
                     ;; grub-mkconfig from grub.  parted is in the
                     ;; manifest because v0.4.1 partition-from-
                     ;; scratch will need it; keeping it now means
                     ;; the same ISO covers both versions and an
                     ;; operator who has not pre-partitioned can
                     ;; eshell-out to parted manually for now.
                     e2fsprogs
                     dosfstools
                     parted
                     ;; grub-pc is the BIOS i386-pc variant.  it
                     ;; ships grub-install + grub-mkconfig along
                     ;; with the i386-pc modules used to write the
                     ;; MBR stub.  v0.4.1 adds grub-efi to the
                     ;; manifest when the wizard learns UEFI.
                     grub-pc
                     %base-packages))

    ;; %base-services is kept because removing shepherd-root-service-type
    ;; outright breaks any service that extends it (login, mingetty,
    ;; nscd, guix-daemon, ...). we leave the whole shepherd graph in the
    ;; store and simply never reach it: emacs-init-boot-service execs
    ;; /sbin/emacs-init before the shepherd exec gexp runs. shepherd
    ;; lives in the store as inert bits.
    ;;
    ;; extra-special-file is a service-producing procedure in guix, not
    ;; a record field, so the wiring is done here. it places the
    ;; phase-1 binary at /sbin/emacs-init via a symlink into the store.
    ;;
    ;; build order: the local-file below references ../pid1/emacs-init,
    ;; which means `make -C pid1` MUST run before `guix system image
    ;; system.scm`. if you skip the make, guix errors with "no such
    ;; file" and the boot image is never produced. that is the intended
    ;; failure mode for phase 1; phase 2 replaces this with a real
    ;; package definition so the bits are produced by guix.
    (services
     (cons* emacs-init-boot-service
            (extra-special-file "/sbin/emacs-init" emacs-init-binary)
            (extra-special-file "/etc/geos/user-init.el" user-init-el)
            ;; v0.6 item 1.2: lay the user-side chain on disk at fixed
            ;; paths.  user-init.el loads each absolute path via plain
            ;; `load' (not require) so the per-user emacs does not
            ;; depend on the supervisor having loaded anything.  panic
            ;; and use-package-shim live under /etc/geos/core/; the
            ;; userland packages under /etc/geos/user/userland/.  the
            ;; supervisor's -l chain no longer references these files;
            ;; the user-emacs side does.
            (extra-special-file "/etc/geos/core/panic.el" panic-el)
            (extra-special-file "/etc/geos/core/use-package-shim.el"
                                use-package-shim-el)
            ;; v0.6 item 3: rpc-client.el laid down for the per-user
            ;; emacs to load via user-init--chain.  rpc-server.el is
            ;; NOT laid down user-side: the verb handlers call pid1-*
            ;; primitives that the per-user emacs deliberately lacks.
            (extra-special-file "/etc/geos/core/rpc-client.el"
                                rpc-client-el)
            (extra-special-file "/etc/geos/user/userland/files.el"
                                userland-files-el)
            (extra-special-file "/etc/geos/user/userland/shell.el"
                                userland-shell-el)
            (extra-special-file "/etc/geos/user/userland/uname.el"
                                userland-uname-el)
            (extra-special-file "/etc/geos/user/userland/git.el"
                                userland-git-el)
            (extra-special-file "/etc/geos/user/userland/web.el"
                                userland-web-el)
            (extra-special-file "/etc/geos/user/userland/mail.el"
                                userland-mail-el)
            (extra-special-file "/etc/geos/user/userland/chat.el"
                                userland-chat-el)
            (extra-special-file "/etc/geos/user/userland/notes.el"
                                userland-notes-el)
            (extra-special-file "/etc/geos/user/userland/pdf.el"
                                userland-pdf-el)
            ;; v0.7 item 3.1: audio.el lives ONLY user-side now.  the
            ;; ALSA wrappers and the *audio* buffer both live in the
            ;; per-user emacs; the supervisor never opens *audio*.  a
            ;; stuck mixer call (e.g. amixer hung on an unresponsive
            ;; card) stalls one user-emacs, not PID 1.
            (extra-special-file "/etc/geos/user/userland/audio.el"
                                userland-audio-el)
            ;; v0.7 item 4.2: user-side *services* over RPC.  loaded
            ;; before userland/init.el so the verifier walks the
            ;; services-client feature too.
            (extra-special-file "/etc/geos/user/userland/services-client.el"
                                userland-services-client-el)
            (extra-special-file "/etc/geos/user/userland/init.el"
                                userland-init-el)
            ;; v0.7 item 1.2: the EXWM stack now lives user-side.  the
            ;; per-user emacs loads exwm-config / multimon / fonts /
            ;; input from /etc/geos/user/ via user-init--chain.  the
            ;; supervisor no longer -l's these files; this is what
            ;; finishes the v0.6 item 1 trim that left wm/ in place.
            (extra-special-file "/etc/geos/user/exwm-config.el"
                                exwm-config-el)
            (extra-special-file "/etc/geos/user/multimon.el"
                                multimon-el)
            (extra-special-file "/etc/geos/user/fonts.el"
                                fonts-el)
            (extra-special-file "/etc/geos/user/input.el"
                                input-el)
            ;; v0.7 item 3.1: the *audio* buffer.  laid down at this
            ;; path so user-init--chain can load it after the userland
            ;; chain (buffers/audio.el requires userland-audio at load
            ;; time, so it MUST follow userland/audio.el in the chain).
            (extra-special-file "/etc/geos/user/audio-buffer.el"
                                audio-buffer-el)
            %base-services))

    (name-service-switch %mdns-host-lookup-nss)))

;; v0.4 item 10: the deterministic root-device UUID upstream's
;; operating-system-for-image will compute.  the inputs to
;; operating-system-uuid are the file-systems digest list, hostname,
;; and service-type names.  base-os/skeleton is byte-equal to the
;; intermediate os upstream constructs (same hostname, same services,
;; same file-systems, root device = "/dev/placeholder"), so the hash
;; matches.  if upstream ever changes the hash recipe, the smoke test
;; will catch it: the kernel cmdline's root= UUID will not match the
;; partition UUID and mount will fail.
(define %geos-root-uuid
  (operating-system-uuid base-os/skeleton 'dce))

;; base-os is what the rest of the file (bootloader menu-entries) and
;; what `guix system image' both consume.  the only difference from
;; base-os/skeleton is the root file-system's device, which is now the
;; predicted UUID instead of the placeholder string.  consequence:
;;   - operating-system-initrd-file base-os bakes a mount table that
;;     looks for the root partition by uuid.
;;   - image-with-os* reads (file-system-device root-file-system) to
;;     stamp the partition's uuid field, so the on-disk partition
;;     header carries the same uuid the initrd will look for.
;;   - operating-system-for-image runs its own placeholder-then-uuid
;;     dance, computes the SAME uuid (because the intermediate os it
;;     builds is identical to base-os/skeleton), and ends up returning
;;     an os equivalent to base-os.  net effect: one initrd derivation,
;;     one system derivation, both menu entries point at them.
(define base-os
  (operating-system
    (inherit base-os/skeleton)
    (file-systems
     (cons (file-system
             (mount-point %geos-root-mount-point)
             (device %geos-root-uuid)
             (type %geos-root-fs-type))
           %base-file-systems))))

;; v0.4 item 10: the final value of this file.  inherits everything
;; from base-os and only overrides the bootloader so the
;; menu-entries field can reference base-os itself for kernel and
;; initrd files.  what GRUB ends up writing:
;;
;;   menuentry "GNU/Emacs OS (UI mode, Xorg + EXWM)" { ...ui args... }     [default]
;;   menuentry "GNU/Emacs OS (Console mode, framebuffer Emacs)" { ...console args... }
;;
;; the auto-generated UI entry comes from operating-system-bootcfg's
;; boot-parameters->menu-entry pass; the console entry below is
;; appended afterwards by grub-configuration-file (it concatenates
;; system entries and bootloader-configuration menu-entries in that
;; order).  default-entry stays at 0 so an unattended boot lands on
;; UI as it always has.
;;
;; both entries reference (operating-system-kernel-file base-os) and
;; (operating-system-initrd-file base-os): one kernel binary, one
;; initrd derivation, two cmdlines.  if a future reconfigure picks
;; up a newer linux-libre or adds an initrd module, both entries
;; follow.
;;
;; the bootable triple (root=, gnu.system=, gnu.load=) is what
;; Guix's boot script needs to find /run/booted-system.  for the
;; auto-entry, operating-system-bootcfg builds this triple itself;
;; for the console entry we have to splice it in front of the user
;; args by hand, which is what geos-bootable-kernel-arguments at the
;; top of this file is for.  version is hard-coded to 1 to match
;; %boot-parameters-version (the version where gnu.load/gnu.system
;; replaced --load/--system); bumping requires a coordinated change
;; on the upstream side anyway.
(operating-system
  (inherit base-os)
  (bootloader
    (bootloader-configuration
      (bootloader grub-bootloader)
      (targets '("/dev/sda"))
      (menu-entries
        (let* ((root-fs (operating-system-root-file-system base-os))
               (root-dev (file-system-device root-fs))
               (bootable (geos-bootable-kernel-arguments
                          base-os root-dev 1)))
          (list
            (menu-entry
              (label "GNU/Emacs OS (Console mode, framebuffer Emacs)")
              (linux (operating-system-kernel-file base-os))
              (initrd (operating-system-initrd-file base-os))
              (linux-arguments
                (append bootable
                        (geos-user-kernel-arguments 'console))))
            ;; v0.4 item 10: recovery boot.  same kernel + initrd as
            ;; the other entries (we share one closure), but pid1
            ;; reads geos.mode=recovery and (a) skips Xorg and (b)
            ;; sets GEOS_MODE=recovery in emacs's env.  early-init.el
            ;; then drops the rest of the -l userland chain so a
            ;; broken defservice or defcustom cannot wedge the boot.
            ;; the operator lands on bare *scratch* with panic.el in
            ;; scope.
            (menu-entry
              (label "GNU/Emacs OS (Recovery, no userland chain)")
              (linux (operating-system-kernel-file base-os))
              (initrd (operating-system-initrd-file base-os))
              (linux-arguments
                (append bootable
                        (geos-user-kernel-arguments 'recovery))))))))))
