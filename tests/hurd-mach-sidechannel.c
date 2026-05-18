/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* hurd-mach-sidechannel.c, probe for the v0.8 design 2.2 mechanics.
 *
 * the v0.8 design pivoted from SCM_RIGHTS-over-pflocal (design 2.1,
 * killed by 2026-05-18 pflocal probe FAIL) to a parallel Mach channel
 * (design 2.2).  the load-bearing question for 2.2:
 *
 *   does the auth dance (auth_user_authenticate on the client side,
 *   auth_server_authenticate on the supervisor side) complete cleanly
 *   on this Hurd build, when both sides share a Mach rendezvous port?
 *
 * the side-channel TRANSPORT (how the rendezvous port travels from
 * client task to supervisor task) is well-trodden Mach IPC; we trust
 * that.  what's not been proven on Debian GNU/Hurd 0.9 is the auth
 * dance itself; the previous v0.8 work died before it could call
 * auth_*_authenticate end-to-end.
 *
 * probe shape: a single process, two pthreads, sharing the
 * rendezvous via the shared port-name table.  the client thread
 * calls auth_user_authenticate, the server thread calls
 * auth_server_authenticate.  if both return KERN_SUCCESS the dance
 * works and design 2.2's only remaining question is the transport,
 * which is standard.
 *
 * build: gcc -Wall -Wextra -Werror -pthread -o hurd-mach-sidechannel
 *        hurd-mach-sidechannel.c
 * run:   ./hurd-mach-sidechannel
 *
 * exit 0 + "OK" on success, exit 1 + "FAIL: ..." otherwise.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <mach.h>
#include <hurd.h>

struct probe_ctx {
    mach_port_t rendez_send;   /* fresh send right, MOVE_SEND from client */
    mach_port_t rendez_send2;  /* fresh send right, MOVE_SEND from server */
    kern_return_t client_kr;
    kern_return_t server_kr;
    uid_t observed_euid;
    int observed_neuids;
};

/* CLIENT thread: auth_user_authenticate(self_auth, rendez, ...) */
static void *
client_thread(void *arg)
{
    struct probe_ctx *ctx = arg;

    auth_t self_auth = getauth();
    if (self_auth == MACH_PORT_NULL) {
        ctx->client_kr = KERN_INVALID_TASK;
        return NULL;
    }

    mach_port_t newport = MACH_PORT_NULL;
    ctx->client_kr = auth_user_authenticate(self_auth,
                                            ctx->rendez_send,
                                            MACH_MSG_TYPE_MOVE_SEND,
                                            &newport);
    if (ctx->client_kr == KERN_SUCCESS && newport != MACH_PORT_NULL)
        (void)mach_port_deallocate(mach_task_self(), newport);
    (void)mach_port_deallocate(mach_task_self(), self_auth);
    return NULL;
}

/* SERVER thread: auth_server_authenticate(self_auth, rendez, ...) */
static void *
server_thread(void *arg)
{
    struct probe_ctx *ctx = arg;

    auth_t self_auth = getauth();
    if (self_auth == MACH_PORT_NULL) {
        ctx->server_kr = KERN_INVALID_TASK;
        return NULL;
    }

    /* mint the "newport" the server hands the client.  on a real
     * supervisor this would be a fresh auth port the supervisor
     * creates for the client; for the probe a self-allocated
     * receive right + send right works. */
    mach_port_t newport_rcv = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &newport_rcv);
    if (kr != KERN_SUCCESS) {
        ctx->server_kr = kr;
        return NULL;
    }
    kr = mach_port_insert_right(mach_task_self(), newport_rcv,
                                newport_rcv,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        ctx->server_kr = kr;
        return NULL;
    }

    uid_t *euids = NULL; mach_msg_type_number_t neuids = 0;
    uid_t *auids = NULL; mach_msg_type_number_t nauids = 0;
    gid_t *egids = NULL; mach_msg_type_number_t negids = 0;
    gid_t *agids = NULL; mach_msg_type_number_t nagids = 0;

    ctx->server_kr = auth_server_authenticate(self_auth,
                                              ctx->rendez_send2,
                                              MACH_MSG_TYPE_MOVE_SEND,
                                              newport_rcv,
                                              MACH_MSG_TYPE_MAKE_SEND,
                                              &euids, &neuids,
                                              &auids, &nauids,
                                              &egids, &negids,
                                              &agids, &nagids);
    if (ctx->server_kr == KERN_SUCCESS && neuids > 0) {
        ctx->observed_euid = euids[0];
        ctx->observed_neuids = neuids;
    }
    (void)mach_port_deallocate(mach_task_self(), self_auth);
    return NULL;
}

int
main(void)
{
    /* allocate the rendezvous receive right, mint two send rights
     * (one for the client thread to MOVE_SEND, one for the server
     * thread to MOVE_SEND).  the receive right stays in our port
     * table; auth_*_authenticate consumes the send rights internally
     * via the auth server. */
    mach_port_t rendez_rcv = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &rendez_rcv);
    if (kr != KERN_SUCCESS) {
        fprintf(stdout, "FAIL: mach_port_allocate kr=0x%x\n",
                (unsigned)kr);
        return 1;
    }

    kr = mach_port_insert_right(mach_task_self(), rendez_rcv,
                                rendez_rcv,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        fprintf(stdout, "FAIL: insert_right #1 kr=0x%x\n",
                (unsigned)kr);
        return 1;
    }
    kr = mach_port_insert_right(mach_task_self(), rendez_rcv,
                                rendez_rcv,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        fprintf(stdout, "FAIL: insert_right #2 kr=0x%x\n",
                (unsigned)kr);
        return 1;
    }

    struct probe_ctx ctx = {
        .rendez_send  = rendez_rcv,  /* same name; user-refs > 1 */
        .rendez_send2 = rendez_rcv,
        .client_kr = KERN_FAILURE,
        .server_kr = KERN_FAILURE,
        .observed_euid = 0,
        .observed_neuids = 0,
    };

    pthread_t client_t, server_t;
    if (pthread_create(&server_t, NULL, server_thread, &ctx) != 0) {
        fprintf(stdout, "FAIL: pthread_create server\n");
        return 1;
    }
    if (pthread_create(&client_t, NULL, client_thread, &ctx) != 0) {
        fprintf(stdout, "FAIL: pthread_create client\n");
        return 1;
    }

    pthread_join(client_t, NULL);
    pthread_join(server_t, NULL);

    if (ctx.client_kr != KERN_SUCCESS) {
        fprintf(stdout,
                "FAIL: client auth_user_authenticate kr=0x%x\n",
                (unsigned)ctx.client_kr);
        return 1;
    }
    if (ctx.server_kr != KERN_SUCCESS) {
        fprintf(stdout,
                "FAIL: server auth_server_authenticate kr=0x%x\n",
                (unsigned)ctx.server_kr);
        return 1;
    }
    if (ctx.observed_neuids == 0) {
        fprintf(stdout, "FAIL: server saw empty effective uid set\n");
        return 1;
    }

    fprintf(stdout, "OK auth euid=%u (neuids=%d)\n",
            (unsigned)ctx.observed_euid, ctx.observed_neuids);
    return 0;
}
