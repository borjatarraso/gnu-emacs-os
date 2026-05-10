;;; boot-marker.el --- write boot sentinels to /dev/console -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; smoke-test gate.  /iso-build/smoke-test.sh boots the qcow2 with the
;; serial console wired to a tmpfile and greps it for sentinel
;; strings.  pid1 emits its own markers (X server up, etc) which prove
;; the supervisor reached its main loop.  what those markers do NOT
;; prove is that emacs got past the -l chain and into the userland.
;; an init.el that errors on file load, or a panic.el that swallows
;; the error and leaves the rest of the chain unevaluated, would
;; still pass a pid1-only smoke test.
;;
;; this file closes that gap.  loaded LAST in the boot gexp's -l
;; chain (see system.scm).  if it ran, every previous -l ran too,
;; modulo errors that panic.el reported but did not abort.  it writes
;; "geos: emacs userland up" to /dev/console synchronously, then
;; arms a hook on exwm-init-hook that emits "geos: exwm up" once the
;; window manager grabs root (UI mode only; in console mode that hook
;; never fires and that is fine).
;;
;; failure mode: when /dev/console is not writable (interactive emacs
;; on a dev host, no module loaded, etc) the writes are silently
;; skipped.  the markers exist for the smoke test, not for users.

(require 'panic)

(defvar boot-marker--console "/dev/console"
  "Where the smoke-test serial console lives during boot.
defvar (not defconst) so a test harness can rebind it.")

(defvar boot-marker--cmdline "/proc/cmdline"
  "Where we look for the geos.mode= boot token.")

(defun boot-marker--in-boot-emacs-p ()
  "Return non-nil iff this emacs was spawned by GEOS PID 1.
We probe /proc/cmdline for the geos.mode= token that pid1 itself
parses. that token is unique to our boot path; a dev-host emacs
loaded interactively will not match.  also handles the case where
/proc/cmdline is unreadable (non-Linux dev host) by returning nil."
  (and (file-readable-p boot-marker--cmdline)
       (condition-case _
           (let ((coding-system-for-read 'binary))
             (with-temp-buffer
               (insert-file-contents boot-marker--cmdline)
               (goto-char (point-min))
               ;; anchor on the start of cmdline or a literal space.
               ;; \b alone misfires on tokens like "not-geos.mode="
               ;; because the dash-to-letter is also a word boundary.
               (re-search-forward
                "\\(?:^\\|[ \t]\\)geos\\.mode=" nil t)))
         (error nil))))

(defun boot-marker--write (msg)
  "Append MSG and a newline to `boot-marker--console'.
Returns t on success, nil on any degraded path.  errors are caught
and reported through `panic-handle' so a regression in `write-region'
does not silently swallow the smoke-test signal, but never raise:
this code runs during boot and must not derail it."
  (cond
   ;; dev-host gate. file-writable-p on /dev/console can return t for
   ;; root or permissive perms, which would pollute the dev tty every
   ;; time the file gets loaded interactively. instead probe
   ;; /proc/cmdline for the geos.mode= token that only PID 1's boot
   ;; sets. Guix's /run/booted-system would also work, but we have no
   ;; activate.scm step (no shepherd) so that path never appears.
   ((not (boot-marker--in-boot-emacs-p))
    nil)
   ((not (file-writable-p boot-marker--console))
    nil)
   (t
    (condition-case err
        (let ((coding-system-for-write 'utf-8)
              (write-region-inhibit-fsync t))
          (write-region (concat msg "\n") nil boot-marker--console
                        t 'silent)
          t)
      (error
       ;; never raise from here, but leave a breadcrumb in *panic*
       ;; so a regression in the write path does not silently kill
       ;; the smoke-test signal.
       (when (fboundp 'panic-handle)
         (panic-handle err 'boot-marker--write))
       nil)))))

(defun boot-marker--emit-userland ()
  "Emit the userland-up sentinel."
  (boot-marker--write "geos: emacs userland up"))

(defun boot-marker--emit-exwm ()
  "Emit the exwm-up sentinel."
  (boot-marker--write "geos: exwm up"))

;; load-time emit.  by the time this file is being loaded every
;; previous -l in the boot gexp has run; if any of them errored,
;; panic.el either rerouted to *panic* and continued or escalated.
(boot-marker--emit-userland)

;; arm the exwm marker.  with-eval-after-load does not fire if the
;; package is loaded BEFORE this hook is added; in our boot order
;; exwm-config.el (which requires exwm) runs earlier in the -l chain,
;; so we cannot rely on it.  add-hook directly: exwm-init-hook is
;; defvar'd inside exwm-core.el, which exwm-config.el has already
;; loaded by the time we get here.  guard boundp anyway: in console
;; mode exwm-config skips (require 'exwm), so the hook is unbound
;; and we silently move on (no exwm in console mode is by design).
(if (boundp 'exwm-init-hook)
    (add-hook 'exwm-init-hook #'boot-marker--emit-exwm)
  ;; route the skip notice through the same console writer so it
  ;; lands somewhere greppable instead of being drowned in
  ;; *Messages*.
  (boot-marker--write
   "boot-marker: exwm-init-hook unbound, skipping exwm sentinel"))

(provide 'boot-marker)
;;; boot-marker.el ends here
