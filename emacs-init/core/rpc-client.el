;;; rpc-client.el --- user side of the user/supervisor RPC -*- lexical-binding: t -*-
;;; SPDX-License-Identifier: GPL-3.0-or-later

;; v0.6 item 3.  the user-emacs uses this file to ask the supervisor
;; to do privileged things on its behalf.  see rpc-server.el for the
;; matching supervisor side and the wire format.
;;
;; one-shot client: each call opens a fresh AF_UNIX connection,
;; sends the request, blocks until reply, closes.  emacs's
;; `make-network-process' supports `:family local' for unix-domain
;; sockets so this needs no C primitive on the client side.
;;
;; authentication is implicit: the kernel records the connecting
;; process's uid/gid at connect() time and the supervisor reads it
;; via SO_PEERCRED.  the user-emacs cannot lie about its uid.
;;
;; wire format mirrors rpc-server.el:
;;   request:  4-byte big-endian length, then LEN bytes of (verb arg1 ...)
;;   reply:    same shape; (:status STATUS :payload P)
;;
;; trust model: the reply sexp comes from the supervisor (root) and
;; is `read'-parsed.  we do NOT eval it.  the reply structure is
;; pattern-matched against the (:status :payload) shape; anything
;; else is a protocol error and is surfaced via `error'.

