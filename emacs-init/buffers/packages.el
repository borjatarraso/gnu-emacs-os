;;; packages.el --- *packages* buffer, the live UI for the system profile manifest -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; what does it show: the set of packages installed in the current
;; system profile, parsed from /run/current-system/profile/manifest.
;; columns are NAME, VERSION, OUTPUT, STORE-PATH (truncated). only
;; top-level entries from the manifest's `packages' form are listed,
;; not their propagated-inputs. those are dependencies, not what the
;; admin asked for.
;;
;; how does it refresh: not on a timer. the manifest only changes when
;; somebody runs `guix system reconfigure', which we do not do at
;; runtime. cached on first `M-x packages', `g' rereads from disk.
;;
;; what can the user do here: `g' reread, `/' filter by regex against
;; the NAME column, `RET' pop a *package-entry* buffer with the full
;; manifest sexp for the row, `q' bury (concept buffers do not die).
;;
;; what breaks if the source disappears: on a non-Guix host, or before
;; pid1 has linked /run/current-system, the manifest file is missing.
;; we render a single line "no manifest, are you on guix?" and do not
;; signal. genuine read/parse failures route through `panic-handle'.

(require 'panic)

(defvar packages-buffer-name "*packages*"
  "Name of the canonical installed-packages buffer.
Per project convention this buffer is conceptually unkillable;
`q' buries it.")

(defvar packages-buffer-entry-name "*package-entry*"
  "Name of the popup buffer that shows the raw sexp for one entry.")

