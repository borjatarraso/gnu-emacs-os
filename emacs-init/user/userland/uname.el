;;; uname.el --- GEOS-aware uname for eshell -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; the kernel's uname(2) syscall returns "Linux" for sysname because
;; that string is hard-coded into the kernel at compile time
;; (init/version.c, UTS_SYSNAME). userland cannot override it via
;; sethostname/setdomainname; only nodename and domainname are
;; writable from CAP_SYS_ADMIN.
;;
;; that is fine. in GEOS, no system binary in the profile actually
;; calls uname(2) for anything user-visible, because there is no
;; system binary that the user runs as a CLI. eshell IS the only
;; shell, /bin/sh forwards into eshell, so when the user types
;;   $ uname -a
;; the resolution path is:
;;   1. eshell looks for an alias named "uname"  (none)
;;   2. eshell looks for a function named eshell/uname (this file)
;;   3. only if both are absent does eshell exec the binary
;; we override step 2. the user sees GEOS as the OS, with the actual
;; kernel name in parens so they still know the kernel underneath.
;;
;; if a future tool calls uname(2) directly, it will still see
;; "Linux". that is correct behavior: the kernel IS Linux. GEOS is
;; the OS that runs ON Linux. only the user-facing CLI is rebranded.

(require 'panic)

(defun geos--uts-field (file)
  "Read FILE and return its trimmed contents as a string.
Used to pull /proc/sys/kernel/* values without shelling out."
  (condition-case _
      (with-temp-buffer
        (insert-file-contents file)
        (string-trim (buffer-string)))
    (error "")))

(defun geos--machine ()
  "Best-effort guess at the hardware machine string.
emacs's `system-configuration' looks like \"x86_64-pc-linux-gnu\";
the leading hyphen-separated component is what `uname -m' would
return on this build."
  (or (car-safe (split-string (or system-configuration "") "-"))
      "unknown"))

(defun geos--uname-flags (argv)
  "Parse a uname-style ARGV list and return a string of flag chars.
Accepts both clustered (\"-asr\") and split (\"-a\" \"-s\" \"-r\") forms.
Anything that does not start with `-' is ignored: GEOS uname has no
positional args."
  (mapconcat (lambda (a)
               (if (and (stringp a) (string-prefix-p "-" a))
                   (substring a 1)
                 ""))
             argv ""))

(defun eshell/uname (&rest args)
  "GEOS uname.  Replaces sysname `Linux' with `GEOS', annotates the
real kernel name in parentheses on -a output.

Supported flags: -a -s -n -r -v -m -o and --help.  Unknown flags are
treated as -s, which matches GNU coreutils behavior."
  (condition-case err
      (let* ((argv (flatten-tree args))
             (flags (geos--uname-flags argv))
             (kernel  (geos--uts-field "/proc/sys/kernel/ostype"))
             (release (geos--uts-field "/proc/sys/kernel/osrelease"))
             (version (geos--uts-field "/proc/sys/kernel/version"))
             (host    (geos--uts-field "/proc/sys/kernel/hostname"))
             (mach    (geos--machine))
             (sysname "GEOS")
             (osname  "GNU/Emacs"))
        (cond
         ((member "--help" argv)
          (concat
           "Usage: uname [OPTION]...\n"
           "Print certain system information.  GEOS edition.\n"
           "  -a   all of the below, in the order: -snrvmo\n"
           "  -s   sysname (GEOS)\n"
           "  -n   nodename (hostname)\n"
           "  -r   kernel release\n"
           "  -v   kernel version\n"
           "  -m   machine hardware\n"
           "  -o   operating system\n"))
         ((string-match-p "a" flags)
          ;; GEOS hostname kernel-release kernel-version machine GNU/Emacs (Linux)
          ;; the parenthesised kernel is the GEOS-specific addition;
          ;; everything else matches the columns coreutils prints.
          (format "%s %s %s %s %s %s (%s)\n"
                  sysname host release version mach osname kernel))
         ((string-match-p "n" flags) (concat host    "\n"))
         ((string-match-p "r" flags) (concat release "\n"))
         ((string-match-p "v" flags) (concat version "\n"))
         ((string-match-p "m" flags) (concat mach    "\n"))
         ((string-match-p "o" flags) (concat osname  "\n"))
         ;; -s, default, or unknown flags: just the sysname.
         (t (concat sysname "\n"))))
    (error
     (if (fboundp 'panic-handle)
         (panic-handle err 'eshell-uname))
     ;; eshell expects a string return; degrade gracefully so the
     ;; user does not see "uname: lisp error" if something blew up.
     "GEOS\n")))

(provide 'userland-uname)
;;; uname.el ends here
