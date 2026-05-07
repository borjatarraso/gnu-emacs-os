;;; fonts.el --- declarative font config with fallback chain -*- lexical-binding: t -*-

;; phase 5c. font wiring for the EXWM session. three concerns, in order:
;;   1. default monospace face: use a family the system profile actually
;;      ships. verify with `find-font' before setting; if missing,
;;      panic-handle and stay on whatever emacs picked. degraded mode is
;;      worse than the default but better than dead.
;;   2. symbol/emoji fallback: Noto Color Emoji or Symbola. `set-fontset-font'
;;      against the `symbol' script and the unicode emoji ranges. emoji is
;;      not load-bearing, so a missing font here is a `message' (warn-only),
;;      not a panic.
;;   3. CJK fallback: Noto Sans CJK if present. same find-font check.
;;      again warn-only.
;;
;; HiDPI: detect via `x-display-pixel-width' and `x-display-mm-width'.
;; if effective DPI > 144 we scale the default size proportionally.
;; the math is:
;;   dpi = pixels / (mm / 25.4)        ; 25.4 mm per inch
;; we round to int and pin scale to a sane window so a 1mm display
;; report (which the kernel sometimes hands back when EDID is missing)
;; doesn't blow the size up to 9000pt.
;;
;; a note on Noto Color Emoji on emacs without harfbuzz: COLR/CPAL color
;; rendering needs `(featurep 'harfbuzz)'. without it the glyphs render
;; as outlined boxes. we don't try to detect that here, the comment is
;; the warning.

(require 'panic)

(defvar fonts-default-family "DejaVu Sans Mono"
  "Family name we want as the default monospace face.
DejaVu Sans Mono ships with %base-packages via fontconfig defaults
on Guix, so it is the safest pick that doesn't add a new system
package. Override at the top of this file if a future profile
swaps in something nicer.")

(defvar fonts-default-size 12
  "Base point size for the default face before HiDPI scaling.
Integer. Scaled by `fonts--hidpi-scale' on display init.")

