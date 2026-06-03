;;; state.el --- persistent state under /var/emacs/ -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;; Every concept buffer (journal, packages, network, ...) used to
;; re-derive its state from /proc on every refresh.  no scratchpad meant
;; no continuity across reboots and no place for one-shot configuration
;; to land.  this file is the scratchpad.
;;
;; on-disk layout under /var/emacs/:
;;   journal/      kmsg seq position, dropped lines counter
;;   packages/     manifest cache, install history
;;   network/      last-applied interface config
;;   users/        passwd shadow file (item 4 lands later)
;;   services/     defservice records persisted across reboots (item 2)
;;   dotfiles/     where eshell aliases and similar live
;;
;; pid1 mounts /var as ext4 if a partition labelled geos-var exists at
;; boot, else tmpfs.  on tmpfs every state-write still works but is
;; lost on reboot; that is the documented degraded mode.  state-mode
;; below tells callers which they got.
;;
;; atomicity contract: state-write writes to KEY.tmp, fsyncs the tmp
;; file, renames over KEY, then fsyncs the parent dir via the pid1
;; module's pid1-fsync-dir.  on ext4 this gives crash-consistency: a
;; reader either sees the old value or the new value, never a torn or
;; partial write.  on tmpfs the fsync is near-no-op but the rename is
;; still atomic per VFS semantics, so the write contract holds.
;;
;; values are written and read as elisp s-exprs via prin1 / read.  this
;; rules out arbitrary-byte values but keeps everything debuggable: cat
;; /var/emacs/journal/seq prints something a human can parse.

