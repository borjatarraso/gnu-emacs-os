;;; user-init.el --- per-user emacs userland for GEOS -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; runs in the per-user emacs, NOT the supervisor.  this is the v0.6
;; foothold for user-side userland: the per-user emacs gets exactly
;; one defun and one keybinding for now, geos-logout.  future v0.6+
;; work moves dired/eshell/notes/etc out of emacs-init/userland/
;; (where they currently load into the supervisor) into this file
;; tree instead.
;;
;; loaded by session--child-argv via `-l /etc/geos/user-init.el',
;; the path extra-special-file'd in system.scm to point at this
;; file's store hash.  loads BEFORE any optional per-user
;; /var/emacs/users/NAME/init.el so the system command set is
;; available to user-side init code that might want to rebind it.
;;
;; security posture: this file runs as the logged-in user, not root.
;; the per-user emacs has the privileges of that user; nothing here
;; talks back to the supervisor over a wire protocol (the supervisor
;; observes child exit via the /proc poller, no side channel).  if
;; that changes, the new wire protocol is the load-bearing security
;; boundary.

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

(provide 'geos-user-init)
;;; user-init.el ends here
