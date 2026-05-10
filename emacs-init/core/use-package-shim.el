;;; use-package-shim.el --- bootstrap use-package and the :comment keyword -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; project rule: every package goes through use-package with a
;; one-line :comment justification. use-package itself ships
;; in-tree on emacs 30, but :comment is not one of its built-in
;; keywords, so the userland files raise
;;   use-package: Unrecognized keyword: :comment
;; the moment they evaluate. that wedges eww, erc, org, pdf-tools,
;; notmuch, magit and dired in one go.
;;
;; this file requires use-package and teaches it to accept :comment as
;; a no-op. the keyword exists purely as readable documentation next
;; to the package's :config block; it has no runtime effect, no
;; bytecode emitted, and it is invisible to /ricer-check beyond the
;; presence test.
;;
;; load order: this file MUST be -l'd in the boot gexp BEFORE any
;; userland/*.el. panic.el is its only required predecessor, so the
;; gexp slot is right after panic, before the wm chain.

(require 'panic)

(condition-case err
    (require 'use-package)
  (error
   ;; loud failure path.  if use-package is not on the load-path,
   ;; every subsequent userland/*.el will hit "void-function
   ;; use-package" the moment it is loaded, which fans out into a
   ;; storm of *panic* entries that obscure the root cause.  log
   ;; the missing-package event with high signal so a human reading
   ;; *panic* sees ONE clear message rather than thirty derived ones.
   (if (fboundp 'panic-handle)
       (panic-handle (list 'use-package-missing err) 'use-package-shim-require)
     (message "use-package-shim: require failed: %S" err))
   ;; mirror to /dev/console when boot-marker is loaded so smoke-test
   ;; harnesses can pick the failure up out-of-band.  guarded with
   ;; require-noerror because boot-marker.el normally loads AFTER us.
   (when (require 'boot-marker nil 'noerror)
     (when (fboundp 'boot-marker--write)
       (boot-marker--write
        "use-package-shim: use-package missing, userland will not load")))))

(when (featurep 'use-package)
  ;; register :comment so use-package--check-keywords stops rejecting
  ;; it. position in the list is cosmetic for a no-op keyword; we
  ;; cons it to the front so it sorts ahead of side-effecting
  ;; keywords during macro expansion.
  (unless (memq :comment use-package-keywords)
    (setq use-package-keywords
          (cons :comment use-package-keywords)))

  ;; normalizer: pass the args list through unchanged. use-package
  ;; calls this with (NAME KEYWORD ARGS); a normalizer is required
  ;; even for trivial keywords because the default validator chokes
  ;; on a bare string argument.
  (defun use-package-normalize/:comment (_name _keyword args)
    "Accept :comment STRING.  Return ARGS untouched."
    args)

  ;; handler: emit no code of our own; just keep processing the rest
  ;; of the keyword list. nil contribution from a handler means the
  ;; keyword is documentation-only, which is exactly what we want.
  (defun use-package-handler/:comment (name _keyword _arg rest state)
    "No-op handler so :comment expands to nothing."
    (use-package-process-keywords name rest state)))

(provide 'use-package-shim)
;;; use-package-shim.el ends here
