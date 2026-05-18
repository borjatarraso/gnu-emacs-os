/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* hurd-publish-auth-port.c, verification harness for slice 2 of v0.8
 * design 2.2.
 *
 * the question this answers: does the file_set_translator-based
 * publish path in port_hurd.c::hurd_publish_auth_port actually install
 * a live active translator at /servers/geos-auth that survives long
 * enough for showtrans(1) to see it, AND can the supervisor task
 * subsequently look the path back up and get a working send right?
 *
 * the body below is a verbatim copy of hurd_publish_auth_port from
 * port_hurd.c.  i deliberately do not link against port_hurd.c itself
 * because that TU has unrelated half-built bodies (hurd_get_peer_cred
 * shipped against the old auth_server_authenticate signature; slice 5
 * rewrites it) which would block the harness build.  the copy is small
 * (one function plus its file-static slot) and the duplication is
 * temporary: slice 5 lands the full PORT=hurd supervisor build and
 * this test becomes ground-truth crosscheck rather than the only build
 * path.
 *
 * build (Hurd VM):
 *   gcc -Wall -Wextra -Werror -o hurd-publish-auth-port \
 *       hurd-publish-auth-port.c -lhurduser -lmachuser
 *
 * run as root (file_set_translator on /servers needs write perms):
 *   ./hurd-publish-auth-port
 *
 * expected on success:
 *   OK published recv=<port-name> idempotency=EBUSY-as-expected
 *   exit 0
 *
 * post-run external check (the runlog captures this):
 *   showtrans /servers/geos-auth
 *     should print the active translator marker.
 *
 * the test deliberately runs hurd_publish_auth_port twice: the second
 * call asserts the idempotency-with-EBUSY contract documented in the
 * function's prose. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <hurd.h>
#include <hurd/fsys.h>
#include <mach.h>

/* file-static slot, mirrors port_hurd.c's hurd_auth_port. */
static mach_port_t hurd_auth_port = MACH_PORT_NULL;

/* verbatim copy of hurd_publish_auth_port; keep in sync with
 * port_hurd.c.  if these drift, the verification stops being
 * meaningful and the runlog needs to call that out. */
static int
hurd_publish_auth_port(void)
{
    if (hurd_auth_port != MACH_PORT_NULL) {
        errno = EBUSY;
        return -1;
    }
    mach_port_t recv = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &recv);
    if (kr != KERN_SUCCESS) {
        errno = (kr == KERN_RESOURCE_SHORTAGE) ? ENOMEM : EIO;
        return -1;
    }
    kr = mach_port_insert_right(mach_task_self(), recv, recv,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        (void)mach_port_mod_refs(mach_task_self(), recv,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        errno = EIO;
        return -1;
    }
    int fd = open("/servers/geos-auth", O_CREAT | O_WRONLY, 0600);
    if (fd < 0) {
        int saved = errno;
        (void)mach_port_deallocate(mach_task_self(), recv);
        (void)mach_port_mod_refs(mach_task_self(), recv,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        errno = saved;
        return -1;
    }
    (void)close(fd);
    file_t node = file_name_lookup("/servers/geos-auth", O_NOTRANS, 0);
    if (node == MACH_PORT_NULL) {
        int saved = errno;
        (void)mach_port_deallocate(mach_task_self(), recv);
        (void)mach_port_mod_refs(mach_task_self(), recv,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        errno = saved ? saved : EIO;
        return -1;
    }
    kr = file_set_translator(node,
                             0,
                             FS_TRANS_SET | FS_TRANS_FORCE,
                             0,
                             NULL, 0,
                             recv,
                             MACH_MSG_TYPE_COPY_SEND);
    (void)mach_port_deallocate(mach_task_self(), node);
    if (kr != KERN_SUCCESS) {
        (void)mach_port_deallocate(mach_task_self(), recv);
        (void)mach_port_mod_refs(mach_task_self(), recv,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
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
    hurd_auth_port = recv;
    return 0;
}

int
main(void)
{
    /* first call: publishes.  must return 0. */
    int rc = hurd_publish_auth_port();
    if (rc != 0) {
        fprintf(stdout, "FAIL: first publish rc=%d errno=%d (%s)\n",
                rc, errno, strerror(errno));
        return 1;
    }
    unsigned int first_port = (unsigned int)hurd_auth_port;

    /* second call: must return -1 with EBUSY and must NOT touch the
     * slot (idempotency contract from the function's prose). */
    errno = 0;
    rc = hurd_publish_auth_port();
    if (rc != -1 || errno != EBUSY) {
        fprintf(stdout,
                "FAIL: second publish rc=%d errno=%d (expected -1/EBUSY)\n",
                rc, errno);
        return 1;
    }
    if ((unsigned int)hurd_auth_port != first_port) {
        fprintf(stdout,
                "FAIL: slot mutated on EBUSY path (was 0x%x, now 0x%x)\n",
                first_port, (unsigned int)hurd_auth_port);
        return 1;
    }

    /* sleep briefly so a wrapping script has time to fire showtrans
     * against /servers/geos-auth before this process exits and the
     * active translator goes away.  60s is plenty for the runlog
     * capture; CTRL-C is fine to bail early. */
    fprintf(stdout,
            "OK published recv=0x%x idempotency=EBUSY-as-expected\n",
            first_port);
    fprintf(stdout, "holding port for 60s so showtrans can observe.\n");
    fflush(stdout);
    sleep(60);
    return 0;
}
