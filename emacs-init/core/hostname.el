;;; hostname.el --- apply /etc/hostname via pid1-set-hostname -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

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

(defconst hostname-max-length 63
  "Maximum hostname length we accept.
Linux's HOST_NAME_MAX is 64 INCLUDING the trailing NUL, so the
usable length is 63.  sethostname(2) takes a length argument and
will accept exactly 64 bytes, but utsname.nodename is sized to
HOST_NAME_MAX and a 64-byte name leaves no room for the NUL the
gethostname(3) wrapper expects.  We cap at 63 so what we set is
what gethostname will return.")

(defconst hostname-valid-regexp
  "\\`[a-z0-9]\\(?:[a-z0-9-]*[a-z0-9]\\)?\\'"
  "RFC 952/1123 single-label hostname syntax, lowercase only.
Letters, digits, and internal hyphens; no leading or trailing
hyphen, no dots, no whitespace, no control bytes.  DNS is
case-insensitive on the wire but every shell prompt, log line, and
config file in this tree assumes lowercase, and accepting mixed
case here just means /etc/hostname can drift out of sync with what
people type.  We do not allow multi-label names because
/etc/hostname conventionally holds the short name; the FQDN comes
from DNS.")

(defun hostname--validation-failure (s)
  "Return a symbol describing why S is not a valid hostname, or nil if it is.
Used to surface specific failure modes in messages and panic frames so
an operator looking at *panic* sees \"too long\" instead of a generic
\"missing or invalid\".  (M6, audit round-5 2026-05-10)"
  (cond
   ((not (stringp s))                              'not-a-string)
   ((string-empty-p s)                             'empty)
   ((> (length s) hostname-max-length)             'too-long)
   ((not (string-match-p hostname-valid-regexp s)) 'bad-syntax)
   (t                                              nil)))

(defun hostname--validate (s)
  "Return S if it is a syntactically valid hostname, else nil.
Rejects empty, oversize, and anything outside `hostname-valid-regexp'.
Used to keep a malformed /etc/hostname from being passed verbatim
to sethostname(2)."
  (and (null (hostname--validation-failure s)) s))

(defun hostname--read ()
  "Return validated contents of `hostname-file', else nil.
Reads as raw bytes (binary), trims surrounding whitespace, then
runs the result through `hostname--validate'.  binary read avoids
coding-system surprises on a /proc-shaped boundary file."
  (when (file-readable-p hostname-file)
    (condition-case _
        (let* ((coding-system-for-read 'binary)
               (s (with-temp-buffer
                    (insert-file-contents hostname-file)
                    (string-trim (buffer-string))))
               (why (hostname--validation-failure s)))
          (cond
           ((null why) s)
           (t
            (message "hostname: %s rejected (%s, raw=%S)"
                     hostname-file why s)
            nil)))
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
          (message "hostname: %s missing, empty, or invalid, skipping"
                   hostname-file)
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
