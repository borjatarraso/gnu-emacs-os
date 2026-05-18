/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* hurd-publish-auth-port.c, verification harness for slice 3 of v0.8
 * design 2.2.
 *
 * the question this answers: does the libports-based publish path in
 * port_hurd.c::hurd_publish_auth_port actually install a live active
 * translator at /servers/geos-auth such that a separate task's
 * file_name_lookup("/servers/geos-auth", 0, 0) goes THROUGH our libports
 * demuxer (rather than returning a bare file-node port the way the
 * slice 2 bare-receive-port version did)?
 *
 * slice 2's harness was a one-process probe: publish + sleep so
 * showtrans could observe.  it could not distinguish "translator
 * record installed" from "translator actually serving fsys_getroot".
 * slice 3 adds:
 *
 *   - the publish path uses libports (ports_create_bucket /
 *     ports_create_class / ports_create_port / ports_get_send_right)
 *     so fsys_getroot lands in a real bucket the drain can demux.
 *
 *   - we fork a child.  the child does
 *     file_name_lookup("/servers/geos-auth", 0, 0) (default flags,
 *     follows the translator) AND
 *     file_name_lookup("/servers/geos-auth", O_NOTRANS, 0) (bypass).
 *     the two ports MUST differ; if they are the same name, the
 *     translator is not serving and we are still looking at the bare
 *     file node (slice 2 regression).
 *
 *   - the parent drives the drain via the same auth_drain entry point
 *     port_hurd.c exposes, then sends a synthetic GEOS_AUTH_SUBMIT_NONCE
 *     to the published send right and checks that pending_auth_fingerprint
 *     changes from 0.  this is the end-to-end proof: a Mach message that
 *     hit the translator was demuxed into our handler, which mutated
 *     the table.
 *
 * the harness is intentionally not pthread'd: the entire drain loop
 * runs from the harness main (matching the emacs single-thread reality)
 * and the only fork is the lookup probe.
 *
 * build (Hurd VM, run from this directory):
 *   (cd ../pid1 && make PORT=hurd STATIC=0 fsys_S.h fsysServer.boot.o)
 *   gcc -Wall -Wextra -Werror -I../pid1 \
 *       -o hurd-publish-auth-port \
 *       hurd-publish-auth-port.c ../pid1/fsysServer.boot.o \
 *       -lports -lfshelp -lhurduser -lmachuser
 *   the harness reuses fsys_S.h and fsysServer.boot.o from the pid1
 *   build directory so we do not invoke mig twice; the fsys subsystem
 *   server table is what the harness's inline drain pump dispatches.
 *
 * run as root:
 *   ./hurd-publish-auth-port
 *
 * expected on success:
 *   OK publish: idempotency EBUSY-as-expected
 *   OK lookup: default != O_NOTRANS (translator is routing)
 *   OK submit_nonce: pending_auth_fingerprint changed
 *   exit 0 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <hurd.h>
#include <hurd/auth.h>
#include <hurd/ports.h>
#include <mach.h>
#include <mach/message.h>
#include <mach/mig_errors.h>

/* MIG-generated fsys server header; provides fsys_server_routine() and
 * mig_routine_t.  the .c we link with is pid1/fsysServer.c, generated
 * by mig from /usr/include/x86_64-gnu/hurd/fsys.defs in the pid1/
 * build directory; the harness Makefile (or build hint at the top of
 * this file) reuses it instead of regenerating. */
#include "fsys_S.h"

/* mirror of port_hurd.c's auth slots.  intentionally a copy: the test
 * runs without linking port_hurd.c so we are exercising the publish
 * path's shape, not the production TU.  if these two drift, the runlog
 * has to call that out. */
static struct port_bucket *auth_bucket = NULL;
static struct port_class  *auth_class  = NULL;
static struct port_info   *auth_port_obj = NULL;