(require 'panic)
(require 'port)

(defconst state-root "/var/emacs/"
  "Root of the persistent state tree.
trailing slash so file-name-as-directory handling is uniform.
mounted by pid1 (see mount_var() in pid1/emacs-init.c).")

(defconst state--subdirs
  '("journal" "packages" "network" "users" "services" "dotfiles"
    "sessions" "lockouts")
  "Subdirectories created at boot under `state-root'.
each maps to a feature area; state keys live under one of these
prefixes by convention.  state-write does not enforce the prefix
since callers occasionally need ad-hoc paths (probes, smoke
tests), but anything user-facing should live under one of these.")

(defvar state-mode nil
  "Either \\='persistent (ext4 under /var) or \\='tmpfs (lost on reboot)
or nil if state-root is not writable.  set by `state--detect-mode'
called from `state--ensure-layout'.  buffer modes display this in
the header line so the user knows whether their actions survive a
poweroff.")

(defun state--detect-mode-linux ()
  "Linux backend for `state--detect-mode'.
Reads /proc/mounts to find what is on /var.  /proc may be missing on
a degraded dev host; degrade to nil silently."
  (condition-case _
      (with-temp-buffer
        (insert-file-contents "/proc/mounts")
        (goto-char (point-min))
        (cond
         ((re-search-forward "^[^ ]+ /var tmpfs " nil t) 'tmpfs)
         ((re-search-forward "^[^ ]+ /var ext4 " nil t) 'persistent)
         ((file-writable-p state-root) 'tmpfs)
         (t nil)))
    (error nil)))

(defun state--detect-mode-hurd ()
  "Hurd backend for `state--detect-mode'.
The Hurd procfs translator exposes /proc/mounts too; the contents
differ from Linux (an ext2fs translator settles /var instead of an
ext4 driver, or there is no /var line at all because /var is just a
subtree of the root translator), but the file shape is the same so
the same read works.  i accept the hurd-native mount types as-is:
ext2fs/ext3/ext4 all mean \\='persistent here, tmpfs (unlikely but
not impossible) means \\='tmpfs, and a missing /var line falls
through to a writable-probe of state-root.  no special-case parsing
beyond the type alternation; absent /proc nodes are a normal-case
degraded mode, not a panic."
  (condition-case _
      (with-temp-buffer
        (insert-file-contents "/proc/mounts")
        (goto-char (point-min))
        (cond
         ((re-search-forward "^[^ ]+ /var tmpfs " nil t) 'tmpfs)
         ((re-search-forward "^[^ ]+ /var ext[234]\\(?:fs\\)? " nil t) 'persistent)
         ((file-writable-p state-root) 'tmpfs)
         (t nil)))
    (error
     ;; /proc/mounts not present (no procfs translator yet, or a
     ;; stripped recovery boot).  fall back to the writable-probe
     ;; so persistence-aware buffers still see something usable.
     (if (file-writable-p state-root) 'tmpfs nil))))

(defun state--detect-mode ()
  "Set `state-mode' to \\='persistent, \\='tmpfs, or nil.
Dispatches on `geos-kernel'.  on linux, reads /proc/mounts and
matches ext4/tmpfs.  on hurd, reads the same /proc/mounts (the
procfs translator exposes it) and matches ext2fs/ext3/ext4/tmpfs,
falling back to a writable-probe if no /var line is present.  on
an unknown kernel we still route the miss through
`geos-port-unimplemented' so the post-mortem shows which kernel
failed."
  (setq state-mode
        (cond
         ((geos-kernel-linux-p)
          (state--detect-mode-linux))
         ((geos-kernel-hurd-p)
          (state--detect-mode-hurd))
         (t
          (geos-port-unimplemented 'state-detect-mode)
          nil))))

(defun state-path (key)
  "Return the absolute path for state KEY.
KEY is a relative path like \"journal/seq\".  no encoding: the
caller is responsible for keeping KEY safe (no leading slash, no
.. segments).  state-write rejects unsafe keys via `state--safe-key-p'."
  (concat state-root key))

(defun state--safe-key-p (key)
  "Return non-nil if KEY is a safe relative state path.
forbids absolute paths, .. segments, and control bytes.  the goal
is not security against a hostile elisp caller (none exists in this
tree) but cheap defence against bugs that would otherwise scribble
outside /var/emacs."
  (and (stringp key)
       (not (string-empty-p key))
       (not (string-prefix-p "/" key))
       (not (string-match-p "\\.\\." key))
       (not (string-match-p "[\x00-\x1f]" key))))

(defun state--ensure-dir (path)
  "make-directory PATH parents=t, panic-handle on error.
returns t on success, nil on failure."
  (condition-case err
      (progn
        (unless (file-directory-p path)
          (make-directory path t))
        t)
    (error
     (when (fboundp 'panic-handle)
       (panic-handle err `(state--ensure-dir . ,path)))
     nil)))

(defun state--ensure-layout ()
  "Create /var/emacs and the standard subdirs.
called from early-init.el after `user-emacs-directory' is set.
idempotent: every directory is mkdir-with-parents.  panic-handle
catches failures so a missing /var (pid1 mount_var() failed) does
not derail boot.  also calls `state--detect-mode' so the rest of
the system can branch on whether persistence works."
  (when (state--ensure-dir state-root)
    (dolist (sub state--subdirs)
      (state--ensure-dir (concat state-root sub))))
  (state--detect-mode))

(defun state-read (key &optional default)
  "Return the value previously stored under KEY, or DEFAULT if absent.
the value is read as an elisp s-expr from the file at
\(state-path KEY).  on read error (file missing, parse failure)
returns DEFAULT and does NOT panic: a missing key is a normal case
\(first boot, fresh tmpfs).  parse failures DO get logged via
`panic-handle' so a corrupted state file leaves a breadcrumb."
  (let ((path (state-path key)))
    (cond
     ((not (state--safe-key-p key))
      (when (fboundp 'panic-handle)
        (panic-handle (list 'state-read-bad-key key) 'state-read))
      default)
     ((not (file-readable-p path)) default)
     (t
      (condition-case err
          (with-temp-buffer
            (let ((coding-system-for-read 'utf-8))
              (insert-file-contents path))
            (goto-char (point-min))
            (read (current-buffer)))
        (error
         (when (fboundp 'panic-handle)
           (panic-handle err `(state-read . ,key)))
         default))))))

(defun state-write (key value)
  "Persist VALUE under KEY.  return t on success, nil on failure.
write goes to KEY.tmp first, then rename(2) over KEY, then fsync
the parent directory via `pid1-fsync-dir'.  on ext4 this is
crash-consistent.  on tmpfs the fsync is a near-no-op but the
rename remains atomic.  if pid1-fsync-dir is unbound (module not
loaded, dev host) we skip the fsync and the write still goes
through; durability is downgraded but visibility holds.

VALUE may be any printable elisp object.  prin1 with print-length
and print-level both nil to avoid truncation in pathological cases."
  (cond
   ((not (state--safe-key-p key))
    (when (fboundp 'panic-handle)
      (panic-handle (list 'state-write-bad-key key) 'state-write))
    nil)
   (t
    (condition-case err
        (let* ((path (state-path key))
               (tmp (concat path ".tmp"))
               (dir (file-name-directory path))
               (print-length nil)
               (print-level nil)
               (write-region-inhibit-fsync nil)
               (coding-system-for-write 'utf-8))
          (state--ensure-dir dir)
          (with-temp-file tmp
            (let ((standard-output (current-buffer)))
              (prin1 value)))
          (rename-file tmp path t)
          (when (fboundp 'pid1-fsync-dir)
            (condition-case _
                (pid1-fsync-dir dir)
              (error nil)))
          t)
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err `(state-write . ,key)))
       nil)))))

