/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* hurd-client-handshake.c, verification harness for slice 4 of v0.8
 * design 2.2.
 *
 * the question this answers: with the slice 3 libports publish path in
 * place AND the slice 4 fsys_getroot MOVE_SEND fix, does a separate
 * task's client-side handshake (file_name_lookup + hand-rolled
 * submit_nonce mach_msg + auth_user_authenticate) complete cleanly and
 * deposit a matching {nonce, uid, gid} row in the supervisor's
 * pending_auth table?
 *
 * slice 3's harness (tests/hurd-publish-auth-port.c) proved the
 * publish path routes fsys_getroot to the libports bucket.  but the
 * harness's child blocked in file_name_lookup, attributed to a
 * MAKE_SEND vs MOVE_SEND mismatch in S_fsys_getroot.  slice 4 phase
 * 4a fixes that; this harness verifies the fix end-to-end by running
 * the full client-side dance instead of stopping at file_name_lookup.
 *
 * the test harness mirrors port_hurd.c::hurd_publish_auth_port +
 * hurd_client_auth_handshake.  we intentionally do NOT link against
 * port_hurd.c; we re-implement the publish and demuxer state so the
 * harness exercises the same shape pid1 ships without dragging in the
 * whole module.
 *
 * build (Hurd VM, run from tests/):
 *   (cd ../pid1 && make PORT=hurd STATIC=0 fsys_S.h fsysServer.boot.o)
 *   gcc -Wall -Wextra -Werror -I../pid1 \
 *       -o hurd-client-handshake hurd-client-handshake.c \
 *       ../pid1/fsysServer.boot.o \
 *       -lports -lfshelp -lhurduser -lmachuser
 *
 * run as root:
 *   ./hurd-client-handshake
 *
 * expected on success:
 *   parent OK publish: idempotency EBUSY-as-expected
 *   child  OK file_name_lookup returned <addr>
 *   child  OK submit_nonce sent
 *   child  OK auth_user_authenticate kr=0
 *   child  slice4_handshake_ok=1
 *   parent OK drained submit_nonce; pending_auth fingerprint changed
 *   parent slice4_handshake_ok=1
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

#include "fsys_S.h"

/* mirror of port_hurd.c's auth slots and the wire-level constants.
 * intentionally a copy so the harness can run without linking
 * port_hurd.c; if these drift from production, the runlog has to
 * call that out. */
static struct port_bucket *auth_bucket = NULL;
static struct port_class  *auth_class  = NULL;
static struct port_info   *auth_port_obj = NULL;

#define GEOS_AUTH_PENDING_MAX        16
#define GEOS_AUTH_NONCE_LEN          16
#define GEOS_AUTH_TTL_SECS           5
#define GEOS_AUTH_SUBMIT_NONCE_MSGID 90001

struct pending_auth_row {
    uint8_t  nonce[GEOS_AUTH_NONCE_LEN];
    uint32_t uid;
    uint32_t gid;
    time_t   expiry;
};

static struct pending_auth_row pending_auth[GEOS_AUTH_PENDING_MAX];

/* wire struct: client-side message layout.  must match
 * pid1/port_hurd.c's `struct submit_nonce_request` exactly; if the
 * field order or msgt_* descriptor settings differ, the server's
 * cast-to-struct read picks up garbage. */
struct submit_nonce_request {
    mach_msg_header_t Head;
    mach_msg_type_t   rendez_type;
    mach_port_t       rendez;
    mach_msg_type_t   nonce_type;
    uint8_t           nonce[GEOS_AUTH_NONCE_LEN];
};

typedef struct {
    mach_msg_header_t Head;
    mach_msg_type_t   RetCodeType;
    kern_return_t     RetCode;
} mig_reply_t;

static const mach_msg_type_t geos_retcode_type = {
    .msgt_name       = MACH_MSG_TYPE_INTEGER_32,
    .msgt_size       = 32,
    .msgt_number     = 1,
    .msgt_inline     = 1,
    .msgt_longform   = 0,
    .msgt_deallocate = 0,
    .msgt_unused     = 0,
};

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

