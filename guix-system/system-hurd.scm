;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;; system-hurd.scm, the operating-system record for the Hurd port of
;; GNU/Emacs Operating System (GEOS).
;;
;; this is step 3 of the hurd work order, docs/v04-item11-hurd-spike.md
;; lines 161-166.  the goal here is a record that `guix system
;; disk-image -t hurd64-raw` will chew on; whether the produced image
;; actually boots far enough to print "geos: emacs userland up" on the
;; Hurd console is the step 6 deliverable, not step 3.  this file lives
;; on the hurd side branch only; main never sees it.
;;
;; design: inherit nothing record-wise from system.scm.  i tried that
;; first and ran into two problems.  (1) (gnu system) and (gnu system
;; hurd) define different default services; an `inherit' would either
;; pick the linux defaults and leave the hurd services out, or vice
;; versa, and either way half the boot wiring would be silently wrong.
;; (2) system.scm imports (gnu packages xorg) and friends which exist
;; for both kernels but pull in linux-only artefacts (xf86-input-evdev
;; needs /dev/input/eventN; xorg-server on Hurd would attach to the
;; X protocol over the local socket and pretend it has DRI, then crash
;; at the first DRM call).  the cleaner shape is: rebuild the record
;; from scratch using the same userland local-files that system.scm
;; references, drop the X/EXWM/dhcpcd surfaces, and call gnu-system
;; with the gnumach+hurd kernel pair.
;;
;; explicitly dropped from system.scm, and why:
;;
;;   xorg-server, xf86-input-evdev, xkbcomp, xkeyboard-config, xterm,
;;   emacs-exwm                  no usable DRM/KMS on hurd today.  v0.4
;;                               line is console-only; v0.6+ revisits.
;;   font-google-noto-{,emoji,cjk}   xorg-only consumers.  console emacs
;;                               on the framebuffer renders with the
;;                               kernel-vt font set; no reason to bloat
;;                               the closure with desktop fonts.
;;   dhcpcd                      v0.4 hurd has no pfinet RPC backend in
;;                               port_hurd.c yet (step 5).  the /network
;;                               buffer's `d' key will fail with ENOSYS
;;                               on hurd until step 5 ships.
;;   ibus, ibus-libpinyin, dbus  ibus is an X client; useless on the
;;                               framebuffer.  CJK input on hurd
;;                               console is v0.6+ if ever.
;;   alsa-utils, alsa-lib        gnumach has no ALSA layer.  *audio*
;;                               buffer renders "not on this kernel"
;;                               via geos-port-unimplemented.
;;   e2fsprogs, dosfstools, parted, grub-pc       install wizard is
;;                               linux-only (v0.4 item 3, /sys/block +
;;                               grub-pc dependency).  hurd installs
;;                               stay the Guix manual `guix system init`
;;                               flow.
;;
;; kept verbatim (the userland is portable, only the kernel and the X
;; surface change):
;;
;;   emacs               console-friendly; on hurd this is emacs-no-x
;;                       in practice, but `emacs' alone resolves to
;;                       the no-toolkit variant when X is absent at
;;                       link time.  if the build complains we can
;;                       pin to emacs-no-x-toolkit explicitly.
;;   pid1 module + emacs-init binary    same source, built with
;;                                      PORT=hurd in pid1/Makefile.
;;   shstub /bin/sh      pure POSIX, no kernel surface.
;;   core/*.el           panic, state, supervise, hostname, passwd,
;;                       session, port (the elisp seam), rpc-server.
;;   buffers/*.el        users, login, processes, services, journal,
;;                       network.  buffers that read /sys/* render an
;;                       unimplemented message via
;;                       geos-port-unimplemented (see core/port.el).
;;   user/userland/*.el  dired, eshell, magit, eww, notmuch, erc, org.
;;                       all pure-elisp; no kernel surface.
;;
;; on the boot mode: hurd v0.4 is `geos.mode=console' by default (no
;; Xorg).  early-init.el reads /proc/cmdline; hurd's procfs translator
;; exposes /proc/cmdline as a string, so the existing reader works
;; without a branch.  the operating-system's kernel-arguments below
;; carries `geos.mode=console' so even without GRUB on hurd
;; (gnumach uses its own bootloader path) the cmdline emerges with the
;; same token.
;;
;; on the device naming: hurd uses /dev/hd0s1 (first IDE disk, first
;; slice) instead of /dev/sda1.  the file-systems record below points
;; at /dev/hd0s1; the disk-image build target is `hurd64-raw' which
;; lays out a single-partition image matching that path.

(use-modules (gnu)
             (gnu packages admin)
             (gnu packages base)
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu services)
             (gnu services base)
             (gnu system)
             ;; the (gnu system hurd) module provides %hurd-default-
             ;; operating-system and the gnumach / hurd packages.
             ;; resolved by the channel pin in channels.scm; the hurd
             ;; channel is bundled in upstream guix today.
             (gnu system hurd)
             (guix gexp))

