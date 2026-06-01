;;; install.el --- *install* wizard buffer for v0.4 MVP -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; v0.4 item 3.  the bare-metal install wizard.  this is the
;; orchestrator buffer that glues the install/ tree together:
;;
;;   install/disk.el     enumerate /sys/block, present a pick list,
;;                       refuse anything currently mounted.
;;   install/mkfs.el     mkfs.ext4 the chosen partition.
;;   install/copy.el     copy /gnu/store + /var/guix + current-system.
;;   install/grub.el     grub-install + grub-mkconfig.
;;
;; the wizard does NOT partition.  for v0.4 the operator boots a
;; Guix live ISO (or any live linux with parted), creates an MBR
;; with a single ext4 root partition, then boots into GEOS and runs
;; M-x install.  partition-from-scratch ships in v0.4.1.
;;
;; state machine:
;;
;;   :welcome        RET advances if /tmp/install ready
;;        |
;;        v
;;   :disk-pick      g refresh, n/p navigate, RET pick
;;        |
;;        v
;;   :part-pick      n/p navigate the chosen disk's partitions,
;;                   RET pick (or RET on the disk itself for the
;;                   whole disk, but that fails on a disk that
;;                   refuses naked-fs)
;;        |
;;        v
;;   :format-confirm  y to format, n to back up to :part-pick
;;        |
;;        v
;;   :format          mkfs.ext4 running (timer-rendered spinner)
;;        |
;;        v
;;   :mount           pid1-mount target at /mnt/install
;;        |
;;        v
;;   :copy            cp -a chain (work-buffer size in header)
;;        |
;;        v
;;   :grub            grub-install then grub-mkconfig
;;        |
;;        v
;;   :done            r to reboot, q to bury
;;
;; failure handling: every async step gets (callback ok reason).  on
;; nil the wizard transitions to :error and stores the reason in
;; `install--last-error'.  the operator sees a one-line diagnostic
;; plus a pointer to the per-step work buffer.  q to bury, RET to
;; restart at :welcome.

(require 'cl-lib)
(require 'panic)
(require 'port)
(require 'install-disk)
(require 'install-mkfs)
(require 'install-copy)
(require 'install-grub)

(defvar install-buffer-name "*install*"
  "Name of the wizard buffer.")

(defvar install-target-mount "/mnt/install"
  "Where the freshly-formatted target gets mounted during install.
Plain directory under the live root; pid1 creates it on demand.
Hard-coded because the wizard is the only mounter of this path.")

(defvar install-root-label "geos-root"
  "ext4 volume label written to the target.  fallback to UUID by
default; this is here so a debug session can `mount LABEL=geos-root'
without parsing blkid.")

