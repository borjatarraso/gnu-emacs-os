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
     * on Linux this is getsockopt(SO_PEERCRED) returning struct ucred;
     * NONCE is ignored.  on Hurd there is no SO_PEERCRED; the
     * supervisor minted a 16-byte NONCE on accept, wrote it to the
     * client, and the client ran the auth_user_authenticate dance
     * against the gnumach auth server with the matching NONCE in the
     * submit_nonce mach_msg.  hurd_get_peer_cred consults the
     * pending_auth[] table the per-tick drain has populated; if the
     * NONCE row is present, the uid/gid are copied out and the row is
     * cleared.  if the NONCE row is not yet present the body sleeps
     * 200ms and retries up to 5 times, surfacing ETIMEDOUT if the
     * client never completes the handshake.  rows in pending_auth[]
     * also expire after 5s so an abandoned handshake never wedges.
     * the supervisor side (Fpid1_rpc_poll) special-cases ENOSYS by
     * closing the connection and returning nil to the poller, so the
     * per-200ms timer does not panic forever on a backend that does
     * not implement the call; every other errno is forwarded as
     * pid1-error and panic-handled.  UID_OUT / GID_OUT are written
     * only on success; on failure their contents are unspecified, and
     * the caller initialises them to a non-root sentinel before the
     * port call as defence in depth.  NONCE must be non-NULL; the
     * Hurd backend returns -1 with errno=EINVAL on NULL, and ENOSYS
     * if publish_auth_port has not run.
     *
     * slice 5 of v0.8 design 2.2 grew this signature to take the
     * 16-byte NONCE the supervisor wrote to the client on accept.
     * the Linux backend ignores NONCE; the (void)nonce cast keeps
     * -Wunused-parameter -Werror clean.  full design at
     * docs/v08-hurd-peer-cred-design.md section 3.5.2. */
    int (*get_peer_cred)(int fd, const uint8_t nonce[16],
                         uint32_t *uid_out, uint32_t *gid_out);

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
     * identical to today.  the nonce arg is ignored.
     *
     * Hurd backend: returns 0 on a successful handshake, -1 with
     * errno on failure (EACCES if the auth server rejects; EAGAIN if
     * the auth server or the supervisor's auth port is unreachable
     * so the caller can retry).  the slice 4 body looks up the
     * supervisor's auth port via file_name_lookup("/servers/geos-auth",
     * 0, 0), allocates a rendezvous receive right + send-right pair,
     * hand-rolls a mach_msg(msgh_id=90001, rendezvous MOVE_SEND,
     * nonce[16]) against the auth port, then runs
     * auth_user_authenticate against the rendezvous to complete the
     * dance.  the supervisor's per-tick drain reads the matching
     * submit_nonce request and the auth server matches the two
     * halves to extract the client's uid/gid.
     *
     * NONCE is the 16-byte rendezvous identifier the elisp client
     * read off the AF_UNIX socket immediately after connect (the
     * supervisor writes 16 raw bytes on accept, no length prefix).
     * the same nonce arrives at the supervisor side via the AF_UNIX
     * stream (so the supervisor can match the Mach submit_nonce
     * message to the right AF_UNIX connection).  must be non-NULL;
     * NULL returns -1 with errno=EINVAL.
     *
     * the full design lives at docs/v08-hurd-peer-cred-design.md;
     * the seam is intentionally tiny (one slot, two args, one int
     * return) so a skeptic review can verify "linux is no-op, hurd
     * does N steps" by reading the two bodies side by side. */
    int (*client_auth_handshake)(int fd, const uint8_t nonce[16]);

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

    /* return byte size of block device NAME (bare name, no "/dev/"
     * prefix) in *OUT.  on Linux this is `/sys/block/<name>/size *
     * 512' (sysfs publishes size in 512-byte sectors per
     * Documentation/ABI/stable/sysfs-block, regardless of physical
     * sector size, so the 512 multiplier is the contract, not a
     * sector-size assumption).  on Hurd this is file_get_storage_info
     * on the storeio file_t from file_name_lookup("/dev/<name>",
     * O_READ, 0), with total_bytes = ints[2] * sum(offsets[2k+1])
     * over the offsetsCnt/2 runs.  units on both sides are bytes
     * directly.  the 2026-05-20 storeio probe (docs/runlogs/
     * 2026-05-20-hurd-storeio-getsize.md) confirmed
     * file_get_storage_info as the working RPC after device_get_status
     * returned MIG_BAD_ID on the file_t the cookbook said to use.
     *
     * NAME validation: no NULL, no empty string, no '/' or ".." or
     * any path separator.  bare device names only; the caller already
     * computed the bare form from a /dev/ scan, this is defence in
     * depth so a callsite that grew a /dev/ prefix can't escape into
     * arbitrary sysfs paths.  EINVAL on bad input.
     *
     * returns 0 on success, -1 with errno set on failure: ENOENT for
     * a missing node (no /sys/block/<name>/size on Linux, no
     * /dev/<name> on Hurd), ENXIO for a node present but lacking a
     * translator on Hurd, EIO for an unparseable sysfs size on Linux
     * (the kernel writes a single decimal token plus newline; anything
     * else means the file was clobbered or this isn't really a sysfs
     * size node).
     *
     * the Hurd side ships in port_hurd.c on the side branch as the
     * first of the four post-v0.9 Mach RPC slots; the slot lands here
     * so the elisp consumers in emacs-init/buffers/disks.el and
     * emacs-init/install/disk.el have a single name to dispatch
     * against on both kernels. */
    int (*disk_size_bytes)(const char *name, uint64_t *out);

    /* arm a "die when parent dies" link from the child of a fork()+exec()
     * sequence.  intended call site: in the child, after setsid() and
     * before exec(), inside spawn_xorg() and similar future spawn paths.
     * SIGNAL is the POSIX signal number to deliver to the child (typically
     * SIGTERM) when the parent process (pid1) dies.
     *
     * Linux backend: prctl(PR_SET_PDEATHSIG, signal).  see
     * docs/runlogs/2026-05-21-hurd-xorg-probe.md probe F.  re-arm with
     * any signal is a Linux kernel-level write (no contract concern).
     *
     * Hurd backend (v0.9.9 v2, side branch only): the real Mach
     * dead-name notify path with revised ownership and re-entry
     * contracts after v1 VM-verify falsification.  call sequence:
     * proc_pid2task(getproc(), getppid(), &parent_task) with a 10x
     * 100ms retry loop on KERN_INVALID_NAME (covers the freshly-
     * forked-caller race; pid1 is the registered ancestor of all
     * spawn_xorg children from boot so the retry is a no-op there),
     * mach_port_allocate(self, RECEIVE, &notify_port),
     * mach_port_request_notification(self, parent_task,
     * MACH_NOTIFY_DEAD_NAME, sync=0, notify_port, MAKE_SEND_ONCE,
     * &prev), drop prev if VALID, then a PTHREAD_CREATE_DETACHED
     * watcher that blocks in mach_msg on notify_port with
     * TIMEOUT_NONE until the dead-name message arrives and does
     * kill(getpid(), signal).  parent_task's SEND right ownership
     * transfers to the watcher; the watcher deallocates both
     * parent_task and notify_port on exit.  do NOT deallocate
     * parent_task in the armer on success (v1 bug: the kernel binds
     * the notification record to the ipc_entry in our ipc_space per
     * mach_port.defs:228-251, so eagerly dropping the send right
     * frees the entry and silently consumes the notification).
     *
     * re-entrancy contract (v2): IDEMPOTENT on same signal, EALREADY
     * on different signal.  a second call with the same signal as the
     * live arm returns 0 with no side effects; a second call with a
     * different signal returns -1/EALREADY and the FIRST arm stays
     * live (so signal-on-death is whichever was armed first).  there
     * is never more than one watcher pthread per process.  v1 tried
     * last-writer-wins via mod_refs(-1) on the previous receive right
     * and that DOES NOT WAKE the old watcher's mach_msg on gnumach
     * (wakeup is keyed on message arrival, not on rights destruction),
     * leaking +100 pthreads per 100 calls.  callers that genuinely
     * need to change the death-link signal must exec into a new
     * process (Mach receive rights and pthreads do not survive exec).
     *
     * exec divergence: Mach receive rights and pthreads do not survive
     * exec, so the link silently breaks on the exec'd image.  caller
     * re-arms post-exec if needed.  cited in docs/runlogs/2026-05-21-
     * hurd-xorg-probe.md probes F2/G and in mach_port.defs:247 +
     * notify.defs:106.
     *
     * callers tolerate ENOSYS: the death-link is defence-in-depth, the
     * Hurd spawn path still works without it (pid1 dying causes the
     * kernel to reboot anyway).  caller logs ENOSYS at INFO and
     * continues; EALREADY is treated as success by spawn_xorg-style
     * call sites (the first arm wins, the redundant call is the
     * caller's bug to fix); any other errno is panic-routed.
     *
     * return values:
     *   0          : success, OR idempotent second arm with same
     *                signal on Hurd (Linux always treats as success).
     *   -1/EINVAL  : signal out of range.
     *   -1/ENOMEM  : malloc/pthread_create resource failure (Hurd).
     *   -1/EALREADY: Hurd, second arm with different signal; first
     *                arm stays live.
     *   -1/ESRCH   : Hurd, parent already dead after retry loop;
     *                in-process kill(getpid(), signal) has fired
     *                before this return.  fires on any of the
     *                "parent-gone" code set {KERN_INVALID_NAME,
     *                KERN_FAILURE, KERN_NO_SPACE} after err_kern
     *                decoding (gnumach 1.8+git20260224 returns
     *                proc_pid2task errors WRAPPED in the err_kern
     *                subsystem rather than as bare KERN_* constants).
     *   -1/EIO     : Hurd, unknown kern_return_t. */
    int (*arm_parent_death)(int signal);
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

/* the Hurd backend instance.  defined in port_hurd.c on the hurd side
 * branch; the Linux build never links port_hurd.c so referring to
 * this symbol from a Linux TU would fail at the linker stage.  the
 * extern declaration is conditional on PORT_HURD so a Linux build
 * with -Wundef does not see a dangling declaration: the Makefile
 * defines PORT_HURD only when PORT=hurd. */
#ifdef PORT_HURD
extern const port_caps port_hurd_impl;
#endif

#endif /* GEOS_PID1_PORT_LAYER_H */
