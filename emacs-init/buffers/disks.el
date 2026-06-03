;;; disks.el --- *disks* buffer, the live UI for lsblk + df + mount -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;; what does it show: two columnar sections in one read-only buffer.
;; first section is the list of block devices straight out of
;; /sys/block/ (NAME, SIZE, REMOVABLE, MOUNTED-ON). second section is
;; the live mount table from /proc/mounts joined with statfs results
;; (DEVICE, MOUNT-POINT, FSTYPE, USED%, FREE-BYTES).
;;
;; how does it refresh: a 5-second repeating timer owned by the
;; buffer. block devices and mount tables churn on the order of
;; minutes, not seconds, so 5s is plenty. timer is started on first
;; display, cancelled in the kill hook, and self-cancels if it ever
;; fires against a dead buffer (same shape as network.el). `g' forces
;; an immediate refresh.
;;
;; what can the user do here: `g' refresh, `RET' on a mount line pops
;; *disks-mount-details* with the full statfs result, `RET' on a block
;; device line pops *disks-blockdev-details* dumping every readable
;; attribute file under /sys/block/<name>/, `q' buries.
;;
;; what breaks if the source disappears: /proc/mounts and /sys/block
;; are kernel-provided and effectively always present on Linux. on
;; read failure (procfs unmounted, namespace tricks) the section
;; renders "(no data)" and the underlying error is funnelled through
;; `panic-handle'. statfs failure on a single mount degrades that one
;; row to "?" rather than poisoning the whole render.
;;
;; on Hurd the data sources change: there is no sysfs at all, so the
;; block-devices section walks /dev/ for whole-disk node patterns
;; (wd0, hd0, sd0, ucd0, ud0, cd0, fd0; the sN partition slices land
;; in the mount section instead).  /proc/mounts is provided by the
;; Hurd procfs translator and parses with the existing Linux parser
;; unchanged.  size comes from the `pid1-disk-size-bytes' module
;; binding when loaded (the slot wires through pid1-module.so to the
;; storeio device_get_status RPC in port_hurd.c); nil still surfaces
;; if the underlying RPC fails and the formatter renders "?" so the
;; column stays honest.

