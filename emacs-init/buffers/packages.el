;;; packages.el --- *packages* buffer, the live UI for the system profile manifest -*- lexical-binding: t -*-

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

(defun packages-buffer--read-manifest ()
  "Read and parse the manifest. Populate the cache and the state slot.
Returns the new state symbol. errors during read or parse are
routed through `panic-handle' and leave state as `error'."
  (cond
   ((not (file-exists-p packages-buffer-manifest-path))
    (setq packages-buffer--cache nil
          packages-buffer--state 'missing))
   (t
    (condition-case err
        (let ((sexp (with-temp-buffer
                      (insert-file-contents packages-buffer-manifest-path)
                      (read (current-buffer)))))
          (setq packages-buffer--cache
                (packages-buffer--extract-top-level sexp)
                packages-buffer--state 'ok))
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err 'packages-buffer-read))
       (setq packages-buffer--cache nil
             packages-buffer--state 'error)))))
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

(defun packages-buffer--render ()
  "Repaint the current buffer from `packages-buffer--cache'.
Honours the buffer-local filter. wrapped in `condition-case' so
a render glitch routes through panic without killing the buffer."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col  (current-column)))
    (erase-buffer)
    (setq header-line-format
          (format "*packages*  %s%s"
                  (pcase packages-buffer--state
                    ('ok (format "%d entries" (length packages-buffer--cache)))
                    ('missing "no manifest")
                    ('error "read failed, see *panic*")
                    (_ "uninitialised"))
                  (if packages-buffer--filter
                      (format "  filter:%s" packages-buffer--filter)
                    "")))
    (condition-case err
        (pcase packages-buffer--state
          ('missing
           (insert "no manifest, are you on guix?\n")
           (insert (format "  expected at %s\n"
                           packages-buffer-manifest-path)))
          ('error
           (insert "manifest read failed, see *panic*\n"))
          ('ok
           (insert (format "  %-32s %-14s %-8s %s\n"
                           "name" "version" "output" "store"))
           (let ((shown 0))
             (dolist (p packages-buffer--cache)
               (when (packages-buffer--matches-filter-p p)
                 (let ((line (format "  %-32s %-14s %-8s %s"
                                     (plist-get p :name)
                                     (plist-get p :version)
                                     (plist-get p :output)
                                     (packages-buffer--truncate-store
                                      (plist-get p :store)))))
                   (insert (propertize line 'packages-entry p) "\n")
                   (setq shown (1+ shown)))))
             (when (zerop shown)
               (insert "  (no rows match filter)\n"))))
          (_
           (insert "uninitialised\n")))
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

(defun packages-buffer-quit ()
  "Bury *packages*. Per project rules we do not kill it."
  (interactive)
  (bury-buffer))

(defvar packages-buffer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g")   #'packages-buffer-refresh)
    (define-key m (kbd "/")   #'packages-buffer-filter)
    (define-key m (kbd "RET") #'packages-buffer-show-entry)
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

;; TODO(6): no supervise.el wiring. this buffer owns no timer and no
;; long-running process. the manifest is a static file we read on
;; demand. if a future revision adds an inotify watch on
;; /run/current-system, register the watcher's lifecycle here.

(provide 'packages-buffer)
;;; packages.el ends here