(defvar install--state :welcome
  "Current wizard step.  one of :welcome :disk-pick :part-pick
:format-confirm :format :mount :copy :grub :done :error.")

(defvar install--disks nil
  "Cached `install-disk-list' result for the current run.")

(defvar install--picked-disk nil
  "The plist the operator selected at :disk-pick.")

(defvar install--picked-part nil
  "The /dev/X path the operator selected at :part-pick.")

(defvar install--last-error nil
  "Last failure reason from any async step.  rendered at :error.")

(defvar install--row 0
  "Row index for the caret in list states (:disk-pick, :part-pick).")

(defvar install--progress nil
  "Free-form string the active step writes to the header.")

;; -- partition enumeration ----------------------------------------------------

(defun install--partitions-for (disk-name)
  "Return list of partitions of DISK-NAME.
DISK-NAME is bare (sda, nvme0n1; or wd0 on Hurd).

linux arm: scans /sys/block/DISK/ for sub-entries that are
partitions (the kernel exposes them as directories named after
the partition, e.g. sda1 / nvme0n1p1, with a `partition' file
inside).  returns a list of /dev/X path strings.  no mounted
check here; the caller (the format-confirm step) re-checks
against /proc/mounts to refuse a mounted partition.

hurd arm (v1.0.0 slice A): defers to
`install--partitions-for-hurd', which returns a list of plists
shaped (:name :node :size-bytes :mounted-p) because hurd has no
sysfs and the slice convention is the storeio translator
node-name suffix (wd0s1, wd0s2, ...).  the two arms return
different shapes on purpose: the hurd plist carries enough info
(size, mount state) for a future render-side polish to grow a
richer part-pick screen.  downstream wizard steps (mkfs / grub
i386-pc) still do not port; `install-yes' refuses to advance
past :format-confirm on a non-linux kernel."
  (cond
   ((geos-kernel-hurd-p)
    (install--partitions-for-hurd disk-name))
   (t
    (let ((dir (concat "/sys/block/" disk-name "/")))
      (when (file-directory-p dir)
        (let (parts)
          (dolist (entry (directory-files dir nil "\\`[^.]"))
            (let ((part-file (concat dir entry "/partition")))
              (when (file-readable-p part-file)
                (push (concat "/dev/" entry) parts))))
          (sort parts #'string<)))))))

;; -- render --------------------------------------------------------------------

(defun install--header ()
  "Header-line string for the current state."
  (format "*install*  state=%s%s"
          install--state
          (if install--progress
              (concat "  " install--progress)
            "")))

(defun install--render ()
  "Repaint the buffer for the current `install--state'.
Wrapped in condition-case so a render glitch routes through panic
without killing the buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq header-line-format (install--header))
    (condition-case err
        (pcase install--state
          (:welcome (install--render-welcome))
          (:disk-pick (install--render-disk-pick))
          (:part-pick (install--render-part-pick))
          (:format-confirm (install--render-format-confirm))
          (:format (install--render-busy "formatting target partition (mkfs.ext4)..."))
          (:mount (install--render-busy "mounting target..."))
          (:copy (install--render-busy "copying system closure (this can take minutes)..."))
          (:grub (install--render-busy "installing GRUB..."))
          (:done (install--render-done))
          (:error (install--render-error))
          (_ (insert (format "unknown state: %s\n" install--state))))
      (error
       (panic-handle err 'install--render)
       (insert "render failed, see *panic*\n")))))

(defun install--render-welcome ()
  "Intro screen.  RET to start, q to bury."
  (insert "  RET start    q quit\n\n")
  (insert "=== GEOS install wizard ===\n\n")
  (insert "  This will format a partition and install GEOS onto it.\n")
  (insert "  You must have already partitioned the target disk\n")
  (insert "  (one ext4 root partition is enough).  The wizard does\n")
  (insert "  not partition disks in this release.\n\n")
  (insert "  Press RET to start, q to back out.\n"))

(defun install--render-disk-pick ()
  "Render the disk-pick step."
  (insert "  n/p move    RET pick    g refresh    q quit\n\n")
  (insert "=== pick a target disk ===\n\n")
  (cond
   ((null install--disks)
    (insert "  no disks visible under /sys/block (use g to retry)\n"))
   (t
    (insert (format "  %-12s %-8s %-10s %-7s %s\n"
                    "device" "size" "model" "flags" ""))
    (let ((i 0))
      (dolist (d install--disks)
        (let* ((caret (if (= i install--row) "->" "  "))
               (size (install-disk-format-bytes (plist-get d :size-bytes)))
               (model (or (plist-get d :model) "?"))
               (rem (if (plist-get d :removable) "rmv" ""))
               (mnt (if (plist-get d :mounted) "MNT" ""))
               (flags (string-trim (concat rem " " mnt)))
               (line (format "%s %-12s %-8s %-10s %-7s"
                             caret
                             (plist-get d :path)
                             size model flags)))
          (insert (propertize line 'install-disk d) "\n"))
        (cl-incf i))))))

(defun install--bad-shape (p)
  "Route a malformed partition entry P through panic-handle.
the part-pick screen accepts two shapes: a /dev/X path string (the
linux arm of `install--partitions-for') or a plist carrying :name
:node :size-bytes :mounted-p (the hurd arm).  anything else means
a regression in one of those producers; surface it via panic-handle
rather than letting it raise up into the keymap handler."
  (panic-handle (cons 'install-bad-part-shape p) 'install--part-pick)
  nil)

(defun install--part-name (p)
  "Return the bare slice name for partition P, or nil if shape unknown.
P is a /dev/X string (linux arm) or a plist with :name (hurd arm).
returns nil and routes through `install--bad-shape' for anything else,
so callers can simply check non-nil before using the result."
  (cond
   ((stringp p) (substring p (length "/dev/")))
   ((and (listp p) (plist-member p :name)) (plist-get p :name))
   (t (install--bad-shape p))))

(defun install--part-node (p)
  "Return the absolute /dev path for partition P, or nil if shape unknown.
P is a /dev/X string (linux arm of `install--partitions-for') or a
plist with :node (hurd arm).  three downstream call sites need this
to convert the operator's pick into argv for mkfs.ext4, pid1-mount,
and the grub-prep chain; without this helper each of those would
have to grow its own (cond ((stringp p) p) ((listp p) ...)) which
is the bug surface slice C is closing.  bad shapes route through
`install--bad-shape' and the helper returns nil so callers can
short-circuit cleanly."
  (cond
   ((stringp p) p)
   ((and (listp p) (plist-member p :node)) (plist-get p :node))
   (t (install--bad-shape p))))

(defun install--part-size-human (p)
  "Return a humanised byte count for partition plist P, or nil.
walks the plist's :size-bytes slot; falls back to a raw `%d' format
if `file-size-human-readable' is unavailable (older Emacs), and to
\"?\" if :size-bytes itself is nil.  not called for the linux arm
because that arm's elements are plain path strings."
  (let ((bytes (plist-get p :size-bytes)))
    (cond
     ((not bytes) "?")
     ((fboundp 'file-size-human-readable)
      (file-size-human-readable bytes))
     (t (format "%d" bytes)))))

(defun install--part-render-line (p)
  "Return the displayed text for a single partition entry P.
two shapes:
  - string \"/dev/X\" (linux): render verbatim, byte-identical to
    the pre-slice-B output so the linux arm is undisturbed.
  - plist (:name :node :size-bytes :mounted-p) (hurd): render as
    \"<name>   <size-human>   [mounted]\" where the bracket marker
    only appears when :mounted-p is non-nil.

unknown shapes route through `install--bad-shape' and the rendered
string falls back to a `?'-prefixed `prin1' so the operator at
least sees something instead of a blank line."
  (cond
   ((stringp p) p)
   ((and (listp p) (plist-member p :name))
    (let ((name (plist-get p :name))
          (size (install--part-size-human p))
          (mnt (plist-get p :mounted-p)))
      (format "%s   %s%s"
              name
              size
              (if mnt "   [mounted]" ""))))
   (t
    (install--bad-shape p)
    (format "? %S" p))))

(defun install--render-part-pick ()
  "Render the partition-pick step."
  (let* ((disk install--picked-disk)
         (parts (and disk (install--partitions-for (plist-get disk :name)))))
    (insert "  n/p move    RET pick    b back    q quit\n\n")
    (insert (format "=== pick a partition on %s ===\n\n"
                    (plist-get disk :path)))
    (cond
     ((null parts)
      (insert "  no partitions on this disk\n")
      (insert "  the wizard does not partition disks; use the Guix\n")
      (insert "  live ISO's parted to create a partition, then start\n")
      (insert "  the wizard again with `g'.\n"))
     (t
      (let ((i 0))
        (dolist (p parts)
          (let* ((caret (if (= i install--row) "->" "  "))
                 (line (format "%s %s" caret (install--part-render-line p))))
            (insert (propertize line 'install-part p) "\n"))
          (cl-incf i)))))))

(defun install--render-format-confirm ()
  "Render the format-confirm step.
both arms render via `install--part-node' so the operator sees
\"/dev/wd0s2\" on hurd rather than the raw plist text; falls back
to the bare name if for some reason :node is missing, and to a
literal `?' if the shape is unrecognised so a regression upstream
in `install--partitions-for' surfaces visibly here instead of as
a malformed-format crash."
  (insert "  y format    n back    q quit\n\n")
  (insert "=== confirm format ===\n\n")
  (insert (format "  about to format %s as ext4 with label %S.\n"
                  (or (install--part-node install--picked-part)
                      (install--part-name install--picked-part)
                      "?")
                  install-root-label))
  (insert "  ALL DATA ON THIS PARTITION WILL BE LOST.\n\n")
  (insert "  press y to proceed, n to back out.\n"))

(defun install--render-busy (msg)
  "Render a running-step screen with MSG."
  (insert "  q quit (after completion)\n\n")
  (insert (format "=== %s ===\n\n" install--state))
  (insert "  " msg "\n")
  (insert "  see the per-step work buffer for live output.\n"))

(defun install--render-done ()
  "Render the success screen.
target line goes through `install--part-node' so the hurd arm
prints the /dev path the kernel actually saw rather than the
prin1 of the plist."
  (insert "  r reboot    q bury\n\n")
  (insert "=== install complete ===\n\n")
  (insert (format "  target:    %s\n"
                  (or (install--part-node install--picked-part)
                      (install--part-name install--picked-part)
                      "?")))
  (insert (format "  mounted:   %s\n" install-target-mount))
  (insert "  bootloader: GRUB (BIOS / i386-pc)\n\n")
  (insert "  Remove the install medium and press r to reboot.\n"))

(defun install--render-error ()
  "Render the failure screen."
  (insert "  RET restart    q quit\n\n")
  (insert "=== install failed ===\n\n")
  (insert (format "  step:   %s\n" install--state))
  (insert (format "  reason: %S\n\n" install--last-error))
  (insert "  check the per-step work buffer for full output.\n")
  (insert "  press RET to restart from the welcome screen.\n"))

;; -- transitions --------------------------------------------------------------

(defun install--repaint ()
  "Repaint the install buffer if it is live."
  (let ((buf (get-buffer install-buffer-name)))
    (when buf
      (with-current-buffer buf
        (install--render)))))

(defun install--enter-disk-pick ()
  "Refresh `install--disks' and switch to :disk-pick."
  (setq install--disks (install-disk-list)
        install--row 0
        install--state :disk-pick)
  (install--repaint))

(defun install--enter-part-pick (disk)
  "Switch to :part-pick for DISK."
  (setq install--picked-disk disk
        install--row 0
        install--state :part-pick)
  (install--repaint))

(defun install--enter-format-confirm (part)
  "Switch to :format-confirm with PART picked."
  (setq install--picked-part part
        install--state :format-confirm)
  (install--repaint))

(defun install--fail (reason)
  "Move to :error with REASON.  internal."
  (setq install--last-error reason
        install--progress nil
        install--state :error)
  (install--repaint))

(defun install--enter-format ()
  "Spawn mkfs.ext4 on `install--picked-part'.
resolves the /dev path through `install--part-node' so the linux
arm passes the original string verbatim and the hurd arm passes
the plist's :node slot (e.g. \"/dev/wd0s2\").  a nil from the
helper means the partition shape was unrecognised, in which case
`install--bad-shape' has already routed the panic and we fail the
step rather than handing nil down to mkfs.ext4."
  (let ((node (install--part-node install--picked-part)))
    (cond
     ((null node)
      (install--fail (cons :format 'bad-partition-shape)))
     (t
      (setq install--state :format
            install--progress "spawning mkfs.ext4")
      (install--repaint)
      (install-mkfs-ext4
       node install-root-label
       (lambda (ok reason)
         (cond
          ((not ok) (install--fail (cons :format reason)))
          (t (install--enter-mount)))))))))

(defun install--enter-mount ()
  "Create `install-target-mount' and pid1-mount the target there.
resolves the /dev path through `install--part-node' for the same
reason `install--enter-format' does: pid1-mount wants a string,
not the operator's plist.  a nil from the helper fails the step."
  (setq install--state :mount install--progress nil)
  (install--repaint)
  (condition-case err
      (let ((node (install--part-node install--picked-part)))
        (cond
         ((null node)
          (install--fail (cons :mount 'bad-partition-shape)))
         (t
          (unless (file-directory-p install-target-mount)
            (make-directory install-target-mount t))
          (when (fboundp 'pid1-mount)
            (pid1-mount node install-target-mount
                        "ext4" 0 nil))
          (install--enter-copy))))
    (error
     (install--fail (cons :mount err)))))

(defun install--enter-copy ()
  "Copy /gnu/store, /var/guix, /run/current-system."
  (setq install--state :copy install--progress nil)
  (install--repaint)
  (install-copy-system
   install-target-mount
   (lambda (ok reason)
     (cond
      ((not ok) (install--fail (cons :copy reason)))
      (t (install--enter-grub))))))

(defun install--enter-grub ()
  "Run grub-install + grub-mkconfig against the target."
  (setq install--state :grub install--progress nil)
  (install--repaint)
  (install-grub-finalize
   (plist-get install--picked-disk :path)
   install-target-mount
   (lambda (ok reason)
     (cond
      ((not ok) (install--fail (cons :grub reason)))
      (t (setq install--state :done install--progress nil)
         (install--repaint))))))

;; -- commands -----------------------------------------------------------------

(defun install-advance ()
  "RET handler.  meaning depends on `install--state'."
  (interactive)
  (pcase install--state
    (:welcome (install--enter-disk-pick))
    (:disk-pick
     (let ((d (nth install--row install--disks)))
       (cond
        ((null d) (message "install: no disk on this line"))
        ((plist-get d :mounted)
         (message "install: refuses to wipe %s, it has a mounted partition"
                  (plist-get d :path)))
        (t (install--enter-part-pick d)))))
    (:part-pick
     (let* ((disk install--picked-disk)
            (parts (and disk (install--partitions-for
                              (plist-get disk :name))))
            (p (nth install--row parts))
            ;; bare-name extractor handles both shapes; if the shape
            ;; is bad it routes through `install--bad-shape' and
            ;; returns nil, which the (null name) arm catches below.
            (name (and p (install--part-name p))))
       (cond
        ((null p) (message "install: no partition on this line"))
        ((null name)
         (message "install: bad partition shape, see *panic*"))
        ((install-disk-mounted-p name)
         (message "install: refuses to wipe %s, mounted in /proc/mounts"
                  name))
        (t (install--enter-format-confirm p)))))
    (:error (install :welcome))
    (_ (message "install: RET has no meaning in state %s" install--state))))

(defun install-next ()
  "Move the caret down by one in list states.
In :format-confirm, doubles as the `no' answer (backs to :part-pick),
because the format-confirm help text says `n back' and we keep one
binding per key."
  (interactive)
  (pcase install--state
    (:format-confirm (install--enter-part-pick install--picked-disk))
    (_
     (let ((max
            (pcase install--state
              (:disk-pick (length install--disks))
              (:part-pick (length
                           (install--partitions-for
                            (plist-get install--picked-disk :name))))
              (_ 0))))
       (when (> max 0)
         (setq install--row (min (1- max) (1+ install--row)))
         (install--render))))))

(defun install-prev ()
  "Move the caret up by one in list states."
  (interactive)
  (when (memq install--state '(:disk-pick :part-pick))
    (setq install--row (max 0 (1- install--row)))
    (install--render)))

(defun install-refresh ()
  "Refresh the disk list at :disk-pick."
  (interactive)
  (when (eq install--state :disk-pick)
    (install--enter-disk-pick)))

(defun install-back ()
  "Back up one step where it makes sense."
  (interactive)
  (pcase install--state
    (:part-pick (install--enter-disk-pick))
    (:format-confirm (install--enter-part-pick install--picked-disk))
    (_ (message "install: no back from %s" install--state))))

(defun install-yes ()
  "y handler.  only meaningful in :format-confirm.
Both linux and hurd advance through the same mkfs.ext4 +
grub-install + grub-mkconfig chain: the 2026-05-23 v1.x research
(see `docs/runlogs/...-v1x-install-hurd-scope.md') verified that
mke2fs and grub-install both open /dev/wd0sN storeio nodes via
plain open(O_RDWR) and lseek/pwrite byte-for-byte, so no new
port_caps slot was needed.  the partition the operator picked
is a /dev/X string on linux and a (:name :node :size-bytes
:mounted-p) plist on hurd; the downstream steps
(`install--enter-format', `install--enter-mount') resolve the
device path via `install--part-node' so either shape works.

other kernels (no other arms today) still fail here with a
`geos-port-unimplemented' record; that is the canonical refusal
shape and keeps the wizard from half-doing it on a kernel where
the binary surface is unverified."
  (interactive)
  (pcase install--state
    (:format-confirm
     (cond
      ((or (geos-kernel-linux-p) (geos-kernel-hurd-p))
       (install--enter-format))
      (t
       (geos-port-unimplemented 'install-format)
       (install--fail
        (cons :format
              (format "format step unsupported on %s" geos-kernel))))))
    (_ (message "install: y has no meaning in %s" install--state))))

(defun install-reboot ()
  "r handler.  reboot via pid1-reboot if in :done."
  (interactive)
  (cond
   ((not (eq install--state :done))
    (message "install: reboot only after :done"))
   ((not (fboundp 'pid1-reboot))
    (message "install: pid1-reboot is not available"))
   ((yes-or-no-p "reboot now? ")
    (pid1-reboot))))

(defun install-quit ()
  "Bury the install buffer.  per project rules we do not kill."
  (interactive)
  (bury-buffer))

;; -- mode + entry point -------------------------------------------------------

(defvar install-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'install-advance)
    (define-key m (kbd "n") #'install-next)
    (define-key m (kbd "p") #'install-prev)
    (define-key m (kbd "g") #'install-refresh)
    (define-key m (kbd "b") #'install-back)
    (define-key m (kbd "y") #'install-yes)
    (define-key m (kbd "r") #'install-reboot)
    (define-key m (kbd "q") #'install-quit)
    m)
  "Keymap for `install-mode'.")

(define-derived-mode install-mode special-mode "Install"
  "Major mode for the *install* wizard buffer.
See file commentary for the state machine."
  (setq truncate-lines t))

;;;###autoload
(defun install (&optional reset-state)
  "Display the *install* wizard, creating it on first call.
Optional RESET-STATE selects an explicit starting state (defaults
to :welcome).  Interactive: M-x install."
  (interactive)
  (let ((buf (get-buffer-create install-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'install-mode)
        (install-mode))
      (setq install--state (or reset-state :welcome)
            install--row 0
            install--progress nil
            install--last-error nil)
      (install--render))
    (display-buffer buf)
    buf))

(provide 'install-buffer)
;;; install.el ends here
