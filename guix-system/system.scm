;; system.scm, the operating-system record for GNU/Emacs OS.
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
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu packages fonts)
             (gnu packages linux)
             (gnu packages mail)
             (gnu packages xorg)
             (gnu services)
             (gnu services base)
             (guix gexp))

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

(define use-package-shim-el
    ;; bootstraps use-package and registers the project's :comment
    ;; keyword as a no-op so the userland files do not raise
    ;; "Unrecognized keyword: :comment" at load time. depends on
    ;; panic.el, must load before any userland/*.el.
    (local-file "../emacs-init/core/use-package-shim.el"
                "use-package-shim.el"))

(define network-el
    ;; phase-4 core. /proc/net/dev and /proc/net/route parsers, plus
    ;; the declarative network-interface-config + bring-up hook into
    ;; pid1-bring-up-lo. requires panic, must load after panic.el.
    (local-file "../emacs-init/core/network.el" "network.el"))

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
    (local-file "../emacs-init/wm/exwm-config.el" "exwm-config.el"))

;; phase 5c additions. these three are (require)d from exwm-config.el
;; AFTER (exwm-enable) returns, so they need to be on load-path before
;; that file evaluates. the simplest way to guarantee that is to -l
;; them BEFORE exwm-config.el in the boot gexp; loading a file with
;; provide is enough to satisfy a later require. nothing here breaks
;; the no-DISPLAY degradation path: each module's -apply guards on
;; display-graphic-p / DISPLAY before doing any work.
(define multimon-el
    (local-file "../emacs-init/wm/multimon.el" "multimon.el"))
(define fonts-el
    (local-file "../emacs-init/wm/fonts.el" "fonts.el"))
(define input-el
    (local-file "../emacs-init/wm/input.el" "input.el"))

;; phase 5b userland files. each one wires up one user-facing package
;; via use-package. they are loaded by userland-init-el below, AFTER
;; exwm-config so the wm has the root window before any of these
;; packages spawn buffers. order inside the chain is cosmetic; nothing
;; here depends on anything else here.
(define userland-files-el
    (local-file "../emacs-init/userland/files.el" "userland-files.el"))
(define userland-shell-el
    (local-file "../emacs-init/userland/shell.el" "userland-shell.el"))
(define userland-git-el
    (local-file "../emacs-init/userland/git.el" "userland-git.el"))
(define userland-web-el
    (local-file "../emacs-init/userland/web.el" "userland-web.el"))
(define userland-mail-el
    (local-file "../emacs-init/userland/mail.el" "userland-mail.el"))
(define userland-chat-el
    (local-file "../emacs-init/userland/chat.el" "userland-chat.el"))
(define userland-notes-el
    (local-file "../emacs-init/userland/notes.el" "userland-notes.el"))
(define userland-pdf-el
    (local-file "../emacs-init/userland/pdf.el" "userland-pdf.el"))
(define userland-init-el
    ;; thin entry point that requires each of the above. loaded LAST so
    ;; exwm has already claimed the root frame.
    (local-file "../emacs-init/userland/init.el" "userland-init.el"))

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
                    #~(begin
                        ;; lay down /bin/sh -> shstub before handing
                        ;; off, because activation (which would
                        ;; normally do this via extra-special-file)
                        ;; never runs: our execl replaces the boot
                        ;; script process before activate.scm loads.
                        ;; if /bin already has an sh from the rootfs,
                        ;; replace it; the catch eats EEXIST when the
                        ;; symlink is already correct from a previous
                        ;; boot of the same store path.
                        (catch #t
                          (lambda ()
                            (when (file-exists? "/bin/sh")
                              (delete-file "/bin/sh"))
                            (symlink #$shstub-sh "/bin/sh"))
                          (const #f))
                        (execl #$emacs-init-binary
                               "emacs-init"
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
                                #$(file-append xorg-server "/lib/xorg/modules")
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
                               "-l" #$use-package-shim-el
                               "-l" #$network-el
                               "-l" #$network-buffer-el
                               ;; phase 5c modules -l'd BEFORE
                               ;; exwm-config so the (require 'multimon)
                               ;; etc inside that file resolve without
                               ;; a fresh load. the order between these
                               ;; three doesn't matter, none depends on
                               ;; another.
                               "-l" #$multimon-el
                               "-l" #$fonts-el
                               "-l" #$input-el
                               "-l" #$exwm-config-el
                               ;; phase 5b: userland packages. each
                               ;; (provide 'userland-foo)s, then init.el
                               ;; verifies they are all present. order
                               ;; here is the same as `userland-modules'
                               ;; in init.el, kept in lockstep so the
                               ;; verification list matches the load
                               ;; order. nothing in here depends on
                               ;; anything else in here, so the order
                               ;; itself is cosmetic.
                               "-l" #$userland-files-el
                               "-l" #$userland-shell-el
                               "-l" #$userland-git-el
                               "-l" #$userland-web-el
                               "-l" #$userland-mail-el
                               "-l" #$userland-chat-el
                               "-l" #$userland-notes-el
                               "-l" #$userland-pdf-el
                               "-l" #$userland-init-el
                               ;; phase 6 buffers. lazy-loaded entry
                               ;; points; touching any of these via M-x
                               ;; spins up the per-buffer timer/source.
                               ;; loading the file itself is cheap, no
                               ;; side effects beyond defun + provide.
                               "-l" #$processes-buffer-el
                               "-l" #$journal-buffer-el
                               "-l" #$services-buffer-el
                               "-l" #$disks-buffer-el
                               "-l" #$packages-buffer-el))))

(operating-system
  (host-name "emacs-os")
  (timezone "Europe/Madrid")
  (locale "en_US.utf8")

  (kernel linux-libre)

  ;; no init= here on purpose. guix's initrd ignores the kernel
  ;; cmdline init= and execs gnu.load=...boot, so any value we put
  ;; here would be a lie. the real handover happens in
  ;; emacs-init-boot-service above. linux uses the LAST console= as
  ;; the primary /dev/console; serial last so /boot-vm captures PID 1
  ;; output over -serial mon:stdio. on real hardware we will flip
  ;; these so tty1 wins.
  ;;
  ;; phase 5c update: nomodeset and vga=0x317 are gone. with virtio_gpu
  ;; loaded from initrd-modules, we WANT KMS up so Xorg's modesetting
  ;; driver has a /dev/dri/card0 to bind. vesafb is no longer the
  ;; rendering surface; virtio-gpu's drm fbcon is.
  (kernel-arguments
   (cons* "console=tty1"
          "console=ttyS0,115200"
          %default-kernel-arguments))

  ;; phase 5c: load virtio_gpu in the initrd so /dev/dri/card0 exists
  ;; before pid1 spawns Xorg. virtio_pci is needed because virtio_gpu
  ;; rides PCI; drm is pulled in transitively but listing it explicitly
  ;; documents intent. without these, modesetting would log
  ;; "no devices detected" and Xorg would die at AddScreen.
  (initrd-modules (cons* "virtio_pci"
                         "virtio_gpu"
                         "drm"
                         %base-initrd-modules))

  (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets '("/dev/sda"))))

  (file-systems
   (cons (file-system
           (mount-point "/")
           (device "/dev/sda1")
           (type "ext4"))
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
  ;;   xf86-input-libinput input driver. opens /dev/input/event* with
  ;;                       libinput. needs AutoAddDevices=true in
  ;;                       xorg.conf because we have no udev to push
  ;;                       hotplug events.
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
  ;;                                emacs-init/wm/fonts.el default family
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
                   xf86-input-libinput
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
          %base-services))

  (name-service-switch %mdns-host-lookup-nss))