(defvar fonts-emoji-family "Noto Color Emoji"
  "Preferred emoji font family. Falls back to Symbola if missing.
Both are looked up via `find-font'. If neither is present we log
and skip emoji wiring; emoji is not load-bearing for the OS.")

(defvar fonts-symbol-fallback-family "Symbola"
  "Fallback symbol font when Noto Color Emoji isn't available.")

(defvar fonts-cjk-family "Noto Sans CJK SC"
  "Preferred CJK family. Guix's font-google-noto-sans-cjk installs
this and several siblings (TC, JP, KR). SC covers Simplified Chinese
and works as a pan-CJK fallback well enough for v1.")

(defvar fonts--applied nil
  "Non-nil once `fonts-apply' has run successfully at least once.
Idempotency guard so a stray re-load (or a future hot-config reload)
doesn't keep stacking fontset entries.")

(defun fonts--trace (msg)
  "Best-effort trace to /dev/console; same shape as multimon--trace.
Errors swallowed: tracing is never the failure mode."
  (condition-case _
      (write-region (format "fonts: %s\n" msg)
                    nil "/dev/console" 'append 'nomsg)
    (error nil)))

(defun fonts--display-dpi ()
  "Return effective DPI of the current X display, or nil if we can't tell.
Both `x-display-pixel-width' and `x-display-mm-width' return 0 on
displays that didn't ship EDID (Xvfb, some virtio-gpu, certain BIOSes).
We treat 0 as \"unknown\" and bail. nil from us means \"don't scale\"."
  (condition-case _
      (let ((px (x-display-pixel-width))
            (mm (x-display-mm-width)))
        (when (and (numberp px) (numberp mm)
                   (> px 0) (> mm 0))
          ;; 25.4 mm per inch. round to int.
          (round (/ (* px 25.4) mm))))
    (error nil)))

(defun fonts--hidpi-scale (base-size)
  "Return a font size scaled for the current DPI, anchored at BASE-SIZE.
Threshold: 144 DPI is roughly 1.5x scale, the standard \"HiDPI\" floor.
Below that we leave BASE-SIZE alone. Above, we scale linearly off 96
DPI as the canonical 1.0x baseline. Pinned to [BASE-SIZE, 4*BASE-SIZE]
to defend against bogus EDID."
  (let ((dpi (fonts--display-dpi)))
    (cond
     ((null dpi) base-size)
     ((<= dpi 144) base-size)
     (t
      (let* ((ratio (/ (float dpi) 96.0))
             (scaled (round (* base-size ratio))))
        (min (* base-size 4) (max base-size scaled)))))))

(defun fonts--font-available-p (family)
  "Return non-nil if FAMILY resolves to an installed font.
Wraps `find-font' under condition-case because find-font can raise
on a half-built fontset. nil on any error."
  (condition-case _
      (and family (find-font (font-spec :family family)))
    (error nil)))

(defun fonts--set-default-face (family size)
  "Set the default and fixed-pitch faces to FAMILY at SIZE points.
Uses `font-spec' rather than the legacy XLFD string syntax so a
weird family name (spaces, hyphens) doesn't accidentally parse as
something else. Errors route through panic-handle."
  (condition-case err
      (let ((spec (font-spec :family family :size size)))
        (set-face-attribute 'default nil :font spec)
        ;; mirror to fixed-pitch so packages that explicitly request
        ;; the fixed-pitch face don't end up mismatched in size.
        (set-face-attribute 'fixed-pitch nil :font spec)
        (fonts--trace
         (format "default face <- %s @ %dpt" family size)))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err (cons 'fonts--set-default-face family))
       (message "fonts: setting default to %s/%d failed: %S"
                family size err)))))

(defun fonts--set-emoji-fontset ()
  "Wire emoji and symbol-script fallbacks into the global fontset.
Tries `fonts-emoji-family' first, then `fonts-symbol-fallback-family'.
If neither is present, log a warn (not a panic) and return nil. emoji
is decoration, the OS does not need it."
  (let* ((emoji (cond
                 ((fonts--font-available-p fonts-emoji-family)
                  fonts-emoji-family)
                 ((fonts--font-available-p fonts-symbol-fallback-family)
                  fonts-symbol-fallback-family)
                 (t nil))))
    (cond
     ((null emoji)
      (fonts--trace
       (format "no emoji family (tried %s, %s); skipping emoji wiring"
               fonts-emoji-family fonts-symbol-fallback-family))
      nil)
     (t
      (condition-case err
          (let ((spec (font-spec :family emoji)))
            ;; the `symbol' script covers most Unicode symbol blocks
            ;; emacs categorizes; it is the canonical entry for
            ;; arrows, dingbats, miscellaneous technical etc.
            (set-fontset-font t 'symbol spec nil 'prepend)
            ;; explicit emoji ranges. emacs doesn't always classify
            ;; the modern emoji-presentation codepoints under `symbol'.
            ;; the (BEG . END) ranges below cover Emoticons, Misc
            ;; Symbols & Pictographs, Supplemental Symbols & Pictographs,
            ;; Symbols & Pictographs Extended-A, and the regional
            ;; indicator block (flag emoji).
            (dolist (range '((#x1F300 . #x1F5FF)
                             (#x1F600 . #x1F64F)
                             (#x1F680 . #x1F6FF)
                             (#x1F900 . #x1F9FF)
                             (#x1FA70 . #x1FAFF)
                             (#x1F1E6 . #x1F1FF)))
              (set-fontset-font t range spec nil 'prepend))
            (fonts--trace (format "emoji <- %s" emoji))
            t)
        (error
         (if (fboundp 'panic-handle)
             (panic-handle err 'fonts--set-emoji-fontset)
           (message "fonts: emoji wiring failed: %S" err))
         nil))))))

(defun fonts--set-cjk-fontset ()
  "Wire CJK script fallbacks into the global fontset.
Warn-only on missing family. Same pattern as emoji."
  (cond
   ((not (fonts--font-available-p fonts-cjk-family))
    (fonts--trace
     (format "no CJK family (tried %s); skipping CJK wiring"
             fonts-cjk-family))
    nil)
   (t
    (condition-case err
        (let ((spec (font-spec :family fonts-cjk-family)))
          (dolist (script '(han kana hangul cjk-misc bopomofo))
            (set-fontset-font t script spec nil 'prepend))
          (fonts--trace (format "CJK <- %s" fonts-cjk-family))
          t)
      (error
       (if (fboundp 'panic-handle)
           (panic-handle err 'fonts--set-cjk-fontset)
         (message "fonts: CJK wiring failed: %S" err))
       nil)))))

(defun fonts-apply ()
  "Apply the declarative font config. Idempotent. Safe before X is up.
Returns t when the default face was set, nil otherwise (degraded mode).
Emoji and CJK are best-effort and do not affect the return value."
  (interactive)
  (cond
   ((not (display-graphic-p))
    (fonts--trace "no graphical display, skipping font config")
    nil)
   (t
    (let* ((size (fonts--hidpi-scale fonts-default-size))
           (have-default (fonts--font-available-p fonts-default-family)))
      (cond
       ((not have-default)
        ;; missing the default family is a degraded-mode condition,
        ;; not a panic per se, but it is unusual enough that we route
        ;; through panic-handle so it shows up in *panic*.
        (when (fboundp 'panic-handle)
          (panic-handle (list 'fonts-default-missing fonts-default-family)
                        'fonts-apply))
        (fonts--trace
         (format "default family %s missing; leaving emacs default"
                 fonts-default-family)))
       (t
        (fonts--set-default-face fonts-default-family size)))
      (fonts--set-emoji-fontset)
      (fonts--set-cjk-fontset)
      (setq fonts--applied t)
      (fonts--trace
       (format "apply done dpi=%S size=%d default=%s"
               (fonts--display-dpi) size
               (if have-default fonts-default-family "unchanged")))
      have-default))))

(provide 'fonts)
;;; fonts.el ends here
