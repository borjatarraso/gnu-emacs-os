;;; init.el --- userland package chain entry point -*- lexical-binding: t -*-

;; loaded last in the boot -l chain, AFTER exwm-config.el and after
;; each of the per-package userland files (files.el, shell.el, git.el,
;; web.el, mail.el, chat.el, notes.el, pdf.el). that ordering matters:
;; exwm has to claim the root window before any user-facing code spawns
;; buffers, otherwise a popup from one of these packages could land on
;; the wrong frame.
;;
;; the boot gexp -l's each userland file individually so they are all
;; (require)d by the time we get here. this file then just walks the
;; manifest and verifies each feature is actually provided. a missing
;; feature is logged via panic-handle, not raised, because emacs is
;; the OS and partial degradation beats total death.

(require 'panic)

(defvar userland-modules
  '(userland-files
    userland-shell
    userland-git
    userland-web
    userland-mail
    userland-chat
    userland-notes
    userland-pdf)
  "Ordered list of userland feature symbols that should be loaded.
Each one corresponds to a file in this directory: e.g.
`userland-files' lives in files.el. The boot gexp -l's each one
before this init.el runs; this list is just the manifest we use
to confirm that happened.")

(defun userland--verify-one (feature)
  "Confirm FEATURE is provided. Log via `panic-handle' if not.
Returns t when present, nil when missing. Never raises."
  (condition-case err
      (cond
       ((featurep feature) t)
       (t
        ;; not provided. that means the boot gexp dropped a -l, or the
        ;; file errored out during its own load and only landed a
        ;; partial provide. either way it is a degraded-mode event
        ;; worth logging, not a panic to crash on.
        (if (fboundp 'panic-handle)
            (panic-handle (list 'userland-feature-missing feature)
                          'userland--verify-one)
          (message "userland/init: feature %s not provided" feature))
        nil))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err (cons 'userland--verify-one feature))
       (message "userland/init: %s verify failed: %S" feature err))
     nil)))

(defun userland-verify-all ()
  "Walk `userland-modules' and verify each is loaded.
Returns the list of features that were missing, or nil when
everything is present. Useful at the M-x prompt to confirm a
boot landed clean."
  (interactive)
  (let ((missing '()))
    (dolist (m userland-modules)
      (unless (userland--verify-one m)
        (push m missing)))
    (let ((m (nreverse missing)))
      (when (called-interactively-p 'interactive)
        (message "userland: %s"
                 (if m (format "missing %S" m) "all features present")))
      m)))

(condition-case err
    (userland-verify-all)
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'userland-init-verify)
     (message "userland/init: verify failed before panic-handle: %S" err))))

;; TODO(5b/6): once core/supervise.el lands, register the long-running
;; helpers here (notmuch's poll timer, magit-process' auto-revert
;; timer, pdf-tools' epdfinfo subprocess) so a death gets restarted
;; instead of silently dropping a feature.

(provide 'userland-init)
;;; init.el ends here
