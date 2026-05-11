;;; passwd.el --- /etc/passwd, /etc/shadow, /etc/group reader+writer -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; the multi-user story sits on three colon-separated text files that
;; have not changed shape since the 1970s.  this file owns reading and
;; writing them.  no PAM, no nsswitch.conf, no name-service caching:
;; root is the supervisor emacs, the supervisor is the only writer,
;; and the readers are the *users* buffer plus whatever wants to map
;; uid/gid to name (processes.el, login.el later).
;;
;; layout per file (one record per line, fields separated by `:'):
;;   /etc/passwd  user:x:uid:gid:gecos:home:shell
;;   /etc/shadow  user:hash:lstchg:min:max:warn:inactive:expire:flag
;;   /etc/group   name:x:gid:user1,user2,...
;;
;; the `x' in passwd field 2 is a placeholder indicating the password
;; lives in /etc/shadow, which is the modern unix convention.  we
;; never inline a hash into /etc/passwd; that would make it world-
;; readable on any sane installation.
;;
;; atomicity: every writer goes through `passwd--atomic-write' which
;; renames a tmp file over the live one and fsyncs the parent dir
;; via pid1-fsync-dir, mirroring `state-write' in core/state.el.  on
;; tmpfs the fsync is a near-no-op but rename is still atomic, so the
;; "reader sees old or new, never torn" contract holds either way.
;;
;; HARD RULE: every error path goes through `panic-handle'.  this is
;; system supervision: a bare `error' that escapes here would take
;; PID 1 down.

(require 'cl-lib)
(require 'panic)
(require 'state)
(require 'subr-x)

(defconst passwd-passwd-file "/etc/passwd"
  "Path to the system password database (no hashes, just records).")

(defconst passwd-shadow-file "/etc/shadow"
  "Path to /etc/shadow.  0640 root:shadow on a healthy system.")

(defconst passwd-group-file "/etc/group"
  "Path to /etc/group.")

(defconst passwd-min-uid 1000
  "Lowest UID `passwd-add-user' will pick automatically.
matches the conventional unix split: <1000 are system accounts,
>=1000 are interactive humans.  callers may override by passing an
explicit :uid.")

(defconst passwd-max-uid 60000
  "Upper bound on UIDs `passwd-add-user' will pick.")

(defconst passwd-default-shell "/bin/sh"
  "Default login shell for new users.
points at the shstub which forwards into eshell, so a new account
lands on a working shell out of the box.")

(defconst passwd-default-home-prefix "/home/"
  "Where home directories live; concatenated with the username.")

;;;; tiny parser

(defun passwd--read-lines (path)
  "Return PATH split into a list of non-empty, non-comment lines.
panic-handles read failure.  signals nothing; returns nil if the
file is missing or unreadable so callers can degrade."
  (condition-case err
      (cond
       ((not (file-readable-p path)) nil)
       (t
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8))
            (insert-file-contents path))
          (let ((out '()))
            (dolist (line (split-string (buffer-string) "\n"))
              (let ((trimmed (string-trim line)))
                (unless (or (string-empty-p trimmed)
                            (string-prefix-p "#" trimmed))
                  (push line out))))
            (nreverse out)))))
    (error
     (panic-handle err `(passwd--read-lines . ,path))
     nil)))

(defun passwd--split-record (line)
  "Split LINE on `:' into a list of fields.  no empty trailing skip:
the trailing field of /etc/group is allowed to be the empty string,
which `split-string' with omit-nulls=t would silently drop."
  (split-string line ":" nil))

;;;; readers

(defun passwd-read-passwd ()
  "Return /etc/passwd as a list of plists.
each plist: (:user STRING :uid INT :gid INT :gecos STRING
:home STRING :shell STRING).  malformed rows are skipped with a
panic-handle breadcrumb; we never raise from a read."
  (let ((out '()))
    (dolist (line (passwd--read-lines passwd-passwd-file))
      (condition-case err
          (let ((f (passwd--split-record line)))
            (when (>= (length f) 7)
              (push (list :user  (nth 0 f)
                          :uid   (string-to-number (nth 2 f))
                          :gid   (string-to-number (nth 3 f))
                          :gecos (nth 4 f)
                          :home  (nth 5 f)
                          :shell (nth 6 f))
                    out)))
        (error
         (panic-handle err `(passwd-read-passwd . ,line)))))
    (nreverse out)))

(defun passwd-read-group ()
  "Return /etc/group as a list of plists.
each plist: (:group STRING :gid INT :members LIST-OF-STRING)."
  (let ((out '()))
    (dolist (line (passwd--read-lines passwd-group-file))
      (condition-case err
          (let ((f (passwd--split-record line)))
            (when (>= (length f) 4)
              (push (list :group (nth 0 f)
                          :gid (string-to-number (nth 2 f))
                          :members
                          (let ((m (nth 3 f)))
                            (if (string-empty-p m)
                                nil
                              (split-string m "," t))))
                    out)))
        (error
         (panic-handle err `(passwd-read-group . ,line)))))
    (nreverse out)))

(defun passwd-read-shadow ()
  "Return /etc/shadow as a list of plists.
each plist: (:user STRING :hash STRING :lstchg INT-OR-NIL
:min INT-OR-NIL :max INT-OR-NIL :warn INT-OR-NIL
:inactive INT-OR-NIL :expire INT-OR-NIL :flag STRING).

returns nil when /etc/shadow is unreadable (we do not run as root,
or the file does not exist on this system).  callers must tolerate
nil rather than panicking."
  (let ((out '())
        (parse-int-or-nil
         (lambda (s)
           (cond ((or (null s) (string-empty-p s)) nil)
                 (t (string-to-number s))))))
    (dolist (line (passwd--read-lines passwd-shadow-file))
      (condition-case err
          (let ((f (passwd--split-record line)))
            (when (>= (length f) 2)
              (push (list :user     (nth 0 f)
                          :hash     (nth 1 f)
                          :lstchg   (funcall parse-int-or-nil (nth 2 f))
                          :min      (funcall parse-int-or-nil (nth 3 f))
                          :max      (funcall parse-int-or-nil (nth 4 f))
                          :warn     (funcall parse-int-or-nil (nth 5 f))
                          :inactive (funcall parse-int-or-nil (nth 6 f))
                          :expire   (funcall parse-int-or-nil (nth 7 f))
                          :flag     (or (nth 8 f) ""))
                    out)))
        (error
         (panic-handle err `(passwd-read-shadow . ,line)))))
    (nreverse out)))

;;;; writers

(defun passwd--render-passwd-line (e)
  "Render a passwd plist E back to a colon-delimited line."
  (format "%s:x:%d:%d:%s:%s:%s"
          (plist-get e :user)
          (plist-get e :uid)
          (plist-get e :gid)
          (or (plist-get e :gecos) "")
          (plist-get e :home)
          (plist-get e :shell)))

(defun passwd--render-group-line (e)
  "Render a group plist E back to a colon-delimited line."
  (format "%s:x:%d:%s"
          (plist-get e :group)
          (plist-get e :gid)
          (mapconcat #'identity (or (plist-get e :members) '()) ",")))

(defun passwd--render-shadow-line (e)
  "Render a shadow plist E back to a colon-delimited line.
nil int-or-nil fields render as empty strings, which is how the
on-disk format spells \"unset\"."
  (let ((fmt (lambda (v) (if (numberp v) (format "%d" v) ""))))
    (format "%s:%s:%s:%s:%s:%s:%s:%s:%s"
            (plist-get e :user)
            (plist-get e :hash)
            (funcall fmt (plist-get e :lstchg))
            (funcall fmt (plist-get e :min))
            (funcall fmt (plist-get e :max))
            (funcall fmt (plist-get e :warn))
            (funcall fmt (plist-get e :inactive))
            (funcall fmt (plist-get e :expire))
            (or (plist-get e :flag) ""))))

(defun passwd--atomic-write (path content)
  "Replace PATH with CONTENT atomically.  return t on success, nil on failure.
mirrors `state-write': writes PATH.tmp, renames over PATH, fsyncs
the parent directory.  preserves an existing file's mode bits when
possible (so /etc/shadow stays 0640 across rewrites)."
  (condition-case err
      (let* ((tmp (concat path ".tmp"))
             (dir (file-name-directory path))
             (existing-mode (and (file-exists-p path)
                                 (file-modes path)))
             (coding-system-for-write 'utf-8))
        (with-temp-file tmp
          (insert content))
        (when existing-mode
          (set-file-modes tmp existing-mode))
        (rename-file tmp path t)
        (when (fboundp 'pid1-fsync-dir)
          (condition-case _
              (pid1-fsync-dir dir)
            (error nil)))
        t)
    (error
     (panic-handle err `(passwd--atomic-write . ,path))
     nil)))

(defun passwd-write-passwd (entries)
  "Atomically replace /etc/passwd with rendered ENTRIES."
  (passwd--atomic-write
   passwd-passwd-file
   (concat
    (mapconcat #'passwd--render-passwd-line entries "\n")
    "\n")))

(defun passwd-write-group (entries)
  "Atomically replace /etc/group with rendered ENTRIES."
  (passwd--atomic-write
   passwd-group-file
   (concat
    (mapconcat #'passwd--render-group-line entries "\n")
    "\n")))

(defun passwd-write-shadow (entries)
  "Atomically replace /etc/shadow with rendered ENTRIES."
  (passwd--atomic-write
   passwd-shadow-file
   (concat
    (mapconcat #'passwd--render-shadow-line entries "\n")
    "\n")))

;;;; helpers

(defun passwd--next-uid ()
  "Pick the smallest free UID in [`passwd-min-uid', `passwd-max-uid']."
  (let* ((used (mapcar (lambda (e) (plist-get e :uid))
                       (passwd-read-passwd)))
         (n passwd-min-uid))
    (while (and (<= n passwd-max-uid) (memq n used))
      (setq n (1+ n)))
    (and (<= n passwd-max-uid) n)))

(defun passwd--user-exists-p (name)
  "Return non-nil if NAME is in /etc/passwd."
  (cl-some (lambda (e) (string= (plist-get e :user) name))
           (passwd-read-passwd)))

(defun passwd--group-exists-p (name)
  "Return non-nil if NAME is in /etc/group."
  (cl-some (lambda (e) (string= (plist-get e :group) name))
           (passwd-read-group)))

(defun passwd--days-since-epoch ()
  "Return the integer count of days since 1970-01-01 UTC.
used for shadow's :lstchg field (last password change)."
  (/ (truncate (float-time)) 86400))

(defun passwd--gen-salt-bytes (n)
  "Return N random bytes as a unibyte string from /dev/urandom.
panics if /dev/urandom is unavailable: a random-failure boot
should not silently fall back to a deterministic salt, that is
exactly the way password databases get owned."
  ;; BEG must be nil here, not 0.  `insert-file-contents-literally'
  ;; rejects a non-nil BEG on a non-seekable file/device and
  ;; /dev/urandom is non-seekable.  passing nil means "from the start",
  ;; which is what we want, and END=n caps the read at n bytes.
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (insert-file-contents-literally "/dev/urandom" nil nil n))
    (buffer-substring-no-properties (point-min)
                                    (+ (point-min) n))))

(defconst passwd--salt-alphabet
  "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  "64-char alphabet crypt(3) accepts inside a salt.
yescrypt+sha512crypt both restrict the salt to this set, leaving
the `$' as the field separator.  16 random chars is a 96-bit salt
which is comfortably more than the 64 bits the format requires.")

(defun passwd--gen-salt-string (n)
  "Return an N-char salt drawn from `passwd--salt-alphabet'.
N=16 is the conventional length for yescrypt and sha512crypt."
  (let* ((bytes (passwd--gen-salt-bytes n))
         (out (make-string n ?.)))
    (dotimes (i n)
      (aset out i
            (aref passwd--salt-alphabet (% (aref bytes i) 64))))
    out))

(defun passwd-hash-password (plaintext)
  "Hash PLAINTEXT with a fresh random salt using `pid1-crypt'.
returns the encoded hash string suitable for shadow's :hash slot,
or signals if the pid1 module is not loaded.  default algorithm is
yescrypt (`$y$'), the modern libxcrypt default; falls back to
sha512crypt (`$6$') if the running libxcrypt does not have
yescrypt compiled in (older guix images)."
  (unless (fboundp 'pid1-crypt)
    (signal 'error '("passwd-hash-password: pid1-crypt unbound")))
  (let* ((salt (passwd--gen-salt-string 16))
         ;; yescrypt salt prefix is "$y$j9T$<salt>" where j9T is the
         ;; default cost parameter set; older formats use just $6$<salt>.
         ;; we try yescrypt first; on EINVAL fall back to sha512crypt.
         (yescrypt-salt (concat "$y$j9T$" salt "$"))
         (sha512-salt   (concat "$6$" salt "$")))
    (condition-case _
        (funcall (symbol-function 'pid1-crypt) plaintext yescrypt-salt)
      (error
       (funcall (symbol-function 'pid1-crypt) plaintext sha512-salt)))))

;;;; mutators

(defun passwd-add-user (name &rest plist)
  "Create a new user NAME with optional plist overrides.
recognised keys: :uid INT, :gid INT, :gecos STRING, :home STRING,
:shell STRING.  unspecified fields are derived: uid via
`passwd--next-uid', gid same as uid, home as
`passwd-default-home-prefix'+NAME, shell as `passwd-default-shell',
gecos as the empty string.  also creates a primary group with the
same name and gid.  returns t on success, nil on routed failure.

does NOT set a password; the new account is locked (`!' in shadow)
until `passwd-set-password' runs."
  (interactive "sNew username: ")
  (cond
   ((not (stringp name))
    (panic-handle (list 'passwd-add-user-bad-name name) 'passwd-add-user)
    nil)
   ((string-match-p "[^a-zA-Z0-9_-]" name)
    (panic-handle (list 'passwd-add-user-illegal-name name) 'passwd-add-user)
    nil)
   ((passwd--user-exists-p name)
    (message "passwd: user %s already exists" name)
    nil)
   (t
    (let* ((uid (or (plist-get plist :uid) (passwd--next-uid)))
           (gid (or (plist-get plist :gid) uid))
           (gecos (or (plist-get plist :gecos) ""))
           (home  (or (plist-get plist :home)
                      (concat passwd-default-home-prefix name)))
           (shell (or (plist-get plist :shell) passwd-default-shell)))
      (cond
       ((null uid)
        (panic-handle '(passwd-add-user uid-exhausted) 'passwd-add-user)
        nil)
       (t
        (let* ((pw-rec (list :user name :uid uid :gid gid :gecos gecos
                             :home home :shell shell))
               (sh-rec (list :user name :hash "!" :lstchg
                             (passwd--days-since-epoch)
                             :min 0 :max 99999 :warn 7
                             :inactive nil :expire nil :flag ""))
               (gr-rec (list :group name :gid gid :members (list name)))
               (pws (append (passwd-read-passwd) (list pw-rec)))
               (shs (append (passwd-read-shadow) (list sh-rec)))
               (grs (cond
                     ((passwd--group-exists-p name) (passwd-read-group))
                     (t (append (passwd-read-group) (list gr-rec))))))
          (and (passwd-write-passwd pws)
               (passwd-write-group grs)
               (passwd-write-shadow shs)
               (progn
                 (message "passwd: added user %s uid=%d gid=%d" name uid gid)
                 t)))))))))

(defun passwd-delete-user (name)
  "Remove NAME from /etc/passwd, /etc/shadow, and the same-name group.
refuses to remove uid 0.  does NOT delete the home directory; the
operator is expected to back up first.  returns t on success."
  (interactive
   (list (completing-read "Delete user: "
                          (mapcar (lambda (e) (plist-get e :user))
                                  (passwd-read-passwd)))))
  (let* ((all (passwd-read-passwd))
         (target (cl-find-if (lambda (e) (string= (plist-get e :user) name))
                             all)))
    (cond
     ((null target)
      (message "passwd: no such user %s" name)
      nil)
     ((zerop (plist-get target :uid))
      (message "passwd: refusing to delete uid 0 (%s)" name)
      nil)
     (t
      (let* ((pws (cl-remove-if (lambda (e) (string= (plist-get e :user) name))
                                all))
             (shs (cl-remove-if (lambda (e) (string= (plist-get e :user) name))
                                (passwd-read-shadow)))
             (grs (cl-remove-if (lambda (e) (string= (plist-get e :group) name))
                                (passwd-read-group))))
        (and (passwd-write-passwd pws)
             (passwd-write-shadow shs)
             (passwd-write-group grs)
             (progn (message "passwd: deleted user %s" name) t)))))))

(defun passwd-set-password (name plaintext)
  "Set NAME's hashed password from PLAINTEXT.  routes failure through panic-handle.
PLAINTEXT is hashed via `passwd-hash-password' (yescrypt by
default).  shadow's :lstchg slot is bumped to today.  returns t on
success.  prompts via `read-passwd' interactively so the
plaintext never lands in command-history."
  (interactive
   (list (completing-read
          "User: "
          (mapcar (lambda (e) (plist-get e :user))
                  (passwd-read-passwd)))
         (read-passwd "New password: " t)))
  (cond
   ((or (null plaintext) (string-empty-p plaintext))
    (message "passwd: empty password rejected")
    nil)
   (t
    (condition-case err
        (let* ((hash (passwd-hash-password plaintext))
               (rows (passwd-read-shadow))
               (existing (cl-find-if (lambda (e)
                                       (string= (plist-get e :user) name))
                                     rows))
               (today (passwd--days-since-epoch))
               (updated
                (cond
                 (existing
                  (mapcar
                   (lambda (e)
                     (cond
                      ((string= (plist-get e :user) name)
                       (let ((c (copy-sequence e)))
                         (plist-put c :hash hash)
                         (plist-put c :lstchg today)))
                      (t e)))
                   rows))
                 (t
                  (append rows
                          (list (list :user name :hash hash :lstchg today
                                      :min 0 :max 99999 :warn 7
                                      :inactive nil :expire nil
                                      :flag ""))))))
               (ok (passwd-write-shadow updated)))
          (when ok (message "passwd: password set for %s" name))
          ok)
      (error
       (panic-handle err `(passwd-set-password . ,name))
       nil)))))

;;;; verification (login.el's entry point into the password store)

(defun passwd--extract-salt (stored)
  "Return the salt prefix from STORED, suitable for re-feeding to `pid1-crypt'.
crypt(3)'s output is `$ID$[PARAMS$]SALT$HASH'.  the slice we hand back
to crypt_r is everything up to and including the final `$' before the
hash, which crypt_r treats as the salt input and re-emits with the
correct hash appended.  yescrypt adds a params segment between ID and
salt (`$y$j9T$<salt>$<hash>'); we keep that intact by walking `$' from
the front and stopping when the next segment would be the hash.

returns nil if STORED is missing, locked (`!' or `*' prefix), or
malformed enough that we can't pick out a salt.  callers treat nil as
\"no possible match\" and fail closed."
  (cond
   ((or (null stored) (string-empty-p stored)) nil)
   ((or (string-prefix-p "!" stored) (string-prefix-p "*" stored)) nil)
   ((not (string-prefix-p "$" stored)) nil)
   (t
    (let* ((parts (split-string stored "\\$" t))
           (id (car parts)))
      (cond
       ;; yescrypt: $y$<params>$<salt>$<hash> -> keep first 3 fields
       ((and (string= id "y") (>= (length parts) 4))
        (concat "$" (mapconcat #'identity (cl-subseq parts 0 3) "$") "$"))
       ;; sha512crypt: $6$<salt>$<hash> -> keep first 2 fields.  same
       ;; shape for sha256crypt ($5$) and md5crypt ($1$); we treat them
       ;; uniformly because the position of the hash is identical.
       ((and (member id '("1" "5" "6")) (>= (length parts) 3))
        (concat "$" (mapconcat #'identity (cl-subseq parts 0 2) "$") "$"))
       (t nil))))))

(defun passwd--ct-string-eq (a b)
  "Constant-time-ish string equality.
Elisp's `equal' short-circuits on the first mismatched byte, which
leaks a few microseconds of timing per matched prefix byte.  for a
local console login that is not a realistic attack (the attacker
already has /dev/console), but we are about to extend to network
logins in v0.6 and it costs us nothing to do it right now.

invariant: both args must be strings.  returns t iff they have the
same length AND every byte matches.  the xor accumulator means we
walk the full string regardless of where the mismatch is."
  (cond
   ((not (and (stringp a) (stringp b))) nil)
   ((/= (length a) (length b)) nil)
   (t
    (let ((acc 0)
          (n (length a)))
      (dotimes (i n)
        (setq acc (logior acc (logxor (aref a i) (aref b i)))))
      (zerop acc)))))

(defun passwd-verify (name plaintext)
  "Return t iff PLAINTEXT hashes to NAME's stored shadow entry.
returns nil on any failure path: unknown user, locked account
(`!' or `*' hash), shadow unreadable, salt unparseable, crypt
unavailable, or hash mismatch.

uses `pid1-crypt' against the salt extracted from the stored hash;
this is the same crypt_r(3) used by `passwd-hash-password' so a
password set on this box will re-verify on this box regardless of
which algorithm libxcrypt picked.

the hash comparison is constant-time via `passwd--ct-string-eq'.
the early returns (unknown user, locked, etc.) are NOT
constant-time; that timing leak is documented and accepted: an
attacker who can already poll the login surface fast enough to
distinguish them already knows the username space from /etc/passwd."
  (cond
   ((or (not (stringp name)) (string-empty-p name)) nil)
   ((not (stringp plaintext)) nil)
   ((not (fboundp 'pid1-crypt)) nil)
   (t
    (condition-case err
        (let* ((rows (passwd-read-shadow))
               (row (cl-find-if
                     (lambda (e) (string= (plist-get e :user) name))
                     rows))
               (stored (and row (plist-get row :hash)))
               (salt (passwd--extract-salt stored)))
          (cond
           ((null salt) nil)
           (t
            (let ((computed
                   (funcall (symbol-function 'pid1-crypt) plaintext salt)))
              (passwd--ct-string-eq stored computed)))))
      (error
       (panic-handle err `(passwd-verify . ,name))
       nil)))))

;;;; user-facing keymap (under C-c e u)

(defvar passwd-prefix-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "a") #'passwd-add-user)
    (define-key m (kbd "d") #'passwd-delete-user)
    (define-key m (kbd "p") #'passwd-set-password)
    m)
  "Keymap for user-account commands, hung under \\`C-c e u'.")

(define-key global-map (kbd "C-c e u") passwd-prefix-map)

(provide 'passwd)
;;; passwd.el ends here
