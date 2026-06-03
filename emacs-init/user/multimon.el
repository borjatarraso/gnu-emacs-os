;;; multimon.el --- xrandr-driven workspace-to-monitor mapping -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;; phase 5c. multi-head wiring for exwm. nothing here changes the
;; single-display QEMU smoke path: with one monitor every workspace
;; lands on it and the rescan is a 4-line no-op. on real hardware the
;; rescan walks `xrandr --listmonitors', builds a workspace map, and
;; tells exwm-randr where to pin each workspace. RANDR hotplug events
;; come back into us via `exwm-randr-screen-change-hook'.
;;
;; rules I am holding myself to here:
;;   - process-file ONLY. no shell-command, ever. /no-shell-check.
;;   - errors route through panic-handle (with the fboundp gate, the
;;     same hazard core/network.el documents).
;;   - the function is idempotent. re-running rescan should converge,
;;     not flap. so we recompute the map from scratch each call rather
;;     than diffing.
;;
;; mapping policy (workspace -> monitor):
;;   1 monitor   : workspaces 0..3 all on it.
;;   2 monitors  : 0,1 on primary; 2,3 on secondary.
;;   3+ monitors : same as 2-monitor case for 0..3, ignore the rest.
;;                 a future version can spread evenly, but exwm with
;;                 4 workspaces and 3 heads is already exotic enough
;;                 to want manual control.

