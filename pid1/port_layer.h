/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* port_layer.h, the kernel-portability seam for pid1.
 *
 * pid1 has a handful of operations that are Linux syscalls today and
 * will be Mach RPCs on the Hurd port. instead of sprinkling
 * #ifdef __linux__ across emacs-init.c, every such operation goes
 * through a function pointer hung off a single struct.  one C file
 * per kernel (port_linux.c, eventually port_hurd.c on the side
 * branch) defines the bodies; the active backend is selected once at
 * startup and never swapped.
 *
 * the spike that produced this layer is docs/v04-item11-hurd-spike.md.
 * step 1 of the work order there is "port-layer refactor on Linux, no
 * Hurd code yet, zero behaviour change", which is what landing this
 * header accomplishes.
 *
 * design notes:
 *
 *   - waitpid(2) is POSIX and works on Hurd as-is.  it does not go
 *     through the port layer; the supervisor calls it directly.
 *     same goes for fsync, open/close, socket, posix_spawn / fork+
 *     execve, and crypt(3).  the layer carries only the surfaces the
 *     spike flagged as Linux-only.
 *
 *   - every function returns 0 on success, -1 with errno set on
 *     failure.  matches the libc convention every existing caller
 *     already speaks; cuts the diff in emacs-init.c down to a name
 *     swap.
 *
 *   - prctl(PR_SET_NAME) is listed in HURD_PORT.md as part of the
 *     port surface, but pid1 does not call it today.  I keep the
 *     struct minimal: adding capabilities the implementation does
 *     not use is how a clean abstraction rots into a maintenance
 *     hazard.  when a real caller appears the slot lands then.
 *
 *   - suspend takes the kernel-side state string (mem/freeze/standby/
 *     disk) rather than a numeric enum.  the elisp side already
 *     whitelists the four tokens; passing the same string through to
 *     the port keeps the layering symmetrical and avoids a translation
 *     table that the Hurd backend would have to mirror anyway.
 *
 *   - set_address takes a CIDR prefix length (0..32), not a netmask.
 *     the existing module binding (Fpid1_set_address) computes the
 *     mask itself from the prefix; pushing that into the port layer
 *     would force every backend to repeat the same arithmetic.
 *
 *   - the address parameters are uint32_t in network byte order, the
 *     same shape the kernel ABI uses on Linux.  the Hurd pfinet RPC
 *     takes the same byte order, so the boundary is consistent.
 */

#ifndef GEOS_PID1_PORT_LAYER_H
#define GEOS_PID1_PORT_LAYER_H

#include <stddef.h>
#include <stdint.h>

