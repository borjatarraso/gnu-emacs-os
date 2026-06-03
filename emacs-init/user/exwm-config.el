;;; exwm-config.el --- phase 5a, bring up exwm and one x11 client -*- lexical-binding: t -*-
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
(require 'cl-lib)  ; cl-incf in the B1 bounded grow loop

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
swallowed: tracing is a debug aid, never the failure mode.
write-region-inhibit-fsync is defensive: a no-op for character
devices today but cheap to set in case a future emacs flushes ttys."
  (condition-case _
      (let ((write-region-inhibit-fsync t))
        (write-region (format "exwm-trace: %s\n" msg)
                      nil "/dev/console" 'append 'nomsg))
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

;; v0.6 sub-feature (B): per-user emacs windows arrive with
;; WM_CLASS first field "geos-user-NAME" because session--child-argv
;; passes --name geos-user-NAME on the per-user emacs command line.
;; exwm exposes that as `exwm-instance-name' inside the X buffer.
;; route each distinct NAME to its own workspace so the supervisor's
;; root view (workspace 0) stays uncluttered and switching users is
;; one `s-N' away.
;;
;; design note: i deliberately do NOT bump the default
;; `exwm-workspace-number' (still 4 from phase 5a). instead the
;; allocator calls `exwm-workspace-add' on demand to grow past the
;; current count. rationale: setting a large default workspace count
;; up front allocates frames i may never use, and changing
;; exwm-workspace-number after exwm-enable is the part of the api
;; the docstring tells you not to touch. grow-on-first-sighting is
;; the cheaper move and matches how a typical session unfolds (one
;; user logs in, gets workspace 1, second user shows up later).
(defvar exwm-config--user-workspace (make-hash-table :test 'equal)
  "Map NAME (string) to workspace index (integer).
Workspace 0 is reserved for the supervisor emacs that owns the
root window. Per-user emacses with `exwm-instance-name' matching
`geos-user-NAME' get workspaces 1, 2, 3, ... in order of first
appearance. Populated lazily by
`exwm-config--user-workspace-for'.")

(defvar exwm-config--user-workspace-next 1
  "Next workspace index to hand out to a new per-user emacs.
Starts at 1 because 0 is the supervisor. Bumped by
`exwm-config--user-workspace-for' on every fresh allocation. Not
recycled on user logout: if borja logs in, gets ws 1, logs out,
and alice logs in, alice gets ws 2. Cheap to leave a hole, and
sticky indices keep muscle-memory of `s-1 = borja' intact across
a re-login.")

(defun exwm-config--user-workspace-for (name)
  "Return the workspace index assigned to NAME, allocating if needed.
NAME is the user shortname captured from `geos-user-NAME' in
`exwm-instance-name'. If NAME has been seen before AND the cached
index is still in range of `exwm-workspace--list', return the
cached slot. If the cache is stale (workspace deleted out from
under us, B2 skeptic 2026-05-11), fall through to the allocator
which will re-grow the pool under the same slot, preserving
muscle-memory of `s-N = NAME'. Returns nil when the live workspace
list is not introspectable (W3, fall-back: skip the move and let
exwm leave the window wherever it landed) or when the bounded
grow loop (B1, skeptic 2026-05-11) fails to advance after 8
tries (broken display, RANDR-less env, future emacs-exwm cap).
The caller MUST tolerate nil."
  (condition-case err
      (if (not (boundp 'exwm-workspace--list))
          ;; W3 explicit degradation: no live list to validate against,
          ;; so we cannot honestly allocate. Caller skips the move.
          nil
        (let* ((cached (gethash name exwm-config--user-workspace))
               (live-len (length exwm-workspace--list)))
          (if (and cached (< cached live-len))
              cached
            (let ((idx (or cached exwm-config--user-workspace-next)))
              ;; B1: bounded grow loop. exwm-workspace-add SHOULD append
              ;; one workspace per call, but a future emacs-exwm (or a
              ;; RANDR-less display, or an internal cap) might return
              ;; without growing the list. an unbounded while inside
              ;; exwm-manage-finish-hook freezes PID 1's main thread.
              ;; bail after 8 no-progress iterations and return nil.
              (when (fboundp 'exwm-workspace-add)
                (let ((tries 0)
                      (last-len live-len))
                  (while (and (>= idx (length exwm-workspace--list))
                              (< tries 8))
                    (exwm-workspace-add)
                    (when (= (length exwm-workspace--list) last-len)
                      (cl-incf tries))
                    (setq last-len (length exwm-workspace--list)))))
              (if (< idx (length exwm-workspace--list))
                  (progn
                    (puthash name idx exwm-config--user-workspace)
                    ;; only advance the next-pointer when we minted a
                    ;; brand-new slot. a cache-rebuild reuses idx and
                    ;; must not nudge the counter forward.
                    (when (or (null cached) (>= idx
                                                exwm-config--user-workspace-next))
                      (setq exwm-config--user-workspace-next (1+ idx)))
                    idx)
                ;; grow loop bailed, idx still OOB. caller skips.
                nil)))))
    (error
     (panic-handle err (cons 'exwm-config--user-workspace-for name))
     nil)))

(defun exwm-config--maybe-route-user-window ()
  "Route a freshly managed per-user emacs window to its workspace.
Hook body for `exwm-manage-finish-hook'. Reads the buffer-local
`exwm-instance-name' that exwm sets on the managed buffer before
running this hook. On a match against `geos-user-NAME', looks up
or allocates a workspace index for NAME and moves the window
there via `exwm-workspace-move-window'. No-op on no match (so a
plain xterm or a non-user-tagged emacs frame stays where exwm
put it). All errors are caught and routed to panic-handle: a
wedge in routing must not crash exwm's manage path, which would
leave the window unmanaged and possibly the keyboard grabbed.

The match-data is saved (W4 skeptic 2026-05-11) so we do not
clobber whatever other entries on the same hook were inspecting.
The capture group is tightened (N4) to the same character class
`passwd-add-user' accepts for usernames: cache keys are read from
the X protocol, which the C-side username validator never sees,
so we re-validate on the elisp side.

When the captured NAME has no row in session.el's registry, we
leave an audit breadcrumb via `panic-handle' (W1 skeptic
2026-05-11) and STILL route the window: the breadcrumb is for
forensics on a spoofed instance-name, not enforcement. Gated on
`fboundp' so this file loads on a pre-v0.5 image with no
session.el present."
  (condition-case err
      (when (and (boundp 'exwm-instance-name)
                 (stringp exwm-instance-name))
        (save-match-data
          (when (string-match
                 "\\`geos-user-\\([a-zA-Z0-9_-]+\\)\\'"
                 exwm-instance-name)
            (let* ((name (match-string 1 exwm-instance-name))
                   ;; v0.6 item 6.3: session.el is now authoritative
                   ;; on workspace allocation.  `session-spawn' picks
                   ;; the index BEFORE pid1-spawn-as-uid and stamps
                   ;; the record; here we just read it back.  the
                   ;; legacy local allocator (`exwm-config--user-
                   ;; workspace-for') remains the fallback for an
                   ;; unregistered window: a spoofed instance-name
                   ;; with no matching session record still gets
                   ;; routed, just without the supervisor's blessing.
                   ;; the breadcrumb on the unknown-user path stays.
                   (session-idx
                    (and (fboundp 'session-workspace-for-name)
                         (session-workspace-for-name name)))
                   (idx (or session-idx
                            (exwm-config--user-workspace-for name))))
              ;; W1 audit: log unknown-user breadcrumbs but do not
              ;; block the move. session-get returns nil for an
              ;; unregistered name; an attacker who guesses a valid
              ;; username still ends up routed, just with a trace.
              (when (fboundp 'session-get)
                (unless (session-get name)
                  (panic-handle (list 'exwm-route-unknown-user name)
                                'exwm-config--maybe-route-user-window)))
              ;; if session.el picked the index, make sure the EXWM
              ;; pool has actually grown to cover it.  the supervisor
              ;; allocation is symbolic; the live workspace list still
              ;; has to exist before `exwm-workspace-move-window'.
              ;; reuse the bounded grow loop from the legacy allocator
              ;; by piping the index through it as a cache hint: the
              ;; function returns the same index if already cached or
              ;; in range, otherwise grows the pool.
              (when (and session-idx
                         (boundp 'exwm-workspace--list)
                         (>= session-idx (length exwm-workspace--list)))
                (puthash name session-idx exwm-config--user-workspace)
                (exwm-config--user-workspace-for name))
              (when (and idx (fboundp 'exwm-workspace-move-window))
                ;; pass exwm--id explicitly. without it,
                ;; exwm-workspace-move-window resolves the "current
                ;; window" from the selected emacs window, not the
                ;; managed X buffer. inside
                ;; exwm-manage-finish-hook the selected window is
                ;; still the supervisor's, so the move silently
                ;; relocated the wrong window and left the new X
                ;; buffer on workspace 0. captured here on
                ;; 2026-05-11 after a probe showed exwm--frame
                ;; unchanged post-move; with the id arg the buffer
                ;; lands on the right ws.
                (exwm-workspace-move-window idx exwm--id)
                ;; v0.6 item 6.1: tell session.el where this user
                ;; actually landed so the supervisor knows the
                ;; workspace occupancy.  v0.6 item 6.3 made session.el
                ;; the primary source; only stamp here when the index
                ;; came from the local fallback allocator, so we still
                ;; persist a record for a recovery path that had no
                ;; pre-spawn workspace stamp.
                (when (and (null session-idx)
                           (fboundp 'session-record-workspace))
                  (condition-case err
                      (session-record-workspace name idx)
                    (error
                     (panic-handle
                      err
                      'exwm-config--maybe-route-user-window-record))))
                (exwm-config--trace
                 (format "routed user=%s instance=%s -> ws %d"
                         name exwm-instance-name idx)))))))
    (error
     (panic-handle err 'exwm-config--maybe-route-user-window))))

;; the hook attachment lives down inside the (require 'exwm) branch
;; below (search "exwm-manage-finish-hook"). an earlier draft wired it
;; here at top level under a (boundp ...) guard, but exwm-config.el is
;; loaded BEFORE (require 'exwm) runs, so the boundp check returned nil
;; and the hook was silently never installed. caught 2026-05-12 after
;; a fresh-boot test showed `geos-user-tester' windows landing on
;; workspace 0 with no routing trace.

;; (B-fullscreen-hang, 2026-05-10) earlier draft mutated
;; initial-frame-alist and default-frame-alist with (fullscreen . fullboth)
;; right here, BEFORE (exwm-enable). that hangs emacs hard on a real
;; Xorg with no WM yet: emacs sends a NetWM _NET_WM_STATE_FULLSCREEN
;; request and the X server has nobody to forward the hint to, so the
;; frame parameter machinery loops waiting for the round-trip.
;; symptom: serial log freezes after "should-enable=t" and userland
;; never reaches boot-marker. fix: defer fullscreen until exwm-enable
;; returns and exwm IS the WM, then call set-frame-parameter on the
;; live frame (no alist mutation needed since exwm reflows everything
;; once it grabs root). the cosmetic border on first boot is acceptable
;; for the seconds it takes exwm to take over.
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
        ;; install the per-user routing hook NOW, after (require 'exwm)
        ;; has defined `exwm-manage-finish-hook' but before (exwm-enable)
        ;; starts managing windows. add-hook is idempotent on eq function
        ;; symbols so re-running this branch (e.g. on a manual reload)
        ;; does not stack duplicates.
        (add-hook 'exwm-manage-finish-hook
                  #'exwm-config--maybe-route-user-window)
        (exwm-config--trace "calling exwm-enable")
        ;; finally hand the keyboard and root window over to exwm.
        ;; this is the line that makes emacs into a window manager.
        (exwm-enable)
        (exwm-config--trace "exwm-enable returned")
        ;; deferred fullscreen pin: now that exwm is the WM, the
        ;; _NET_WM_STATE_FULLSCREEN hint has someone to forward it to.
        ;; apply via set-frame-parameter to the live frame so the
        ;; cosmetic border disappears once exwm processes its first
        ;; event. errors swallowed: this is cosmetic, never load-bearing.
        (when (boundp 'exwm-init-hook)
          (add-hook
           'exwm-init-hook
           (lambda ()
             (condition-case _
                 (dolist (f (frame-list))
                   (when (frame-parameter f 'display)
                     (set-frame-parameter f 'fullscreen 'fullboth)))
               (error nil)))))
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
This is the s-& launcher. CMD is the program plus optional args.
We use `split-string-and-unquote' so quoted args (like
\"xterm -e 'echo hello world'\") tokenize correctly: a plain
whitespace split would otherwise hand `start-process' the
fragments [\"echo\" \"hello\" \"world'\"] and the user would see
the shell-quote-removal-or-grouping behavior they expected drop
on the floor.  Errors route through panic-handle so a bogus
binary name does not kill the wm."
  (interactive (list (read-string "Run: ")))
  (condition-case err
      (let* ((parts (condition-case _
                        (split-string-and-unquote cmd)
                      (error (split-string cmd "[ \t]+" t))))
             (prog (car parts))
             (args (cdr parts)))
        (when prog
          (apply #'start-process prog nil prog args)
          (message "exwm-config: launched %s" cmd)))
    (error (panic-handle err (cons 'exwm-config--launch cmd)))))

(provide 'exwm-config)
;;; exwm-config.el ends here
