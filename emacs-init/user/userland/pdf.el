;;; pdf.el --- pdf-tools, render PDFs in a buffer -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; pdf-tools renders PDF pages by talking to a poppler-based helper
;; binary, `epdfinfo'. Guix builds that helper for us as part of the
;; emacs-pdf-tools system package, so there is no compile-on-first-use
;; dance to deal with. i still bind pdf-tools-install to a key because
;; it is the canonical "register pdf-view-mode for .pdf files" call,
;; and on a fresh image i want one keystroke to flip that switch.
;;
;; the helper binary is forked via make-process. no shell-out.

(require 'panic)

(condition-case err
    (use-package pdf-tools
      :comment "PDF reader. epdfinfo helper, no shell, no preview-only fallback."
      :defer t
      :bind (("C-c e p" . pdf-tools-install))
      :config
      ;; midnight mode flips colors for night reading. off by default,
      ;; togglable via M-x pdf-view-midnight-minor-mode in a buffer.
      (setq-default pdf-view-display-size 'fit-page))
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'userland-pdf-load)
     (message "userland/pdf: load failed before panic-handle: %S" err))))

(provide 'userland-pdf)
;;; pdf.el ends here
