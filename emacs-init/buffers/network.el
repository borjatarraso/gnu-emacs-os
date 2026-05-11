;;; network.el --- *network* buffer, the live UI for ip a / ip r -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; what does it show: the current set of network interfaces (from
;; /proc/net/dev) and the kernel routing table (from /proc/net/route),
;; rendered as two columnar sections inside a single read-only buffer.
;;
;; how does it refresh: a 2-second repeating timer that the buffer
;; owns. timer is started on first display and cancelled when the
;; buffer is killed. `g' forces an immediate refresh.
;;
;; what can the user do here: `g' refresh, `RET' on an interface line
;; pops a *network-iface-details* buffer with the full counter set,
;; `q' buries (we never kill our concept buffers, same as *processes*).
;;
;; what breaks if the source disappears: /proc/net/dev and
;; /proc/net/route are kernel-provided and effectively always present
;; on Linux. if reading them fails (procfs unmounted, namespace weird)
;; the buffer prints "no data" rows and routes the underlying error
;; through `panic-handle'. it does NOT die.

(require 'panic)
(require 'cl-lib)  ; cl-flet in network-buffer-show-iface-details

;; core/network.el ships the parsers. during early dev this file may
;; not be loaded yet. we tolerate that and print a placeholder, per
;; project convention: the OS keeps running, the buffer just degrades.
;; same handler-hazard as core/network.el's load-time apply: guard
;; with fboundp so a missing panic-handle (load-order glitch under
;; byte-compile or repl eval) does not raise a fresh void-function.
(condition-case err
    (require 'network)
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'network-buffer-require)
     (message "network-buffer: require failed before panic-handle existed: %S" err))))

(defvar network-buffer-name "*network*"
  "Name of the canonical network state buffer.
Per project rules this buffer is conceptually unkillable. the
timer cleanup hook exists for symmetry, not because we expect
the buffer to die.")

(defvar network-buffer-iface-details-name "*network-iface-details*"
  "Name of the popup buffer that shows extended counters for one iface.")

(defvar network-buffer-refresh-interval 2
  "Seconds between automatic refreshes of *network*.
Two seconds is fast enough to feel live, slow enough that parsing
1000 ifaces stays well under our 100ms budget.")

(defvar-local network-buffer--timer nil
  "Per-buffer timer driving auto-refresh. Cancelled in the kill hook.")

(defun network-buffer--source-available-p ()
  "Return non-nil if both proc parsers from core/network.el are bound."
  (and (fboundp 'network-read-proc-net-dev)
       (fboundp 'network-read-proc-net-route)))

(defun network-buffer--iface-state (plist)
  "Return a short up/down/idle string for interface PLIST.
We do not have RTNL here, so heuristic: any non-zero counter on
either direction means the iface has carried traffic and is
treated as `up'. lo with zero counters reads as `idle'. this is a
approximation, not netlink truth."
  (let ((rx (or (plist-get plist :rx-bytes) 0))
        (tx (or (plist-get plist :tx-bytes) 0)))
    (cond ((and (zerop rx) (zerop tx)) "idle")
          (t "up"))))

(defun network-buffer--format-bytes (n)
  "Right-pad N as a 12-wide decimal string. no SI scaling for now."
  (format "%12d" (or n 0)))

(defun network-buffer--render-interfaces (ifaces)
  "Insert the interfaces section for IFACES (list of plists)."
  (insert "interfaces\n")
  (insert (format "  %-10s %12s %12s %-6s\n"
                  "iface" "rx-bytes" "tx-bytes" "state"))
  (if (null ifaces)
      (insert "  (no data)\n")
    (dolist (i ifaces)
      (let ((line (format "  %-10s %s %s %-6s"
                          (plist-get i :iface)
                          (network-buffer--format-bytes
                           (plist-get i :rx-bytes))
                          (network-buffer--format-bytes
                           (plist-get i :tx-bytes))
                          (network-buffer--iface-state i))))
        ;; stash the plist on the line so RET can pick it up without
        ;; re-parsing /proc.
        (insert (propertize line 'network-iface i) "\n")))))

(defun network-buffer--render-routes (routes)
  "Insert the routing table section for ROUTES (list of plists)."
  (insert "\nroutes\n")
  (insert (format "  %-16s %-16s %-8s\n" "dest" "gateway" "iface"))
  (if (null routes)
      (insert "  (no data)\n")
    (dolist (r routes)
      (let* ((dest (plist-get r :dest))
             (shown (if (string= dest "0.0.0.0") "default" dest)))
        ;; parser stores the next-hop under :gw, not :gateway. shipped
        ;; with :gateway here in the first cut and saw the column blank;
        ;; aligning to the parser is the right side of this arg.
        (insert (format "  %-16s %-16s %-8s\n"
                        shown
                        (plist-get r :gw)
                        (plist-get r :iface)))))))

(defun network-buffer--render ()
  "Repaint the current buffer from /proc. Caller holds the buffer current.
Wrapped in `condition-case' so a parse glitch does not stop the
timer or kill the buffer."
  (let ((inhibit-read-only t)
        (start-line (line-number-at-pos))
        (start-col (current-column)))
    (erase-buffer)
    (setq header-line-format
          (format "*network*  refreshed %s"
                  (format-time-string "%Y-%m-%d %H:%M:%S")))
    (cond
     ((not (network-buffer--source-available-p))
      (insert "core/network.el not loaded\n"))
     (t
      (condition-case err
          (let ((ifaces (network-read-proc-net-dev))
                (routes (network-read-proc-net-route)))
            (network-buffer--render-interfaces ifaces)
            (network-buffer--render-routes routes))
        (error
         (panic-handle err 'network-buffer-render)
         (insert "render failed, see *panic*\n")))))
    ;; restore point roughly where the user had it. this matters for
    ;; RET-on-iface workflows where the timer fires mid-read.
    (goto-char (point-min))
    (forward-line (1- start-line))
    (move-to-column start-col)))

(defun network-buffer-refresh ()
  "Force a refresh of *network*. Bound to `g'."
  (interactive)
  (let ((buf (get-buffer network-buffer-name)))
    (when buf
      (with-current-buffer buf
        (network-buffer--render)))))

(defun network-buffer--timer-tick (buf)
  "Timer callback. Refresh BUF if it still exists, else self-cancel.
The kill-hook normally cancels our timer, but if the buffer is
killed without our hook running (or recreated under the same
name with a fresh buffer-local timer slot) the previously-armed
timer survives and fires here against a dead buffer. detect that
and cancel ourselves out of `timer-list' so we do not leak a
two-second wakeup forever."
  (if (buffer-live-p buf)
      (with-current-buffer buf
        (condition-case err
            (network-buffer--render)
          (error
           ;; fboundp guard: if panic.el somehow has not loaded yet
           ;; (timer scheduled before init.el's -l chain finished, or
           ;; load order regression), the bare panic-handle call would
           ;; itself raise void-function and detach the timer with no
           ;; trace.  degrade to message in that window.
           (if (fboundp 'panic-handle)
               (panic-handle err 'network-buffer-timer)
             (message "network-buffer-timer: %S (panic-handle unbound)" err)))))
    ;; the buffer-local slot is gone with the buffer, so we cannot
    ;; cancel via the stash. walk timer-list and cancel by callback
    ;; identity. this is O(timers) but timers are few and we only
    ;; pay it once per orphaned timer.
    (dolist (tm (append timer-list timer-idle-list))
      (when (and (timerp tm)
                 (eq (timer--function tm) #'network-buffer--timer-tick)
                 (equal (timer--args tm) (list buf)))
        (cancel-timer tm)))))

(defun network-buffer--start-timer ()
  "Install the 2-second refresh timer on the current buffer."
  (when (timerp network-buffer--timer)
    (cancel-timer network-buffer--timer))
  (setq network-buffer--timer
        (run-at-time network-buffer-refresh-interval
                     network-buffer-refresh-interval
                     #'network-buffer--timer-tick
                     (current-buffer))))

(defun network-buffer--kill-hook ()
  "Cancel the per-buffer refresh timer when *network* is killed.
Project rule: this buffer is never killed. the hook is here for
symmetry with the rest of buffers/."
  (when (timerp network-buffer--timer)
    (cancel-timer network-buffer--timer)
    (setq network-buffer--timer nil)))

(defun network-buffer-iface-at-point ()
  "Return the iface plist stored on the current line, or nil."
  (get-text-property (line-beginning-position) 'network-iface))

(defun network-buffer-show-iface-details ()
  "Open a popup with extended info for the iface on the current line.
Bound to `RET'. silently no-ops on lines without an iface."
  (interactive)
  (let ((plist (network-buffer-iface-at-point)))
    (when plist
      (let ((buf (get-buffer-create network-buffer-iface-details-name)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (special-mode)
            ;; numberp guards: if /proc/net/dev parsing returned a
            ;; short row earlier, the missing counters land here as
            ;; nil; %d on nil signals wrong-type-argument and pops a
            ;; *Backtrace* the moment the user hits RET.  fall back to
            ;; "?" instead.
            (cl-flet ((cnt (k)
                        (let ((v (plist-get plist k)))
                          (if (numberp v) (format "%d" v) "?"))))
              (insert (format "iface:      %s\n" (plist-get plist :iface)))
              (insert (format "rx-bytes:   %s\n" (cnt :rx-bytes)))
              (insert (format "rx-packets: %s\n" (cnt :rx-packets)))
              (insert (format "rx-errs:    %s\n" (cnt :rx-errs)))
              (insert (format "rx-drop:    %s\n" (cnt :rx-drop)))
              (insert (format "tx-bytes:   %s\n" (cnt :tx-bytes)))
              (insert (format "tx-packets: %s\n" (cnt :tx-packets)))
              (insert (format "tx-errs:    %s\n" (cnt :tx-errs)))
              (insert (format "tx-drop:    %s\n" (cnt :tx-drop))))
            (goto-char (point-min))))
        (display-buffer buf)))))

(defun network-buffer-set-static ()
  "Prompt for address/prefix/gateway and apply to the iface at point.
Bound to `s'. Falls back to a free-form read of the iface name if
point is not on an iface row. Calls `network-set-static', which
routes pid1-error through panic-handle."
  (interactive)
  (let* ((p (network-buffer-iface-at-point))
         (default-iface (and p (plist-get p :iface)))
         (n (read-string (format "Interface%s: "
                                 (if default-iface
                                     (format " (default %s)" default-iface)
                                   ""))
                         nil nil default-iface))
         (a (read-string (format "Address for %s: " n)))
         (pf (read-number (format "Prefix length for %s/%s: " n a) 24))
         (g (let ((s (read-string "Gateway (empty for none): ")))
              (if (string-empty-p s) nil s))))
    (if (fboundp 'network-set-static)
        (progn
          (network-set-static n a pf g)
          (network-buffer-refresh))
      (message "network-buffer: network-set-static unbound; load core/network.el"))))

(defun network-buffer-bring-up ()
  "Bring the iface at point up via flag-only ioctl (no address change).
Bound to `i'. For lo this routes through `pid1-bring-up-lo'; for
any other iface we currently have no flag-only entry point, so we
message the user to use `s' (which does flags + address). that is
intentional: bringing a NIC up with no address attached is rarely
what an operator actually wants and we'd rather force the prompt."
  (interactive)
  (let* ((p (network-buffer-iface-at-point))
         (iface (and p (plist-get p :iface))))
    (cond
     ((null iface)
      (message "network-buffer: no interface on this line"))
     ((string= iface "lo")
      (if (fboundp 'network--bring-up-lo)
          (progn (funcall (symbol-function 'network--bring-up-lo))
                 (network-buffer-refresh))
        (message "network-buffer: network--bring-up-lo unbound")))
     (t
      (message "network-buffer: %s needs an address; press `s'" iface)))))

(defun network-buffer-quit ()
  "Bury *network*. Per project rules we do not kill it."
  (interactive)
  (bury-buffer))

(defvar network-buffer-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g")   #'network-buffer-refresh)
    (define-key m (kbd "RET") #'network-buffer-show-iface-details)
    (define-key m (kbd "s")   #'network-buffer-set-static)
    (define-key m (kbd "i")   #'network-buffer-bring-up)
    (define-key m (kbd "q")   #'network-buffer-quit)
    m)
  "Keymap for `network-buffer-mode'.")

(define-derived-mode network-buffer-mode special-mode "Network"
  "Major mode for the *network* buffer.
Read-only view of /proc/net/dev and /proc/net/route, refreshed
every two seconds. see the file commentary for the four-question
contract."
  (setq truncate-lines t)
  (add-hook 'kill-buffer-hook #'network-buffer--kill-hook nil t))

;;;###autoload
(defun network ()
  "Display the *network* buffer, creating it on first call.
Interactive entry point: `M-x network'. starts the refresh timer
if it is not already running."
  (interactive)
  (let ((buf (get-buffer-create network-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'network-buffer-mode)
        (network-buffer-mode))
      (network-buffer--render)
      (unless (timerp network-buffer--timer)
        (network-buffer--start-timer)))
    (display-buffer buf)
    buf))

;; TODO(6): when core/supervise.el lands, register here:
;;   (supervise-register
;;    :name 'network-buffer-timer
;;    :kind 'timer
;;    :start (lambda ()
;;             (with-current-buffer (get-buffer-create network-buffer-name)
;;               (unless (derived-mode-p 'network-buffer-mode)
;;                 (network-buffer-mode))
;;               (network-buffer--start-timer)))
;;    :stop  (lambda ()
;;             (let ((buf (get-buffer network-buffer-name)))
;;               (when buf
;;                 (with-current-buffer buf
;;                   (network-buffer--kill-hook))))))
;; until then the timer is started lazily by `network' and there is
;; no restart-on-death. acceptable for phase 4, not for v1.

(provide 'network-buffer)
;;; network.el ends here