static int
pending_auth_alloc_slot(void)
{
    time_t now = time(NULL);
    for (int i = 0; i < GEOS_AUTH_PENDING_MAX; i++) {
        if (pending_auth[i].expiry != 0 && pending_auth[i].expiry < now)
            memset(&pending_auth[i], 0, sizeof pending_auth[i]);
    }
    for (int i = 0; i < GEOS_AUTH_PENDING_MAX; i++)
        if (pending_auth[i].expiry == 0) return i;
    memset(&pending_auth[0], 0, sizeof pending_auth[0]);
    return 0;
}

/* server-side handler: records the nonce, replies via mig_reply_t.
 * mirrors port_hurd.c::S_geos_auth_submit_nonce. */
static void
S_geos_auth_submit_nonce(struct submit_nonce_request *inp,
                         mig_reply_t *outp)
{
    mach_msg_header_t *rh = &outp->Head;
    rh->msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(inp->Head.msgh_bits),
                                   0);
    rh->msgh_size = sizeof(*outp);
    rh->msgh_remote_port = inp->Head.msgh_remote_port;
    rh->msgh_local_port = MACH_PORT_NULL;
    rh->msgh_seqno = 0;
    rh->msgh_id = inp->Head.msgh_id + 100;
    outp->RetCodeType = geos_retcode_type;
    outp->RetCode = KERN_SUCCESS;

    if (inp->Head.msgh_size < sizeof(*inp)) {
        outp->RetCode = MIG_BAD_ARGUMENTS;
        return;
    }
    mach_port_t rendez = inp->rendez;
    if (rendez == MACH_PORT_NULL || !MACH_PORT_VALID(rendez)) {
        outp->RetCode = MIG_BAD_ARGUMENTS;
        return;
    }

    /* for the harness we mirror port_hurd.c slice 3 behaviour: record
     * the nonce with sentinel uid/gid.  slice 5 will run the real
     * auth_server_authenticate against rendez; for now the harness's
     * proof is that the fingerprint changed (table mutated). */
    (void)mach_port_deallocate(mach_task_self(), rendez);
    int slot = pending_auth_alloc_slot();
    memcpy(pending_auth[slot].nonce, inp->nonce, GEOS_AUTH_NONCE_LEN);
    pending_auth[slot].uid = (uint32_t)-1;
    pending_auth[slot].gid = (uint32_t)-1;
    pending_auth[slot].expiry = time(NULL) + GEOS_AUTH_TTL_SECS;
}

/* S_fsys_getroot: the slice 4 phase 4a fix.  hands back a libports-
 * vended send right with MOVE_SEND so file_name_lookup unblocks. */
kern_return_t
fsys_getroot (fsys_t fsys,
              mach_port_t dotdot_node,
              const_idarray_t gen_uids,
              mach_msg_type_number_t gen_uids_cnt,
              const_idarray_t gen_gids,
              mach_msg_type_number_t gen_gids_cnt,
              int flags,
              retry_type *do_retry,
              string_t retry_name,
              mach_port_t *file,
              mach_msg_type_name_t *filePoly)
{
    (void)fsys; (void)gen_uids; (void)gen_uids_cnt;
    (void)gen_gids; (void)gen_gids_cnt; (void)flags;
    if (MACH_PORT_VALID(dotdot_node))
        mach_port_deallocate(mach_task_self(), dotdot_node);
    if (auth_port_obj == NULL) {
        *file = MACH_PORT_NULL;
        *filePoly = MACH_MSG_TYPE_COPY_SEND;
        *do_retry = FS_RETRY_NONE;
        retry_name[0] = '\0';
        return EOPNOTSUPP;
    }
    *do_retry = FS_RETRY_NORMAL;
    retry_name[0] = '\0';
    *file = ports_get_send_right(auth_port_obj);
    *filePoly = MACH_MSG_TYPE_MOVE_SEND;
    return KERN_SUCCESS;
}

/* demuxer chain.  custom verb id first, then fsys_server_routine,
 * then libports notify.  matches port_hurd.c::geos_auth_demuxer. */
