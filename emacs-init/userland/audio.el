;;; audio.el --- ALSA volume + playback wrappers -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; ALSA is the userland audio API GEOS uses.  no PulseAudio, no
;; PipeWire: both want a session daemon and we are shepherd-free.
;; the kernel exposes ALSA cards under /proc/asound/cards and the
;; userland wraps it through alsa-utils' amixer + aplay binaries.
;;
;; this file's contract: small, sentinel-driven shell-outs to
;; amixer/aplay via `make-process'.  no `shell-command' anywhere; per
;; project rule we never wrap the call in a /bin/sh.  the binaries
;; themselves take care of their own argument parsing.
;;
;; long-term we want a tiny pid1-alsa.so that wraps snd_mixer_open
;; directly.  v0.4 ships the make-process path; the C module is a
;; v0.5 follow-up since it pulls libasound into the build inputs and
;; we have not validated that on the pinned guix channel yet.

(require 'panic)

(defgroup audio nil
  "ALSA wrappers for the GEOS userland."
  :group 'emacs
  :prefix "audio-")

(defcustom audio-default-card "default"
  "ALSA card name passed to amixer's -c flag.
\"default\" is whatever the kernel decided is card 0.  the *audio*
buffer's RET on a row writes the card index here so subsequent
volume actions land on the picked card."
  :type 'string :group 'audio)

(defcustom audio-default-control "Master"
  "ALSA mixer control to twiddle for `audio-volume' / `audio-mute-toggle'.
\"Master\" works on intel-hda and most USB cards; some virtio cards
expose only \"PCM\".  user can rebind."
  :type 'string :group 'audio)

(defcustom audio-amixer-binary "amixer"
  "Name of the amixer binary.  resolved via PATH.
PATH on a booted GEOS includes /run/current-system/profile/bin so
the alsa-utils binary lives there."
  :type 'string :group 'audio)

(defcustom audio-aplay-binary "aplay"
  "Name of the aplay binary, same PATH resolution."
  :type 'string :group 'audio)

(defun audio--executable (name)
  "Return the absolute path of NAME or nil if not on PATH.
caches nothing: the path is stable across the boot, but a future
profile reconfigure could move it and we'd rather see fresh."
  (executable-find name))

(defun audio--spawn (program args &optional sentinel)
  "Spawn PROGRAM with ARGS via make-process.  SENTINEL optional.
panic-handle catches `make-process' failures (typically ENOENT
when alsa-utils is not in the profile).  returns the process or
nil on routed failure."
  (cond
   ((not program)
    (panic-handle '(audio-program-missing) 'audio--spawn)
    nil)
   (t
    (condition-case err
        (make-process :name (concat "audio:" (file-name-nondirectory program))
                      :command (cons program args)
                      :buffer nil
                      :noquery t
                      :sentinel (or sentinel #'ignore))
      (error
       (panic-handle err `(audio--spawn . ,program))
       nil)))))

;;;; volume + mute

(defun audio-volume (level &optional control card)
  "Set CONTROL on CARD to LEVEL percent (0..100).
defaults: control=`audio-default-control', card=`audio-default-card'.
runs `amixer -c CARD sset CONTROL LEVEL%' through make-process; the
sentinel logs but does not block."
  (interactive
   (list (read-number "Volume (0-100): " 50)))
  (let* ((c (or control audio-default-control))
         (k (or card audio-default-card))
         (lvl (max 0 (min 100 level)))
         (prog (audio--executable audio-amixer-binary)))
    (audio--spawn prog (list "-c" k "sset" c (format "%d%%" lvl)))))

(defun audio-mute-toggle (&optional control card)
  "Toggle mute on CONTROL/CARD via `amixer sset ... toggle'.
same defaults as `audio-volume'."
  (interactive)
  (let* ((c (or control audio-default-control))
         (k (or card audio-default-card))
         (prog (audio--executable audio-amixer-binary)))
    (audio--spawn prog (list "-c" k "sset" c "toggle"))))

(defun audio-play-file (path)
  "Play PATH via aplay through make-process.
no progress feedback today; a future *audio* buffer can hook a
process filter onto the spawn for that.  PATH must already be a
WAV/FLAC/PCM file aplay understands."
  (interactive "fAudio file: ")
  (let ((prog (audio--executable audio-aplay-binary)))
    (audio--spawn prog (list (expand-file-name path)))))

;;;; minimal sysfs reader

(defun audio-set-default-card (card)
  "Set `audio-default-card' to CARD (string).
public setter so other files can repoint the default sink without
fighting the defcustom-from-foreign-file byte-compile warning."
  (setq audio-default-card card))

(defun audio-list-cards ()
  "Return a list of (INDEX . NAME) tuples from /proc/asound/cards.
the file format is one card per two lines, the first of which
starts with the card index, the second with the card model.  if
/proc/asound is missing (no kernel ALSA module loaded, e.g. on a
container build host) returns nil."
  (cond
   ((not (file-readable-p "/proc/asound/cards")) nil)
   (t
    (condition-case err
        (with-temp-buffer
          (insert-file-contents "/proc/asound/cards")
          (let ((out '()))
            (goto-char (point-min))
            (while (re-search-forward
                    "^[ \t]*\\([0-9]+\\)[ \t]+\\[\\([^]]+\\)\\]"
                    nil t)
              (push (cons (string-to-number (match-string 1))
                          (string-trim (match-string 2)))
                    out))
            (nreverse out)))
      (error
       (panic-handle err 'audio-list-cards)
       nil)))))

(provide 'userland-audio)
;;; audio.el ends here
