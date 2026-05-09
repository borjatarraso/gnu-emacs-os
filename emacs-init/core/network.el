;;; network.el --- interface bring-up and /proc network state -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

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
  '(("lo" . (:address "127.0.0.1" :netmask "255.0.0.0" :auto-up t)))
  "Declarative interface table.
Each entry is (NAME . PLIST). PLIST keys:
  :address  string, e.g. \"127.0.0.1\"
  :netmask  string, e.g. \"255.0.0.0\"
  :gateway  string or nil
  :auto-up  bool, bring the interface up at boot.

`network-apply-config' walks this list and converges the system
toward it. today only the lo + :auto-up case actually does
anything; the rest is a placeholder until the pid1 module exposes
SIOCSIFADDR."
  :group 'network
  :type '(alist
          :key-type (string :tag "Interface name")
          :value-type
          (plist :key-type symbol
                 :options ((:address (string :tag "IPv4 address"))
                           (:netmask (string :tag "Netmask"))
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
       (t
        ;; TODO(5c): wire :address / :netmask / :gateway once
        ;; pid1-set-address lands C-side. until then we acknowledge
        ;; the config exists but cannot enact it.
        (message "network: %s config noted, no apply path yet (phase 5)" name)
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
not abort the rest."
  (interactive)
  (dolist (entry network-interface-config)
    (network--apply-entry (car entry) (cdr entry))))

;;;; /proc readers
;;
;; pure: open file, parse, return data. no buffer side effects leak
;; out, no global state mutated. these are the sort of thing the
;; *network* buffer (later) will poll on a timer.

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

(defun network-read-proc-net-dev ()
  "Parse /proc/net/dev into a list of plists, one per interface.
Each plist: (:iface STRING :rx-bytes N :rx-packets N :rx-errs N
:rx-drop N :tx-bytes N :tx-packets N :tx-errs N :tx-drop N).
Skips the two header lines. Signals `network-error' if a data
line does not have the expected column count."
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

(defun network--hex-to-ipv4 (hex)
  "Convert kernel little-endian HEX (8 chars) to dotted IPv4 string.
/proc/net/route gives addresses as 32-bit hex in host (LE on x86)
byte order. \"0101A8C0\" is 192.168.1.1. zero is rendered as
\"0.0.0.0\" which is what we want for default-gateway rows."
  (if (or (null hex) (not (= (length hex) 8)))
      (signal 'network-error (list "bad hex ipv4" hex))
    (format "%d.%d.%d.%d"
            (string-to-number (substring hex 6 8) 16)
            (string-to-number (substring hex 4 6) 16)
            (string-to-number (substring hex 2 4) 16)
            (string-to-number (substring hex 0 2) 16))))

(defun network-read-proc-net-route ()
  "Parse /proc/net/route into a list of plists.
Each plist: (:iface STRING :dest STRING :gw STRING :mask STRING
:flags INT :metric INT). Addresses are converted from kernel hex
to dotted IPv4. Signals `network-error' on malformed rows."
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

;;;; user-facing entry points
;;
;; per project rule, our keys hang off `C-c e'. the network sub-prefix
;; is `C-c e n'. nothing fancy yet, just the operations a human might
;; want at the prompt before the *network* buffer lands.

(defvar network-prefix-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "a") #'network-apply-config)
    (define-key m (kbd "i") #'network-show-interfaces)
    (define-key m (kbd "r") #'network-show-routes)
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
