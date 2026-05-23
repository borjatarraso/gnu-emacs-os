;;; audio.el --- ALSA volume + playback wrappers -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; ALSA is the userland audio API GEOS uses on linux.  no PulseAudio,
;; no PipeWire on that arm: both want a session daemon and we are
;; shepherd-free.  the kernel exposes ALSA cards under /proc/asound/
;; cards and the userland wraps it through alsa-utils' amixer + aplay
;; binaries.
;;
;; on hurd there is no ALSA: no /dev/snd, no /hurd/audio*, no driver
;; on debian-ports.  v1.x bucket-3 closes the v0.9.7 audio follow-on
;; by promoting pulseaudio's pactl CLI as the userland surface.  the
;; daemon needs no kernel (module-null-sink loads on a devhost) so
;; pactl set-sink-volume / set-sink-mute / list short sinks all run
;; honestly even though no sample reaches real hardware; a future
;; module-tunnel-sink to a linux box gives us a real path without
;; touching this file.  the Z piece (a /hurd/audio translator) is
;; deferred upstream and out of GEOS scope.
;;
;; this file's contract: small, sentinel-driven shell-outs via
;; `make-process'.  no `shell-command' anywhere; per project rule we
;; never wrap the call in a /bin/sh.  the binaries themselves take
;; care of their own argument parsing.
;;
;; long-term we want a tiny pid1-alsa.so that wraps snd_mixer_open
;; directly on the linux arm.  v0.4 shipped the make-process path; the
;; C module is a v0.5+ follow-up since it pulls libasound into the
;; build inputs and we have not validated that on the pinned guix
;; channel yet.  the hurd arm has no equivalent on the roadmap because
;; nothing under it is a syscall, only the pactl protocol over an
;; AF_UNIX socket the pulseaudio daemon owns.

