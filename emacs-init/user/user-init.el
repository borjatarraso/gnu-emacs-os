;;; user-init.el --- per-user emacs userland for GEOS -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; runs in the per-user emacs, NOT the supervisor.  this is the v0.6
;; entry point for user-side userland: the per-user emacs loads its
;; own panic, its own use-package shim, and the userland/*.el chain
;; (dired/eshell/magit/eww/notmuch/erc/org/pdf-tools).  the supervisor
;; no longer -l's any of these.  the boundary has actually moved.
;;
;; v0.7 item 1.2: the EXWM stack (exwm-config / multimon / fonts /
;; input) moved from the supervisor's -l chain into this file's
;; user-init--chain.  the supervisor no longer runs exwm-enable; the
;; per-user emacs does, becoming the X window manager for the duration
;; of its session.  the audio userland (userland-audio.el) still
;; double-loads because the *audio* buffer in emacs-init/buffers/audio.el
;; requires it supervisor-side.  the supervisor-side X frame for *login*
;; is still drawn on :0 but unmanaged; slice 1.3 closes that connection
;; across a session via x-display-release.
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
    ;; step 2 of the hurd port: kernel-portability seam.  must come
    ;; after panic.el (port.el requires it) and before anything that
    ;; branches on `geos-kernel'.  processes-buffer.el later in the
    ;; chain is the current user-side consumer; future user buffers
    ;; with kernel-aware data sources will pick up the predicate
    ;; here without re-ordering the chain.
    "/etc/geos/core/port.el"
    "/etc/geos/core/rpc-client.el"
    "/etc/geos/core/use-package-shim.el"
    ;; v0.7 item 1.2: the EXWM stack.  multimon / fonts / input come
    ;; first so exwm-config's `(require 'multimon)` etc resolve
    ;; without a fresh load; exwm-config.el is the last of the four
    ;; and is the file that actually calls (exwm-enable), making this
    ;; emacs the X window manager.
    "/etc/geos/user/multimon.el"
    "/etc/geos/user/fonts.el"
    "/etc/geos/user/input.el"
    "/etc/geos/user/exwm-config.el"
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
    ;; v0.7 item 3.1: the *audio* buffer follows the userland chain.
    ;; buffers/audio.el (require)s userland-audio at load time, so it
    ;; MUST come after userland/audio.el.
    "/etc/geos/user/audio-buffer.el"
    ;; v0.7 item 4.2: the user-side *services* view.  fetches the
    ;; supervisor's registry over the v0.6 RPC channel; MUST come
    ;; after rpc-client (which is loaded at the head of the chain).
    "/etc/geos/user/userland/services-client.el"
    ;; v0.7 item 4.3: user-side *journal* view, polls the
    ;; journal-tail RPC verb (added in v0.6 item 3).
    "/etc/geos/user/userland/journal-client.el"
    ;; v0.7 item 4.4: *processes* user-side.  /proc is world-
    ;; readable so the same buffers/processes.el the supervisor
    ;; uses works here without an RPC indirection.  having the
    ;; view in the user-emacs means a stuck process render
    ;; (regex backtrack on a long cmdline) stalls one session,
    ;; not PID 1.
    "/etc/geos/user/processes-buffer.el"
    "/etc/geos/user/userland/init.el")
  "Ordered list of files the per-user emacs loads.
each path is laid down by extra-special-file in guix-system/
system.scm and resolves to a store entry.  panic.el FIRST so the
rest of the chain can panic-handle; rpc-client.el SECOND so M-x
geos-rpc-* commands are usable as soon as the rest of the chain
errors (the user can still talk to the supervisor over the unix
socket even if userland/ load fails); use-package-shim THIRD
because every userland/*.el wraps its package in use-package
with the :comment keyword the shim adds; then the userland files
in the same order the supervisor used to -l them (shell before
uname because uname adds an eshell/uname override).  the verifier
init.el is LAST and walks (featurep ...) for each userland
module.

v0.7 item 1.2 added exwm-config / multimon / fonts / input to the
chain after use-package-shim and before the userland files.  the
user-emacs is now the X window manager.  audio.el IS in the chain
so the verifier sees it user-side; it is also -l'd supervisor-side
because buffers/audio.el requires it there.  the file's load is
idempotent (use-package + a defconst); double-load is harmless.

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

(defun user-init--load-per-user ()
  "Load /var/emacs/users/$USER/init.el iff present, regular, and owned by us.
v0.6 item 2.2: a user MAY drop an init.el into their state dir to
customize their per-user emacs.  the directory is pre-created and
chowned by the supervisor (session.el's
`session--ensure-user-state-dir') so the user owns it mode 0700;
this loader respects that boundary by reading the file under the
running uid, NOT through the supervisor's -l argv as the v0.5
session--child-argv used to.  the move matters because it lets us
gate on ownership in-process instead of trusting a supervisor-side
existence check that runs as root.

three gates, all of them required:

  - file-exists-p: a missing file is the common case (no per-user
    customization yet).  trace and return cleanly.

  - regular file: refuse symlinks, sockets, devices.  the dir is
    user-writable mode 0700 so the user can drop a symlink to
    /etc/passwd or /dev/zero in there; loading either is a way to
    mis-target the read.  the type slot of `file-attributes' is nil
    iff regular file (t for dir, string for symlink target).

  - owner == us: a file we did not write must not be loaded by us.
    with the dir mode 0700 the only way for a foreign-owned file to
    appear here is for root (the supervisor) to have written it,
    which is a bug or an attack vector; loading it would let root
    inject code into our session through the wrong channel.  the
    check costs one stat(2) and shuts the door.

errors are routed through panic-handle.  a broken per-user init.el
must not block the user from a usable emacs: trace, panic-handle,
move on."
  (condition-case err
      (let* ((user  (user-login-name))
             (path  (format "/var/emacs/users/%s/init.el" user))
             (attrs (and (file-exists-p path)
                         (file-attributes path 'integer))))
        (cond
         ((null attrs)
          (user-init--trace (format "no per-user init at %s" path)))
         ((not (eq (file-attribute-type attrs) nil))
          (user-init--trace
           (format "per-user init %s not a regular file, refusing"
                   path)))
         ((not (= (file-attribute-user-id attrs) (user-uid)))
          (user-init--trace
           (format "per-user init %s owned by uid %d not %d, refusing"
                   path (file-attribute-user-id attrs) (user-uid))))
         (t
          (load path nil 'nomessage)
          (user-init--trace (format "loaded per-user init %s" path)))))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'user-init--load-per-user)
       (user-init--trace
        (format "per-user init load failed: %S" err))))))

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
(user-init--load-per-user)

(provide 'geos-user-init)
;;; user-init.el ends here
