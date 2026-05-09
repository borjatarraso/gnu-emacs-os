;;; exwm-config.el --- phase 5a, bring up exwm and one x11 client -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; phase 5a goal: emacs comes up as an x client, exwm takes over the
;; root window, i can M-x and start-process xterm and see a window.
;; nothing fancier. multi-monitor, fonts and input methods are 5c.
;;
;; ordering rules i learned the hard way (1am notes):
;;   - (exwm-enable) HAS to run before the first x frame is created.
;;     in our boot path emacs is launched with DISPLAY=:0 already in
;;     its env (pid1 fork-execs Xorg first, see emacs-init.c), so the
;;     initial frame IS an x frame. that means we must require exwm
;;     and call (exwm-enable) at file load time, not in a hook.
;;   - emacs-init -l's our files in order. exwm-config.el is the LAST
;;     -l in the boot gexp so panic / network are already up.
;;   - every error path here goes through panic-handle. an uncaught
;;     error in a window-manager handler means PID 1's userland is
;;     dead and the supervisor respawns emacs in a tight loop. that
;;     would be bad.

(require 'panic)

;; phase 5a debug crutch: scribble every load-time event to /dev/console
;; so the serial log on -serial mon:stdio captures it. removed once the
;; buffer-bridge supervise.el lands a proper status pane.
;;
;; (B8, skeptic 2026-05-06) used to also write to /dev/tty1 via two
;; with-temp-buffer + write-region calls. single-thread emacs blocks
;; on either device hanging, and tty1 has hung on us once already
;; under EFI fb pressure. /dev/console is enough: kernel cmdline
;; aliases console= to whichever tty/serial is live, and the QEMU GTK
;; window mirrors tty1's framebuffer console anyway. wrap the write
;; in condition-case so a missing or unwriteable device is silent.
(defun exwm-config--trace (msg)
  "Best-effort write MSG to /dev/console.
Used to surface boot-time wm progress on the serial stdio. Errors
swallowed: tracing is a debug aid, never the failure mode."
  (condition-case _
      (write-region (format "exwm-trace: %s\n" msg)
                    nil "/dev/console" 'append 'nomsg)
    (error nil)))

(exwm-config--trace "loading")

;; cheap guard: if there is no DISPLAY in the env, we are running on
;; the dev host or in tty mode. do not even pretend to load exwm.
;; this also makes (load "exwm-config.el") safe in a normal emacs
;; without bricking it.
(defvar exwm-config--should-enable
  (and (getenv "DISPLAY") t)
  "Non-nil when this emacs has a DISPLAY and should bring exwm up.
Set at load time so reloading the file does not flip the answer
mid-session if the env mutates.")

(exwm-config--trace
 (format "should-enable=%s display=%s"
         exwm-config--should-enable (getenv "DISPLAY")))

;; we boot emacs with -Q which means --no-site-file is set, which means
;; the system profile's subdirs.el never runs and `load-path' does not
;; include exwm / xelb / compat (every elisp dep our emacs-exwm needs).
;; instead of switching to -q (which would also load any stray
;; /etc/emacs/site-start.el and is a bigger blast radius than I want at
;; boot), I find the system profile by parsing /proc/cmdline for
;; gnu.system=PATH (set by the guix initrd), then load that profile's
;; subdirs.el. that file is laid down by guix's profile-derivation
;; build step and contains a single `normal-top-level-add-to-load-path'
;; call listing every site-lisp subdir, so it is the canonical answer
;; to "what should load-path be on this system".
;;
;; the alternative was to hardcode emacs-exwm/emacs-xelb/emacs-compat
;; versioned subdirs in system.scm via file-append, but that breaks on
;; every package upgrade. parsing /proc/cmdline is uglier but stable.
(defun exwm-config--system-profile ()
  "Return the system profile dir from /proc/cmdline gnu.system=PATH.
Returns nil if /proc/cmdline is unreadable or the marker is absent.
Stripped of any junk after the path: kernel cmdline tokens are
whitespace separated."
  (condition-case _
      (with-temp-buffer
        (insert-file-contents "/proc/cmdline")
        (goto-char (point-min))
        (when (re-search-forward "gnu\\.system=\\([^ \n\t]+\\)" nil t)
          (concat (match-string 1) "/profile")))
    (error nil)))

(defun exwm-config--push-system-site-lisp ()
  "Load the system profile's subdirs.el so exwm shows up on load-path.
Idempotent: subdirs.el's `normal-top-level-add-to-load-path' is a
no-op for entries already present. Safe under panic-handle because a
malformed profile only logs and continues. Returns the path loaded,
or nil when there was nothing to load."
  (condition-case err
      (let* ((profile (exwm-config--system-profile))
             (subdirs (and profile
                           (concat profile
                                   "/share/emacs/site-lisp/subdirs.el"))))
        (cond
         ((null profile)
          (exwm-config--trace "no gnu.system= in /proc/cmdline, skipping")
          nil)
         ((not (file-readable-p subdirs))
          (exwm-config--trace (format "%s missing, skipping" subdirs))
          nil)
         (t
          (load subdirs nil 'nomessage)
          (exwm-config--trace (format "loaded %s, load-path=%d entries"
                                      subdirs (length load-path)))
          subdirs)))
    (error
     (panic-handle err 'exwm-config--push-system-site-lisp)
     nil)))

;; (B3, skeptic 2026-05-06) earlier draft built s-0..s-3 as anonymous
;; lambdas and stuffed them into exwm-input-global-keys. some emacs-exwm
;; releases internally do (symbol-function (cdr binding)) on those
;; entries, and a bare lambda has no symbol-function, raising
;; void-function and tearing down input handling. four named defuns
;; sidestep the version-skew entirely. each routes errors through
;; panic-handle so a stuck workspace switch does not kill the wm.
(defun exwm-config-switch-workspace-0 ()
  "Jump to workspace 0. Bound to s-0."
  (interactive)
  (condition-case err
      (exwm-workspace-switch-create 0)
    (error (panic-handle err '(exwm-workspace-switch . 0)))))

(defun exwm-config-switch-workspace-1 ()
  "Jump to workspace 1. Bound to s-1."
  (interactive)
  (condition-case err
      (exwm-workspace-switch-create 1)
    (error (panic-handle err '(exwm-workspace-switch . 1)))))

(defun exwm-config-switch-workspace-2 ()
  "Jump to workspace 2. Bound to s-2."
  (interactive)
  (condition-case err
      (exwm-workspace-switch-create 2)
    (error (panic-handle err '(exwm-workspace-switch . 2)))))

(defun exwm-config-switch-workspace-3 ()
  "Jump to workspace 3. Bound to s-3."
  (interactive)
  (condition-case err
      (exwm-workspace-switch-create 3)
    (error (panic-handle err '(exwm-workspace-switch . 3)))))

(when exwm-config--should-enable
  (exwm-config--push-system-site-lisp)
  ;; use-package isn't bootstrapped by phase 5a (no package.el on the
  ;; image yet), but the project rule says "every package via
  ;; use-package with a :comment". emacs-exwm is added to the system
  ;; profile in guix-system/system.scm, so it is on `load-path' as
  ;; soon as the push above runs. require it under a condition-case so
  ;; a missing .el is degraded mode, not a panic.
  (condition-case err
      (progn
        (exwm-config--trace "requiring exwm")
        ;; cheap version of use-package: require + configure. when
        ;; package.el lands in 5b we will swap this for a real
        ;; (use-package exwm :comment "phase 5a, x window manager") block.
        (require 'exwm)
        (exwm-config--trace "exwm required, configuring")
        ;; four virtual workspaces is plenty for a smoke test, and
        ;; matches the usual exwm tutorial so muscle memory works.
        (setq exwm-workspace-number 4)
        ;; global keys. these have to be set BEFORE exwm-enable; once
        ;; exwm grabs the keyboard, mutating exwm-input-global-keys
        ;; needs a (exwm-input--update-global-prefix-keys) which i'd
        ;; rather not depend on at this stage.
        ;;
        ;; bindings:
        ;;   s-r           reset to line-mode (recover from a runaway
        ;;                 char-mode app eating C-g).
        ;;   s-w           switch workspace (prompts for index).
        ;;   s-0..s-3      jump to workspace N directly.
        ;;   s-&           launcher: read a program name, start-process
        ;;                 it. NO shell-command. /no-shell-check would
        ;;                 fail otherwise.
        (setq exwm-input-global-keys
              `(([?\s-r] . exwm-reset)
                ([?\s-w] . exwm-workspace-switch)
                (,(kbd "s-0") . exwm-config-switch-workspace-0)
                (,(kbd "s-1") . exwm-config-switch-workspace-1)
                (,(kbd "s-2") . exwm-config-switch-workspace-2)
                (,(kbd "s-3") . exwm-config-switch-workspace-3)
                ([?\s-&] . exwm-config--launch)))
        (exwm-config--trace "calling exwm-enable")
        ;; finally hand the keyboard and root window over to exwm.
        ;; this is the line that makes emacs into a window manager.
        (exwm-enable)
        (exwm-config--trace "exwm-enable returned")
        ;; phase 5c: bring up multi-monitor, fonts, input methods.
        ;; ordering matters here. exwm-randr-enable MUST come before
        ;; the first multimon-rescan because it installs the X event
        ;; mask we need to actually see RANDR notifications. fonts and
        ;; input depend on exwm only insofar as they want a graphical
        ;; frame to apply to (font-spec on a tty frame is a no-op).
        ;; every step is a condition-case so a phase-5c regression
        ;; does not undo the working phase-5a smoke path.
        (condition-case err
            (progn
              (require 'multimon)
              (when (fboundp 'exwm-randr-enable)
                (exwm-randr-enable))
              (when (boundp 'exwm-randr-screen-change-hook)
                (add-hook 'exwm-randr-screen-change-hook
                          #'multimon-rescan))
              (multimon-rescan))
          (error (panic-handle err 'exwm-config-multimon-init)))
        (condition-case err
            (progn
              (require 'fonts)
              (fonts-apply))
          (error (panic-handle err 'exwm-config-fonts-init)))
        (condition-case err
            (progn
              (require 'input)
              (input-apply))
          (error (panic-handle err 'exwm-config-input-init)))
        ;; smoke-test bridge: phase 5a runs against Xvfb, which
        ;; renders to memory only, so the QEMU GTK display still
        ;; shows tty1's kernel-framebuffer console. write status via
        ;; the trace helper (console-only since B8) so /boot-vm
        ;; captures it on stdio. dropped once 5c renders to a real
        ;; display.
        (condition-case err
            (exwm-config--trace
             (format "exwm: enabled, ws=%d display=%s xterm=%s"
                     exwm-workspace-number
                     (getenv "DISPLAY")
                     (executable-find "xterm")))
          (error (panic-handle err 'exwm-config-console-status)))
        ;; phase 5a end-condition canary: launch xterm right away so
        ;; the boot completes with one X11 client running. we are
        ;; allowed to do this without a user keystroke because the
        ;; phase 5a deliverable is "EXWM up + one X11 app". errors
        ;; here go through panic-handle, never bare error.
        ;;
        ;; (B4, skeptic 2026-05-06) attach a sentinel so a fast-failing
        ;; xterm (X up but font missing, or DISPLAY unreachable, or
        ;; xterm itself segfaults) lands in *panic* with the event
        ;; string. without this we silently see "started, pid=N" and
        ;; never know phase 5a regressed. "finished" matches the
        ;; clean-exit event string emacs uses ("finished\n"); anything
        ;; else (signal, exit nonzero) routes through panic-handle.
        (condition-case err
            (let ((xterm (executable-find "xterm")))
              (if xterm
                  (let ((proc (start-process "xterm-canary" nil xterm)))
                    (set-process-sentinel
                     proc
                     (lambda (_p event)
                       (unless (string-match-p "finished" event)
                         (if (fboundp 'panic-handle)
                             (panic-handle
                              (list 'xterm-canary-died event)
                              'exwm-config-launch-xterm)
                           (message
                            "exwm-config: xterm-canary died: %s" event)))))
                    (exwm-config--trace
                     (format "xterm-canary started, pid=%s status=%s"
                             (process-id proc) (process-status proc))))
                (exwm-config--trace "xterm not on PATH, canary skipped")))
          (error (panic-handle err 'exwm-config-xterm-canary)))
        (message "exwm-config: enabled, %d workspaces, DISPLAY=%s"
                 exwm-workspace-number (getenv "DISPLAY")))
    ;; (B9, skeptic 2026-05-06) same hazard core/network.el documents:
    ;; if panic.el failed to load, panic-handle is unbound, and calling
    ;; it here raises void-function which escapes the handler and takes
    ;; PID 1's userland down. fboundp gate degrades to a message instead.
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'exwm-config-load)
       (message "exwm-config: failed before panic-handle existed: %S"
                err)))))

(defun exwm-config--launch (cmd)
  "Read CMD and start-process it detached. No shell wrapper.
This is the s-& launcher. CMD is the program plus optional args
separated by whitespace. We split on whitespace once, no quoting
fanciness, because phase 5a only needs to launch xterm. Errors
route through panic-handle so a bogus binary name does not kill
the wm."
  (interactive (list (read-string "Run: ")))
  (condition-case err
      (let* ((parts (split-string cmd "[ \t]+" t))
             (prog (car parts))
             (args (cdr parts)))
        (when prog
          (apply #'start-process prog nil prog args)
          (message "exwm-config: launched %s" cmd)))
    (error (panic-handle err (cons 'exwm-config--launch cmd)))))

(provide 'exwm-config)
;;; exwm-config.el ends here
