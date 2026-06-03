;;; web.el --- eww, the only browser on this image -*- lexical-binding: t -*-
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