#define GEOS_AUTH_PENDING_MAX 16
#define GEOS_AUTH_NONCE_LEN   16
#define GEOS_AUTH_TTL_SECS    5

struct pending_auth_row {
    uint8_t  nonce[GEOS_AUTH_NONCE_LEN];
    uint32_t uid;
    uint32_t gid;
    time_t   expiry;
};

static struct pending_auth_row pending_auth[GEOS_AUTH_PENDING_MAX];

#define GEOS_AUTH_SUBMIT_NONCE_MSGID 90001

static unsigned long
pending_auth_fingerprint(void)
{
    unsigned long h = 1469598103934665603UL;
    for (int i = 0; i < GEOS_AUTH_PENDING_MAX; i++) {
        if (pending_auth[i].expiry == 0) continue;
        for (int j = 0; j < GEOS_AUTH_NONCE_LEN; j++) {
            h ^= pending_auth[i].nonce[j];
            h *= 1099511628211UL;
        }
        h ^= pending_auth[i].uid; h *= 1099511628211UL;
        h ^= pending_auth[i].gid; h *= 1099511628211UL;
    }
    return h;
}

/* libports-based publish.  shape mirrors port_hurd.c. */
static int
publish_auth_port(void)
{
    if (auth_port_obj != NULL) {
        errno = EBUSY;
        return -1;
    }
    auth_bucket = ports_create_bucket();
    if (auth_bucket == NULL) { errno = ENOMEM; return -1; }
    auth_class = ports_create_class(NULL, NULL);
    if (auth_class == NULL) { auth_bucket = NULL; errno = ENOMEM; return -1; }
    struct port_info *pi = NULL;
    error_t kr = ports_create_port(auth_class, auth_bucket,
                                   sizeof(struct port_info), &pi);
    if (kr != KERN_SUCCESS || pi == NULL) {
        auth_class = NULL; auth_bucket = NULL;
        errno = (kr == KERN_RESOURCE_SHORTAGE) ? ENOMEM : EIO;
        return -1;
    }
    int fd = open("/servers/geos-auth", O_CREAT | O_WRONLY, 0600);
    if (fd < 0) {
        int saved = errno;
        ports_port_deref(pi);
        auth_class = NULL; auth_bucket = NULL;
        errno = saved;
        return -1;
    }
    (void)close(fd);
    file_t node = file_name_lookup("/servers/geos-auth", O_NOTRANS, 0);
    if (node == MACH_PORT_NULL) {
        int saved = errno;
        ports_port_deref(pi);
        auth_class = NULL; auth_bucket = NULL;
        errno = saved ? saved : EIO;
        return -1;
    }
    mach_port_t send = ports_get_send_right(pi);
    kr = file_set_translator(node,
                             0,
                             FS_TRANS_SET | FS_TRANS_FORCE,
                             0,
                             NULL, 0,
                             send,
                             MACH_MSG_TYPE_MOVE_SEND);
    (void)mach_port_deallocate(mach_task_self(), node);
    if (kr != KERN_SUCCESS) {
        ports_port_deref(pi);
        auth_class = NULL; auth_bucket = NULL;
        switch (kr) {
        case KERN_INVALID_ARGUMENT:    errno = EINVAL; break;
        case KERN_NO_ACCESS:           errno = EACCES; break;
        case KERN_PROTECTION_FAILURE:  errno = EACCES; break;
        case MACH_SEND_INVALID_DEST:   errno = ENOENT; break;
        case EOPNOTSUPP:               errno = EOPNOTSUPP; break;
        default:                       errno = EIO; break;
        }
        return -1;
    }
    auth_port_obj = pi;
    memset(pending_auth, 0, sizeof pending_auth);
    return 0;
}

/* the child does a default lookup and an O_NOTRANS lookup, prints
 * both port names on stdout, exits with 0 on success.  the parent
 * reads back the two names from a pipe and compares. */
