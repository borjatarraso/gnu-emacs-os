;;; hostname.el --- apply /etc/hostname via pid1-set-hostname -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; Guix bakes operating-system host-name into /etc/hostname via
;; etc-service-type, regardless of whether the hostname Shepherd
;; service runs.  but we removed Shepherd.  so /etc/hostname sits on
;; disk and nothing ever calls sethostname(2), which leaves
;; /proc/sys/kernel/hostname as the kernel's compile-time default
;; ("(none)").  uname -a then prints "(none)" in the nodename column,
;; which looks broken even though everything else is fine.
;;
;; this file closes that gap.  read /etc/hostname, trim, hand it to
;; the pid1 module's pid1-set-hostname (sethostname(2) under the
;; hood).  loaded from the boot gexp early, right after panic.el so
;; failures land in *panic* instead of derailing boot.

(require 'panic)

(defconst hostname-file "/etc/hostname"
  "Where Guix's etc-service-type writes operating-system host-name.")

(defun hostname--read ()
  "Return contents of `hostname-file', trimmed.
Return nil when the file is absent or unreadable.  empty/whitespace
content reads as nil so callers can fall back."
  (when (file-readable-p hostname-file)
    (condition-case _
        (let ((s (with-temp-buffer
                   (insert-file-contents hostname-file)
                   (string-trim (buffer-string)))))
          (if (string-empty-p s) nil s))
      (error nil))))

(defun hostname-apply ()
  "Read `hostname-file' and call `pid1-set-hostname'.
Idempotent and safe to invoke at the M-x prompt to re-apply after
editing /etc/hostname.  returns the hostname string on success, nil
on any degraded path (no module, missing file, syscall EPERM).  all
errors route through `panic-handle' so a hostname misconfiguration
cannot take supervision down."
  (interactive)
  (condition-case err
      (let ((name (hostname--read)))
        (cond
         ((not name)
          (message "hostname: %s missing or empty, skipping" hostname-file)
          nil)
         ((not (fboundp 'pid1-set-hostname))
          ;; running as plain `emacs -Q' on a dev host with no module.
          ;; documented degraded mode, not a panic.
          (message "hostname: pid1-set-hostname unbound, skipping (no module)")
          nil)
         (t
          (funcall (symbol-function 'pid1-set-hostname) name)
          (message "hostname: set to %s" name)
          name)))
    (error
     (panic-handle err 'hostname-apply)
     nil)))

;; load-time apply.  same hazard pattern as core/network.el: if
;; panic.el somehow has not loaded yet, degrade to message instead
;; of letting a void-function escape PID 1.
(condition-case err
    (hostname-apply)
  (error
   (if (fboundp 'panic-handle)
       (panic-handle err 'hostname-load-time-apply)
     (message "hostname: load-time apply failed before panic-handle existed: %S" err))))

(provide 'hostname)
;;; hostname.el ends here