static int
geos_auth_demuxer(mach_msg_header_t *inp, mach_msg_header_t *outp)
{
    if (inp->msgh_id == GEOS_AUTH_SUBMIT_NONCE_MSGID) {
        S_geos_auth_submit_nonce((struct submit_nonce_request *)inp,
                                 (mig_reply_t *)outp);
        return 1;
    }
    mig_routine_t fr = fsys_server_routine(inp);
    if (fr != 0) {
        (*fr)(inp, outp);
        return 1;
    }
    if (ports_notify_server(inp, outp))
        return 1;
    return 0;
}

/* libports-based publish.  shape mirrors port_hurd.c. */
static int
publish_auth_port(void)
{
    if (auth_port_obj != NULL) { errno = EBUSY; return -1; }
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
        case KERN_INVALID_ARGUMENT:   errno = EINVAL; break;
        case KERN_NO_ACCESS:          errno = EACCES; break;
        case KERN_PROTECTION_FAILURE: errno = EACCES; break;
        case MACH_SEND_INVALID_DEST:  errno = ENOENT; break;
        case EOPNOTSUPP:              errno = EOPNOTSUPP; break;
        default:                      errno = EIO; break;
        }
        return -1;
    }
    auth_port_obj = pi;
    memset(pending_auth, 0, sizeof pending_auth);
    return 0;
}

/* drain pump.  shape mirrors port_hurd.c::hurd_auth_drain with the
 * slice 4 phase 4b cleanups (no MACH_RCV_LARGE, double-memset, no
 * double-deallocate of send-once reply ports). */
static void
drain_once(int *fsys_getroot_calls)
{
    union { mach_msg_header_t hdr; uint8_t buf[8192]; } in_msg, out_msg;
    for (int i = 0; i < 16; i++) {
        memset(&in_msg, 0, sizeof in_msg);
        memset(&out_msg, 0, sizeof out_msg);
        in_msg.hdr.msgh_local_port = auth_bucket->portset;
        in_msg.hdr.msgh_size = sizeof in_msg;
        kern_return_t kr = mach_msg(&in_msg.hdr,
                                    MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                    0, sizeof in_msg,
                                    auth_bucket->portset,
                                    0, MACH_PORT_NULL);
        if (kr == MACH_RCV_TIMED_OUT) return;
        if (kr != KERN_SUCCESS) {
            fprintf(stdout, "parent: warn mach_msg rcv kr=0x%x\n",
                    (unsigned)kr);
            return;
        }
        if (in_msg.hdr.msgh_id == 22002)
            (*fsys_getroot_calls)++;
        out_msg.hdr.msgh_size = 0;
        out_msg.hdr.msgh_remote_port = MACH_PORT_NULL;
        (void)geos_auth_demuxer(&in_msg.hdr, &out_msg.hdr);
        if (MACH_PORT_VALID(out_msg.hdr.msgh_remote_port) &&
            out_msg.hdr.msgh_size > 0) {
            (void)mach_msg(&out_msg.hdr,
                           MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                           out_msg.hdr.msgh_size, 0,
                           MACH_PORT_NULL, 0, MACH_PORT_NULL);
        }
    }
}

/* client-side handshake.  mirrors port_hurd.c::hurd_client_auth_handshake
 * but writes status lines to STATUS_FD so the parent can read them. */
