;;; cmdline.el --- /proc/cmdline parser shared by core/ -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Author: Borja Tarraso <borja.tarraso@member.fsf.org>
;;; Project: GNU/Emacs Operating System (GEOS)

;; two callers used to parse /proc/cmdline on their own and they had
;; quietly drifted apart.  boot-marker.el wanted prefix-match: did the
;; kernel get told `geos.mode=' anything?  any value after the `=' was
;; fine.  session.el wanted literal-token match: is the exact string
;; `geos.login=skip' on the cmdline, and not as a substring of
;; something else.  same anchoring rule on the left edge (start of
;; line or whitespace), different rule on the right edge (any tail vs
;; whitespace-or-eol).  W3 in the phase-3 skeptic notes asked for one
;; source of truth before a third caller showed up and invented a
;; third variant.  this file is that source of truth.
;;
;; design choice: tokenize once, build the two predicates on top.  the
;; tokenize step is the only place that touches the filesystem; the
;; predicates are pure string-list ops on its result.  that way the
;; over-match traps (`not-geos.mode=foo' should not satisfy
;; `geos.mode=', the substring `bar geos.login=skipnot' should not
;; satisfy `geos.login=skip') reduce to "is this a real token" rather
;; than "does my regex anchor the right edge correctly".
;;
;; never raises.  unreadable /proc/cmdline (dev host, sandbox, fuse
;; weirdness, doesn't matter) returns nil and the caller falls through
;; to its non-boot path.  the boot must not die because we could not
;; figure out whether we are booting.

(defvar geos-cmdline-path "/proc/cmdline"
  "Path to the kernel command line pseudo-file.
defvar (not defconst) so a test harness can rebind it to a fixture
file under /tmp without touching the real /proc.  not user-tunable
in any meaningful sense; the path is fixed by Linux.  every helper
in this file reads through this variable, so a single `let' is
enough to swap the source.")

(defun geos-cmdline-tokens ()
  "Return the whitespace-delimited tokens of `geos-cmdline-path' as a list.
Returns nil if the file is unreadable or if reading it raises.  the
file is read as binary so a stray non-utf8 byte (rare but legal in a
bootloader-supplied cmdline) does not raise a decoding error.  the
result is a list of strings with no empty entries; the caller should
not have to filter empty tokens out.  this is the only function in
this file that touches the filesystem."
  (and (file-readable-p geos-cmdline-path)
       (condition-case _
           (let ((coding-system-for-read 'binary))
             (with-temp-buffer
               (insert-file-contents geos-cmdline-path)
               ;; split-string with omit-nulls and a whitespace regexp
               ;; drops leading, trailing, and run-of-spaces empties.
               ;; the kernel terminates cmdline with a newline, which
               ;; the whitespace class catches.
               (split-string (buffer-string) "[ \t\n\r]+" t)))
         (error nil))))

(defun geos-cmdline-token-p (token)
  "Return non-nil iff TOKEN is a literal whitespace-delimited token on the cmdline.
TOKEN is a plain string, not a regex; it is compared with `string='.
this is the strict match: `geos.login=skip' matches only the exact
string `geos.login=skip', not `geos.login=skipnot' and not
`not-geos.login=skip'.  errors are swallowed via `geos-cmdline-tokens'
and return nil."
  (and (stringp token)
       (member token (geos-cmdline-tokens))
       t))

(defun geos-cmdline-key-present-p (key)
  "Return non-nil iff some cmdline token starts with KEY.
KEY is a literal string (typically something like `geos.mode='), not
a regex.  this is the prefix match: `geos.mode=' is satisfied by any
token that begins with those nine characters, so `geos.mode=ui' and
`geos.mode=console' both match but `not-geos.mode=ui' does not (it
starts with `not-', not with `geos.mode=').  errors are swallowed
via `geos-cmdline-tokens' and return nil."
  (and (stringp key)
       (let ((toks (geos-cmdline-tokens))
             (hit nil))
         (while (and toks (not hit))
           (when (string-prefix-p key (car toks))
             (setq hit t))
           (setq toks (cdr toks)))
         hit)))

(provide 'cmdline)
;;; cmdline.el ends here