typedef struct port_caps {
    /* the backend's short kernel name, "linux" or "hurd".  the
     * standalone PID 1 binary (emacs-init.c main()) snprintf's
     * "GEOS_KERNEL=<name>" from this slot into its execve envp before
     * spawning the supervisor emacs, and core/session.el forwards that
     * env var through to each per-user emacs.  core/port.el reads it
     * via `(getenv "GEOS_KERNEL")' and interns it as `geos-kernel'.
     *
     * the module path (emacs_module_init) does NOT re-splice; it is
     * loaded inside the process that main() already execve'd with
     * GEOS_KERNEL in its env, so the supervisor emacs inherits the
     * value through normal process-env inheritance.  this asymmetry is
     * intentional: the module is never the primordial process, so it
     * never sets process env, it only inherits it.
     *
     * bare const char * because there is no runtime dispatch here, only
     * an identity.  each backend's table answers "which kernel am I"
     * for both the elisp seam and the env splice; one slot, one
     * answer.  port_require_or_abort() asserts non-NULL. */
    const char *kernel_name;

    /* mount(2) on Linux; settrans-equivalent on Hurd.  same semantics
     * as Linux mount(2): src/tgt/type may not be NULL, opts may. */
    int (*mount)(const char *src, const char *tgt, const char *type,
                 unsigned long flags, const char *opts);

    /* sethostname(2) on Linux; Mach proc_sethostname-ish on Hurd. */
    int (*set_hostname)(const char *name, size_t len);

    /* bring up the loopback interface.  no args because every backend
     * knows its own loopback name ("lo" on Linux). */
    int (*bring_up_lo)(void);

    /* assign IPv4 ADDR_BE (network byte order) + PREFIX (0..32) to
     * IFNAME and bring it up.  on Linux this is three ioctls. */
    int (*set_address)(const char *ifname, uint32_t addr_be, int prefix);

    /* install a default IPv4 route via GW_BE (network byte order)
     * through IFNAME.  on Linux this is one SIOCADDRT. */
    int (*set_route_default)(uint32_t gw_be, const char *ifname);

    /* reboot(2) on Linux with the LINUX_REBOOT_CMD_* constant in CMD;
     * host_reboot Mach RPC on Hurd.  syncs first.  on success the
     * kernel kills every process including the caller, so a return is
     * only ever -1 with errno set. */
    int (*reboot)(int cmd);

    /* suspend the system to STATE ("mem"/"freeze"/"standby"/"disk").
     * on Linux this is a write to /sys/power/state and the call
     * returns when the kernel finishes resuming.  Hurd has no
     * equivalent today; the Hurd backend returns -1 with errno=ENOSYS
     * and the elisp side renders M-x geos-suspend as "not on this
     * kernel".  (W5) the Hurd stub will not use STATE; cast it to
     * (void) at the top of the body to keep -Wunused-parameter quiet
     * under -Werror. */
    int (*suspend)(const char *state);

    /* peer credentials for an AF_UNIX SOCK_STREAM accepted fd.
     * on Linux this is getsockopt(SO_PEERCRED) returning struct ucred.
     * on Hurd there is no SO_PEERCRED; auth ports passed via mach_msg
     * are the native equivalent but require a separate handshake the
     * RPC channel does not have yet.  the Hurd backend returns -1 with
     * errno=ENOSYS until a real handshake lands.  the supervisor side
     * (Fpid1_rpc_poll) special-cases ENOSYS by closing the connection
     * and returning nil to the poller, so the per-200ms timer does not
     * panic forever on the unsupported kernel; every other errno is
     * forwarded as pid1-error and panic-handled.  UID_OUT / GID_OUT
     * are written only on success; on failure their contents are
     * unspecified, and the caller initialises them to a non-root
     * sentinel before the port call as defence in depth. */
    int (*get_peer_cred)(int fd, uint32_t *uid_out, uint32_t *gid_out);

    /* client-side counterpart to get_peer_cred.  the Linux peer-cred
     * model is server-only: getsockopt(SO_PEERCRED) reads a snapshot
     * the kernel took at the client's connect() instant, so the client
     * has nothing to do.  the Hurd model is bidirectional: pflocal has
     * no SO_PEERCRED, so the client and the server have to perform an
     * auth_user_authenticate / auth_server_authenticate dance against
     * the gnumach auth server, joined by a rendezvous Mach port the
     * client transmits to the server via pflocal's SCM_PORT-equivalent
     * cmsg.  this slot is what the client side calls right after
     * connect(2) and before its first send: allocate the rendezvous,
     * sendmsg it as ancillary data on a single placeholder byte, then
     * register with the auth server.  the supervisor's get_peer_cred
     * body consumes that byte (and the attached cmsg) before reading
     * the 4-byte length prefix.
     *
     * Linux backend: returns 0 immediately, no syscalls.  the client
     * truly has nothing to do; the wire bytes on Linux are bit-
     * identical to today.
     *
     * Hurd backend: returns 0 on a successful handshake, -1 with
     * errno on failure (ENOSYS until the real body lands in v0.8
     * step 4; EACCES if the auth server rejects; EAGAIN if the auth
     * server is unreachable so the caller can retry).
     *
     * the full design lives at docs/v08-hurd-peer-cred-design.md;
     * the seam is intentionally tiny (one slot, one int return) so a
     * skeptic review can verify "linux is no-op, hurd does N steps"
     * by reading the two bodies side by side. */
    int (*client_auth_handshake)(int fd);

    /* publish the long-lived auth Mach port the design-2.2 handshake
     * needs.  the supervisor calls this exactly once at startup, before
     * the first Fpid1_rpc_poll tick.
     *
     * Linux backend: returns 0 immediately, no syscalls.  there is no
     * out-of-band Mach channel on Linux; SO_PEERCRED is server-side
     * and snapshots the credential at the client's connect() instant.
     *
     * Hurd backend: opens a translator at /servers/geos-auth that
     * publishes a send right to a long-lived auth receive port owned
     * by the supervisor.  clients call file_name_lookup("/servers/
     * geos-auth", 0, 0) to acquire the send right, then mach_msg the
     * (16-byte nonce, rendezvous send right) tuple through it.  the
     * supervisor's per-tick drain inside Fpid1_rpc_poll reads matching
     * pending-auth entries and runs auth_server_authenticate against
     * the rendezvous to extract the caller's uid/gid.  returns 0 on
     * success, -1 with errno (ENOSYS until slice 2 of v0.8 design-2.2
     * lands the translator body; EACCES if the translator setup
     * rejects; EAGAIN if the auth server is unreachable).
     *
     * the call is idempotent only in the trivial sense that the Linux
     * backend does nothing twice as cheaply as once; the Hurd backend
     * will reject a second call with EBUSY (a translator is a singleton
     * per fs path).  callers should treat it as one-shot. */
    int (*publish_auth_port)(void);

    /* drain pending messages on the design-2.2 auth port.  the
     * supervisor calls this at the top of every Fpid1_rpc_poll tick,
     * before accept(); the body is bounded so a flood cannot starve
     * the AF_UNIX accept path.  added in slice 3 of v0.8 design-2.2
     * (see docs/v08-hurd-peer-cred-design.md section 3.5.7).
     *
     * Linux backend: returns 0 immediately, no syscalls.  there is no
     * auth port to drain.
     *
     * Hurd backend: pulls up to a small batch of Mach messages
     * (currently 16) off the libports bucket associated with
     * /servers/geos-auth via mach_msg(MACH_RCV_TIMEOUT=0) and
     * dispatches each one into a hand-rolled demuxer that handles
     * fsys_getroot (returning the auth send right so libdiskfs can
     * route file_name_lookup traffic to our process) and our private
     * geos_auth_submit_nonce verb (extracting the client's
     * effective uid/gid via auth_server_authenticate, inserting a
     * {nonce -> uid, gid, expiry} row into the pending-auth table
     * that slice 5's hurd_get_peer_cred consults).  the drain is
     * fully non-blocking; MACH_RCV_TIMED_OUT after the first empty
     * read is the steady-state return.  the function returns 0 even
     * when it processes zero messages; a real failure (mach_msg
     * returning something other than KERN_SUCCESS or
     * MACH_RCV_TIMED_OUT) surfaces as -1 with errno=EIO.  ENOSYS
     * is returned only if publish_auth_port has not yet succeeded;
     * the supervisor uses that to skip the drain until the auth
     * channel is live. */
    int (*auth_drain)(void);
} port_caps;

/* the active backend.  starts NULL.  exactly one assignment per
 * process, done at startup before any port-> call: the standalone
 * PID 1 binary picks port_linux_impl from main(); the dynamic module
 * picks it from emacs_module_init().  the Hurd backend will land a
 * parallel port_hurd_impl on the side branch and a build-time
 * selector.
 *
 * the "starts NULL, must be assigned" contract is intentional: a
 * silent default-to-linux would mask "forgot to register the Hurd
 * backend" as a Linux-syscalls-on-Mach run, which is exactly the
 * footgun the Hurd port has to avoid (B2, skeptic review 2026-05-12).
 * call port_require_or_abort() after assignment to enforce the
 * invariant in one place. */
extern const port_caps *port;

/* asserts that `port` has been assigned.  intended to be called once
 * from main() / emacs_module_init() right after the assignment; on a
 * NULL port it writes a one-line diagnostic to fd 2 and abort()s.
 * defined in port_linux.c today; the Hurd backend defines its own
 * copy in port_hurd.c with the same semantics. */
void port_require_or_abort(void);

/* the Linux backend instance.  defined in port_linux.c. */
extern const port_caps port_linux_impl;

#endif /* GEOS_PID1_PORT_LAYER_H */