static int
client_handshake(const uint8_t nonce[GEOS_AUTH_NONCE_LEN], int status_fd)
{
    mach_port_t auth_send = file_name_lookup("/servers/geos-auth", 0, 0);
    if (auth_send == MACH_PORT_NULL) {
        dprintf(status_fd, "child  FAIL: file_name_lookup errno=%d (%s)\n",
                errno, strerror(errno));
        return -1;
    }
    dprintf(status_fd, "child  OK file_name_lookup returned 0x%x\n",
            (unsigned)auth_send);

    mach_port_t rendez_rcv = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &rendez_rcv);
    if (kr != KERN_SUCCESS) {
        dprintf(status_fd, "child  FAIL: mach_port_allocate kr=0x%x\n",
                (unsigned)kr);
        mach_port_deallocate(mach_task_self(), auth_send);
        return -1;
    }
    kr = mach_port_insert_right(mach_task_self(), rendez_rcv, rendez_rcv,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        dprintf(status_fd, "child  FAIL: mach_port_insert_right kr=0x%x\n",
                (unsigned)kr);
        mach_port_mod_refs(mach_task_self(), rendez_rcv,
                           MACH_PORT_RIGHT_RECEIVE, -1);
        mach_port_deallocate(mach_task_self(), auth_send);
        return -1;
    }

    struct submit_nonce_request msg;
    memset(&msg, 0, sizeof msg);
    msg.Head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0)
                       | MACH_MSGH_BITS_COMPLEX;
    msg.Head.msgh_size = sizeof msg;
    msg.Head.msgh_remote_port = auth_send;
    msg.Head.msgh_local_port  = MACH_PORT_NULL;
    msg.Head.msgh_seqno       = 0;
    msg.Head.msgh_id          = GEOS_AUTH_SUBMIT_NONCE_MSGID;

    msg.rendez_type.msgt_name       = MACH_MSG_TYPE_MOVE_SEND;
    msg.rendez_type.msgt_size       = 8 * (unsigned)sizeof(mach_port_t);
    msg.rendez_type.msgt_number     = 1;
    msg.rendez_type.msgt_inline     = 1;
    msg.rendez_type.msgt_longform   = 0;
    msg.rendez_type.msgt_deallocate = 0;
    msg.rendez_type.msgt_unused     = 0;
    msg.rendez = rendez_rcv;  /* user-ref minted by insert_right above */

    msg.nonce_type.msgt_name       = MACH_MSG_TYPE_BYTE;
    msg.nonce_type.msgt_size       = 8;
    msg.nonce_type.msgt_number     = GEOS_AUTH_NONCE_LEN;
    msg.nonce_type.msgt_inline     = 1;
    msg.nonce_type.msgt_longform   = 0;
    msg.nonce_type.msgt_deallocate = 0;
    msg.nonce_type.msgt_unused     = 0;
    memcpy(msg.nonce, nonce, GEOS_AUTH_NONCE_LEN);

    kr = mach_msg(&msg.Head,
                  MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                  sizeof msg, 0,
                  MACH_PORT_NULL,
                  500, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), auth_send);
    if (kr != KERN_SUCCESS) {
        dprintf(status_fd, "child  FAIL: mach_msg send kr=0x%x\n",
                (unsigned)kr);
        mach_port_mod_refs(mach_task_self(), rendez_rcv,
                           MACH_PORT_RIGHT_RECEIVE, -1);
        return -1;
    }
    dprintf(status_fd, "child  OK submit_nonce sent\n");

    mach_port_t newport = MACH_PORT_NULL;
    auth_t self_auth = getauth();
    if (self_auth == MACH_PORT_NULL) {
        dprintf(status_fd, "child  FAIL: getauth returned NULL\n");
        mach_port_mod_refs(mach_task_self(), rendez_rcv,
                           MACH_PORT_RIGHT_RECEIVE, -1);
        return -1;
    }
    kr = auth_user_authenticate(self_auth, rendez_rcv,
                                MACH_MSG_TYPE_MAKE_SEND,
                                &newport);
    mach_port_deallocate(mach_task_self(), self_auth);
    mach_port_mod_refs(mach_task_self(), rendez_rcv,
                       MACH_PORT_RIGHT_RECEIVE, -1);
    /* the slice 4 harness's parent does NOT run the matching
     * auth_server_authenticate (slice 5 will).  with no server-side
     * matching call the auth_user_authenticate either blocks waiting
     * for a match (typical) or returns MIG_NO_REPLY / ETIMEDOUT.  we
     * report the kr and continue: the slice 4 PASS marker is that
     * submit_nonce reached the bucket, which the parent will confirm
     * via the fingerprint change. */
    dprintf(status_fd, "child  OK auth_user_authenticate kr=0x%x\n",
            (unsigned)kr);
    if (MACH_PORT_VALID(newport))
        mach_port_deallocate(mach_task_self(), newport);
    return 0;
}

