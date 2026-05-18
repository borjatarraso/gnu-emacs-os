/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* hurd-pflocal-cmsg.c, a focused probe for the v0.8 peer-cred design.
 *
 * the recommended design at docs/v08-hurd-peer-cred-design.md routes
 * the client's rendezvous Mach port to the supervisor through an
 * AF_UNIX SCM_RIGHTS-equivalent cmsg on the pflocal socket.  the
 * design's section 6 flags "does pflocal pass Mach port rights through
 * SCM_RIGHTS cmsgs" as the highest-risk unknown: pflocal's ancillary
 * data path is documented but rarely exercised in the wild, and if it
 * silently drops or corrupts the port the entire 2.1 design fails and
 * we fall back to 2.2 (parallel Mach channel).
 *
 * this binary exercises that exact path in-process: socketpair, mint a
 * fresh receive right + send right, sendmsg one end with the send
 * right attached as SCM_RIGHTS, recvmsg the other end, confirm the
 * cmsg shape is right and the received name is a valid Mach send
 * right.  no pid1 dependency: it links against -lmach only.
 *
 * run as any user.  exits 0 on success, prints "OK"; exits 1 on
 * failure, prints "FAIL: <reason>".  if FAIL, the v0.8 design takes
 * the 2.2 fallback (parallel Mach channel) as documented in section
 * 2.2 of the design doc.
 *
 * portability: the file uses the same SCM_RIGHTS name on Hurd as on
 * Linux because Hurd's <sys/socket.h> exposes the same numeric
 * constant for "ancillary data carrying a kernel-mediated descriptor",
 * where the "descriptor" happens to be a Mach port name on Hurd and a
 * file descriptor on Linux.  the wire shape is identical from the
 * cmsg-walker's point of view; only the integer in the payload means
 * different things.  if a future Hurd release renames the constant
 * (SCM_PORT or similar), update both this probe and the matching
 * server-side cmsg walk in port_hurd.c::hurd_get_peer_cred.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <mach.h>

/* one-shot helper: print FAIL: REASON, return 1 from main. */
static int
fail(const char *reason)
{
    fprintf(stdout, "FAIL: %s\n", reason);
    return 1;
}