(require 'panic)
(require 'port)

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

(defcustom audio-pactl-binary "pactl"
  "Name of the pactl binary on the hurd arm.
PATH resolution.  pactl ships in pulseaudio-utils on debian-ports
hurd-amd64; absent on a stripped image, in which case the buffer
arm falls back to the \"not implemented\" banner.  the gate is
`(executable-find audio-pactl-binary)' in every entry, so a missing
binary degrades to no-op rather than panic-spam."
  :type 'string :group 'audio)

(defcustom audio-pactl-default-sink "@DEFAULT_SINK@"
  "pactl sink reference for the default-sink verbs.
pactl exposes the magic name `@DEFAULT_SINK@' that resolves to
whatever the daemon currently treats as the default sink.  the
*audio* buffer's RET on a row overrides this with a literal sink
name so the user can pick a specific sink without having to call
`pactl set-default-sink' first."
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

;;;; pactl helpers (hurd arm)

(defvar audio--pactl-default-sink-runtime nil
  "Live override of the pactl sink name.
the *audio* buffer's RET on a row writes a literal sink name here so
later set-volume / set-mute calls hit that sink instead of
`@DEFAULT_SINK@'.  nil means \"use `audio-pactl-default-sink'\".
keep this distinct from the defcustom so a user pick survives a
`customize-set-variable' refresh, and so the value is per-emacs (not
written to custom-file).")

(defun audio--pactl-sink ()
  "Return the sink name pactl should target right now.
prefers the runtime override (set by `audio-pactl-set-default-sink')
then falls back to the defcustom."
  (or audio--pactl-default-sink-runtime
      audio-pactl-default-sink))

(defun audio-pactl-set-default-sink (sink)
  "Point subsequent pactl verbs at literal SINK name.
SINK is a string like `auto_null' from `pactl list short sinks'.
does NOT call `pactl set-default-sink' (that mutates the daemon's
global state for every client); only changes our own per-emacs
target.  pass nil to clear back to `@DEFAULT_SINK@'."
  (setq audio--pactl-default-sink-runtime sink))

(defvar audio--pactl-sync-timeout 2.0
  "Wallclock deadline in seconds for `audio--pactl-collect-sync'.
budget for one round-trip to the pulseaudio daemon.  list-short
sinks returns in well under 100 ms on a healthy daemon; the cap
exists so a wedged or absent daemon does not stall the redisplay
loop more than a beat.  on hit we return nil same as a nonzero
exit, no panic.")

(defun audio--pactl-collect-sync (args)
  "Run `pactl ARGS' under make-process and return the stdout string, or nil.
synchronous-by-pump: spawns through `make-process' (project rule, no
call-process to a shell), pumps `accept-process-output' until the
sentinel marks the process done or `audio--pactl-sync-timeout'
elapses.  returns:

  - the captured stdout as a string on clean (status 0) exit;
  - nil on missing binary, nonzero exit, kill-on-timeout, or any
    make-process raise routed through panic-handle.

we capture into a hidden work buffer (' *audio-pactl*) the sentinel
later kills; never `with-temp-buffer' because the process outlives
the form on the timeout path and would dangle a dead buffer ref."
  (let ((prog (audio--executable audio-pactl-binary)))
    (cond
     ((not prog) nil)
     (t
      (let* ((buf (generate-new-buffer " *audio-pactl*"))
             (done nil)
             (ok   nil)
             (proc nil))
        (unwind-protect
            (condition-case err
                (progn
                  (setq proc
                        (make-process
                         :name "audio:pactl-sync"
                         :command (cons prog args)
                         :buffer buf
                         :noquery t
                         :connection-type 'pipe
                         :sentinel
                         (lambda (p _ev)
                           (when (memq (process-status p)
                                       '(exit signal closed failed))
                             (setq done t
                                   ok (and (eq (process-status p) 'exit)
                                           (zerop (process-exit-status p))))))))
                  (let ((deadline (+ (float-time)
                                     audio--pactl-sync-timeout)))
                    (while (and (not done)
                                (< (float-time) deadline))
                      (accept-process-output proc 0.05)))
                  (cond
                   ((not done)
                    (ignore-errors (delete-process proc))
                    nil)
                   (ok
                    (with-current-buffer buf (buffer-string)))
                   (t nil)))
              (error
               (panic-handle err 'audio--pactl-collect-sync)
               nil))
          (when (buffer-live-p buf) (kill-buffer buf))))))))

(defun audio--pactl-spawn-async (args)
  "Spawn `pactl ARGS' fire-and-forget via `audio--spawn'.
the set-volume / set-mute verbs don't need a return value; we want
the round-trip to not block the redisplay.  sentinel = ignore;
panic-handle catches make-process raises through audio--spawn."
  (let ((prog (audio--executable audio-pactl-binary)))
    (when prog
      (audio--spawn prog args))))

(defun audio--parse-pactl-list-short-sinks (text)
  "Parse `pactl list short sinks' TEXT into a list of (INDEX . NAME).
canonical line shape is tab-separated:

  INDEX<TAB>NAME<TAB>MODULE<TAB>FORMAT<TAB>STATE

we only keep INDEX and NAME; the module and state belong in a richer
view that does not exist yet.  blank lines and lines that fail to
split into at least two fields are dropped silently (defensive
against future pactl versions adding header rows)."
  (let ((out '()))
    (dolist (line (split-string (or text "") "\n" t))
      (let ((fields (split-string line "\t")))
        (when (and (>= (length fields) 2)
                   (string-match-p "\\`[0-9]+\\'" (nth 0 fields)))
          (push (cons (string-to-number (nth 0 fields))
                      (nth 1 fields))
                out))))
    (nreverse out)))

(defun audio--list-cards-hurd ()
  "Hurd backend for `audio-list-cards'.  reads `pactl list short sinks'.
returns a list of (INDEX . NAME) tuples mirroring the linux arm's
shape so `buffers/audio.el' can render the same row format on either
kernel.  when pactl is absent (no pulseaudio-utils installed), routes
`geos-port-unimplemented' and returns nil so the buffer falls through
to the banner.  when pactl is present but the daemon is not running,
also returns nil; the buffer renders an empty list, no panic spam."
  (let ((prog (audio--executable audio-pactl-binary)))
    (cond
     ((not prog)
      (geos-port-unimplemented 'audio-list-cards-hurd-pactl-missing))
     (t
      (let ((text (audio--pactl-collect-sync '("list" "short" "sinks"))))
        (cond
         ((null text) nil)
         (t (audio--parse-pactl-list-short-sinks text))))))))

;;;; volume + mute

(defun audio--volume-linux (level control card)
  "Linux backend: amixer sset CONTROL on CARD to LEVEL%.
extracted so the kernel dispatch in `audio-volume' reads cleanly."
  (let* ((c (or control audio-default-control))
         (k (or card audio-default-card))
         (lvl (max 0 (min 100 level)))
         (prog (audio--executable audio-amixer-binary)))
    (audio--spawn prog (list "-c" k "sset" c (format "%d%%" lvl)))))

(defun audio--volume-hurd (level)
  "Hurd backend: pactl set-sink-volume SINK LEVEL%.
no control/card concept: pactl operates on sinks, not on per-card
mixer controls.  gated on pactl presence; degrades to no-op when
absent (the linux arm gets the same shape when amixer is missing,
via audio--spawn's nil-program panic route)."
  (let* ((prog (audio--executable audio-pactl-binary))
         (lvl  (max 0 (min 100 level))))
    (cond
     ((not prog)
      (geos-port-unimplemented 'audio-volume-hurd-pactl-missing))
     (t
      (audio--pactl-spawn-async
       (list "set-sink-volume" (audio--pactl-sink) (format "%d%%" lvl)))))))

(defun audio-volume (level &optional control card)
  "Set audio volume to LEVEL percent (0..100).
dispatches on `geos-kernel'.  linux arm runs `amixer -c CARD sset
CONTROL LEVEL%' through make-process (CONTROL defaults to
`audio-default-control', CARD to `audio-default-card').  hurd arm
runs `pactl set-sink-volume @DEFAULT_SINK@ LEVEL%' and ignores
CONTROL/CARD (pactl has no per-card mixer concept)."
  (interactive
   (list (read-number "Volume (0-100): " 50)))
  (cond
   ((geos-kernel-linux-p) (audio--volume-linux level control card))
   ((geos-kernel-hurd-p)  (audio--volume-hurd level))
   (t (geos-port-unimplemented 'audio-volume))))

(defun audio--mute-toggle-linux (control card)
  "Linux backend: amixer sset CONTROL on CARD toggle.
extracted symmetric to `audio--volume-linux'."
  (let* ((c (or control audio-default-control))
         (k (or card audio-default-card))
         (prog (audio--executable audio-amixer-binary)))
    (audio--spawn prog (list "-c" k "sset" c "toggle"))))

(defun audio--mute-toggle-hurd ()
  "Hurd backend: pactl set-sink-mute SINK toggle.
pactl's `toggle' argument flips the current state, same shape as
amixer's `toggle'.  gated on pactl presence."
  (let ((prog (audio--executable audio-pactl-binary)))
    (cond
     ((not prog)
      (geos-port-unimplemented 'audio-mute-toggle-hurd-pactl-missing))
     (t
      (audio--pactl-spawn-async
       (list "set-sink-mute" (audio--pactl-sink) "toggle"))))))

(defun audio-mute-toggle (&optional control card)
  "Toggle mute on the current sink/control.
dispatches on `geos-kernel'.  linux arm runs `amixer sset CONTROL
toggle' on CARD; hurd arm runs `pactl set-sink-mute @DEFAULT_SINK@
toggle' and ignores CONTROL/CARD."
  (interactive)
  (cond
   ((geos-kernel-linux-p) (audio--mute-toggle-linux control card))
   ((geos-kernel-hurd-p)  (audio--mute-toggle-hurd))
   (t (geos-port-unimplemented 'audio-mute-toggle))))

(defun audio-play-file (path)
  "Play PATH via aplay (linux) / paplay (hurd) through make-process.
no progress feedback today; a future *audio* buffer can hook a
process filter onto the spawn for that.  PATH must already be a
WAV/FLAC/PCM file the binary understands.  on hurd with no
pulseaudio-utils installed, routes `geos-port-unimplemented' and
returns nil."
  (interactive "fAudio file: ")
  (cond
   ((geos-kernel-linux-p)
    (let ((prog (audio--executable audio-aplay-binary)))
      (audio--spawn prog (list (expand-file-name path)))))
   ((geos-kernel-hurd-p)
    (let ((prog (audio--executable "paplay")))
      (cond
       ((not prog)
        (geos-port-unimplemented 'audio-play-file-hurd-paplay-missing))
       (t (audio--spawn prog (list (expand-file-name path)))))))
   (t (geos-port-unimplemented 'audio-play-file))))

(defun audio-play-sample (name)
  "Play named pulseaudio sample NAME via `pactl play-sample'.
hurd-only verb: pactl maintains a cached set of named samples
loaded via `module-loopback' or `pactl upload-sample'.  no linux
analogue here (alsa-utils has no sample cache); on linux this
routes `geos-port-unimplemented' and returns nil so callers know.

no *audio* buffer key wires this today; the entry point exists so
a future test-tone affordance has a verb to call."
  (interactive "sSample name: ")
  (cond
   ((geos-kernel-hurd-p)
    (let ((prog (audio--executable audio-pactl-binary)))
      (cond
       ((not prog)
        (geos-port-unimplemented 'audio-play-sample-pactl-missing))
       (t (audio--pactl-spawn-async (list "play-sample" name))))))
   (t (geos-port-unimplemented 'audio-play-sample))))

;;;; minimal sysfs reader

(defun audio-set-default-card (card)
  "Set `audio-default-card' to CARD (string).
public setter so other files can repoint the default sink without
fighting the defcustom-from-foreign-file byte-compile warning."
  (setq audio-default-card card))

(defun audio--list-cards-linux ()
  "Linux backend for `audio-list-cards'.  Reads /proc/asound/cards.
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

(defun audio-list-cards ()
  "Return a list of (INDEX . NAME) tuples for visible audio sinks/cards.
Dispatches on `geos-kernel'.  Linux reads /proc/asound/cards.  Hurd
shells out to `pactl list short sinks' via `audio--list-cards-hurd';
when pactl is absent (no pulseaudio-utils in the image) the hurd
backend routes `geos-port-unimplemented' and returns nil so callers
fall through cleanly (the *audio* buffer already renders \"no
cards visible\" on a nil return).  any other kernel value lands in
`geos-port-unimplemented' as before.

note the small dishonesty: on hurd the rows are pulse sinks, not
cards.  for a UI that asks \"what can I play out of?\" the
distinction is invisible; for a future tooltip layer we will widen
the shape to carry `:source-kind' so the renderer can label."
  (cond
   ((geos-kernel-linux-p) (audio--list-cards-linux))
   ((geos-kernel-hurd-p)  (audio--list-cards-hurd))
   (t (geos-port-unimplemented 'audio-list-cards))))

(provide 'userland-audio)
;;; audio.el ends here