(defvar packages-buffer-manifest-path "/run/current-system/profile/manifest"
  "Path to the system profile manifest sexp.
Linked into place by pid1's link_current_system. on a dev host
running plain emacs -Q this file is absent and the buffer
degrades to a one-line notice.")

(defvar packages-buffer-user-profile-path
  (expand-file-name ".guix-profile/manifest" "~")
  "Path to the user profile manifest sexp.
Per-user mutable profile that `guix package -i' / `guix package -r'
scribble.  Optional: if absent, the user-profile section just shows
\"(no user profile yet)\" and `i' creates it on first install.")

(defvar packages-buffer-guix-binary "guix"
  "Name of the guix binary to invoke for install/remove operations.
Resolved via `executable-find' at the call site so PATH from
/run/current-system/profile/bin wins.  Override this for tests.")

(defvar packages-buffer-build-buffer-name "*guix-build*"
  "Name of the buffer that receives stdout/stderr from `guix package'.")

(defvar packages-buffer--user-cache nil
  "Cached parsed user-profile entries from the last manifest read.
Same shape as `packages-buffer--cache'.")

(defvar packages-buffer--user-state nil
  "One of nil, `ok', `missing', `error'.  Mirrors --state for the user.")

(defvar packages-buffer--build-process nil
  "Currently-running guix package install/remove process, or nil.
Single-slot lock: a second invocation while this is non-nil is
refused.  Cleared from the sentinel.")

(defvar packages-buffer--cache nil
  "Cached parsed package entries from the last manifest read.
List of plists with :name :version :output :store :raw. nil
before the first successful parse, or after a read failure.")

(defvar packages-buffer--state nil
  "One of nil, `ok', `missing', `error'.
Drives what the renderer prints. separated from the cache so a
failed reread does not silently keep showing stale data.")

(defvar-local packages-buffer--filter nil
  "Buffer-local regex filter. nil means show everything.")

(defun packages-buffer--read-one-manifest (path)
  "Read and parse one manifest at PATH.
Returns (cons STATE ENTRIES) where STATE is one of `ok', `missing',
`error'.  Errors route through `panic-handle' and yield (`error' . nil)."
  (cond
   ((not (file-exists-p path))
    (cons 'missing nil))
   (t
    (condition-case err
        (let ((sexp (with-temp-buffer
                      (insert-file-contents path)
                      ;; bind read-circle nil so a manifest with #N=
                      ;; circular markers cannot allocate unbounded
                      ;; structure inside our process.  guix's manifest
                      ;; format does not use circulars in practice but
                      ;; the user's `guix package -e' form is sourced
                      ;; from disk and we do not control its contents.
                      (let ((read-circle nil))
                        (read (current-buffer))))))
          (cons 'ok (packages-buffer--extract-top-level sexp)))
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err 'packages-buffer-read))
       (cons 'error nil))))))

(defun packages-buffer--read-manifest ()
  "Read both system and user manifests; populate caches and state slots.
Returns the system state symbol (preserved for old callers)."
  (let ((sys (packages-buffer--read-one-manifest
              packages-buffer-manifest-path))
        (usr (packages-buffer--read-one-manifest
              packages-buffer-user-profile-path)))
    (setq packages-buffer--cache       (cdr sys)
          packages-buffer--state       (car sys)
          packages-buffer--user-cache  (cdr usr)
          packages-buffer--user-state  (car usr)))
  packages-buffer--state)

(defun packages-buffer--extract-top-level (sexp)
  "Pull the top-level package entries out of a parsed manifest SEXP.
Manifest shape, observed on a live guix system:

  (manifest
    (version 4)
    (packages
      ((NAME VERSION OUTPUT STORE-PATH . EXTRAS)
       (NAME VERSION OUTPUT STORE-PATH . EXTRAS)
       ...)))

EXTRAS may carry (search-paths ...) or (propagated-inputs ...).
we ignore them for the row view; RET shows the whole entry. we
deliberately do NOT recurse into propagated-inputs: those are
dependencies, not what the admin declared.

return value is a list of plists, sorted by name ascending."
  (let* ((pkgs-form (assoc 'packages (cdr sexp)))
         (entries (and pkgs-form (cadr pkgs-form)))
         (out '()))
    (dolist (e entries)
      ;; defensive: skip anything that does not look like a
      ;; (NAME VERSION OUTPUT STORE . _) tuple. malformed manifests
      ;; should not crash the renderer.
      (when (and (listp e)
                 (>= (length e) 4)
                 (stringp (nth 0 e))
                 (stringp (nth 1 e))
                 (stringp (nth 2 e))
                 (stringp (nth 3 e)))
        (push (list :name    (nth 0 e)
                    :version (nth 1 e)
                    :output  (nth 2 e)
                    :store   (nth 3 e)
                    :raw     e)
              out)))
    (sort out (lambda (a b)
                (string< (plist-get a :name)
                         (plist-get b :name))))))

(defun packages-buffer--truncate-store (path)
  "Truncate a /gnu/store path for column display.
We strip the leading /gnu/store/ and cap at 48 chars. the full
path is on the row's text properties for RET."
  (let* ((stripped (if (string-prefix-p "/gnu/store/" path)
                       (substring path (length "/gnu/store/"))
                     path))
         (max 48))
    (if (> (length stripped) max)
        (concat (substring stripped 0 (- max 3)) "...")
      stripped)))

(defun packages-buffer--matches-filter-p (entry)
  "Return non-nil if ENTRY's :name matches the active filter.
No filter means everything matches."
  (or (null packages-buffer--filter)
      (string-match-p packages-buffer--filter
                      (plist-get entry :name))))

(defun packages-buffer--render-section (label state cache profile-tag)
  "Render one profile section into the current buffer.
LABEL is the human heading (\"system profile\", \"user profile\").
STATE / CACHE come from one of the read slots.  PROFILE-TAG is
either `system' or `user' and ends up on each row's text properties
so the action keys know whether removal is allowed."
  (insert (format "\n=== %s ===\n" label))
  (pcase state
    ('missing
     (insert (format "  (no manifest at %s)\n"
                     (if (eq profile-tag 'system)
                         packages-buffer-manifest-path
                       packages-buffer-user-profile-path))))
    ('error
     (insert "  manifest read failed, see *panic*\n"))
    ('ok
     (insert (format "  %-32s %-14s %-8s %s\n"
                     "name" "version" "output" "store"))
     (let ((shown 0))
       (dolist (p cache)
         (when (packages-buffer--matches-filter-p p)
           (let* ((row (append p (list :profile profile-tag)))
                  (line (format "  %-32s %-14s %-8s %s"
                                (plist-get p :name)
                                (plist-get p :version)
                                (plist-get p :output)
                                (packages-buffer--truncate-store
                                 (plist-get p :store)))))
             (insert (propertize line 'packages-entry row) "\n")
             (setq shown (1+ shown)))))
       (when (zerop shown)
         (insert "  (no rows match filter)\n"))))
    (_
     (insert "  uninitialised\n"))))

(defun packages-buffer--render ()
  "Repaint the current buffer from the system + user caches.
Honours the buffer-local filter. wrapped in `condition-case' so
a render glitch routes through panic without killing the buffer."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col  (current-column)))
    (erase-buffer)
    (setq header-line-format
          (format "*packages*  sys:%s  user:%s%s%s"
                  (pcase packages-buffer--state
                    ('ok (format "%d" (length packages-buffer--cache)))
                    ('missing "-")
                    ('error "ERR")
                    (_ "?"))
                  (pcase packages-buffer--user-state
                    ('ok (format "%d" (length packages-buffer--user-cache)))
                    ('missing "-")
                    ('error "ERR")
                    (_ "?"))
                  (if packages-buffer--filter
                      (format "  filter:%s" packages-buffer--filter)
                    "")
                  (if packages-buffer--build-process
                      "  [build running]"
                    "")))
    (condition-case err
        (progn
          (insert "  i install   D remove (user only)   g refresh   "
                  "/ filter   RET inspect   q bury\n")
          (packages-buffer--render-section
           "system profile (immutable until reconfigure)"
           packages-buffer--state packages-buffer--cache 'system)
          (packages-buffer--render-section
           "user profile (mutable via guix package)"
           packages-buffer--user-state packages-buffer--user-cache 'user))
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err 'packages-buffer-render))
       (insert "render failed, see *panic*\n")))
    (goto-char (point-min))
    (forward-line (1- start-line))
    (move-to-column start-col)))

(defun packages-buffer-refresh ()
  "Reread the manifest from disk and repaint. Bound to `g'."
  (interactive)
  (let ((buf (get-buffer packages-buffer-name)))
    (when buf
      (with-current-buffer buf
        (packages-buffer--read-manifest)
        (packages-buffer--render)))))

(defun packages-buffer-filter (regex)
  "Set the buffer-local filter REGEX and repaint. Bound to `/'.
Empty input clears the filter."
  (interactive
   (list (read-string "filter regex (empty to clear): "
                      packages-buffer--filter)))
  (setq packages-buffer--filter
        (if (string-empty-p regex) nil regex))
  (packages-buffer--render))

(defun packages-buffer-entry-at-point ()
  "Return the entry plist stored on the current line, or nil."
  (get-text-property (line-beginning-position) 'packages-entry))

(defun packages-buffer-show-entry ()
  "Pop a buffer with the full manifest sexp for the row at point.
Bound to `RET'. silently no-ops on header / blank lines."
  (interactive)
  (let ((entry (packages-buffer-entry-at-point)))
    (when entry
      (let ((buf (get-buffer-create packages-buffer-entry-name)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (special-mode)
            (insert (format "name:    %s\n" (plist-get entry :name)))
            (insert (format "version: %s\n" (plist-get entry :version)))
            (insert (format "output:  %s\n" (plist-get entry :output)))
            (insert (format "store:   %s\n\n" (plist-get entry :store)))
            (insert "raw manifest entry:\n\n")
            (let ((print-length nil)
                  (print-level nil))
              (pp (plist-get entry :raw) (current-buffer)))
            (goto-char (point-min))))
        (display-buffer buf)))))

(defun packages-buffer--build-buffer ()
  "Get-or-create the shared *guix-build* buffer in fundamental-ish mode."
  (let ((buf (get-buffer-create packages-buffer-build-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (setq truncate-lines nil))
    buf))

(defun packages-buffer--build-sentinel (proc event)
  "Sentinel for the guix package process.
On exit clears the lock, refreshes the *packages* buffer, and
appends a status line to *guix-build*.  EVENT is the standard
sentinel string (`finished\n', `exited abnormally with code N\n')."
  (let ((status (process-exit-status proc))
        (op (process-get proc 'packages-op))
        (target (process-get proc 'packages-target)))
    (with-current-buffer (packages-buffer--build-buffer)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n--- %s %s: %s (exit=%d)\n"
                        op target
                        (string-trim event)
                        status))))
    (setq packages-buffer--build-process nil)
    (let ((buf (get-buffer packages-buffer-name)))
      (when buf
        (with-current-buffer buf
          (packages-buffer--read-manifest)
          (packages-buffer--render))))
    (message "guix package %s %s: exit %d" op target status)))

(defun packages-buffer--build-filter (proc chunk)
  "Write CHUNK to *guix-build*, honoring read-only buffers."
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

(defun packages-buffer--start-guix (op target)
  "Spawn `guix package OP TARGET' via make-process. Returns the process.
OP is one of \"-i\" or \"-r\".  TARGET is a guix package name string.
Refuses if a build is already in flight."
  (when packages-buffer--build-process
    (user-error "guix package: a build is already running, see %s"
                packages-buffer-build-buffer-name))
  (let* ((bin (executable-find packages-buffer-guix-binary))
         (build-buf (packages-buffer--build-buffer)))
    (unless bin
      (panic-handle (list 'guix-not-found packages-buffer-guix-binary)
                    'packages-buffer-start-guix)
      (user-error "guix binary not found on PATH"))
    (with-current-buffer build-buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n=== guix package %s %s ===\n" op target))))
    (display-buffer build-buf)
    (let ((proc (make-process
                 :name (format "guix-package-%s" (if (string= op "-i") "i" "r"))
                 :command (list bin "package" op target)
                 :buffer build-buf
                 :noquery t
                 :connection-type 'pipe
                 :filter #'packages-buffer--build-filter
                 :sentinel #'packages-buffer--build-sentinel)))
      (process-put proc 'packages-op op)
      (process-put proc 'packages-target target)
      (setq packages-buffer--build-process proc)
      ;; refresh the header so the [build running] tag appears.
      (let ((buf (get-buffer packages-buffer-name)))
        (when buf
          (with-current-buffer buf (packages-buffer--render))))
      proc)))

(defun packages-buffer-install (name)
  "Install a package into the user profile.  Bound to `i'.
Prompts for NAME (defaults to the entry at point if any).  Spawns
`guix package -i NAME'; output streams into *guix-build*.  The
*packages* buffer auto-refreshes when the build sentinel fires."
  (interactive
   (let* ((entry (packages-buffer-entry-at-point))
          (default (and entry (plist-get entry :name))))
     (list (read-string (if default
                            (format "install (default %s): " default)
                          "install: ")
                        nil nil default))))
  (when (or (null name) (string-empty-p name))
    (user-error "install: empty package name"))
  (packages-buffer--start-guix "-i" name))

(defun packages-buffer-remove ()
  "Remove the user-profile package on the current line.  Bound to `D'.
Refuses if the row is from the system profile (those need a
reconfigure, not `guix package -r').  Asks for y-or-n confirmation."
  (interactive)
  (let ((entry (packages-buffer-entry-at-point)))
    (cond
     ((null entry)
      (user-error "no package on this line"))
     ((not (eq (plist-get entry :profile) 'user))
      (user-error
       "%s is in the system profile; use *reconfigure* to remove it"
       (plist-get entry :name)))
     ((not (yes-or-no-p
            (format "remove %s from user profile? "
                    (plist-get entry :name))))
      (message "remove: cancelled"))
     (t
      (packages-buffer--start-guix "-r" (plist-get entry :name))))))

(defun packages-buffer-quit ()
  "Bury *packages*. Per project rules we do not kill it."
  (interactive)
  (bury-buffer))

(defvar packages-buffer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g")   #'packages-buffer-refresh)
    (define-key m (kbd "/")   #'packages-buffer-filter)
    (define-key m (kbd "RET") #'packages-buffer-show-entry)
    (define-key m (kbd "i")   #'packages-buffer-install)
    (define-key m (kbd "D")   #'packages-buffer-remove)
    (define-key m (kbd "q")   #'packages-buffer-quit)
    m)
  "Keymap for `packages-buffer-mode'.")

(define-derived-mode packages-buffer-mode special-mode "Packages"
  "Major mode for the *packages* buffer.
Read-only view of the system profile manifest. see the file
commentary for the four-question contract."
  (setq truncate-lines t))

;;;###autoload
(defun packages ()
  "Display the *packages* buffer, creating it on first call.
Interactive entry point: `M-x packages'. reads the manifest on
first call only; use `g' to reread."
  (interactive)
  (let ((buf (get-buffer-create packages-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'packages-buffer-mode)
        (packages-buffer-mode))
      ;; first-call read. subsequent invocations of `M-x packages'
      ;; just bring the buffer forward; an explicit `g' is the way
      ;; to pick up a reconfigure.
      (unless packages-buffer--state
        (packages-buffer--read-manifest))
      (packages-buffer--render))
    (display-buffer buf)
    buf))

;; no supervise.el wiring: this buffer owns no timer and no long-running
;; process between user actions. the install/remove paths spawn a
;; transient guix process directly via make-process and reap it from a
;; sentinel; supervise.el's restart machinery would be wrong here
;; because a failed `guix package -i' should NOT be respawned. if a
;; future revision adds an inotify watch on /run/current-system, that
;; watcher would be the right place for a defservice entry.

(provide 'packages-buffer)
;;; packages.el ends here
