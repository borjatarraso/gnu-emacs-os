;;; user-init.el --- per-user emacs userland for GEOS -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; runs in the per-user emacs, NOT the supervisor.  this is the v0.6
;; entry point for user-side userland: the per-user emacs loads its
;; own panic, its own use-package shim, and the userland/*.el chain
;; (dired/eshell/magit/eww/notmuch/erc/org/pdf-tools).  the supervisor
;; no longer -l's any of these.  the boundary has actually moved.
;;
;; what is NOT moved yet (deferred to v0.6 item 1.3, the exwm display
;; handover): exwm-config.el, multimon.el, fonts.el, input.el.  the
;; supervisor still runs exwm-enable at boot, and the per-user emacs
;; rides as an X client on the supervisor's display.  the audio
;; userland (userland-audio.el) also stays supervisor-side because
;; the *audio* buffer in emacs-init/buffers/audio.el requires it.
;;
;; loaded by session--child-argv via `-l /etc/geos/user-init.el',
;; the path extra-special-file'd in system.scm.  loads BEFORE any
;; optional per-user /var/emacs/users/NAME/init.el so the system
;; command set is available to user-side init code that might want
;; to rebind it.
;;
;; security posture: this file runs as the logged-in user, not root.
;; the per-user emacs has the privileges of that user; nothing here
;; talks back to the supervisor over a wire protocol (the supervisor
;; observes child exit via the /proc poller, no side channel).  if
;; that changes (v0.6 item 3, the RPC channel), the new wire protocol
;; is the load-bearing security boundary.

(defun user-init--trace (msg)
  "Best-effort write MSG to /dev/console.
mirrors the trace pattern from exwm-config.el so user-side boot
events show up on the serial log the smoke-test reads.  errors
swallowed: tracing must never be the failure mode."
  (condition-case _
      (let ((write-region-inhibit-fsync t))
        (write-region (format "user-init: %s\n" msg)
                      nil "/dev/console" 'append 'nomsg))
    (error nil)))

(defun user-init--system-profile ()
  "Return the system profile dir from /proc/cmdline gnu.system=PATH.
duplicates exwm-config--system-profile because the per-user emacs
loads this file before any wm code.  v0.6 item 1.3 lifts exwm-
config user-side and the two copies converge.  returns nil if the
marker is absent or /proc/cmdline is unreadable."
  (condition-case _
      (with-temp-buffer
        (insert-file-contents "/proc/cmdline")
        (goto-char (point-min))
        (when (re-search-forward "gnu\\.system=\\([^ \n\t]+\\)" nil t)
          (concat (match-string 1) "/profile")))
    (error nil)))

(defun user-init--push-system-site-lisp ()
  "Load the system profile's subdirs.el so site-lisp packages resolve.
the per-user emacs starts with -Q so the system profile's
share/emacs/site-lisp/ is NOT on load-path.  the userland/*.el
files want use-package magit / notmuch / pdf-tools, which fail
without site-lisp.  parse /proc/cmdline for gnu.system=, load its
subdirs.el, and load-path picks up every site-lisp subdir.
returns the path loaded, nil on any degraded branch.  errors
caught and routed to panic-handle (which by this point in the
chain has been loaded by `user-init--load-core')."
  (condition-case err
      (let* ((profile (user-init--system-profile))
             (subdirs (and profile
                           (concat profile
                                   "/share/emacs/site-lisp/subdirs.el"))))
        (cond
         ((null profile)
          (user-init--trace "no gnu.system= in /proc/cmdline, skipping")
          nil)
         ((not (file-readable-p subdirs))
          (user-init--trace (format "%s missing, skipping" subdirs))
          nil)
         (t
          (load subdirs nil 'nomessage)
          (user-init--trace (format "loaded %s, load-path=%d entries"
                                    subdirs (length load-path)))
          subdirs)))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'user-init--push-system-site-lisp)
       (user-init--trace (format "site-lisp push failed: %S" err)))
     nil)))

(defconst user-init--chain
  '("/etc/geos/core/panic.el"
    "/etc/geos/core/use-package-shim.el"
    "/etc/geos/user/userland/files.el"
    "/etc/geos/user/userland/shell.el"
    "/etc/geos/user/userland/uname.el"
    "/etc/geos/user/userland/git.el"
    "/etc/geos/user/userland/web.el"
    "/etc/geos/user/userland/mail.el"
    "/etc/geos/user/userland/chat.el"
    "/etc/geos/user/userland/notes.el"
    "/etc/geos/user/userland/pdf.el"
    "/etc/geos/user/userland/audio.el"
    "/etc/geos/user/userland/init.el")
  "Ordered list of files the per-user emacs loads.
each path is laid down by extra-special-file in guix-system/
system.scm and resolves to a store entry.  panic.el FIRST so the
rest of the chain can panic-handle; use-package-shim SECOND
because every userland/*.el wraps its package in use-package
with the :comment keyword the shim adds; then the userland files
in the same order the supervisor used to -l them (shell before
uname because uname adds an eshell/uname override).  the verifier
init.el is LAST and walks (featurep ...) for each userland
module.

NOT in the chain (v0.6 item 1.3 will move them):
  exwm-config.el, multimon.el, fonts.el, input.el        wm side
audio.el IS in the chain so the verifier sees it user-side; it
is also -l'd supervisor-side because buffers/audio.el requires
it there.  the file's load is idempotent (use-package + a
defconst); double-load is harmless.

if site-lisp expansion fails or panic itself fails to load, the
remaining entries still try.  loud failure beats silent partial
load: every miss writes a `user-init: load X failed' line to
/dev/console.")

(defun user-init--load (path)
  "Load PATH under condition-case, route errors through panic-handle.
returns t on success, nil on failure.  failure logs to /dev/console
via user-init--trace so a degraded boot is visible on the serial
log even when panic-handle itself errored.  uses absolute-path load
(not require) because the chain entries live at fixed extra-
special-file paths, not on load-path."
  (condition-case err
      (progn
        (load path nil 'nomessage)
        (user-init--trace (format "loaded %s" path))
        t)
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err (list 'user-init--load path))
       (user-init--trace (format "load %s failed before panic: %S"
                                 path err)))
     nil)))

(defun user-init--run-chain ()
  "Walk `user-init--chain' and load each entry.
site-lisp gets pushed between panic.el and use-package-shim.el
because the shim's (require 'use-package) needs the in-tree
copy on emacs 30 (which works without site-lisp), but the
userland/*.el files that follow need magit/notmuch/pdf-tools,
which DO need site-lisp.  pushing once after panic is enough:
load-path additions are durable for the rest of the session."
  (user-init--trace (format "chain start, %d entries"
                            (length user-init--chain)))
  (dolist (path user-init--chain)
    (user-init--load path)
    ;; site-lisp gets pushed right after panic.el loads, so the
    ;; subsequent loads (including use-package-shim) have panic-
    ;; handle available AND load-path expanded for any userland
    ;; package that doesn't ship in-tree.
    (when (string-suffix-p "/panic.el" path)
      (user-init--push-system-site-lisp)))
  (user-init--trace "chain done"))

(defun geos-logout ()
  "End the current GEOS per-user emacs session.
prompts for confirmation, then calls `kill-emacs' with status 0.
the supervisor's child-exit poller (see session.el's
`session--poll-children') will observe the dead pid within one
poll interval (default 3s) and re-present the *login* buffer.

no side channel to the supervisor: the only signal is `kill-emacs'
itself, which the poller picks up via /proc/<pid> disappearance.
this keeps the trust boundary clean: the per-user emacs cannot
make the supervisor do anything it would not have done on its
own, including immediate teardown.  the latency cost (one poll
tick) is paid for that.

binding: C-c e q, matching the project-wide C-c e <something>
convention for system-supplied commands."
  (interactive)
  (when (yes-or-no-p "Log out of GEOS? ")
    (kill-emacs 0)))

(global-set-key (kbd "C-c e q") #'geos-logout)

(user-init--run-chain)

(provide 'geos-user-init)
;;; user-init.el ends here