(require 'panic)

(defvar multimon--monitors nil
  "Cached list of monitors from the last `multimon-rescan'.
Each entry is a plist: (:name STR :primary BOOL :geometry STR).
GEOMETRY is the raw WxH+X+Y token from xrandr; we don't parse it
because exwm-randr only needs the name. nil before the first scan.")

(defvar multimon--workspace-map nil
  "Cached alist mapping workspace index (int) to monitor name (string).
Recomputed by `multimon-rescan'. fed to `exwm-randr-workspace-monitor-plist'
in the form exwm wants (a flat plist of int monitor int monitor ...).")

(defvar multimon--xrandr-program "xrandr"
  "Name of the xrandr binary to invoke via `process-file'.
Resolved against PATH by `process-file' itself; we don't pre-resolve
because PATH inside our boot env may shift between phases.")

(defvar multimon--last-failure-key nil
  "Last (rc . tail) we logged from xrandr.
Dedupes repeated failures: multimon-rescan can fire on every
randr event, and a misconfigured DISPLAY would otherwise spam
*panic* with one entry per second.  We log when the failure
shape changes (different rc, different tail) and stay silent
between transitions.")

(defun multimon--xrandr-listmonitors ()
  "Return the raw output of `xrandr --listmonitors' as a string.
nil if xrandr is not on PATH, exits non-zero, or the call itself
raises. We never let xrandr's failure mode propagate: a missing
binary on a single-head laptop is a no-op upgrade, not a panic."
  (condition-case err
      (with-temp-buffer
        (let ((rc (process-file multimon--xrandr-program
                                nil t nil "--listmonitors")))
          (cond
           ((not (numberp rc))
            ;; process-file returned a signal description, not an int.
            ;; demoted from panic to message: a stuck X server can
            ;; produce many of these per second and we do not want to
            ;; drown *panic* in noise.  the tail is captured into the
            ;; dedup key so the first instance still gets logged.
            (let ((key (cons 'signal rc)))
              (unless (equal key multimon--last-failure-key)
                (setq multimon--last-failure-key key)
                (when (fboundp 'panic-handle)
                  (panic-handle (list 'multimon-xrandr-signal rc)
                                'multimon--xrandr-listmonitors))))
            nil)
           ((/= rc 0)
            ;; non-zero exit. could mean DISPLAY isn't reachable, the
            ;; X server is mid-restart, or we are running on Xvfb which
            ;; reports 0 monitors but exits 0 anyway. dedupe so a
            ;; persistent failure logs once, not per rescan.
            (let* ((tail (buffer-string))
                   (key (cons rc tail)))
              (unless (equal key multimon--last-failure-key)
                (setq multimon--last-failure-key key)
                (when (fboundp 'panic-handle)
                  (panic-handle (list 'multimon-xrandr-rc rc tail)
                                'multimon--xrandr-listmonitors))))
            nil)
           (t
            (setq multimon--last-failure-key nil)
            (buffer-string)))))
    (error
     (let ((key (cons 'raised (car-safe err))))
       (unless (equal key multimon--last-failure-key)
         (setq multimon--last-failure-key key)
         (when (fboundp 'panic-handle)
           (panic-handle err 'multimon--xrandr-listmonitors))))
     nil)))

(defun multimon--parse-listmonitors (output)
  "Parse OUTPUT of `xrandr --listmonitors' into a list of monitor plists.
xrandr's format on the second and subsequent lines is:
  ` 0: +*HDMI-1 1920/509x1080/286+0+0  HDMI-1'
the leading `+' marks active, the `*' marks primary, the trailing
token is the connector name. we extract name, primary flag, and
the geometry token. lines that don't match the regex are skipped."
  (let ((mons '()))
    (dolist (line (and output (split-string output "\n" t)))
      ;; skip the count line ("Monitors: N") and any blank.  the
      ;; trailing capture is anchored to ([^space]+)$ rather than (.+)$
      ;; so a future xrandr that appends extra fields after the
      ;; canonical name does not capture them into :name.  if it ever
      ;; does, the regex stops matching and we drop the line, which
      ;; is preferable to handing exwm-randr a garbled monitor key.
      (when (string-match
             "^[[:space:]]*[0-9]+:[[:space:]]+\\([+]?\\)\\(\\*?\\)\\([^[:space:]]+\\)[[:space:]]+\\([^[:space:]]+\\)[[:space:]]+\\([^[:space:]]+\\)[[:space:]]*$"
             line)
        (let* ((primary (string= (match-string 2 line) "*"))
               (geom    (match-string 4 line))
               ;; the "name" capture is "+*HDMI-1" stripped to "HDMI-1".
               ;; xrandr puts the canonical connector name as the last
               ;; whitespace-separated token, so prefer that over the
               ;; potentially decorated capture.
               (name    (match-string 5 line)))
          (push (list :name name :primary primary :geometry geom)
                mons))))
    (nreverse mons)))

(defun multimon--build-workspace-map (monitors)
  "Build the workspace->monitor alist from MONITORS.
Policy: 1 monitor => everything on it. 2+ monitors => 0,1 on primary,
2,3 on first non-primary. \"primary\" defaults to the first monitor
when xrandr did not flag one."
  (cond
   ((null monitors) nil)
   ((= (length monitors) 1)
    (let ((name (plist-get (car monitors) :name)))
      `((0 . ,name) (1 . ,name) (2 . ,name) (3 . ,name))))
   (t
    (let* ((primary (or (seq-find (lambda (m) (plist-get m :primary))
                                  monitors)
                        (car monitors)))
           (secondary (or (seq-find (lambda (m)
                                      (not (eq m primary)))
                                    monitors)
                          primary))
           (pname (plist-get primary :name))
           (sname (plist-get secondary :name)))
      `((0 . ,pname) (1 . ,pname) (2 . ,sname) (3 . ,sname))))))

(defun multimon--apply-map (alist)
  "Push ALIST (workspace . monitor) into exwm-randr's plist.
exwm-randr-workspace-monitor-plist is a FLAT plist of int monitor
int monitor ..., not an alist; convert here. Setting it on a single
monitor is harmless and matches exwm's docs."
  (when (boundp 'exwm-randr-workspace-monitor-plist)
    (setq exwm-randr-workspace-monitor-plist
          (apply #'append
                 (mapcar (lambda (cell)
                           (list (car cell) (cdr cell)))
                         alist))))
  ;; ask exwm-randr to recompute its placement immediately if it can.
  ;; older releases expose `exwm-randr-refresh', newer ones
  ;; `exwm-randr--refresh'. we try both, swallow void-function on
  ;; either, because a missing helper just means the next user-visible
  ;; randr event will pick up the new plist.
  (condition-case _
      (cond
       ((fboundp 'exwm-randr-refresh)  (exwm-randr-refresh))
       ((fboundp 'exwm-randr--refresh) (exwm-randr--refresh)))
    (error nil)))

(defun multimon--trace (msg)
  "Best-effort trace to /dev/console; mirrors exwm-config's helper.
Kept local so multimon doesn't have to depend on an internal of
exwm-config.el. Errors swallowed: tracing is never the failure mode.
The write-region-inhibit-fsync bind is defensive: write-region
only fsyncs regular files (not character devices) so it is a no-op
here today, but keeping it set protects against a future emacs
that decides to flush ttys on close."
  (condition-case _
      (let ((write-region-inhibit-fsync t))
        (write-region (format "multimon: %s\n" msg)
                      nil "/dev/console" 'append 'nomsg))
    (error nil)))

(defun multimon-rescan ()
  "Re-read xrandr, recompute the workspace map, and apply it.
Interactive. Bound to `C-c e M r'. Also called from the EXWM
randr screen-change hook so hotplug Just Works on real hardware.
On a single-monitor box (the QEMU smoke test) this collapses to
one round trip and a 4-entry plist. Never raises."
  (interactive)
  (condition-case err
      (let* ((raw  (multimon--xrandr-listmonitors))
             (mons (multimon--parse-listmonitors raw))
             (map  (multimon--build-workspace-map mons)))
        (setq multimon--monitors mons
              multimon--workspace-map map)
        (multimon--apply-map map)
        (multimon--trace
         (format "rescan monitors=%d map=%S" (length mons) map))
        (when (called-interactively-p 'interactive)
          (message "multimon: %d monitor(s), map=%S"
                   (length mons) map))
        map)
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'multimon-rescan)
       (message "multimon-rescan: %S" err))
     nil)))

(defun multimon-arrange ()
  "Re-apply the cached map without re-reading xrandr.
Useful when exwm-randr's plist has been clobbered by a config
reload but the physical layout hasn't changed. If we have no
cached map (rescan never ran), fall back to a full rescan."
  (interactive)
  (condition-case err
      (if multimon--workspace-map
          (progn
            (multimon--apply-map multimon--workspace-map)
            (multimon--trace
             (format "arrange (cached) map=%S" multimon--workspace-map))
            (when (called-interactively-p 'interactive)
              (message "multimon: re-applied cached map"))
            multimon--workspace-map)
        (multimon-rescan))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'multimon-arrange)
       (message "multimon-arrange: %S" err))
     nil)))

;; key binding. s-r is already exwm-reset (taken in exwm-config.el),
;; and s-R is reachable but easy to mistype as s-r and nuke your input
;; mode. so the canonical binding is the project-standard `C-c e' map:
;; `C-c e M r' = "exwm, multimon, rescan". `C-c e M a' = arrange.
;; the `M' subprefix is reserved for monitor-related commands so we
;; can grow into `M f' (focus monitor) etc later without re-mapping.
(defvar multimon-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "r") #'multimon-rescan)
    (define-key m (kbd "a") #'multimon-arrange)
    m)
  "Keymap for multimon commands, bound under `C-c e M'.")

(global-set-key (kbd "C-c e M") multimon-map)

(provide 'multimon)
;;; multimon.el ends here