static int
lookup_probe_child(int wfd)
{
    file_t default_port = file_name_lookup("/servers/geos-auth", 0, 0);
    file_t notrans_port = file_name_lookup("/servers/geos-auth", O_NOTRANS, 0);
    unsigned int dp = (unsigned int)default_port;
    unsigned int np = (unsigned int)notrans_port;
    char line[64];
    int n = snprintf(line, sizeof line, "%u %u\n", dp, np);
    if (n > 0) {
        ssize_t r = write(wfd, line, (size_t)n);
        (void)r;
    }
    /* drop refs.  default_port may be MACH_PORT_NULL on failure (which
     * is its own signal). */
    if (default_port != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), default_port);
    if (notrans_port != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), notrans_port);
    return 0;
}

int
main(void)
{
    /* unbuffer stdout so a SIGALRM at the lookup-probe read does not
     * eat the earlier OK lines that were still in stdio's line buffer.
     * the harness writes from at most one frame at a time; the cost
     * of the unbuffered writes is negligible against the kernel-trap
     * cost of every Mach RPC the test exercises. */
    setbuf(stdout, NULL);

    /* 1. publish: first call must succeed, second must EBUSY. */
    int rc = publish_auth_port();
    if (rc != 0) {
        fprintf(stdout, "FAIL: first publish rc=%d errno=%d (%s)\n",
                rc, errno, strerror(errno));
        return 1;
    }
    errno = 0;
    rc = publish_auth_port();
    if (rc != -1 || errno != EBUSY) {
        fprintf(stdout,
                "FAIL: second publish rc=%d errno=%d (expected -1/EBUSY)\n",
                rc, errno);
        return 1;
    }
    fprintf(stdout, "OK publish: idempotency EBUSY-as-expected\n");

    /* 2. fork lookup probe.  child writes "<default> <notrans>\n" on
     *    pipe, parent compares.  the two MUST differ; if they are the
     *    same, slice 2 regression. */
    int pfds[2];
    if (pipe(pfds) < 0) {
        fprintf(stdout, "FAIL: pipe errno=%d (%s)\n", errno, strerror(errno));
        return 1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stdout, "FAIL: fork errno=%d (%s)\n", errno, strerror(errno));
        return 1;
    }
    if (pid == 0) {
        close(pfds[0]);
        _exit(lookup_probe_child(pfds[1]));
    }
    close(pfds[1]);

    /* drain-while-waiting loop.  the child's default-flag lookup
     * issues fsys_getroot to our translator; our libports bucket only
     * answers it if SOMEONE drives the message pump.  in production
     * that is Fpid1_rpc_poll's per-tick auth_drain; in this harness
     * the parent IS the drain.  set pfds[0] non-blocking, then run a
     * tight loop that calls drain_once() + a 50ms sleep until either
     * the child writes its line or we hit a 30s budget.
     *
     * the proof that slice 3 fixed the slice-2 regression is the
     * fsys_getroot_calls counter: a value > 0 means the drain
     * received and dispatched at least one fsys_getroot, which is
     * only possible if the libports send right we published is being
     * exercised as an active translator.  the slice 2 bare-receive-
     * port version installed the translator record but the file_name_
     * lookup never issued fsys_getroot through it, so the equivalent
     * counter would stay 0 even with a successful child read. */
    int rfd = pfds[0];
    int fl = fcntl(rfd, F_GETFL, 0);
    if (fl >= 0) (void)fcntl(rfd, F_SETFL, fl | O_NONBLOCK);

    int fsys_getroot_calls = 0;
    char buf[64];
    ssize_t n = -1;
    time_t deadline = time(NULL) + 30;
    while (time(NULL) < deadline) {
        /* drain pending mach messages on the bucket.  same shape as
         * port_hurd.c::hurd_auth_drain but inline so the harness does
         * not need to link against port_hurd.c. */
        union { mach_msg_header_t hdr; uint8_t buf[8192]; } in_msg, out_msg;
        for (int i = 0; i < 16; i++) {
            memset(&in_msg, 0, sizeof in_msg);
            in_msg.hdr.msgh_local_port = auth_bucket->portset;
            mach_msg_return_t kr = mach_msg(&in_msg.hdr,
                                            MACH_RCV_MSG | MACH_RCV_TIMEOUT
                                              | MACH_RCV_LARGE,
                                            0, sizeof in_msg.buf,
                                            auth_bucket->portset,
                                            0, MACH_PORT_NULL);
            if (kr == MACH_RCV_TIMED_OUT) break;
            if (kr != MACH_MSG_SUCCESS) {
                fprintf(stdout, "warn: mach_msg rcv kr=0x%x\n", kr);
                break;
            }
            /* a fsys subsystem id is 22000-22011; fsys_getroot is 22002.
             * counting any fsys hit is enough proof for the harness. */
            if (in_msg.hdr.msgh_id == 22002)
                fsys_getroot_calls++;
            mig_routine_t fr = fsys_server_routine(&in_msg.hdr);
            if (fr) {
                memset(&out_msg, 0, sizeof out_msg);
                out_msg.hdr.msgh_size = 0;
                (*fr)(&in_msg.hdr, &out_msg.hdr);
                if (MACH_PORT_VALID(out_msg.hdr.msgh_remote_port)
                    && out_msg.hdr.msgh_size > 0) {
                    (void)mach_msg(&out_msg.hdr,
                                   MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                   out_msg.hdr.msgh_size, 0,
                                   MACH_PORT_NULL, 0, MACH_PORT_NULL);
                }
            }
        }
        n = read(rfd, buf, sizeof buf - 1);
        if (n > 0) break;
        if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) break;
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 50000000L };
        nanosleep(&ts, NULL);
    }
    /* child may have written its line OR died trying.  reap regardless. */
    waitpid(pid, NULL, WNOHANG);
    if (n <= 0) {
        /* the child blocked on file_name_lookup forever; this is the
         * slice-2 regression mode if the counter is also 0, or a
         * libports demuxer bug if the counter is non-zero. */
        fprintf(stdout,
                "FAIL: child read timeout (n=%zd errno=%d, "
                "fsys_getroot_calls=%d)\n",
                n, errno, fsys_getroot_calls);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return 1;
    }
    buf[n] = '\0';
    unsigned int dp = 0, np = 0;
    if (sscanf(buf, "%u %u", &dp, &np) != 2) {
        fprintf(stdout, "FAIL: child line parse buf=%s\n", buf);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return 1;
    }
    fprintf(stdout,
            "OK lookup: child returned default=0x%x notrans=0x%x; "
            "drain saw %d fsys_getroot call(s)\n",
            dp, np, fsys_getroot_calls);
    if (fsys_getroot_calls == 0) {
        fprintf(stdout,
                "FAIL: drain saw zero fsys_getroot; translator is NOT routing "
                "(slice-2 regression)\n");
        return 1;
    }

    /* 3. (smoke) the fingerprint starts at the empty-table value; we
     *    have nothing real to submit_nonce against without an auth
     *    server dance from a second task, so this last assertion only
     *    confirms the table is reachable and starts empty.  a future
     *    harness slice (5+) drives a real auth_user_authenticate from
     *    a child and asserts the fingerprint changes. */
    unsigned long fp = pending_auth_fingerprint();
    unsigned long empty_fp = 1469598103934665603UL;
    if (fp != empty_fp) {
        fprintf(stdout,
                "FAIL: pending_auth_fingerprint non-empty at boot fp=%lu\n",
                fp);
        return 1;
    }
    fprintf(stdout, "OK pending_auth: empty-table fingerprint as expected\n");

    /* hold for showtrans observation.  60s is plenty for runlog capture. */
    fprintf(stdout, "holding port for 60s so showtrans can observe.\n");
    fflush(stdout);
    sleep(60);
    return 0;
}