int
main(void)
{
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0)
        return fail("socketpair AF_UNIX SOCK_STREAM failed");

    /* allocate a fresh receive right.  we never read from it; the
     * point of the probe is to confirm a send right derived from it
     * survives the cmsg round trip.  the receive right stays in our
     * task port space until the process exits. */
    mach_port_t p = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &p);
    if (kr != KERN_SUCCESS) {
        (void)close(sv[0]); (void)close(sv[1]);
        return fail("mach_port_allocate RECEIVE failed");
    }

    /* mint a send right naming the same port.  the kernel keys send
     * rights by (task, port-name); inserting MAKE_SEND against our own
     * task gives us a name we can hand across the cmsg boundary.  on
     * recv the kernel will translate the wire-form name into the
     * receiver's task name space; in this self-test the receiver IS
     * us, so we get the same port name back. */
    kr = mach_port_insert_right(mach_task_self(), p, p,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        return fail("mach_port_insert_right MAKE_SEND failed");
    }

    /* build the sendmsg: one byte of payload (the supervisor's cmsg
     * walker reads at least one byte to find an attached cmsg; a zero-
     * length send on AF_UNIX is allowed but pflocal's cmsg path is
     * exercised only when there is at least one payload byte), plus
     * one SCM_RIGHTS cmsg carrying the send-right name as a single
     * int-sized payload.  the cmsg_len uses CMSG_LEN to include the
     * cmsg header; CMSG_SPACE pads to alignment for the buffer size. */
    char placeholder = 0;
    struct iovec iov = { .iov_base = &placeholder, .iov_len = 1 };

    char cbuf[CMSG_SPACE(sizeof(mach_port_t))];
    memset(cbuf, 0, sizeof cbuf);

    struct msghdr smsg;
    memset(&smsg, 0, sizeof smsg);
    smsg.msg_iov = &iov;
    smsg.msg_iovlen = 1;
    smsg.msg_control = cbuf;
    smsg.msg_controllen = sizeof cbuf;

    struct cmsghdr *cm = CMSG_FIRSTHDR(&smsg);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN(sizeof(mach_port_t));
    memcpy(CMSG_DATA(cm), &p, sizeof p);

    ssize_t sent = sendmsg(sv[0], &smsg, 0);
    if (sent != 1) {
        int saved = errno;
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        fprintf(stdout, "FAIL: sendmsg returned %zd (errno=%d %s)\n",
                sent, saved, strerror(saved));
        return 1;
    }

    /* recvmsg on the other end with a control buffer big enough for
     * one int-sized cmsg.  pflocal places the translated port name in
     * the receiver's task port space; the payload bytes that come back
     * are the receiver's local name for the same kernel-side object. */
    char rplaceholder = 0xFF;
    struct iovec riov = { .iov_base = &rplaceholder, .iov_len = 1 };

    char rcbuf[CMSG_SPACE(sizeof(mach_port_t))];
    memset(rcbuf, 0, sizeof rcbuf);

    struct msghdr rmsg;
    memset(&rmsg, 0, sizeof rmsg);
    rmsg.msg_iov = &riov;
    rmsg.msg_iovlen = 1;
    rmsg.msg_control = rcbuf;
    rmsg.msg_controllen = sizeof rcbuf;

    ssize_t got = recvmsg(sv[1], &rmsg, 0);
    if (got != 1) {
        int saved = errno;
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        fprintf(stdout, "FAIL: recvmsg returned %zd (errno=%d %s)\n",
                got, saved, strerror(saved));
        return 1;
    }

    /* MSG_CTRUNC is the explicit "kernel dropped some cmsg data because
     * your control buffer was too small" signal.  we sized for exactly
     * one cmsg; if pflocal attached more, we want to know about it
     * loudly rather than silently truncate. */
    if (rmsg.msg_flags & MSG_CTRUNC) {
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        return fail("recvmsg set MSG_CTRUNC: control buffer too small");
    }

    struct cmsghdr *rcm = CMSG_FIRSTHDR(&rmsg);
    if (!rcm) {
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        return fail("recvmsg returned no cmsg headers");
    }
    if (rcm->cmsg_level != SOL_SOCKET) {
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        return fail("cmsg_level != SOL_SOCKET");
    }
    if (rcm->cmsg_type != SCM_RIGHTS) {
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        return fail("cmsg_type != SCM_RIGHTS");
    }
    if (rcm->cmsg_len != CMSG_LEN(sizeof(mach_port_t))) {
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        return fail("cmsg_len wrong size for one mach_port_t");
    }

    mach_port_t recv_port = MACH_PORT_NULL;
    memcpy(&recv_port, CMSG_DATA(rcm), sizeof recv_port);
    if (recv_port == MACH_PORT_NULL) {
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        return fail("received port name is MACH_PORT_NULL");
    }

    /* mach_port_type asks the kernel what right types this name has in
     * our task port space.  a successful cmsg-transit send right will
     * have MACH_PORT_TYPE_SEND set; absence of SEND means the kernel
     * gave us a name but it does not refer to a live send right, which
     * is the silent-corruption path the design fears. */
    mach_port_type_t type = 0;
    kr = mach_port_type(mach_task_self(), recv_port, &type);
    if (kr != KERN_SUCCESS) {
        (void)mach_port_deallocate(mach_task_self(), recv_port);
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        fprintf(stdout, "FAIL: mach_port_type on received port: kr=%d\n",
                (int)kr);
        return 1;
    }
    if (!(type & MACH_PORT_TYPE_SEND)) {
        (void)mach_port_deallocate(mach_task_self(), recv_port);
        (void)mach_port_deallocate(mach_task_self(), p);
        (void)close(sv[0]); (void)close(sv[1]);
        fprintf(stdout,
                "FAIL: received port type 0x%x lacks MACH_PORT_TYPE_SEND\n",
                (unsigned)type);
        return 1;
    }

    /* clean up.  in this self-test the recv_port and p likely name the
     * same kernel object; deallocate both rights anyway, the kernel
     * refcounts. */
    (void)mach_port_deallocate(mach_task_self(), recv_port);
    (void)mach_port_deallocate(mach_task_self(), p);
    (void)close(sv[0]);
    (void)close(sv[1]);

    fprintf(stdout, "OK\n");
    return 0;
}
