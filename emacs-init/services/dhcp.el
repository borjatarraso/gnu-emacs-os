;;; dhcp.el --- on-demand DHCP via dhcpcd, sentinel-driven -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

;; v0.4 item 5 finisher.  the *network* buffer's `s' key has shipped a
;; static-IPv4 path that goes straight into pid1-set-address +
;; pid1-set-route-default ioctls.  this file adds the dynamic side:
;; press `d' on an iface row in *network* and we spawn dhcpcd in
;; one-shot mode against that interface.  dhcpcd does the actual
;; SIOCSIFADDR / route insertion via its own ioctls; we just trigger
;; it, capture stdout/stderr into a hidden work buffer for diagnostic
;; purposes, and refresh *network* when the child exits so the new
;; address shows up without the user waiting for the 2s timer tick.
;;
;; why this is not a defservice: one DHCP request per interface per
;; operator action is an event, not a long-running thing the
;; supervisor needs to keep alive.  the renewal timer that turns this
;; into a continuously-leased state is a v0.5 problem (dhcpcd has its
;; own renewal but in -1 mode it exits after BOUND; either we leave
;; the lease to expire and the operator re-presses `d', or we wire a
;; supervise.el periodic timer that re-spawns at lease/2).  for v0.4
;; the imperative "give me a lease now" knob is what the *network*
;; buffer needed to stop being read-only on routable interfaces.
;;
;; why we use dhcpcd at all: a from-scratch RFC2131 client in elisp
;; is at least a quarter of work and would need raw socket support
;; that emacs does not expose.  dhcpcd is in gnu packages admin, we
;; pin it via system.scm, we document the shell-out exception in
;; guix-system/exceptions.scm.  every other DHCP feature dhcpcd
;; carries (resolv.conf rewrites, ntp hooks, the carrier watcher) we
;; turn off via flags so the binary is the smallest IP-getter we can
;; pry out of it.

