;;; rpc-client.el --- user side of the user/supervisor RPC -*- lexical-binding: t -*-
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

;; v0.6 item 3, rewired in v0.8 step 5.  the user-emacs uses this
;; file to ask the supervisor to do privileged things on its behalf.
;; see rpc-server.el for the matching supervisor side and the wire
;; format.
;;
;; one-shot client: each call opens a fresh AF_UNIX connection via
;; `pid1-unix-connect', runs the auth handshake, sends the request,
;; blocks until reply, closes via `pid1-unix-close'.  the fd is
;; owned by pid1 (the dynamic module) from socket() to close(); the
;; module API does not expose the underlying fd of a
;; `make-network-process' object, so to keep the cmsg-bearing prefix
;; on a fd we own we bypass emacs's network-process layer entirely.
;;
;; authentication runs once per connection right after connect via
;; `pid1-client-auth-handshake'.  on Linux that is a no-op: the
;; supervisor reads peer uid/gid via SO_PEERCRED snapshotted at the
;; client's connect() instant, and the wire bytes are bit-identical
;; to the pre-v0.8 traffic.  on Hurd the handshake performs the
;; rendezvous-port + auth_user_authenticate dance (see
;; docs/v08-hurd-peer-cred-design.md section 3); the cmsg with the
;; rendezvous port travels on the fd this process owns.
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

(defconst geos-rpc--reply-max-bytes (* 64 1024)
  "Hard cap on a single reply body.
mirrors `PID1_UNIX_RECV_MAX' on the C side; a length-prefix
larger than this is treated as a wire-format violation and
aborts the call.  intentionally not a defcustom: this is a
wire-level constant matched in C, not a user-tunable surface.")

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

the AF_UNIX fd is owned by pid1 (the dynamic module) from
`pid1-unix-connect' through `pid1-unix-close'; emacs's
`make-network-process' layer is bypassed so the cmsg-bearing auth
prefix the Hurd backend needs travels on a fd this process owns
from socket() to close().  `pid1-client-auth-handshake' runs once
per connection right after connect; on Linux it is a no-op, on
Hurd it performs the rendezvous-port + auth_user_authenticate
dance."
  (unless (stringp verb)
    (error "geos-rpc: verb must be a string, got %S" verb))
  (let* ((sexp        (cons verb args))
         (payload     (prin1-to-string sexp))
         (plen        (string-bytes payload))
         (lenbuf      (geos-rpc--encode-length plen))
         (timeout-ms  (truncate (* geos-rpc-timeout 1000)))
         (fd          nil))
    (unwind-protect
        (progn
          (setq fd (pid1-unix-connect geos-rpc-socket-path))
          ;; slice 5 of v0.8 design 2.2 wire change: the supervisor
          ;; mints a 16-byte rendezvous NONCE on accept and writes it
          ;; immediately, before any other byte hits the wire.  read
          ;; it here with pid1-unix-recv-exactly, then pass it to
          ;; pid1-client-auth-handshake in the arity-2 form.  on Linux
          ;; the bytes are read and discarded (SO_PEERCRED is server-
          ;; side); on Hurd the NONCE is the rendezvous identifier the
          ;; auth_user_authenticate dance keys off.  the transition
          ;; window where the arity-1 fallback was allowed (slice 4)
          ;; is over now that the supervisor side mints + sends; the
          ;; nonce MUST be consumed before our first pid1-unix-send or
          ;; the supervisor sees 16 bytes of garbage on top of the
          ;; length prefix.
          (let ((nonce (pid1-unix-recv-exactly fd 16 timeout-ms)))
            (pid1-client-auth-handshake fd nonce))
          ;; pid1-unix-send signals on short write; no need to verify
          ;; the return value.  the C side loops on EINTR and only
          ;; returns on success or a hard error.
          (pid1-unix-send fd lenbuf)
          (pid1-unix-send fd payload)
          (let* ((header (pid1-unix-recv-exactly fd 4 timeout-ms))
                 (rlen   (geos-rpc--decode-length header 0)))
            (when (or (< rlen 1) (> rlen geos-rpc--reply-max-bytes))
              (error "geos-rpc: bad reply length %d" rlen))
            (let* ((body   (pid1-unix-recv-exactly fd rlen timeout-ms))
                   (parsed (condition-case e
                               (read-from-string body)
                             (error
                              (error "geos-rpc: parse error %S" e))))
                   (reply  (car parsed)))
              (unless (and (listp reply)
                           (eq (plist-get reply :status) 'ok)
                           (plist-member reply :payload))
                (let ((status  (and (listp reply)
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
              (plist-get reply :payload))))
      (when fd
        (ignore-errors (pid1-unix-close fd))))))

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