(define emacs-init-binary
    ;; same source as the linux build, but produced by `make PORT=hurd'
    ;; before the disk-image build.  the local-file path is resolved
    ;; at gexp expansion; if the operator forgets the PORT=hurd flag
    ;; the local-file will pick up whatever emacs-init was built last,
    ;; which on a linux dev host would be the linux binary.  the
    ;; iso-build/hurd-smoke-test.sh wrapper will eventually enforce
    ;; the right build invocation; for step 3 the failure mode is a
    ;; loud kernel panic at gnumach boot, which is acceptable.
    (local-file "../pid1/emacs-init" "emacs-init" #:recursive? #t))

(define pid1-module-so
    (local-file "../pid1/pid1-module.so" "pid1-module.so" #:recursive? #t))

;; the elisp chain mirrors system.scm exactly: every file under
;; emacs-init/core/, every system-concept buffer, every userland
;; module that does not depend on X.  the boot gexp below loads them
;; in the same order as the linux record.

(define early-init-el
    (local-file "../emacs-init/early-init.el" "early-init.el"))
(define panic-el
    (local-file "../emacs-init/core/panic.el" "panic.el"))
(define port-el
    (local-file "../emacs-init/core/port.el" "port.el"))
(define cmdline-el
    (local-file "../emacs-init/core/cmdline.el" "cmdline.el"))
(define use-package-shim-el
    (local-file "../emacs-init/core/use-package-shim.el"
                "use-package-shim.el"))
(define state-el
    (local-file "../emacs-init/core/state.el" "state.el"))
(define supervise-el
    (local-file "../emacs-init/core/supervise.el" "supervise.el"))
(define power-el
    (local-file "../emacs-init/core/power.el" "power.el"))
(define network-el
    (local-file "../emacs-init/core/network.el" "network.el"))
(define hostname-el
    (local-file "../emacs-init/core/hostname.el" "hostname.el"))
(define passwd-el
    (local-file "../emacs-init/core/passwd.el" "passwd.el"))
(define session-el
    (local-file "../emacs-init/core/session.el" "session.el"))
(define rpc-server-el
    (local-file "../emacs-init/core/rpc-server.el" "rpc-server.el"))
(define rpc-client-el
    (local-file "../emacs-init/core/rpc-client.el" "rpc-client.el"))
(define user-init-el
    (local-file "../emacs-init/user/user-init.el" "user-init.el"))
(define boot-marker-el
    (local-file "../emacs-init/core/boot-marker.el" "boot-marker.el"))

(define network-buffer-el
    (local-file "../emacs-init/buffers/network.el" "network-buffer.el"))
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
    (local-file "../emacs-init/buffers/users.el" "users-buffer.el"))
(define login-buffer-el
    (local-file "../emacs-init/buffers/login.el" "login-buffer.el"))

;; userland files that do NOT depend on X.  the dropped ones (audio
;; for ALSA, anything that needs DBus) are deliberately not listed.
(define userland-files-el
    (local-file "../emacs-init/user/userland/files.el" "userland-files.el"))
(define userland-shell-el
    (local-file "../emacs-init/user/userland/shell.el" "userland-shell.el"))
(define userland-uname-el
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
(define userland-services-client-el
    (local-file "../emacs-init/user/userland/services-client.el"
                "userland-services-client.el"))
(define userland-journal-client-el
    (local-file "../emacs-init/user/userland/journal-client.el"
                "userland-journal-client.el"))
(define userland-init-el
    (local-file "../emacs-init/user/userland/init.el" "userland-init.el"))

(define journal-tail-service-el
    (local-file "../emacs-init/services/journal-tail.el" "journal-tail.el"))

(define shstub-sh
    (local-file "../shstub/sh" "sh" #:recursive? #t))

;; the boot service.  same shape as the linux record's emacs-init-boot-
;; service but with an X-less argv (no argv[3] colon-joined Xorg spec,
;; just a placeholder empty string).  emacs-init.c already understands
;; argv[3]="" as "no X, render on /dev/console".
(define emacs-init-boot-service-hurd
    (simple-service 'emacs-init-boot-hurd
                    boot-service-type
                    #~(let ()
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
                        ;; lay down /bin/sh -> shstub.  same crash-safe
                        ;; pattern as system.scm; hurd's filesystem is
                        ;; ext2fs over hd0s1 but rename(2) semantics
                        ;; are the same.
                        (catch 'system-error
                          (lambda () (mkdir "/bin"))
                          (lambda _ #t))
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
                        ;; lay down /etc/geos/user-init.el and
                        ;; /usr/bin/emacs.  identical activation-
                        ;; bypass dance as system.scm; the hurd-side
                        ;; activate.scm has the same does-not-run
                        ;; property for us because we replace the
                        ;; boot script before activation reaches it.
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
                        (catch 'system-error
                          (lambda ()
                            (execl #$emacs-init-binary
                                   #$emacs-init-binary
                                   #$(file-append emacs "/bin/emacs")
                                   #$pid1-module-so
                                   ;; argv[3]: no Xorg on the hurd
                                   ;; console profile.  empty string
                                   ;; means "do not spawn X".
                                   ""
                                   "-Q"
                                   "-l" #$early-init-el
                                   "-l" #$panic-el
                                   "-l" #$port-el
                                   "-l" #$cmdline-el
                                   "-l" #$state-el
                                   "-l" #$supervise-el
                                   "-l" #$power-el
                                   "-l" #$use-package-shim-el
                                   "-l" #$network-el
                                   "-l" #$hostname-el
                                   "-l" #$passwd-el
                                   "-l" #$session-el
                                   "-l" #$rpc-server-el
                                   "-l" #$network-buffer-el
                                   "-l" #$processes-buffer-el
                                   "-l" #$journal-buffer-el
                                   "-l" #$services-buffer-el
                                   "-l" #$disks-buffer-el
                                   "-l" #$packages-buffer-el
                                   "-l" #$reconfigure-buffer-el
                                   "-l" #$users-buffer-el
                                   "-l" #$login-buffer-el
                                   "-l" #$journal-tail-service-el
                                   "-l" #$boot-marker-el))
                          (lambda (key . args)
                            (console-write
                             (string-append
                              "pid1: execl emacs-init failed: "
                              (object->string args) "\n"))))
                        (let loop ()
                          (console-write
                           "pid1: execl returned, init wedged; reboot to recover\n")
                          (sleep 60)
                          (loop)))))

;; the geos.mode token: hurd profile defaults to console.  the rest of
;; the cmdline is informational on gnumach (gnumach does not parse
;; linux panic=10 / oops=panic) but harmless to carry, so the parser
;; on the emacs side stays kernel-agnostic.
(define %geos-hurd-kernel-arguments
  (list "console=com0"
        "geos.mode=console"))

(operating-system
  (host-name "lambda-hurd")
  (timezone "Europe/Madrid")
  (locale "en_US.utf8")
  (label "GNU/Emacs OS (Hurd, console)")

  ;; gnumach is the microkernel; hurd is the userspace translator set
  ;; on top of it.  (gnu system hurd) defines both packages.
  (kernel gnumach)
  (hurd hurd)

  (kernel-arguments %geos-hurd-kernel-arguments)

  ;; gnumach uses GRUB the same way linux does on x86, so the
  ;; bootloader-configuration shape carries over.  the disk-image
  ;; build with -t hurd64-raw lays out a single MBR partition with
  ;; ext2fs, GRUB installed to /dev/hd0.  /dev/hd0 is the hurd-side
  ;; spelling of "first IDE disk".
  (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets '("/dev/hd0"))))

  ;; root on /dev/hd0s1 (first IDE disk, first slice).  the file-
  ;; system type is "ext2" because Hurd's ext2fs translator is what
  ;; understands the on-disk format; ext4 features (extents, journal
  ;; replay) are read-only on Hurd's translator today.  the v0.4
  ;; image stays at ext2 to avoid the half-mounted journal trap.
  (file-systems
   (cons (file-system
           (mount-point "/")
           (device "/dev/hd0s1")
           (type "ext2"))
         %base-file-systems))

  (users %base-user-accounts)

  ;; package set: the userland minus everything X/audio/install.  the
  ;; emacs package on hurd resolves to the no-X variant when xorg-
  ;; server is not in the closure; pinning to emacs-no-x-toolkit
  ;; would be more explicit but the available package on the hurd
  ;; channel today is plain `emacs', so we use that and let guix pick
  ;; the right build configuration based on inputs.
  (packages (cons* emacs
                   %base-packages))

  (services
   (cons* emacs-init-boot-service-hurd
          (extra-special-file "/sbin/emacs-init" emacs-init-binary)
          (extra-special-file "/etc/geos/user-init.el" user-init-el)
          ;; the elisp port seam.  same paths as system.scm so the
          ;; per-user emacs's user-init--chain can load them off
          ;; absolute paths without branching.
          (extra-special-file "/etc/geos/core/panic.el" panic-el)
          (extra-special-file "/etc/geos/core/port.el" port-el)
          (extra-special-file "/etc/geos/core/use-package-shim.el"
                              use-package-shim-el)
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
          (extra-special-file "/etc/geos/user/userland/services-client.el"
                              userland-services-client-el)
          (extra-special-file "/etc/geos/user/userland/journal-client.el"
                              userland-journal-client-el)
          (extra-special-file "/etc/geos/user/userland/init.el"
                              userland-init-el)
          (extra-special-file "/etc/geos/user/processes-buffer.el"
                              processes-buffer-el)
          %base-services))

  (name-service-switch %mdns-host-lookup-nss))
