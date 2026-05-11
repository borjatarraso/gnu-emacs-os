;;; audio.el --- *audio* buffer, ALSA cards + volume control -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; what does it show: the ALSA cards from /proc/asound/cards plus the
;; currently selected default card and control.  no live volume readback
;; yet (would require running amixer get on every refresh, which is a
;; fork per tick, no thanks); the buffer just lets the user nudge volume
;; up/down or pick a card.
;;
;; how does it refresh: re-reads on `g'.  no timer because card list
;; does not change behind our back (USB hotplug aside, and we have no
;; uevent watcher yet).
;;
;; what can the user do here:
;;   `+'/`='  volume up 5%, `-' down 5%, `m' mute toggle,
;;   `RET' on a card row makes it the default, `g' refresh, `q' bury.

(require 'panic)

(condition-case err
    (require 'userland-audio)
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'audio-buffer-require)
     (message "audio-buffer: userland-audio require failed: %S" err))))

(defvar audio-buffer-name "*audio*"
  "Canonical name of the audio control buffer.")

(defvar audio-buffer-volume-step 5
  "Percent points each `+' or `-' tick changes the volume by.")

(defvar-local audio-buffer--current-volume 50
  "Last commanded volume.  not a readback; we do not poll amixer.
the user sees this in the header line so they have feedback that
their `+'/`-' presses actually went somewhere.")

(defun audio-buffer--render ()
  "Repaint *audio* from /proc/asound/cards."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq header-line-format
          (format "*audio*  card=%s  control=%s  vol=%d%%"
                  (if (boundp 'audio-default-card) audio-default-card "?")
                  (if (boundp 'audio-default-control)
                      audio-default-control "?")
                  audio-buffer--current-volume))
    (cond
     ((not (fboundp 'audio-list-cards))
      (insert "userland/audio.el not loaded\n"))
     (t
      (let ((cards (audio-list-cards)))
        (insert (format "  %4s %s\n" "idx" "model"))
        (cond
         ((null cards)
          (insert "  (no ALSA cards visible; /proc/asound missing or empty)\n"))
         (t
          (dolist (c cards)
            (let ((line (format "  %4d %s" (car c) (cdr c))))
              (insert (propertize line 'audio-card c) "\n")))))
        (insert
         "\nkeys: + vol up   - vol down   m mute   RET pick   g refresh   q bury\n"))))))

(defun audio-buffer-refresh ()
  "Force a refresh of *audio*."
  (interactive)
  (let ((buf (get-buffer audio-buffer-name)))
    (when buf
      (with-current-buffer buf
        (audio-buffer--render)))))

(defun audio-buffer-card-at-point ()
  "Return the (INDEX . NAME) tuple on the current row, or nil."
  (get-text-property (line-beginning-position) 'audio-card))

(defun audio-buffer-pick-card ()
  "Make the card on the current line the default sink.  bound to RET.
sets `audio-default-card' to a string of the card index so subsequent
amixer calls use it via `amixer -c N'."
  (interactive)
  (let ((row (audio-buffer-card-at-point)))
    (cond
     ((null row)
      (message "audio-buffer: no card on this line"))
     (t
      (let ((idx (number-to-string (car row))))
        (cond
         ((fboundp 'audio-set-default-card)
          (audio-set-default-card idx)
          (audio-buffer-refresh)
          (message "audio-buffer: default card -> %s (%s)" idx (cdr row)))
         (t
          (message "audio-buffer: userland/audio.el not loaded, cannot pick card"))))))))

(defun audio-buffer-volume-up ()
  "Bump volume by `audio-buffer-volume-step'.  bound to `+' / `='."
  (interactive)
  (setq audio-buffer--current-volume
        (min 100 (+ audio-buffer--current-volume audio-buffer-volume-step)))
  (when (fboundp 'audio-volume)
    (audio-volume audio-buffer--current-volume))
  (audio-buffer-refresh))

(defun audio-buffer-volume-down ()
  "Drop volume by `audio-buffer-volume-step'.  bound to `-'."
  (interactive)
  (setq audio-buffer--current-volume
        (max 0 (- audio-buffer--current-volume audio-buffer-volume-step)))
  (when (fboundp 'audio-volume)
    (audio-volume audio-buffer--current-volume))
  (audio-buffer-refresh))

(defun audio-buffer-mute-toggle ()
  "Toggle mute on the current control.  bound to `m'."
  (interactive)
  (when (fboundp 'audio-mute-toggle)
    (audio-mute-toggle))
  (audio-buffer-refresh))

(defun audio-buffer-quit ()
  "Bury *audio*."
  (interactive)
  (bury-buffer))

(defvar audio-buffer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g")   #'audio-buffer-refresh)
    (define-key m (kbd "RET") #'audio-buffer-pick-card)
    (define-key m (kbd "+")   #'audio-buffer-volume-up)
    (define-key m (kbd "=")   #'audio-buffer-volume-up)
    (define-key m (kbd "-")   #'audio-buffer-volume-down)
    (define-key m (kbd "m")   #'audio-buffer-mute-toggle)
    (define-key m (kbd "q")   #'audio-buffer-quit)
    m)
  "Keymap for `audio-buffer-mode'.")

(define-derived-mode audio-buffer-mode special-mode "Audio"
  "Major mode for the *audio* buffer.
read-only view of /proc/asound/cards plus volume keys backed by
amixer through make-process."
  (setq truncate-lines t))

;;;###autoload
(defun audio ()
  "Display the *audio* buffer.  M-x audio."
  (interactive)
  (let ((buf (get-buffer-create audio-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'audio-buffer-mode)
        (audio-buffer-mode))
      (audio-buffer--render))
    (display-buffer buf)
    buf))

(provide 'audio-buffer)
;;; audio.el ends here