(defun state-delete (key)
  "Remove KEY from the state tree.  return t on success or nothing-to-do.
a missing file is success; only an explicit delete failure returns nil."
  (cond
   ((not (state--safe-key-p key)) nil)
   (t
    (let ((path (state-path key)))
      (condition-case err
          (progn
            (when (file-exists-p path)
              (delete-file path))
            t)
        (error
         (when (fboundp 'panic-handle)
           (panic-handle err `(state-delete . ,key)))
         nil))))))

(defun state-append-journal (filename line)
  "Append LINE plus a newline to /var/emacs/journal/FILENAME.
returns t on success, nil on failure.  FILENAME is the bare basename
(\"auth.log\", \"boot.log\"); the journal/ prefix is added here so a
caller cannot accidentally write to /var/emacs/state.sexp.

unlike `state-write' this does NOT rewrite-then-rename: it opens the
file in append mode and appends one record.  the supervisor is the
only writer to /var/emacs/journal/* so we do not need flock; a future
multi-writer story (per-user emacs writes its own audit lines via
RPC) lands here behind a pid1-flock primitive.

LINE should be a printable elisp object (we prin1 it) so a reader
can `read' the file line by line and recover the structured shape.
embedded newlines in LINE break that contract; the helper does not
attempt to escape them.  callers building audit records (login.el)
emit alists whose values are short atoms, so this is safe in
practice."
  (cond
   ((not (and (stringp filename)
              (not (string-empty-p filename))
              (not (string-match-p "/" filename))))
    (when (fboundp 'panic-handle)
      (panic-handle (list 'state-append-journal-bad-name filename)
                    'state-append-journal))
    nil)
   (t
    (condition-case err
        (let* ((dir (concat state-root "journal/"))
               (path (concat dir filename))
               (print-length nil)
               (print-level nil)
               (write-region-inhibit-fsync nil)
               (coding-system-for-write 'utf-8)
               (rendered (with-output-to-string (prin1 line))))
          (state--ensure-dir dir)
          (write-region (concat rendered "\n") nil path 'append 'nomsg)
          (when (fboundp 'pid1-fsync-dir)
            (condition-case _ (pid1-fsync-dir dir) (error nil)))
          t)
      (error
       (when (fboundp 'panic-handle)
         (panic-handle err `(state-append-journal . ,filename)))
       nil)))))

(defun state-mode-string ()
  "Return a short string for header lines: \"persistent\", \"tmpfs\", \"none\"."
  (pcase state-mode
    ('persistent "persistent")
    ('tmpfs "tmpfs")
    (_ "none")))

;; auto-init at load time when this emacs is the OS userland.  on a
;; dev host pid1-as-emacs-p is nil and the layout step is skipped, so
;; loading the file is side-effect free outside the OS.  on the OS we
;; must materialise the directory tree before any later -l file (the
;; per-buffer state caches in journal/, packages/, etc.) tries to read
;; or write.  state--ensure-layout is itself panic-handled internally,
;; so a write failure here cannot abort boot.
(when (and (boundp 'pid1-as-emacs-p) pid1-as-emacs-p)
  (state--ensure-layout)
  (let ((write-region-inhibit-fsync t))
    (condition-case _
        (write-region
         (format "geos: state-mode=%s root=%s\n"
                 (state-mode-string) state-root)
         nil "/dev/console" 'append 'nomsg)
      (error nil))))

(provide 'state)
;;; state.el ends here