(require 'panic)

(defgroup dhcp nil
  "On-demand DHCP via dhcpcd, triggered from the *network* buffer."
  :group 'network
  :prefix "dhcp-")

(defcustom dhcp-program "dhcpcd"
  "Absolute path or PATH-resolvable name of the dhcpcd binary.
Default is the bare name, resolved against process-environment's
PATH at spawn time.  pin this to a /gnu/store path under
operator policy if you do not trust the supervisor's PATH."
  :type 'string
  :group 'dhcp)

(defcustom dhcp-timeout-seconds 30
  "Wall-clock seconds before we kill an unresponsive dhcpcd.
A DHCP DISCOVER on a non-routable LAN can sit forever waiting
for an OFFER.  rather than leave the request open, we send the
child SIGTERM at this deadline and surface the failure to the
operator.  set to 0 to disable the timeout entirely (you almost
certainly do not want that)."
  :type 'integer
  :group 'dhcp)

(defconst dhcp--work-buffer-prefix " *supervise:dhcp:"
  "Prefix for the hidden per-iface work buffer that captures dhcpcd output.
Leading space hides the buffer from buffer-list.  one buffer per
interface so concurrent requests against different ifaces do not
braid their logs.")

(defvar dhcp--inflight (make-hash-table :test 'equal)
  "Map of iface-name (string) -> (PROCESS . TIMER).
Used to refuse a second `dhcp-request' against the same iface while
the first is still running, and to find the timer for cancellation
when the sentinel fires.  cleared on sentinel completion.")

(defun dhcp--work-buffer-name (iface)
  "Name of the hidden work buffer for IFACE."
  (concat dhcp--work-buffer-prefix iface "*"))

(defun dhcp--cleanup (iface)
  "Remove IFACE from `dhcp--inflight' and cancel any pending timer.
Idempotent: a second call with the same iface is a no-op.  callers
must invoke this from the sentinel exit path AND from the timeout
hook so a clean exit and a forced kill both converge here."
  (let ((entry (gethash iface dhcp--inflight)))
    (when entry
      (let ((timer (cdr entry)))
        (when (timerp timer) (cancel-timer timer)))
      (remhash iface dhcp--inflight))))

(defun dhcp--maybe-refresh-buffer ()
  "Repaint *network* if it exists and the renderer is loaded.
The newly-leased address shows up in /proc/net/dev within a tick;
we just shortcut the 2s timer so the operator sees confirmation
immediately."
  (when (fboundp 'network-buffer-refresh)
    (condition-case err
        (network-buffer-refresh)
      (error (panic-handle err 'dhcp--maybe-refresh-buffer)))))

(defun dhcp--sentinel (iface proc _event)
  "Sentinel for the per-iface dhcpcd PROC on IFACE.
Records exit code, releases the inflight slot, refreshes *network*.
A non-zero exit gets routed through panic-handle so the operator sees
a *panic* entry; the work buffer keeps dhcpcd's own diagnostics in
case the panic message alone is too terse.  a zero exit logs the
lease to the messages buffer so an attentive operator can correlate
the *network* refresh with which request brought the address."
  (when (memq (process-status proc) '(exit signal failed))
    (dhcp--cleanup iface)
    (let* ((sig  (process-status proc))
           (code (process-exit-status proc))
           (clean (and (eq sig 'exit) (zerop code))))
      (cond
       (clean
        (message "dhcp: %s leased (dhcpcd exit 0)" iface)
        (dhcp--maybe-refresh-buffer))
       (t
        ;; signal=signal means we killed it via the timeout; that is
        ;; an operator-visible failure but it is also self-inflicted,
        ;; so the message wording acknowledges it instead of looking
        ;; like dhcpcd itself crashed.
        (panic-handle
         (list (if (eq sig 'signal) 'dhcp-timeout 'dhcp-failed)
               iface
               (cons 'exit code)
               (cons 'status sig))
         (cons 'dhcp--sentinel iface)))))))

(defun dhcp--timeout (iface proc)
  "SIGTERM PROC for IFACE if it is still running at the deadline.
The sentinel will then fire with status=signal and route through
panic-handle.  no-op if the process already exited cleanly between
the timer scheduling and now."
  (when (process-live-p proc)
    (message "dhcp: %s timed out after %ds, sending SIGTERM"
             iface dhcp-timeout-seconds)
    (condition-case err
        (delete-process proc)
      (error (panic-handle err (cons 'dhcp--timeout iface))))))

(defun dhcp-request (iface)
  "Spawn dhcpcd in one-shot mode against IFACE.
Refuses if a request is already in flight for the same interface.
Returns the process object on a successful spawn, nil otherwise.

Flags passed to dhcpcd:
  -1           exit after BOUND, do not stay resident
  -q           quiet stdout
  -B           do not fork to background (sentinel needs to see exit)
  -K           do not watch carrier via netlink (we have no use for it)
  --nohook resolv.conf  do not rewrite /etc/resolv.conf out from under us
  --nohook ntp.conf     do not rewrite ntp.conf either

Errors from `make-process' route through panic-handle and the slot
in `dhcp--inflight' is not taken, so a retry is possible immediately.

Interactively, prompts for the iface name with the iface at point in
*network* as default."
  (interactive
   (let* ((p (and (fboundp 'network-buffer-iface-at-point)
                  (network-buffer-iface-at-point)))
          (default-iface (and p (plist-get p :iface))))
     (list (read-string (format "DHCP request on iface%s: "
                                (if default-iface
                                    (format " (default %s)" default-iface)
                                  ""))
                        nil nil default-iface))))
  (cond
   ((or (not (stringp iface)) (string-empty-p iface))
    (panic-handle (list 'dhcp-bad-iface iface) 'dhcp-request)
    nil)
   ((gethash iface dhcp--inflight)
    (message "dhcp: request already in flight for %s" iface)
    nil)
   (t
    (condition-case err
        (let* ((buf (get-buffer-create (dhcp--work-buffer-name iface)))
               (proc (make-process
                      :name (concat "dhcp:" iface)
                      :buffer buf
                      :noquery t
                      :connection-type 'pipe
                      :command (list dhcp-program
                                     "-1" "-q" "-B" "-K"
                                     "--nohook" "resolv.conf"
                                     "--nohook" "ntp.conf"
                                     iface)
                      :sentinel
                      (lambda (proc event)
                        (dhcp--sentinel iface proc event))))
               (timer (and (> dhcp-timeout-seconds 0)
                           (run-at-time
                            dhcp-timeout-seconds nil
                            #'dhcp--timeout iface proc))))
          (puthash iface (cons proc timer) dhcp--inflight)
          (message "dhcp: %s requesting lease (pid %d)"
                   iface (process-id proc))
          proc)
      (error
       (panic-handle err (cons 'dhcp-request iface))
       nil)))))

(provide 'dhcp)
;;; dhcp.el ends here
