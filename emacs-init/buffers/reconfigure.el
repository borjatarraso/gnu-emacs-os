;;; reconfigure.el --- *reconfigure* buffer, the live UI for guix system reconfigure -*- lexical-binding: t -*-
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

;; what does it show: three short sections in one read-only buffer.
;; first is the active-system pointer (resolved store path of
;; /run/current-system, plus the symlink target so the user can see
;; the generation file).  second is the list of system generations
;; under /var/guix/profiles/ (NUMBER, MTIME, STORE-PATH).  third is
;; the source-file slot (the path the next reconfigure will read,
;; defaulting to /var/emacs/reconfigure/system.scm).
;;
;; how does it refresh: not on a timer.  generations only change
;; when the user runs reconfigure or switch-generation.  `g'
;; rereads on demand, the build sentinel auto-refreshes when it
;; fires.
;;
;; what can the user do here: `r' prompt for a path then spawn
;; `guix system reconfigure PATH' via make-process; output streams
;; into *system-build*, the sentinel refreshes the generations
;; list on success.  `s' on a generation row switches GRUB's
;; default to that generation via `guix system switch-generation N'
;; (does NOT reboot; the next boot picks it up).  `e' opens the
;; current source path with `find-file' so the user can edit it.
;; `RET' on a generation row pops a details buffer.  `g' refresh,
;; `q' bury.
;;
;; what breaks if the source disappears: /var/guix/profiles/ is
;; created by guix on first profile activation and effectively
;; always present.  /run/current-system is linked by pid1 at boot;
;; if it is missing the active-system slot renders "(unset)" and
;; the buffer still works.  the source path is operator-controlled;
;; we never read or scribble it without an explicit `r' or `e'.