(require 'panic)
(require 'port)

(defvar disks-buffer-name "*disks*"
  "Name of the canonical disks state buffer.
Per project rules this buffer is conceptually unkillable. the
timer cleanup hook exists for symmetry, not because we expect
the buffer to die.")

(defvar disks-buffer-mount-details-name "*disks-mount-details*"
  "Name of the popup buffer that shows full statfs for one mount.")

(defvar disks-buffer-blockdev-details-name "*disks-blockdev-details*"
  "Name of the popup buffer that dumps /sys/block/<name>/* for one device.")

(defvar disks-buffer-refresh-interval 5
  "Seconds between automatic refreshes of *disks*.
Block devices and mount tables move on the order of minutes, so
5s feels live without taxing statfs. parsing 1000 mounts here
stays well under the 100ms budget.")

(defvar-local disks-buffer--timer nil
  "Per-buffer timer driving auto-refresh. Cancelled in the kill hook.")

;; -- /proc/mounts parser -----------------------------------------------------

(defun disks-buffer--unescape-mount (s)
  "Decode the octal escapes /proc/mounts uses for spaces, tabs, backslashes.
The kernel writes \\040 for space, \\011 for tab, \\012 for newline,
\\134 for backslash. mtab(5) had the same convention. without this
a path like \"/run/credentials/foo bar\" parses as two tokens and
everything downstream lies."
  (replace-regexp-in-string
   "\\\\\\([0-9][0-9][0-9]\\)"
   (lambda (m) (char-to-string (string-to-number (match-string 1 m) 8)))
   s t t))

(defun disks-buffer--read-proc-mounts ()
  "Return list of plists parsed from /proc/mounts.
Each plist has :device :mount-point :fstype :options. order
matches the file (kernel mount order). reads the file in one
shot, splits in elisp; faster than line-by-line for the typical
50-200 mounts."
  (when (file-readable-p "/proc/mounts")
    (with-temp-buffer
      (insert-file-contents "/proc/mounts")
      (let (out)
        (dolist (line (split-string (buffer-string) "\n" t))
          (let ((fields (split-string line " " t)))
            (when (>= (length fields) 4)
              (push (list :device      (disks-buffer--unescape-mount (nth 0 fields))
                          :mount-point (disks-buffer--unescape-mount (nth 1 fields))
                          :fstype      (nth 2 fields)
                          :options     (nth 3 fields))
                    out))))
        (nreverse out)))))

;; -- /sys/block walker -------------------------------------------------------

(defun disks-buffer--read-sys-int (path)
  "Return integer contents of PATH or nil if unreadable.
/sys files end in newline; `string-to-number' tolerates trailing
junk so we do not bother trimming."
  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (string-to-number (buffer-string)))))

(defun disks-buffer--list-block-devices ()
  "Return list of plists, one per top-level entry under /sys/block.
Each plist has :name :size-bytes :removable. size is sectors *
512, the kernel's blocksize convention regardless of physical
sector size (this is documented in Documentation/ABI/stable/
sysfs-block). loop devices and zero-sized devices are kept; the
caller decides whether to show them."
  (when (file-directory-p "/sys/block")
    (let (out)
      (dolist (name (directory-files "/sys/block" nil "\\`[^.]"))
        (let* ((dir       (concat "/sys/block/" name))
               (sectors   (disks-buffer--read-sys-int (concat dir "/size")))
               (removable (disks-buffer--read-sys-int (concat dir "/removable"))))
          (push (list :name name
                      :size-bytes (and sectors (* sectors 512))
                      :removable (and removable (= removable 1)))
                out)))
      (nreverse out))))

;; -- joining mounts onto block devices ---------------------------------------

(defun disks-buffer--mounts-for-device (name mounts)
  "Return list of mount points under /dev/NAME (or its partitions) from MOUNTS.
We match by device-string prefix since /sys/block/sda has /dev/sda1,
/dev/sda2 etc as its partitions. dm-N entries get their /dev path
the same way. symlinks like /dev/disk/by-uuid/... are NOT resolved
here; /proc/mounts almost always shows the canonical /dev/X path
because the kernel records the dentry that was actually opened."
  (let ((prefix (concat "/dev/" name))
        out)
    (dolist (m mounts)
      (let ((dev (plist-get m :device)))
        (when (or (string= dev prefix)
                  (string-prefix-p (concat prefix "p") dev)   ;; nvme0n1p1
                  (and (string-prefix-p prefix dev)
                       (let ((rest (substring dev (length prefix))))
                         (string-match-p "\\`[0-9]" rest))))  ;; sda1
          (push (plist-get m :mount-point) out))))
    (nreverse out)))

;; -- hurd /dev walker --------------------------------------------------------

(defconst disks-buffer--hurd-whole-disk-re
  "\\`\\(wd\\|hd\\|sd\\|ucd\\|ud\\|cd\\|fd\\)[0-9]+\\'"
  "Match a Hurd whole-disk node name under /dev/.
wd*/hd*/sd* cover IDE and SCSI; ucd*/ud* are USB; cd*/fd* are
removable optical and floppy.  the regex deliberately rejects any
trailing `sN' suffix so partition slices like `wd0s1' do not get
counted as their own disk in the block-devices section.")

(defconst disks-buffer--hurd-removable-re
  "\\`\\(cd\\|fd\\|ucd\\|ud\\)"
  "Match a Hurd disk name that should be flagged removable.
coarse heuristic.  cd/fd are obvious; ucd/ud are USB which we
treat as removable by convention.  the kernel does not publish a
removable bit on Hurd today, this is the best we can do without
RPC.")

(defun disks-buffer--list-hurd-block-devices ()
  "Return list of plists, one per whole-disk node under /dev/ on Hurd.
Mirrors the shape `disks-buffer--list-block-devices' returns on
Linux: each plist carries :name, :size-bytes, :removable.  size
comes from the `pid1-disk-size-bytes' module binding when loaded;
nil still surfaces if the underlying RPC fails, and the formatter
renders nil as \"?\" so the column stays honest.  the fboundp guard
keeps this file loadable on a Linux dev host without pid1-module.so
present.  removable comes from a coarse name-prefix heuristic
(`disks-buffer--hurd-removable-re')."
  (when (file-directory-p "/dev")
    (let (out)
      (condition-case _
          (dolist (name (directory-files "/dev" nil "\\`[^.]"))
            (when (string-match-p disks-buffer--hurd-whole-disk-re name)
              (push (list :name name
                          :size-bytes (when (fboundp 'pid1-disk-size-bytes)
                                        (pid1-disk-size-bytes name))
                          :removable (and (string-match-p
                                           disks-buffer--hurd-removable-re
                                           name)
                                          t))
                    out)))
        (error nil))
      (nreverse out))))

(defun disks-buffer--mounts-for-device-hurd (name mounts)
  "Return mount points whose device column refers to disk NAME on Hurd.
NAME is the bare whole-disk name (e.g. `wd0').  matches the literal
node path `/dev/NAME' optionally followed by `sN' (the partition-
slice marker).  the trailing check guards against `wd0' over-
matching `wd00' on a system with many disks.

mirrors `disks-buffer--mounts-for-device' in shape; cannot share
code because the Linux variant matches on `/dev/sda' + partition
digit suffix and the two formats do not overlap.

`fsysopts /' on Hurd returns store-spec form like `part:2:device:wd0'
which would also identify the disk, but that string is the live
translator argv, not what the Hurd procfs emits in `/proc/mounts'.
the 2026-05-20 probe (`docs/runlogs/2026-05-20-v092-verify-v093-probe.md')
confirmed `/proc/mounts' uses the literal `/dev/wd0s2' shape; add
the store-spec branch back if a future probe finds a Hurd build
that emits translator argv into mounts."
  (let ((prefix (concat "/dev/" name))
        out)
    (dolist (m mounts)
      (let ((dev (plist-get m :device)))
        (when (and (stringp dev)
                   (string-prefix-p prefix dev)
                   (let ((rest (substring dev (length prefix))))
                     (or (string-empty-p rest)
                         (string-match-p "\\`s[0-9]" rest))))
          (push (plist-get m :mount-point) out))))
    (nreverse out)))

(defun disks-buffer--render-block-devices-hurd (devs mounts)
  "Insert the block-devices section for DEVS on Hurd, joining MOUNTS.
Parallel of `disks-buffer--render-block-devices' that calls the
Hurd matcher instead of the Linux one.  the column layout is
identical so the buffer reads the same way across kernels."
  (insert "block devices\n")
  (insert (format "  %-12s %10s %-9s %s\n"
                  "name" "size" "removable" "mounted-on"))
  (if (null devs)
      (insert "  (no data)\n")
    (dolist (d devs)
      (let* ((name (plist-get d :name))
             (mps  (disks-buffer--mounts-for-device-hurd name mounts))
             (line (format "  %-12s %10s %-9s %s"
                           name
                           (disks-buffer--format-bytes
                            (plist-get d :size-bytes))
                           (if (plist-get d :removable) "yes" "no")
                           (if mps (mapconcat #'identity mps ", ") "-"))))
        (insert (propertize line 'disks-blockdev d) "\n")))))

;; -- formatting --------------------------------------------------------------

(defun disks-buffer--format-bytes (n)
  "Render N bytes as a short human-readable string.
Edge case worth flagging: we use binary units (1024) but label
them GB/TB. SI purists will hate this; sysadmins will not notice.
nil renders as \"?\" so a single failed statfs does not produce
\"0 B\" and look like the disk is full."
  (cond
   ((null n) "?")
   ((< n 1024) (format "%d B" n))
   ((< n (* 1024 1024)) (format "%.1f KB" (/ n 1024.0)))
   ((< n (* 1024 1024 1024)) (format "%.1f MB" (/ n (* 1024.0 1024))))
   ((< n (* 1024 1024 1024 1024)) (format "%.1f GB" (/ n (* 1024.0 1024 1024))))
   (t (format "%.2f TB" (/ n (* 1024.0 1024 1024 1024))))))

(defconst disks-buffer--remote-fstypes
  '("nfs" "nfs4" "cifs" "smbfs" "smb3" "fuse" "fuse.sshfs"
    "fuse.gvfsd-fuse" "afs" "ceph" "glusterfs" "9p" "davfs")
  "Filesystem types that may block in `file-system-info'.
statfs(2) on a network or FUSE mount can hang for the protocol
timeout (tens of seconds for NFS soft mounts, indefinitely for
hard mounts) and emacs is single-threaded, so a single hung mount
freezes the whole UI.  rows with these fstypes render \"?\" without
calling statfs.  the user can still M-x df-on-this-mount manually
if they accept the risk.")

(defun disks-buffer--statfs (mount-point fstype)
  "Return (TOTAL USED FREE USED-PCT) for MOUNT-POINT or nil on failure.
`file-system-info' returns (TOTAL FREE AVAIL) in bytes. we compute
USED as TOTAL-FREE rather than TOTAL-AVAIL to match df's default
column. on tmpfs/cgroup/proc the call can return nil; we surface
that as nil so the row renders \"?\".

FSTYPE is checked against `disks-buffer--remote-fstypes' first to
skip mounts that statfs(2) might block on.  emacs is single-
threaded; one stuck NFS mount would freeze the whole UI."
  (cond
   ((member fstype disks-buffer--remote-fstypes) nil)
   (t
    (condition-case _
        (let ((info (file-system-info mount-point)))
          (when (and info (> (nth 0 info) 0))
            (let* ((total (nth 0 info))
                   (free  (nth 1 info))
                   (used  (- total free))
                   (pct   (/ (* 100.0 used) total)))
              (list total used free pct))))
      (error nil)))))

(defun disks-buffer--render-block-devices (devs mounts)
  "Insert the block-devices section for DEVS, joining MOUNTS for the last column."
  (insert "block devices\n")
  (insert (format "  %-12s %10s %-9s %s\n"
                  "name" "size" "removable" "mounted-on"))
  (if (null devs)
      (insert "  (no data)\n")
    (dolist (d devs)
      (let* ((name (plist-get d :name))
             (mps  (disks-buffer--mounts-for-device name mounts))
             (line (format "  %-12s %10s %-9s %s"
                           name
                           (disks-buffer--format-bytes
                            (plist-get d :size-bytes))
                           (if (plist-get d :removable) "yes" "no")
                           (if mps (mapconcat #'identity mps ", ") "-"))))
        (insert (propertize line 'disks-blockdev d) "\n")))))

(defun disks-buffer--render-mounts (mounts)
  "Insert the mounts section for MOUNTS, calling statfs per row.
Statfs is the slow part of this whole file. on a system with
~100 mounts this is still under the 100ms budget. if it ever
isn't, push it to a process-filter pipeline."
  (insert "\nmounts\n")
  (insert (format "  %-32s %-28s %-10s %6s %12s\n"
                  "device" "mount-point" "fstype" "used%" "free"))
  (if (null mounts)
      (insert "  (no data)\n")
    (dolist (m mounts)
      (let* ((mp    (plist-get m :mount-point))
             (info  (disks-buffer--statfs mp (plist-get m :fstype)))
             (used% (if info (format "%5.1f%%" (nth 3 info)) "    ?"))
             (free  (if info (disks-buffer--format-bytes (nth 2 info)) "?"))
             (rich  (append m (list :statfs info)))
             (line  (format "  %-32s %-28s %-10s %6s %12s"
                            (plist-get m :device)
                            mp
                            (plist-get m :fstype)
                            used%
                            free)))
        (insert (propertize line 'disks-mount rich) "\n")))))

(defun disks-buffer--render ()
  "Repaint the current buffer from /proc and /sys.
Wrapped in `condition-case' so a parse glitch does not stop the
timer or kill the buffer.

The data sources branch on `geos-kernel'.  Linux reads /proc/mounts
and /sys/block; that has been the only path since v0.1.  Hurd has no
sysfs at all, but /proc/mounts is provided by the Hurd procfs
translator and parses with the same Linux parser; the Hurd arm walks
/dev/ for whole-disk node patterns (wd*, hd*, sd*, ucd*, ud*, cd*,
fd*) instead, and joins them against /proc/mounts by matching either
the literal `/dev/NAME' prefix or the store-spec `device:NAME' form
that `fsysopts /' produces for the root translator.  size comes from
the `pid1-disk-size-bytes' module binding when loaded; nil still
surfaces if the underlying RPC fails so the \"?\" render stays
honest."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col (current-column)))
    (erase-buffer)
    (setq header-line-format
          (format "*disks*  refreshed %s"
                  (format-time-string "%Y-%m-%d %H:%M:%S")))
    (cond
     ((geos-kernel-linux-p)
      (condition-case err
          (let ((mounts (disks-buffer--read-proc-mounts))
                (devs   (disks-buffer--list-block-devices)))
            (disks-buffer--render-block-devices devs mounts)
            (disks-buffer--render-mounts mounts))
        (error
         (if (fboundp 'panic-handle)
             (panic-handle err 'disks-buffer-render)
           (message "disks-buffer render failed: %S" err))
         (insert "render failed, see *panic*\n"))))
     ((geos-kernel-hurd-p)
      (condition-case err
          (let ((mounts (disks-buffer--read-proc-mounts))
                (devs   (disks-buffer--list-hurd-block-devices)))
            (disks-buffer--render-block-devices-hurd devs mounts)
            (disks-buffer--render-mounts mounts))
        (error
         (if (fboundp 'panic-handle)
             (panic-handle err 'disks-buffer-render-hurd)
           (message "disks-buffer render (hurd) failed: %S" err))
         (insert "render failed, see *panic*\n"))))
     (t
      ;; unknown kernel: route through panic-handle so a post-mortem
      ;; can tell which kernel string slipped past the predicates.
      (geos-port-unimplemented 'disks-buffer-render)
      (insert (format
               "*disks* is not implemented on kernel %s.\n"
               geos-kernel))))
    (goto-char (point-min))
    (forward-line (1- start-line))
    (move-to-column start-col)))

(defun disks-buffer-refresh ()
  "Force a refresh of *disks*. Bound to `g'."
  (interactive)
  (let ((buf (get-buffer disks-buffer-name)))
    (when buf
      (with-current-buffer buf
        (disks-buffer--render)))))

(defun disks-buffer--timer-tick (buf)
  "Timer callback. Refresh BUF if it still exists, else self-cancel.
Same defensive shape as `network-buffer--timer-tick': the kill
hook usually cancels us, but if the buffer dies without our hook
running we walk `timer-list' and remove ourselves so we do not
leak a 5-second wakeup forever."
  (if (buffer-live-p buf)
      (with-current-buffer buf
        (condition-case err
            (disks-buffer--render)
          (error
           (if (fboundp 'panic-handle)
               (panic-handle err 'disks-buffer-timer)
             (message "disks-buffer timer failed: %S" err)))))
    (dolist (tm (append timer-list timer-idle-list))
      (when (and (timerp tm)
                 (eq (timer--function tm) #'disks-buffer--timer-tick)
                 (equal (timer--args tm) (list buf)))
        (cancel-timer tm)))))

(defun disks-buffer--start-timer ()
  "Install the 5-second refresh timer on the current buffer."
  (when (timerp disks-buffer--timer)
    (cancel-timer disks-buffer--timer))
  (setq disks-buffer--timer
        (run-at-time disks-buffer-refresh-interval
                     disks-buffer-refresh-interval
                     #'disks-buffer--timer-tick
                     (current-buffer))))

(defun disks-buffer--kill-hook ()
  "Cancel the per-buffer refresh timer when *disks* is killed.
Project rule: this buffer is never killed. the hook is here for
symmetry with the rest of buffers/."
  (when (timerp disks-buffer--timer)
    (cancel-timer disks-buffer--timer)
    (setq disks-buffer--timer nil)))

;; -- popups ------------------------------------------------------------------

(defun disks-buffer-mount-at-point ()
  "Return the mount plist stashed on the current line, or nil."
  (get-text-property (line-beginning-position) 'disks-mount))

(defun disks-buffer-blockdev-at-point ()
  "Return the block-device plist stashed on the current line, or nil."
  (get-text-property (line-beginning-position) 'disks-blockdev))

(defun disks-buffer--show-mount-details (plist)
  "Pop a buffer with the full statfs result for PLIST."
  (let ((buf (get-buffer-create disks-buffer-mount-details-name))
        (info (plist-get plist :statfs)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (format "device:      %s\n" (plist-get plist :device)))
        (insert (format "mount-point: %s\n" (plist-get plist :mount-point)))
        (insert (format "fstype:      %s\n" (plist-get plist :fstype)))
        (insert (format "options:     %s\n" (plist-get plist :options)))
        (if info
            (progn
              (insert (format "total:       %s (%d bytes)\n"
                              (disks-buffer--format-bytes (nth 0 info))
                              (nth 0 info)))
              (insert (format "used:        %s (%d bytes)\n"
                              (disks-buffer--format-bytes (nth 1 info))
                              (nth 1 info)))
              (insert (format "free:        %s (%d bytes)\n"
                              (disks-buffer--format-bytes (nth 2 info))
                              (nth 2 info)))
              (insert (format "used%%:       %.2f%%\n" (nth 3 info))))
          (insert "statfs:      unavailable\n"))
        (goto-char (point-min))))
    (display-buffer buf)))

(defun disks-buffer--show-blockdev-details (plist)
  "Pop a buffer with the contents of every readable file under /sys/block/NAME/.
We walk only the immediate children, not recursively. the
interesting things (model, vendor, queue/, slaves/, holders/) are
one level down but most of them are themselves directories or
symlinks; we just label those and print the plain files."
  (let* ((name (plist-get plist :name))
         (dir  (concat "/sys/block/" name "/"))
         (buf  (get-buffer-create disks-buffer-blockdev-details-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (format "block device: %s\n" name))
        (insert (format "size:         %s\n"
                        (disks-buffer--format-bytes
                         (plist-get plist :size-bytes))))
        (insert (format "removable:    %s\n"
                        (if (plist-get plist :removable) "yes" "no")))
        (insert "\n/sys/block/" name "/\n")
        (when (file-directory-p dir)
          (dolist (f (directory-files dir nil "\\`[^.]"))
            (let ((path (concat dir f)))
              (cond
               ((file-symlink-p path)
                (insert (format "  %-24s -> %s\n" f (file-symlink-p path))))
               ((file-directory-p path)
                (insert (format "  %-24s <dir>\n" f)))
               ((file-readable-p path)
                (condition-case _
                    (with-temp-buffer
                      (insert-file-contents path nil 0 4096)
                      (let ((s (string-trim (buffer-string))))
                        (insert (format "  %-24s %s\n" f s))))
                  (error
                   (insert (format "  %-24s <unreadable>\n" f)))))
               (t
                (insert (format "  %-24s <perms>\n" f)))))))
        (goto-char (point-min))))
    (display-buffer buf)))

(defun disks-buffer-show-details ()
  "Open the right popup for whatever line point is on.
Bound to `RET'. mount line wins over block-device line if the
text properties somehow overlap, which they should not."
  (interactive)
  (let ((m (disks-buffer-mount-at-point))
        (b (disks-buffer-blockdev-at-point)))
    (cond
     (m (disks-buffer--show-mount-details m))
     (b (disks-buffer--show-blockdev-details b)))))

(defun disks-buffer-quit ()
  "Bury *disks*. Per project rules we do not kill it."
  (interactive)
  (bury-buffer))

(defvar disks-buffer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g")   #'disks-buffer-refresh)
    (define-key m (kbd "RET") #'disks-buffer-show-details)
    (define-key m (kbd "q")   #'disks-buffer-quit)
    m)
  "Keymap for `disks-buffer-mode'.")

(define-derived-mode disks-buffer-mode special-mode "Disks"
  "Major mode for the *disks* buffer.
Read-only view of /proc/mounts and /sys/block joined with statfs
results, refreshed every five seconds. see the file commentary
for the four-question contract."
  (setq truncate-lines t)
  (add-hook 'kill-buffer-hook #'disks-buffer--kill-hook nil t))

;;;###autoload
(defun disks ()
  "Display the *disks* buffer, creating it on first call.
Interactive entry point: `M-x disks'. starts the refresh timer
if it is not already running."
  (interactive)
  (let ((buf (get-buffer-create disks-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'disks-buffer-mode)
        (disks-buffer-mode))
      (disks-buffer--render)
      (unless (timerp disks-buffer--timer)
        (disks-buffer--start-timer)))
    (display-buffer buf)
    buf))

;; TODO(6): when core/supervise.el lands, register here:
;;   (supervise-register
;;    :name 'disks-buffer-timer
;;    :kind 'timer
;;    :start (lambda ()
;;             (with-current-buffer (get-buffer-create disks-buffer-name)
;;               (unless (derived-mode-p 'disks-buffer-mode)
;;                 (disks-buffer-mode))
;;               (disks-buffer--start-timer)))
;;    :stop  (lambda ()
;;             (let ((buf (get-buffer disks-buffer-name)))
;;               (when buf
;;                 (with-current-buffer buf
;;                   (disks-buffer--kill-hook))))))
;; until then the timer is started lazily by `disks' and there is no
;; restart-on-death. acceptable for phase 4, not for v1.

(provide 'disks-buffer)
;;; disks.el ends here
