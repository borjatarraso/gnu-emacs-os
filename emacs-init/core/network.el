;;; network.el --- interface bring-up and /proc network state -*- lexical-binding: t -*-
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

;; HARD RULE: any failure-path error in this file goes through
;; `panic-handle'. no bare `error' for "i could not do my job".
;; this file is supervision. if it raises uncaught while we are PID 1
;; the box stops scheduling user code. route every exception through
;; panic-handle and keep going with a degraded interface.
;;
;; the one exception is parse failures: if /proc/net/dev gives us
;; garbage, that is a malformed-input bug for the caller to deal with,
;; not a "supervision is broken" event. those raise `network-error',
;; declared just below, so callers can distinguish.
;;
;; written at 1am because lo wasn't coming up and i didn't want to
;; dlsym SIOCSIFFLAGS from elisp.

(require 'panic)
(require 'port)
(require 'subr-x)

(define-error 'network-error
  "Network parse or configuration input error"
  'error)

;;;; defcustom: declarative interface config
;;
;; this is "what should be true after boot", not a script. the apply
;; step diffs it against reality and pokes at the right pid1- module
;; calls. for now only :auto-up on lo is wired, the rest is phase 5
;; once pid1-set-address exists C-side.

(defgroup network nil
  "Network interface configuration for the GEOS userland."
  :group 'emacs
  :prefix "network-")

(defcustom network-interface-config
  '(("lo" . (:address "127.0.0.1" :prefix 8 :auto-up t)))
  "Declarative interface table.
Each entry is (NAME . PLIST). PLIST keys:
  :address  string, e.g. \"127.0.0.1\"
  :prefix   integer 0..32, CIDR prefix length (e.g. 24 for /24).
  :gateway  string or nil, default-route next-hop
  :auto-up  bool, bring the interface up at boot.

`network-apply-config' walks this list and calls into the pid1
module to converge the running kernel toward it. lo is special-
cased to use `pid1-bring-up-lo' (so the loopback comes up even
when pid1-set-address is unbound, e.g. plain `emacs -Q'); every
other interface goes through `pid1-set-address' and, if :gateway
is non-nil, `pid1-set-route-default'."
  :group 'network
  :type '(alist
          :key-type (string :tag "Interface name")
          :value-type
          (plist :key-type symbol
                 :options ((:address (string :tag "IPv4 address"))
                           (:prefix (integer :tag "CIDR prefix length"))
                           (:gateway (choice (const :tag "None" nil)
                                             (string :tag "Gateway")))
                           (:auto-up (boolean :tag "Bring up at boot"))))))

;;;; bring-up

