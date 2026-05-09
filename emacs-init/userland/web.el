;;; web.el --- eww, the only browser on this image -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; eww is in-tree. it renders HTML in a buffer, follows links, runs no
;; javascript, and has no third-party storage. for our purposes that
;; is a feature, not a bug. firefox is not coming.

(require 'panic)

(condition-case err
    (use-package eww
      :comment "the browser. no JS, no trackers, renders to a buffer."
      :defer t
      :bind (("C-c e w" . eww))
      :config
      ;; render bare URLs in any buffer as clickable. without this i
      ;; copy/paste URLs back into the prompt, which is silly when
      ;; goto-address-mode exists.
      (add-hook 'eww-mode-hook #'goto-address-mode)
      ;; download dir: ~/Downloads is not guaranteed to exist on a
      ;; fresh boot. fall back to /tmp which is always tmpfs and
      ;; mounted by pid1.
      (setq eww-download-directory
            (lambda ()
              (or (and (file-directory-p (expand-file-name "~/Downloads"))
                       (expand-file-name "~/Downloads"))
                  "/tmp"))))
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'userland-web-load)
     (message "userland/web: load failed before panic-handle: %S" err))))

(provide 'userland-web)
;;; web.el ends here
