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
;;   `n' next card (cycles audio-default-card), `RET' on a card row
;;   makes it the default, `g' refresh, `q' bury.
;;
;; v0.7 item 3.1 lifted this file user-side.  it used to be -l'd from
;; the supervisor's boot gexp (audio renders happening in the PID 1
;; emacs); now it loads from /etc/geos/user/audio-buffer.el via
;; user-init--chain, after the userland chain that provides
;; `audio-volume' / `audio-mute-toggle' / `audio-list-cards'.  a
;; mixer call that wedges (e.g. an unresponsive USB card) now stalls
;; one user-emacs, not PID 1.  the M-x audio entrypoint is bound
;; globally to C-c e a for quick access.

(require 'panic)
(require 'port)
(require 'cl-lib)

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

(defun audio-buffer--render-hurd ()
  "Render the hurd-arm body of *audio*.
Hurd has no ALSA so the cards/PCM surfaces are absent.  Print the
banner the freeze suite and the user expect; do NOT touch ALSA
binaries.  routes a port-unimplemented breadcrumb so a post-mortem
sees the kernel skew that produced the empty buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq header-line-format
          (format "*audio*  kernel=%s  ALSA absent" geos-kernel))
    (insert
     (format
      "*audio* is not implemented on kernel %s.\n\nthe audio view reads /proc/asound, an ALSA-only surface; on hurd a translator-backed audio path is the v0.8 follow-up.  for now: no card list, no volume keys, no pcm count.\n"
      geos-kernel))
    (geos-port-unimplemented 'audio-buffer)))

(defun audio-buffer--pcm-stream-count (&optional path)
  "Return the number of playback PCM substreams visible in PATH.
PATH defaults to /proc/asound/pcm.  each row describes one PCM
device; we count the ones that advertise `playback' since that is
the user-facing signal (`how many output sinks can this kernel
offer?').  not a count of ACTIVE streams (that would need per-
substream status reads); the header line says `pcm:' not
`playing:' to keep the contract honest.  returns nil when the
file is missing (e.g. snd-pcm module not loaded, or a test passing
a nonexistent path).

PATH is parameterised so freeze-tests can feed a canned file
without shadowing `file-readable-p' globally (an early v0.7
attempt hung emacs because the shadow caught internal callers
during `require')."
  (let ((p (or path "/proc/asound/pcm")))
    (condition-case _
        (cond
         ((not (file-readable-p p)) nil)
         (t
          (with-temp-buffer
            (insert-file-contents p)
            (goto-char (point-min))
            (let ((n 0))
              (while (re-search-forward "playback" nil t)
                (setq n (1+ n)))
              n))))
      (error nil))))

(defun audio-buffer--render-linux ()
  "Linux backend for `audio-buffer--render'.
Repaints *audio* from /proc/asound/cards."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (let ((streams (audio-buffer--pcm-stream-count)))
      (setq header-line-format
            (format "*audio*  card=%s  control=%s  vol=%d%%  pcm=%s"
                    (if (boundp 'audio-default-card) audio-default-card "?")
                    (if (boundp 'audio-default-control)
                        audio-default-control "?")
                    audio-buffer--current-volume
                    (if streams (number-to-string streams) "?"))))
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
         "\nkeys: + vol up   - vol down   m mute   n next card   RET pick   g refresh   q bury\n"))))))

(defun audio-buffer--render ()
  "Repaint *audio*.
Dispatches on `geos-kernel'.  Linux arm renders the card list and
PCM count from /proc/asound; hurd arm short-circuits to
`audio-buffer--render-hurd' because that surface does not exist
on this kernel."
  (cond
   ((geos-kernel-linux-p) (audio-buffer--render-linux))
   (t (audio-buffer--render-hurd))))

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

(defun audio-buffer-next-card ()
  "Cycle `audio-default-card' to the next visible card.  bound to `n'.
order = the order `audio-list-cards' returns.  wraps around the end.
when no cards are visible (no ALSA, or /proc/asound empty) emit a
message rather than crash; the header still shows what we have."
  (interactive)
  (cond
   ((not (fboundp 'audio-list-cards))
    (message "audio-buffer: userland/audio.el not loaded"))
   (t
    (let* ((cards (audio-list-cards))
           (idxs  (and cards (mapcar (lambda (c) (number-to-string (car c)))
                                     cards)))
           (cur   (and (boundp 'audio-default-card) audio-default-card))
           (pos   (and cur (cl-position cur idxs :test #'equal)))
           (next  (cond
                   ((null idxs) nil)
                   ((or (null pos) (>= (1+ pos) (length idxs)))
                    (car idxs))
                   (t (nth (1+ pos) idxs)))))
      (cond
       ((null next)
        (message "audio-buffer: no cards visible"))
       (t
        (when (fboundp 'audio-set-default-card)
          (audio-set-default-card next))
        (audio-buffer-refresh)
        (message "audio-buffer: default card -> %s" next)))))))

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
    (define-key m (kbd "n")   #'audio-buffer-next-card)
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

;; v0.7 item 3.1: bind M-x audio under `C-c e a' to match the
;; project's `C-c e *' convention for system-supplied commands.
;; the binding lives here (not in user-init.el) because the file is
;; loaded user-side once and the binding is durable for the session.
(global-set-key (kbd "C-c e a") #'audio)

(provide 'audio-buffer)
;;; audio.el ends here