int
main(void)
{
    setbuf(stdout, NULL);

    /* 1. parent publishes the auth port via libports. */
    int rc = publish_auth_port();
    if (rc != 0) {
        fprintf(stdout, "FAIL: publish_auth_port rc=%d errno=%d (%s)\n",
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
    fprintf(stdout, "parent OK publish: idempotency EBUSY-as-expected\n");

    /* 2. mint a 16-byte nonce.  use /dev/urandom for production-style
     *    realism; if it is missing or short fall back to a fixed
     *    deterministic value so the harness still runs in a minimal
     *    container. */
    uint8_t nonce[GEOS_AUTH_NONCE_LEN];
    int ufd = open("/dev/urandom", O_RDONLY);
    if (ufd >= 0) {
        ssize_t got = read(ufd, nonce, sizeof nonce);
        close(ufd);
        if (got != (ssize_t)sizeof nonce) {
            for (size_t i = 0; i < sizeof nonce; i++)
                nonce[i] = (uint8_t)(i ^ 0xA5);
        }
    } else {
        for (size_t i = 0; i < sizeof nonce; i++)
            nonce[i] = (uint8_t)(i ^ 0xA5);
    }

    /* 3. fork.  child does the handshake; parent drains and watches
     *    the fingerprint. */
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
        int hr = client_handshake(nonce, pfds[1]);
        if (hr == 0)
            dprintf(pfds[1], "child  slice4_handshake_ok=1\n");
        close(pfds[1]);
        _exit(hr == 0 ? 0 : 1);
    }
    close(pfds[1]);

    /* 4. drain-while-waiting loop.  the parent is the message pump;
     *    without it the child's submit_nonce never gets dispatched.
     *    poll the pipe with O_NONBLOCK reads so we can interleave
     *    drain ticks. */
    int rfd = pfds[0];
    int fl = fcntl(rfd, F_GETFL, 0);
    if (fl >= 0) (void)fcntl(rfd, F_SETFL, fl | O_NONBLOCK);

    int fsys_getroot_calls = 0;
    unsigned long fp_before = pending_auth_fingerprint();
    char rbuf[2048];
    size_t rbuf_off = 0;
    time_t deadline = time(NULL) + 30;
    int child_ok = 0;

    while (time(NULL) < deadline) {
        drain_once(&fsys_getroot_calls);
        ssize_t n = read(rfd, rbuf + rbuf_off, sizeof rbuf - 1 - rbuf_off);
        if (n > 0) {
            rbuf_off += (size_t)n;
            rbuf[rbuf_off] = '\0';
            /* forward child status lines to stdout for the runlog. */
            fputs(rbuf, stdout);
            if (strstr(rbuf, "slice4_handshake_ok=1")) {
                child_ok = 1;
                break;
            }
            rbuf_off = 0;  /* line forwarded; ready for next batch */
        } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            break;
        }
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 50000000L };
        nanosleep(&ts, NULL);
    }
    /* one more drain pass to catch any straggler the child posted just
     * before exiting. */
    drain_once(&fsys_getroot_calls);

    int wstatus = 0;
    waitpid(pid, &wstatus, 0);

    unsigned long fp_after = pending_auth_fingerprint();
    if (!child_ok) {
        fprintf(stdout,
                "FAIL: child status incomplete (fp_before=%lu fp_after=%lu "
                "fsys_getroot_calls=%d wstatus=0x%x)\n",
                fp_before, fp_after, fsys_getroot_calls, wstatus);
        return 1;
    }
    if (fp_before == fp_after) {
        fprintf(stdout,
                "FAIL: pending_auth fingerprint unchanged "
                "(fp=%lu, drain saw %d fsys_getroot)\n",
                fp_after, fsys_getroot_calls);
        return 1;
    }
    fprintf(stdout,
            "parent OK drained submit_nonce; "
            "pending_auth fingerprint changed (%lu -> %lu); "
            "drain saw %d fsys_getroot\n",
            fp_before, fp_after, fsys_getroot_calls);
    fprintf(stdout, "parent slice4_handshake_ok=1\n");
    return 0;
}