(require 'cl-lib)
(require 'panic)

(defcustom geos-rpc-socket-path "/run/geos/super.sock"
  "Path of the supervisor's RPC socket.
must match `rpc-server-socket-path' in the supervisor's
rpc-server.el.  hard-coded here for the v0.6 MVP; later versions
may discover the path via an environment variable set by
session.el at spawn time."
  :type 'string)

(defcustom geos-rpc-timeout 5.0
  "Seconds to wait for a complete reply before giving up.
the supervisor's per-verb handlers are short for v0.6 (no shell-
outs, no large data), so 5s is generous.  raise for the future
package-install verb which streams output."
  :type 'number)

(defun geos-rpc--encode-length (n)
  "Return a 4-byte big-endian unibyte string encoding N."
  (unibyte-string (logand (ash n -24) #xff)
                  (logand (ash n -16) #xff)
                  (logand (ash n  -8) #xff)
                  (logand n          #xff)))

(defun geos-rpc--decode-length (s offset)
  "Read 4 BE bytes from string S at OFFSET, return integer."
  (logior (ash (aref s (+ offset 0)) 24)
          (ash (aref s (+ offset 1)) 16)
          (ash (aref s (+ offset 2))  8)
          (aref s (+ offset 3))))

(defun geos-rpc--read-bytes (proc buf n deadline)
  "Block until BUF (process buffer of PROC) holds >= N bytes.
returns t on success, nil on deadline or process death.
DEADLINE is an absolute `float-time' value.  the loop calls
`accept-process-output' with short timeouts so a slow supervisor
yields control predictably (the user-emacs is still single-
threaded; UI redisplay does not happen during this loop but a
500ms wedge on a privileged operation is acceptable)."
  (with-current-buffer buf
    (while (and (< (buffer-size) n)
                (< (float-time) deadline)
                (process-live-p proc))
      (accept-process-output proc 0.1))
    (>= (buffer-size) n)))

(defun geos-rpc (verb &rest args)
  "Send (VERB . ARGS) to the supervisor, return the reply payload.
VERB is a string matching one of the verbs in rpc-server.el's
`rpc-server--verbs'.  ARGS are arbitrary elisp values; they will
be `prin1'd into the request sexp.  ARGS must be printable
(no buffer objects, markers, etc.).

reply shape: a plist (:status STATUS :payload P).
  STATUS = `ok'     -> return P.
  STATUS = `error'  -> signal `error' with P as the message.
  anything else     -> signal `error' as a protocol violation.

failure modes:
  - socket missing (supervisor not running, or RPC disabled):
    signals `error' with the socket path in the message.
  - timeout: signals `error'.
  - malformed reply: signals `error' (does NOT eval).

uses a process-attached buffer (not `with-temp-buffer') because
the network process needs a live buffer to collect bytes into."
  (unless (stringp verb)
    (error "geos-rpc: verb must be a string, got %S" verb))
  (let* ((sexp     (cons verb args))
         (payload  (prin1-to-string sexp))
         (plen     (string-bytes payload))
         (lenbuf   (geos-rpc--encode-length plen))
         (deadline (+ (float-time) geos-rpc-timeout))
         (recv-buf (generate-new-buffer " *geos-rpc-recv*"))
         (proc nil)
         result)
    (unwind-protect
        (progn
          (with-current-buffer recv-buf
            (set-buffer-multibyte nil))
          (setq proc (make-network-process
                      :name "geos-rpc"
                      :family 'local
                      :service geos-rpc-socket-path
                      :coding 'binary
                      :buffer recv-buf
                      :sentinel #'ignore
                      :noquery t))
          (process-send-string proc lenbuf)
          (process-send-string proc payload)
          ;; read 4-byte reply length
          (unless (geos-rpc--read-bytes proc recv-buf 4 deadline)
            (error "geos-rpc: no reply length within %ss"
                   geos-rpc-timeout))
          (let* ((header (with-current-buffer recv-buf
                           (buffer-substring-no-properties 1 5)))
                 (rlen   (geos-rpc--decode-length header 0))
                 (total  (+ 4 rlen)))
            (when (or (< rlen 1) (> rlen (* 64 1024)))
              (error "geos-rpc: bad reply length %d" rlen))
            (unless (geos-rpc--read-bytes proc recv-buf total deadline)
              (error "geos-rpc: short reply (%d/%d bytes)"
                     (with-current-buffer recv-buf (buffer-size))
                     total))
            (let* ((body (with-current-buffer recv-buf
                           (buffer-substring-no-properties 5 (+ 5 rlen))))
                   (parsed (condition-case e
                               (read-from-string body)
                             (error (error "geos-rpc: parse error %S" e))))
                   (reply (car parsed)))
              (unless (and (listp reply)
                           (eq (plist-get reply :status) 'ok)
                           (plist-member reply :payload))
                (let ((status (and (listp reply)
                                   (plist-get reply :status)))
                      (payload (and (listp reply)
                                    (plist-get reply :payload))))
                  (cond
                   ((eq status 'error)
                    (error "geos-rpc: %s"
                           (if (stringp payload) payload
                             (format "%S" payload))))
                   (t
                    (error "geos-rpc: protocol violation: %S" reply)))))
              (setq result (plist-get reply :payload)))))
      (when proc
        (delete-process proc))
      (when (buffer-live-p recv-buf)
        (kill-buffer recv-buf)))
    result))

;; --------------------------------------------------------------------
;; convenience wrappers
;; --------------------------------------------------------------------

(defun geos-rpc-ping ()
  "Send `ping' to the supervisor, return its reply.
the cheap smoke test for the RPC plumbing.  on a healthy system
this returns the symbol `pong'."
  (interactive)
  (let ((r (geos-rpc "ping")))
    (when (called-interactively-p 'interactive)
      (message "geos-rpc-ping: %S" r))
    r))

(defun geos-rpc-journal-tail (&optional n)
  "Return the last N lines of the supervisor's *Messages* (default 50).
the supervisor clamps N to [1, 500]."
  (interactive "P")
  (let* ((nn (cond ((numberp n) n)
                   ((consp n) 50)
                   (t 50)))
         (r (geos-rpc "journal-tail" nn)))
    (when (called-interactively-p 'interactive)
      (with-current-buffer (get-buffer-create "*supervisor-journal*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (dolist (line r) (insert line "\n"))
          (special-mode))
        (display-buffer (current-buffer))))
    r))

(defun geos-rpc-reboot ()
  "Ask the supervisor to reboot.  prompts before sending.
the supervisor calls reboot(2) on success; the kernel terminates
this process along with everything else.  if the supervisor
returns instead (reboot syscall failed), the reply is
`(:status ok :payload rebooting)' but the box stays up."
  (interactive)
  (when (yes-or-no-p "Reboot the machine? ")
    (condition-case err
        (geos-rpc "reboot")
      (error
       (panic-handle err 'geos-rpc-reboot)))))

(defun geos-rpc-poweroff ()
  "Ask the supervisor to power off.  prompts before sending."
  (interactive)
  (when (yes-or-no-p "Power off the machine? ")
    (condition-case err
        (geos-rpc "poweroff")
      (error
       (panic-handle err 'geos-rpc-poweroff)))))

(global-set-key (kbd "C-c e R") #'geos-rpc-reboot)
(global-set-key (kbd "C-c e P") #'geos-rpc-poweroff)

(provide 'rpc-client)
;;; rpc-client.el ends here
