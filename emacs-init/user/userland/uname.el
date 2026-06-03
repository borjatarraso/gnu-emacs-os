;;; uname.el --- GEOS-aware uname for eshell -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>

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
;;
;; on hurd the /proc/sys/kernel/* nodes MAY exist (the hurd procfs
;; translator exposes them, with hurd-native values like "GNU" for
;; ostype and "0.9" for osrelease) or MAY return "" if the translator
;; is not mounted or the node is stripped.  the port seam in
;; core/port.el carries the branch: on hurd we try the same four
;; /proc reads first, and fall back PER FIELD to Emacs built-ins
;; (system-name, emacs-build-time, literal "GNU") for any node that
;; returns "".  per-field, not all-or-nothing: a half-populated
;; procfs gets stitched together with synthesized defaults for the
;; missing columns.  the branch lives at the data-source layer
;; (geos--uname), the eshell entry point geos/uname is unchanged.

(require 'panic)
(require 'port)

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

(defun geos--uname-linux ()
  "Linux backend for `geos--uname'.
Pulls the four UTS fields from /proc/sys/kernel/{ostype,osrelease,
version,hostname}, the same paths uname(2) reads under the hood.
Returns a plist (:kernel STRING :release STRING :version STRING
:host STRING).  the strings are trimmed; an unreadable node degrades
to \"\" via `geos--uts-field' and the caller renders an empty column,
which is what coreutils uname does too on a stripped /proc."
  (list :kernel  (geos--uts-field "/proc/sys/kernel/ostype")
        :release (geos--uts-field "/proc/sys/kernel/osrelease")
        :version (geos--uts-field "/proc/sys/kernel/version")
        :host    (geos--uts-field "/proc/sys/kernel/hostname")))

(defun geos--parse-proc-version-hurd (raw)
  "Parse Hurd's /proc/version into a (RELEASE . VERSION) cons.
On Debian Hurd 0.9 the file is of the form
  Linux version 2.6.1 (GNU 0.9 GNU-Mach ... x86_64)
the leading \"Linux version 2.6.1\" is a Linux-compat preamble;
the parenthesised payload is what we actually want.  RELEASE comes
from the \"GNU <release>\" prefix inside the parens (\"0.9\" here);
VERSION is the rest of the parenthesised payload (the Mach build
string plus arch).  returns nil if RAW does not match the expected
shape so callers fall back to the synthesized defaults."
  (when (stringp raw)
    (let ((trimmed (string-trim raw)))
      (when (string-match
             "(GNU \\([^ )]+\\) +\\(.*\\))[^()]*\\'"
             trimmed)
        (cons (match-string 1 trimmed)
              (string-trim (match-string 2 trimmed)))))))

(defun geos--uname-hurd ()
  "Hurd backend for `geos--uname'.
Try the same /proc/sys/kernel/* paths Linux uses; the hurd procfs
translator exposes them when configured with sysctl emulation,
with hurd-native values (ostype likely \"GNU\" or \"Hurd\",
osrelease likely something like \"0.9\").  Stock Debian Hurd 0.9
does NOT publish /proc/sys/, so the per-field reads fall through
to a secondary source: /proc/version, which is exposed unconditionally
and carries a (GNU <release> GNU-Mach <version> ...) payload we can
parse for :release and :version.  if even /proc/version is absent
we substitute synthesized defaults per-field:

  :kernel  default \"GNU\"  (mach + hurd servers; matches `uname -s'
                              on a real hurd box)
  :release default \"unknown\".  /proc/version parse gives \"0.9\"
                              on debian hurd 0.9 when the sysctl
                              tree is missing.
  :version default `GEOS-userland built <emacs-build-time>'.
                              /proc/version parse gives the GNU-Mach
                              build string when the sysctl tree is
                              missing; honest fallback otherwise.
  :host    default `(system-name)', which on a booted GEOS is what
                              /etc/hostname applied via pid1's
                              sethostname(2) call.

Per-field fallback, not all-or-nothing: a half-populated procfs
gets stitched together with /proc/version data or synthesized
defaults for the missing columns.  no shelling-out."
  (let* ((proc-kernel  (geos--uts-field "/proc/sys/kernel/ostype"))
         (proc-release (geos--uts-field "/proc/sys/kernel/osrelease"))
         (proc-version (geos--uts-field "/proc/sys/kernel/version"))
         (proc-host    (geos--uts-field "/proc/sys/kernel/hostname"))
         (procv-raw    (geos--uts-field "/proc/version"))
         (procv-pair   (geos--parse-proc-version-hurd procv-raw))
         (procv-release (car-safe procv-pair))
         (procv-version (cdr-safe procv-pair))
         (synth-version (concat "GEOS-userland built "
                                (format-time-string
                                 "%a %b %e %H:%M:%S %Y"
                                 (or emacs-build-time (current-time))))))
    (list :kernel  (if (string-empty-p proc-kernel)  "GNU"          proc-kernel)
          :release (cond ((not (string-empty-p proc-release)) proc-release)
                         (procv-release procv-release)
                         (t "unknown"))
          :version (cond ((not (string-empty-p proc-version)) proc-version)
                         (procv-version procv-version)
                         (t synth-version))
          :host    (if (string-empty-p proc-host)
                       (or (system-name) "")
                     proc-host))))

(defun geos--uname ()
  "Return the four UTS fields as a plist, dispatching on `geos-kernel'.
Plist shape: (:kernel STRING :release STRING :version STRING :host
STRING).  Linux arm reads /proc/sys/kernel/*; hurd arm reads the
same paths (hurd procfs translator) and falls back per-field to
Emacs built-ins for any node that returns \"\".  the branch lives
here (data-source layer), not in `eshell/uname' (render layer);
that file builds output strings out of whatever this returns and
never asks which kernel it is on."
  (cond
   ((geos-kernel-linux-p) (geos--uname-linux))
   ((geos-kernel-hurd-p)  (geos--uname-hurd))
   ;; unknown kernel: uname needs SOMETHING to print or eshell
   ;; explodes, so we lie to the user and return the linux shape.
   ;; this is the one place in the port seam where we do NOT route
   ;; through geos-port-unimplemented; the render-or-bust contract
   ;; of eshell/uname wins over the "loud failure on unknown
   ;; kernel" rule documented in core/port.el.
   (t                     (geos--uname-linux))))

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
             (fields  (geos--uname))
             (kernel  (or (plist-get fields :kernel)  ""))
             (release (or (plist-get fields :release) ""))
             (version (or (plist-get fields :version) ""))
             (host    (or (plist-get fields :host)    ""))
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
