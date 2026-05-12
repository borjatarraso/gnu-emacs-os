;;; input.el --- input methods for the EXWM session -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; phase 5c. input methods. the spec says "enable IBus interop" with
;; an explicit fallback to emacs-native quail. I considered IBus and
;; declined for v1. reasons:
;;
;;   1. IBus needs a daemon (ibus-daemon) running under the X session.
;;      we have no DBus session bus on the image either, which IBus
;;      uses for engine-to-client IPC. wiring DBus + dbus-launch + an
;;      IBus daemon supervisor is a small project on its own.
;;   2. the IBus emacs glue (`ibus-mode' from `ibus-el') depends on a
;;      python helper script and a TCP socket on localhost. we don't
;;      have python on the image and don't want it on the image.
;;   3. emacs's built-in `quail' input methods cover the high-value
;;      cases: rfc1345 for accented Latin (compose-key style), TeX
;;      for math, latin-postfix / latin-prefix for European typing.
;;      they need zero daemons, zero sockets, zero ports. they live
;;      inside the same emacs process, which means /no-shell-check
;;      passes by construction.
;;   4. CJK speakers who actually need IBus or fcitx are not the
;;      v1 target. when they are, the right answer is supervise.el
;;      starting an IBus daemon as a managed service, with input.el
;;      flipping `default-input-method' once the socket is reachable.
;;      that work is tracked for v0.2 in the project memory note.
;;
;; what this file does provide:
;;   - sets `default-input-method' to a quail method that is in-tree
;;     on emacs 30 (rfc1345) so C-\ Just Works.
;;   - lets the user pick an alternate via `set-input-method' (already
;;     bound to C-x RET C-\ in vanilla emacs).
;;   - exposes C-c e i to toggle the input method on/off, mirroring
;;     C-\ but living in the project-standard `C-c e' map so EXWM's
;;     char-mode passthrough doesn't eat it.
;;   - prefers `mozc-mode' for Japanese IF a future image ships it.
;;     we don't fail when it's missing, we just skip.

(require 'panic)

(defvar input-default-method "rfc1345"
  "Default quail input method.
rfc1345 is a compose-key style method covering most accented Latin
plus a fair chunk of math and arrows. lives in emacs core, no
extra package. switch to `latin-postfix' if you prefer
\"a''\" to type \"á\" instead of \"&aacute;\".")

(defvar input-alt-methods
  '("TeX"             ;; \alpha -> α etc; useful in org/comments
    "latin-postfix"   ;; a'' -> á
    "latin-prefix"    ;; 'a -> á
    "rfc1345")
  "Methods offered by `input-pick-method'.
Order = preference. Each one is checked with `assoc' against
`input-method-alist' before being offered, so a method missing
from this emacs build is silently dropped.")

(defun input--trace (msg)
  "Best-effort trace to /dev/console; same shape as multimon--trace.
Errors swallowed: tracing is never the failure mode.
write-region-inhibit-fsync is defensive: a no-op for character
devices today but cheap to set in case a future emacs flushes ttys."
  (condition-case _
      (let ((write-region-inhibit-fsync t))
        (write-region (format "input: %s\n" msg)
                      nil "/dev/console" 'append 'nomsg))
    (error nil)))

(defun input--method-available-p (name)
  "Return non-nil when input method NAME is registered in this emacs.
quail loads its method registry lazily; we touch it via require so
the assoc check below sees the in-tree methods.  on a fresh boot
without `leim-list' loaded, `input-method-alist' is empty even
after requiring `quail'; pull leim-list explicitly so the rfc1345
and ipa methods register themselves before we look them up."
  (condition-case _
      (progn
        (require 'quail nil t)
        (require 'leim-list nil t)
        (assoc name input-method-alist))
    (error nil)))

(defun input-toggle-method ()
  "Toggle the current input method on/off.
Mirrors C-\\ but lives under `C-c e i' so EXWM char-mode windows
(which swallow C-\\ when forwarding to an X client) can still get
to it. If `current-input-method' is nil we activate the default;
otherwise we turn it off."
  (interactive)
  (condition-case err
      (cond
       (current-input-method
        (deactivate-input-method)
        (message "input: off"))
       ((input--method-available-p input-default-method)
        (activate-input-method input-default-method)
        (message "input: on (%s)" input-default-method))
       (t
        (message "input: %s not available; nothing to toggle"
                 input-default-method)))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'input-toggle-method)
       (message "input-toggle-method: %S" err)))))

(defun input-pick-method ()
  "Prompt for one of the alternates in `input-alt-methods'.
Filters the list against `input-method-alist' so the user only
sees methods this emacs actually has."
  (interactive)
  (condition-case err
      (let* ((avail (seq-filter #'input--method-available-p
                                input-alt-methods))
             (pick  (and avail (completing-read "input method: "
                                                avail nil t))))
        (cond
         ((null avail)
          (message "input: no alt methods available"))
         ((or (null pick) (string-empty-p pick))
          (message "input: cancelled"))
         (t
          (activate-input-method pick)
          (message "input: on (%s)" pick))))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'input-pick-method)
       (message "input-pick-method: %S" err)))))

(defun input-apply ()
  "Set up input methods at boot.
Picks `input-default-method' if available, else degrades silently.
Also wires `mozc-mode' as a non-default option when present, so
a future image shipping emacs-mozc gets free Japanese support."
  (interactive)
  (condition-case err
      (cond
       ((input--method-available-p input-default-method)
        (setq default-input-method input-default-method)
        ;; mozc-mode optional: we don't (require 'mozc) because that
        ;; would error on every boot until the package lands. featurep
        ;; check after a soft require.
        (when (and (locate-library "mozc")
                   (require 'mozc nil t)
                   (input--method-available-p "japanese-mozc"))
          (input--trace "japanese-mozc available, kept as alternate"))
        (input--trace
         (format "default-input-method <- %s" input-default-method))
        t)
       (t
        ;; this is unusual: rfc1345 is in-tree on emacs 30. log it
        ;; via panic-handle because it means our build is broken.
        (when (fboundp 'panic-handle)
          (panic-handle (list 'input-method-missing input-default-method)
                        'input-apply))
        (input--trace
         (format "%s missing; default-input-method left unchanged"
                 input-default-method))
        nil))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'input-apply)
       (message "input-apply: %S" err))
     nil)))

(global-set-key (kbd "C-c e i") #'input-toggle-method)
(global-set-key (kbd "C-c e I") #'input-pick-method)

(provide 'input)
;;; input.el ends here
