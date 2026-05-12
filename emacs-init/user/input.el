;;; input.el --- input methods for the EXWM session -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; phase 5c shipped quail-only.  v0.7 item 2 grows a chooser:
;;
;;   geos-input-method
;;     :auto    pick IBus under X (when (getenv "DISPLAY") and IBus is
;;              actually reachable); fall back to quail otherwise.
;;     :ibus    force IBus.  fail closed (no input method) if absent.
;;     :quail   force quail.  this is the v0.6 behavior verbatim.
;;
;; rationale: CJK input needs IBus or fcitx; rfc1345 / TeX / latin-*
;; quail methods cover the european-typing common case but cannot
;; do pinyin / kana / hangul.  the chooser keeps quail as the default
;; for now (until slice 2.3 lands ibus + ibus-libpinyin in the system
;; profile) but the seam is in place.
;;
;; what this file provides:
;;   - sets `default-input-method' according to `geos-input-method'.
;;   - lets the user pick an alternate via `set-input-method' (already
;;     bound to C-x RET C-\ in vanilla emacs).
;;   - exposes C-c e i to toggle the input method on/off, mirroring
;;     C-\ but living in the project-standard `C-c e' map so EXWM's
;;     char-mode passthrough doesn't eat it.
;;   - prefers `mozc-mode' for Japanese IF a future image ships it.
;;     we don't fail when it's missing, we just skip.
;;
;; out of scope for slice 2.1: dbus-launch, ibus-daemon supervision,
;; per-user persistence of the chosen method.  the IBus branch is a
;; placeholder that fails-fall-back until slice 2.3.

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

(defcustom geos-input-method :auto
  "How `input-apply' picks an input method at boot.

:auto    try IBus under X (DISPLAY set AND IBus reachable); fall
         back to quail otherwise.  this is the right default for a
         desktop session: CJK users get IBus the moment the system
         profile carries it, european-typing users get rfc1345
         silently.
:ibus    force IBus.  if unreachable, leave `default-input-method'
         nil (fail closed).  use this when you are explicitly
         relying on IBus being present and want a loud miss.
:quail   force quail.  reproduces the v0.6 behavior verbatim.

slice 2.1 ships the chooser but the IBus path is a stub until
slice 2.3 lands the ibus + ibus-libpinyin Guix packages and the
dbus-launch / ibus-daemon supervision wiring.  until then
`input--ibus-available-p' returns nil and :auto falls through to
quail."
  :type '(choice (const :tag "auto (ibus under X, quail otherwise)" :auto)
                 (const :tag "force ibus" :ibus)
                 (const :tag "force quail" :quail))
  :group 'convenience)

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

(defun input--ibus-available-p ()
  "Return non-nil iff an IBus daemon is reachable from this emacs.
slice 2.1 stub: returns nil unconditionally.  slice 2.3 will replace
the body with a real probe: dbus-ping of the org.freedesktop.IBus
well-known name, or `executable-find' for ibus-daemon + a poke at
$IBUS_ADDRESS / ~/.config/ibus/bus/.  keeping the seam empty for
now means :auto falls through to quail and :ibus fails closed,
which is the documented slice 2.1 contract."
  nil)

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

(defun input--quail-apply ()
  "Set `default-input-method' to `input-default-method' via quail.
returns t when the method was applied, nil when it was missing.
this is the v0.6 body of `input-apply' verbatim; slice 2.1 hoisted
it under a name so the dispatcher can pick it on :quail or as the
:auto fallback.  mozc-mode is still soft-probed because a future
image shipping emacs-mozc gets free japanese support even if the
user picked :quail (mozc is a quail-compatible method)."
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
     (format "quail: default-input-method <- %s" input-default-method))
    t)
   (t
    ;; this is unusual: rfc1345 is in-tree on emacs 30. log it
    ;; via panic-handle because it means our build is broken.
    (when (fboundp 'panic-handle)
      (panic-handle (list 'input-method-missing input-default-method)
                    'input--quail-apply))
    (input--trace
     (format "quail: %s missing; default-input-method left unchanged"
             input-default-method))
    nil)))

(defun input--ibus-apply ()
  "Set `default-input-method' to ibus (slice 2.1 stub).
returns nil unconditionally for now: the dispatcher's caller treats
nil as `did not apply' and the :auto branch falls through to quail.
slice 2.3 will:
  - confirm `input--ibus-available-p' (the probe is here today)
  - (require 'ibus) or (setq default-input-method \"ibus\") depending
    on which integration package the system profile carries
  - trace `ibus: default-input-method <- ...' on success
the stub still traces a one-liner so a serial log shows the chooser
was reached, which is the point of the slice: the seam exists and
is testable, even if it does nothing yet."
  (input--trace "ibus: stub (slice 2.3 lands the real probe)")
  nil)

(defun input-apply ()
  "Set up input methods at boot, dispatching on `geos-input-method'.
:quail  -> `input--quail-apply' (v0.6 behavior).
:ibus   -> `input--ibus-apply'  (stub until slice 2.3; fail closed).
:auto   -> ibus first when (getenv \"DISPLAY\") AND
           `input--ibus-available-p'; quail otherwise.

returns t when some method was applied, nil when none was.  errors
are routed through `panic-handle'; the boot must not abort on
input-method setup.  the only way :ibus's `fail closed' shows up
is `default-input-method' remaining nil, which is the same shape
as no input method at all, which is fine: the user can still
M-x set-input-method or hit C-c e I."
  (interactive)
  (condition-case err
      (pcase geos-input-method
        (:quail
         (input--trace "chooser: quail (forced)")
         (input--quail-apply))
        (:ibus
         (input--trace "chooser: ibus (forced; fail-closed if missing)")
         (input--ibus-apply))
        (:auto
         (cond
          ((and (getenv "DISPLAY") (input--ibus-available-p))
           (input--trace "chooser: auto -> ibus")
           (or (input--ibus-apply)
               ;; ibus said it could but couldn't: still fall back.
               (progn
                 (input--trace "chooser: ibus failed, falling back to quail")
                 (input--quail-apply))))
          (t
           (input--trace
            (format "chooser: auto -> quail (DISPLAY=%s ibus=%s)"
                    (or (getenv "DISPLAY") "nil")
                    (if (input--ibus-available-p) "yes" "no")))
           (input--quail-apply))))
        (other
         (input--trace
          (format "chooser: unknown geos-input-method %S, using quail"
                  other))
         (input--quail-apply)))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'input-apply)
       (message "input-apply: %S" err))
     nil)))

(global-set-key (kbd "C-c e i") #'input-toggle-method)
(global-set-key (kbd "C-c e I") #'input-pick-method)

(provide 'input)
;;; input.el ends here