(defun network--bring-up-lo ()
  "Call into the pid1 module to bring loopback up.
Idempotent: the C-side raw_bring_up_lo already ran in pid1's
main(), so SIOCSIFFLAGS here is a no-op on a healthy boot. exists
so future re-bring-up paths (if lo flaps, or under tests) live in
elisp instead of having to bounce out to C.

If `pid1-bring-up-lo' is unbound (running as plain `emacs -Q' on
a dev host with no module loaded) we just message and return.
that is not a panic, it is the documented degraded mode."
  (if (fboundp 'pid1-bring-up-lo)
      (condition-case err
          (progn
            (funcall (symbol-function 'pid1-bring-up-lo))
            (message "network: lo up")
            t)
        (error
         (panic-handle err 'network--bring-up-lo)
         nil))
    (message "network: pid1-bring-up-lo unbound, skipping (no module loaded)")
    nil))

(defun network--set-static (name address prefix gateway)
  "Apply ADDRESS/PREFIX (and optional GATEWAY) to interface NAME.
Calls into the pid1 module. Signals `network-error' on bad input
(missing address, prefix out of range), routes pid1-error through
the caller's panic-handle. Returns t on success, nil on failure
already routed."
  (unless (stringp address)
    (signal 'network-error
            (list "static apply: missing :address" name)))
  (unless (and (integerp prefix) (>= prefix 0) (<= prefix 32))
    (signal 'network-error
            (list "static apply: bad :prefix" name prefix)))
  (cond
   ((not (fboundp 'pid1-set-address))
    (message "network: %s static-config noted, pid1-set-address unbound" name)
    nil)
   (t
    (condition-case err
        (progn
          (funcall (symbol-function 'pid1-set-address) name address prefix)
          (when (and gateway (fboundp 'pid1-set-route-default))
            ;; gateway add can fail with EEXIST on a re-apply; route
            ;; that through panic-handle but do not abort the address
            ;; assignment we just successfully made.
            (condition-case gw-err
                (funcall (symbol-function 'pid1-set-route-default)
                         gateway name)
              (error
               (panic-handle gw-err
                             (cons 'network--set-static-gateway name)))))
          (message "network: %s -> %s/%d%s" name address prefix
                   (if gateway (format " via %s" gateway) ""))
          t)
      (error
       (panic-handle err (cons 'network--set-static name))
       nil)))))

(defun network--apply-entry (name plist)
  "Apply one (NAME . PLIST) row from `network-interface-config'.
Wrapped in condition-case so a single bad row cannot take the
whole apply pass down. `network-error' is re-raised so callers
can distinguish malformed-input bugs from supervision failures
(see header comment about the two error classes)."
  (condition-case err
      (cond
       ((and (string= name "lo") (plist-get plist :auto-up))
        (network--bring-up-lo))
       ((and (plist-get plist :auto-up) (plist-get plist :address))
        (network--set-static name
                             (plist-get plist :address)
                             (plist-get plist :prefix)
                             (plist-get plist :gateway)))
       (t
        ;; entry exists but no actionable shape: missing :address, or
        ;; :auto-up nil (declarative "leave it alone"). log and move on.
        (message "network: %s config noted, no auto-up action" name)
        nil))
    (network-error
     ;; let the caller deal with this. malformed config is not the
     ;; same class of event as "supervision call into the kernel
     ;; failed", and the file's contract promises distinguishability.
     (signal (car err) (cdr err)))
    (error
     (panic-handle err (cons 'network--apply-entry name))
     nil)))

(defun network-apply-config ()
  "Walk `network-interface-config' and apply each entry.
Errors per-entry are routed to `panic-handle' so one bad row does
not abort the rest.  We also catch `network-error' here: the per-
entry function deliberately re-signals malformed-input bugs so a
direct caller can distinguish them, but at the apply pass we still
want every other interface to come up.  log and continue."
  (interactive)
  (dolist (entry network-interface-config)
    (condition-case err
        (network--apply-entry (car entry) (cdr entry))
      (network-error
       (panic-handle err (cons 'network-apply-config (car entry))))
      (error
       (panic-handle err (cons 'network-apply-config (car entry)))))))

;;;; /proc readers
;;
;; pure: open file, parse, return data. no buffer side effects leak
;; out, no global state mutated. these are the sort of thing the
;; *network* buffer (later) will poll on a timer.
;;
;; hurd tier A note (v0.9.2). hurd procfs has no /proc/net/ subtree
;; at all. the route table lives at /proc/route (no `net/' prefix),
;; with decimal-dotted addresses and `/dev/<iface>' in the iface
;; column. there is no /proc/net/dev equivalent, so the hurd
;; "interface counters" reader is a derived list: one row per iface
;; observed in /proc/route plus a synthetic lo, with every counter
;; field zeroed. tier B (pfinet RPC for real byte/packet counters)
;; belongs in port_hurd.c and is out of v0.9.2 scope.

(defun network--read-file (path)
  "Return contents of PATH as a string, or signal `network-error'.
We do not panic-handle here: a missing /proc/net/dev means the
caller asked us to read something the kernel should always have,
which is a malformed-environment bug for them to surface."
  (unless (file-readable-p path)
    (signal 'network-error (list "unreadable" path)))
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun network--split-fields (line)
  "Split LINE on runs of whitespace, dropping empties.
/proc/net/dev uses variable spacing. `split-string' with a regex
handles it but i want the no-empty-trailing behavior consistent
across emacs versions."
  (split-string line "[ \t]+" t))

(defun network--read-proc-net-dev-linux ()
  "Linux backend for `network-read-proc-net-dev'.
Parses /proc/net/dev directly.  signals `network-error' on a short
row.  see `network-read-proc-net-dev' for the plist shape."
  (let* ((raw (network--read-file "/proc/net/dev"))
         (lines (split-string raw "\n" t))
         ;; first two lines are the "Inter-|..." and "face |bytes..."
         ;; headers. drop them. everything else is one row per iface.
         (data-lines (nthcdr 2 lines))
         (out '()))
    (dolist (line data-lines)
      (let* ((trimmed (string-trim line))
             (colon (string-match-p ":" trimmed)))
        (when colon
          (let* ((iface (string-trim (substring trimmed 0 colon)))
                 (rest  (substring trimmed (1+ colon)))
                 (cols  (network--split-fields rest)))
            (unless (>= (length cols) 16)
              (signal 'network-error
                      (list "proc-net-dev short row" iface (length cols))))
            (push (list :iface      iface
                        :rx-bytes   (string-to-number (nth 0 cols))
                        :rx-packets (string-to-number (nth 1 cols))
                        :rx-errs    (string-to-number (nth 2 cols))
                        :rx-drop    (string-to-number (nth 3 cols))
                        :tx-bytes   (string-to-number (nth 8 cols))
                        :tx-packets (string-to-number (nth 9 cols))
                        :tx-errs    (string-to-number (nth 10 cols))
                        :tx-drop    (string-to-number (nth 11 cols)))
                  out)))))
    (nreverse out)))

(defun network--read-proc-net-dev-hurd ()
  "Hurd backend for `network-read-proc-net-dev'.
Hurd procfs has no /proc/net/dev equivalent, so there is no text
file to parse for byte/packet counters.  derive the iface set
from `network--read-proc-net-route-hurd' (which has already
stripped the `/dev/' prefix) and return one row per unique iface
with every counter field stub-zero.  lo rarely shows up in
/proc/route, so force it in.

calling the route reader from inside the dev reader is
intentional: both fire from the same *network* buffer refresh
tick, the route file is small, and writing a second parser of
the same file just to scrape an iface list would be silly.  real
byte/packet counters need a pfinet RPC against /servers/socket/2
and live in port_hurd.c; deferred.

KNOWN LIMITATION: Linux /proc/net/dev enumerates every kernel-
known iface regardless of routing state.  this derivation only
sees ifaces that have at least one route, so a configured-but-
DOWN secondary iface with no route will be invisible in *network*
on Hurd.  in practice the v0.9.2 canonical VM has one routed eth0
plus lo so nothing hides today; documenting the asymmetry here
because the pfinet-RPC follow-up is the proper fix."
  (let* ((rows (network--read-proc-net-route-hurd))
         (ifaces '())
         (out '()))
    (dolist (r rows)
      (let ((ifc (plist-get r :iface)))
        (when (and ifc (not (member ifc ifaces)))
          (push ifc ifaces))))
    (unless (member "lo" ifaces)
      (push "lo" ifaces))
    (dolist (ifc (nreverse ifaces))
      (push (list :iface      ifc
                  :rx-bytes   0
                  :rx-packets 0
                  :rx-errs    0
                  :rx-drop    0
                  :tx-bytes   0
                  :tx-packets 0
                  :tx-errs    0
                  :tx-drop    0)
            out))
    (nreverse out)))

(defun network-read-proc-net-dev ()
  "Parse interface counters into a list of plists, one per interface.
Each plist: (:iface STRING :rx-bytes N :rx-packets N :rx-errs N
:rx-drop N :tx-bytes N :tx-packets N :tx-errs N :tx-drop N).
Dispatches on `geos-kernel': linux reads /proc/net/dev; hurd has
no equivalent file, so the hurd arm derives the iface set from
/proc/route (via `network--read-proc-net-dev-hurd') with every
counter field stub-zero.  real per-iface counters on hurd need a
pfinet RPC against /servers/socket/2 and live in port_hurd.c;
deferred."
  (cond
   ((geos-kernel-linux-p)
    (network--read-proc-net-dev-linux))
   ((geos-kernel-hurd-p)
    (network--read-proc-net-dev-hurd))
   (t
    (geos-port-unimplemented 'network-read-proc-net-dev)
    nil)))

(defun network--hex-to-ipv4 (hex)
  "Convert kernel little-endian HEX (8 chars) to dotted IPv4 string.
/proc/net/route gives addresses as 32-bit hex in host (LE on x86)
byte order. \"0101A8C0\" is 192.168.1.1. zero is rendered as
\"0.0.0.0\" which is what we want for default-gateway rows.

Returns the literal string \"?\" on malformed input rather than
signalling: this is called from inside a `dolist' over /proc rows
and one corrupt row should not abort the rest of the parse.  the
*network* buffer renders \"?\" as the address, the human notices,
and the rest of the routing table still shows up."
  (if (or (not (stringp hex)) (not (= (length hex) 8)))
      "?"
    (condition-case _
        (format "%d.%d.%d.%d"
                (string-to-number (substring hex 6 8) 16)
                (string-to-number (substring hex 4 6) 16)
                (string-to-number (substring hex 2 4) 16)
                (string-to-number (substring hex 0 2) 16))
      (error "?"))))

(defun network--read-proc-net-route-linux ()
  "Linux backend for `network-read-proc-net-route'.
Parses /proc/net/route directly.  see `network-read-proc-net-route'
for the plist shape."
  (let* ((raw (network--read-file "/proc/net/route"))
         (lines (split-string raw "\n" t))
         (data-lines (cdr lines)) ;; first line is the column header
         (out '()))
    (dolist (line data-lines)
      (let ((cols (network--split-fields line)))
        (when (>= (length cols) 8)
          (push (list :iface  (nth 0 cols)
                      :dest   (network--hex-to-ipv4 (nth 1 cols))
                      :gw     (network--hex-to-ipv4 (nth 2 cols))
                      :flags  (string-to-number (nth 3 cols) 16)
                      :metric (string-to-number (nth 6 cols))
                      :mask   (network--hex-to-ipv4 (nth 7 cols)))
                out))))
    (nreverse out)))

(defun network--read-proc-net-route-hurd ()
  "Hurd backend for `network-read-proc-net-route'.
Parses /proc/route (no `net/' prefix on Hurd procfs).  same 11-
column header shape as the Linux file, but addresses are decimal-
dotted already (so we do NOT pass them through `network--hex-to-
ipv4') and the Iface column carries `/dev/<ifname>' which we
strip down to the bare ifname so the *network* buffer renders
`eth0' matching the Linux side.

FLAGS BASE: parsed as hex to match Linux convention and the
`%04X' zero-padded shape the procfs translator emits.  the
v0.9.2 verification sample only contained values 0001 and 0003
which read identically in either base, so this is an inference
from format shape rather than a proven choice; if a future probe
catches a value like `0010' decoding wrong (16 vs 10) flip to
base 10 here.  filed for the v0.9.2 VM re-verify checklist."
  (let* ((raw (network--read-file "/proc/route"))
         (lines (split-string raw "\n" t))
         (data-lines (cdr lines)) ;; first line is the column header
         (out '()))
    (dolist (line data-lines)
      (let* ((cols (network--split-fields line))
             (raw-iface (and (>= (length cols) 8) (nth 0 cols)))
             (iface (cond
                     ((null raw-iface) nil)
                     ((string-prefix-p "/dev/" raw-iface)
                      (substring raw-iface (length "/dev/")))
                     (t raw-iface))))
        (when (and iface (not (string-empty-p iface)))
          (push (list :iface  iface
                      :dest   (nth 1 cols)
                      :gw     (nth 2 cols)
                      :flags  (string-to-number (nth 3 cols) 16)
                      :metric (string-to-number (nth 6 cols))
                      :mask   (nth 7 cols))
                out))))
    (nreverse out)))

(defun network-read-proc-net-route ()
  "Parse the kernel routing table into a list of plists.
Each plist: (:iface STRING :dest STRING :gw STRING :mask STRING
:flags INT :metric INT). Addresses are converted from kernel hex
to dotted IPv4 on linux.

Dispatches on `geos-kernel': linux reads /proc/net/route; hurd
reads /proc/route (no `net/' prefix) where addresses are decimal-
dotted on disk and the iface column has the `/dev/' prefix
stripped before it lands in the plist."
  (cond
   ((geos-kernel-linux-p)
    (network--read-proc-net-route-linux))
   ((geos-kernel-hurd-p)
    (network--read-proc-net-route-hurd))
   (t
    (geos-port-unimplemented 'network-read-proc-net-route)
    nil)))

;;;; user-facing entry points
;;
;; per project rule, our keys hang off `C-c e'. the network sub-prefix
;; is `C-c e n'. nothing fancy yet, just the operations a human might
;; want at the prompt before the *network* buffer lands.

(defun network-set-static (name address prefix &optional gateway)
  "Imperative: assign ADDRESS/PREFIX to NAME, optional GATEWAY default.
Convenience wrapper around `network--set-static' for M-x and the
*network* buffer's `s' key. PREFIX is the CIDR length 0..32.
GATEWAY may be nil. Returns t on success, nil on routed failure."
  (interactive
   (let* ((default-iface
            (or (and (boundp 'network-buffer-iface-at-point)
                     (fboundp 'network-buffer-iface-at-point)
                     (let ((p (network-buffer-iface-at-point)))
                       (and p (plist-get p :iface))))
                ""))
          (n (read-string "Interface: " default-iface))
          (a (read-string (format "Address for %s: " n)))
          (p (read-number (format "Prefix length for %s/%s: " n a) 24))
          (g (let ((s (read-string
                       (format "Gateway (empty for none): "))))
               (if (string-empty-p s) nil s))))
     (list n a p g)))
  (network--set-static name address prefix gateway))

(defvar network-prefix-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "a") #'network-apply-config)
    (define-key m (kbd "i") #'network-show-interfaces)
    (define-key m (kbd "r") #'network-show-routes)
    (define-key m (kbd "s") #'network-set-static)
    m)
  "Keymap for network commands, hung under \\`C-c e n'.")

(defun network-show-interfaces ()
  "Echo a one-line summary per interface in the minibuffer.
Convenience for the prompt; the real *network* buffer lives in
buffers/ later."
  (interactive)
  (condition-case err
      (dolist (p (network-read-proc-net-dev))
        (message "%-8s rx=%-12d tx=%-12d"
                 (plist-get p :iface)
                 (plist-get p :rx-bytes)
                 (plist-get p :tx-bytes)))
    (error (panic-handle err 'network-show-interfaces))))

(defun network-show-routes ()
  "Echo each kernel route as iface dest/mask -> gw."
  (interactive)
  (condition-case err
      (dolist (r (network-read-proc-net-route))
        (message "%-8s %s/%s -> %s"
                 (plist-get r :iface)
                 (plist-get r :dest)
                 (plist-get r :mask)
                 (plist-get r :gw)))
    (error (panic-handle err 'network-show-routes))))

;; global-map always exists, no use-package needed for built-ins.
(define-key global-map (kbd "C-c e n") network-prefix-map)

;;;; module-load-time bring-up
;;
;; calling apply-config at load time means: as soon as core/network.el
;; is required during boot, lo comes up (or we no-op gracefully if the
;; module is not around). future reconfigurations re-call this.
;;
;; HAZARD: a `condition-case' handler that itself calls an unbound
;; `panic-handle' raises a fresh `void-function' which escapes the
;; handler and would take PID 1 down. guard the handler explicitly:
;; if panic.el somehow has not loaded yet (byte-compile pass, repl
;; eval-buffer, mis-ordered -l) we degrade to a `message' instead.

(condition-case err
    (network-apply-config)
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'network-load-time-apply)
     (message "network: load-time apply failed before panic-handle existed: %S" err))))

(provide 'network)
;;; network.el ends here