(require 'panic)

(defvar reconfigure-buffer-name "*reconfigure*"
  "Name of the canonical reconfigure UI buffer.")

(defvar reconfigure-build-buffer-name "*system-build*"
  "Name of the buffer that receives stdout/stderr from `guix system'.")

(defvar reconfigure-current-system-link "/run/current-system"
  "Symlink to the active system generation's store path.
Linked by `link_current_system' in pid1 at boot.  If absent (dev
host, plain emacs), the buffer renders \"(unset)\" but still works.")

(defvar reconfigure-profiles-dir "/var/guix/profiles"
  "Directory holding system-*-link generation symlinks.")

(defvar reconfigure-default-source-path "/var/emacs/reconfigure/system.scm"
  "Default path to the system.scm a reconfigure reads from.
Lives under /var/emacs/ so it survives reboots when /var is on
ext4 (see STATE_LAYOUT.md).  The user is free to point reconfigure
at a different file via the `r' prompt.")

(defvar reconfigure-guix-binary "guix"
  "Name of the guix binary to invoke.  Resolved via `executable-find'.")

(defvar reconfigure--build-process nil
  "Currently-running guix system process, or nil.
Single-slot lock: a second invocation while non-nil is refused.")

(defvar reconfigure--source-path nil
  "Last source path the user picked, persisted across `r' invocations
within the session.  nil means use `reconfigure-default-source-path'.")

(defvar reconfigure--generations nil
  "Cached list of generation plists from the last read.")

(defvar reconfigure--current-target nil
  "Resolved `file-truename' of `reconfigure-current-system-link'.
nil if the symlink is absent.")

;; -- generation listing ------------------------------------------------------

(defun reconfigure--read-generations ()
  "Scan `reconfigure-profiles-dir' for system-N-link entries.
Returns a list of plists (:number :mtime :path :store) sorted by
number descending.  Errors route through panic-handle and yield nil."
  (condition-case err
      (let ((dir reconfigure-profiles-dir)
            (out '()))
        (when (file-directory-p dir)
          (dolist (f (directory-files dir t "\\`system-[0-9]+-link\\'"))
            (let* ((name (file-name-nondirectory f))
                   (num (and (string-match "system-\\([0-9]+\\)-link" name)
                             (string-to-number (match-string 1 name))))
                   (mtime (file-attribute-modification-time
                           (file-attributes f)))
                   (store (condition-case _
                              (file-truename f)
                            (error nil))))
              (when num
                (push (list :number num
                            :mtime mtime
                            :path f
                            :store store)
                      out)))))
        (sort out (lambda (a b)
                    (> (plist-get a :number)
                       (plist-get b :number)))))
    (error
     (when (fboundp 'panic-handle)
       (panic-handle err 'reconfigure-read-generations))
     nil)))

(defun reconfigure--read-current ()
  "Resolve `reconfigure-current-system-link', returning its truename or nil."
  (condition-case _
      (and (file-symlink-p reconfigure-current-system-link)
           (file-truename reconfigure-current-system-link))
    (error nil)))

(defun reconfigure--source ()
  "Return the active source path: per-session override or default."
  (or reconfigure--source-path reconfigure-default-source-path))

;; -- rendering ---------------------------------------------------------------

(defun reconfigure--format-mtime (mtime)
  "Format an mtime tuple for display."
  (format-time-string "%Y-%m-%d %H:%M" mtime))

(defun reconfigure--render ()
  "Repaint the current buffer from the cached generation list.
Wrapped in condition-case so a render glitch routes through panic
without killing the buffer."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col  (current-column)))
    (erase-buffer)
    (setq header-line-format
          (format "*reconfigure*  generations:%s%s"
                  (length reconfigure--generations)
                  (if reconfigure--build-process
                      "  [build running]"
                    "")))
    (condition-case err
        (progn
          (insert "  r reconfigure   s switch-generation   "
                  "e edit source   g refresh   q bury\n")
          (insert "\n=== active system ===\n")
          (insert (format "  link:  %s\n" reconfigure-current-system-link))
          (insert (format "  store: %s\n"
                          (or reconfigure--current-target "(unset)")))
          (insert "\n=== source ===\n")
          (insert (format "  path: %s\n" (reconfigure--source)))
          (insert (format "  exists: %s\n"
                          (if (file-readable-p (reconfigure--source))
                              "yes"
                            "no (run `e' to create / edit)")))
          (insert "\n=== generations ===\n")
          (cond
           ((null reconfigure--generations)
            (insert "  (no generations found, is /var/guix/profiles populated?)\n"))
           (t
            (insert (format "  %-4s %-18s %s\n" "n" "mtime" "store"))
            (dolist (g reconfigure--generations)
              (let* ((current
                      (and reconfigure--current-target
                           (string= reconfigure--current-target
                                    (plist-get g :store))))
                     (line (format "  %-4d %-18s %s%s"
                                   (plist-get g :number)
                                   (reconfigure--format-mtime
                                    (plist-get g :mtime))
                                   (or (plist-get g :store) "?")
                                   (if current "  *" ""))))
                (insert (propertize line 'reconfigure-generation g) "\n"))))))
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err 'reconfigure-render))
       (insert "render failed, see *panic*\n")))
    (goto-char (point-min))
    (forward-line (1- start-line))
    (move-to-column start-col)))

;; -- guix process --------------------------------------------------------

(defun reconfigure--build-buffer ()
  "Get-or-create the *system-build* output buffer."
  (let ((buf (get-buffer-create reconfigure-build-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (setq truncate-lines nil))
    buf))

(defun reconfigure--build-filter (proc chunk)
  "Append CHUNK to PROC's buffer, scrolling if point was at end."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (was-at-end (= (point) (point-max))))
          (save-excursion
            (goto-char (point-max))
            (insert chunk))
          (when was-at-end
            (goto-char (point-max))))))))

(defun reconfigure--build-sentinel (proc event)
  "Sentinel for the `guix system' process.  Clears the lock, refreshes."
  (let ((status (process-exit-status proc))
        (op (process-get proc 'reconfigure-op))
        (target (process-get proc 'reconfigure-target)))
    (with-current-buffer (reconfigure--build-buffer)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n--- %s %s: %s (exit=%d)\n"
                        op (or target "")
                        (string-trim event) status))))
    (setq reconfigure--build-process nil)
    (let ((buf (get-buffer reconfigure-buffer-name)))
      (when buf
        (with-current-buffer buf
          (setq reconfigure--generations (reconfigure--read-generations)
                reconfigure--current-target (reconfigure--read-current))
          (reconfigure--render))))
    (message "guix system %s: exit %d" op status)))

(defun reconfigure--start-guix (op &rest extra-args)
  "Spawn `guix system OP EXTRA-ARGS' via make-process.  Returns the process.
OP is one of \"reconfigure\" / \"switch-generation\" / \"roll-back\".
Refuses if a build is already in flight."
  (when reconfigure--build-process
    (user-error "guix system: a build is already running, see %s"
                reconfigure-build-buffer-name))
  (let* ((bin (executable-find reconfigure-guix-binary))
         (build-buf (reconfigure--build-buffer)))
    (unless bin
      (panic-handle (list 'guix-not-found reconfigure-guix-binary)
                    'reconfigure-start-guix)
      (user-error "guix binary not found on PATH"))
    (with-current-buffer build-buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n=== guix system %s %s ===\n"
                        op (mapconcat #'identity extra-args " ")))))
    (display-buffer build-buf)
    (let ((proc (make-process
                 :name (format "guix-system-%s" op)
                 :command (cons bin (cons "system" (cons op extra-args)))
                 :buffer build-buf
                 :noquery t
                 :connection-type 'pipe
                 :filter #'reconfigure--build-filter
                 :sentinel #'reconfigure--build-sentinel)))
      (process-put proc 'reconfigure-op op)
      (process-put proc 'reconfigure-target (car extra-args))
      (setq reconfigure--build-process proc)
      (let ((buf (get-buffer reconfigure-buffer-name)))
        (when buf
          (with-current-buffer buf (reconfigure--render))))
      proc)))

;; -- commands -----------------------------------------------------------

(defun reconfigure-do-reconfigure (path)
  "Spawn `guix system reconfigure PATH'.  Bound to `r'.
Prompts for PATH (defaults to the per-session source override or
`reconfigure-default-source-path').  PATH must be readable; the
guix process will fail otherwise but we check up front for a
better message."
  (interactive
   (list (read-file-name "system.scm: " nil (reconfigure--source) t
                         (file-name-nondirectory (reconfigure--source)))))
  (unless (file-readable-p path)
    (user-error "reconfigure: %s is not readable" path))
  (when (yes-or-no-p
         (format "reconfigure system from %s? this builds a new generation. "
                 path))
    (setq reconfigure--source-path path)
    (reconfigure--start-guix "reconfigure" path)))

(defun reconfigure-switch-generation ()
  "Switch GRUB's default to the generation on the current line.  Bound to `s'.
Does NOT reboot; the next boot picks up the new default.  The
running system continues on whatever generation it booted from."
  (interactive)
  (let ((g (get-text-property (line-beginning-position)
                              'reconfigure-generation)))
    (cond
     ((null g)
      (user-error "no generation on this line"))
     ((not (yes-or-no-p
            (format "switch GRUB default to generation %d? "
                    (plist-get g :number))))
      (message "switch-generation: cancelled"))
     (t
      (reconfigure--start-guix "switch-generation"
                               (number-to-string (plist-get g :number)))))))

(defun reconfigure-edit-source ()
  "Open the current source path with find-file.  Bound to `e'.
Creates the file (and parent dir) if absent so the user can start
typing directly into a buffer."
  (interactive)
  (let* ((path (reconfigure--source))
         (dir (file-name-directory path)))
    (unless (file-directory-p dir)
      (when (yes-or-no-p (format "create directory %s? " dir))
        (make-directory dir t)))
    (find-file path)))

(defun reconfigure-refresh ()
  "Reread generations and the active-system pointer.  Bound to `g'."
  (interactive)
  (let ((buf (get-buffer reconfigure-buffer-name)))
    (when buf
      (with-current-buffer buf
        (setq reconfigure--generations (reconfigure--read-generations)
              reconfigure--current-target (reconfigure--read-current))
        (reconfigure--render)))))

(defun reconfigure-quit ()
  "Bury *reconfigure*.  Per project rules we do not kill it."
  (interactive)
  (bury-buffer))

;; -- mode + entry point -----------------------------------------------------

(defvar reconfigure-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "r") #'reconfigure-do-reconfigure)
    (define-key m (kbd "s") #'reconfigure-switch-generation)
    (define-key m (kbd "e") #'reconfigure-edit-source)
    (define-key m (kbd "g") #'reconfigure-refresh)
    (define-key m (kbd "q") #'reconfigure-quit)
    m)
  "Keymap for `reconfigure-mode'.")

(define-derived-mode reconfigure-mode special-mode "Reconfigure"
  "Major mode for the *reconfigure* buffer.
See file commentary for the four-question contract."
  (setq truncate-lines t))

;;;###autoload
(defun reconfigure ()
  "Display the *reconfigure* buffer, creating it on first call.
Interactive entry point: `M-x reconfigure'.  Reads /var/guix/profiles/
and /run/current-system on first call; use `g' to refresh."
  (interactive)
  (let ((buf (get-buffer-create reconfigure-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'reconfigure-mode)
        (reconfigure-mode))
      (setq reconfigure--generations (reconfigure--read-generations)
            reconfigure--current-target (reconfigure--read-current))
      (reconfigure--render))
    (display-buffer buf)
    buf))

;; no supervise.el wiring: same rationale as packages.el.  the
;; transient guix process is spawned per-action via make-process and
;; reaped from a sentinel.  a failed reconfigure should NOT be
;; respawned; the user re-issues `r' after fixing whatever the build
;; complained about.

(provide 'reconfigure-buffer)
;;; reconfigure.el ends here
