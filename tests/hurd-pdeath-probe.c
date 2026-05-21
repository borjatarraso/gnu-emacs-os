/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* hurd-pdeath-probe.c, end-to-end probe for the v0.9.9
 * port_hurd_impl.arm_parent_death() body.
 *
 * the question this answers:
 *
 *   when a child calls arm_parent_death(SIGUSR1) on Hurd and the
 *   parent then dies, does the watcher pthread actually deliver
 *   SIGUSR1 to the child via the MACH_NOTIFY_DEAD_NAME path?
 *
 * shape: three processes, two pipes.
 *
 *   harness (the test binary)
 *     -> fork() -> parent (A)
 *                    -> fork() -> child (B)
 *                                   - installs SIGUSR1 handler that
 *                                     writes 1 byte to sentinel pipe
 *                                   - calls port_hurd_impl.arm_parent_death
 *                                     (SIGUSR1)
 *                                   - pause() until the signal arrives
 *                                   - on signal: handler wrote sentinel,
 *                                     main returns from pause and _exit(0)
 *                    - parent A closes its end of B's pipe and _exit(0)
 *                      to fire the death-link.
 *     - harness reads the sentinel byte from B with a 10s alarm.
 *     - harness waitpid()s B and asserts WIFEXITED && !WIFSIGNALED.
 *
 * the "harness forks A which forks B" layout is what keeps the
 * harness alive long enough to do the assertions; if we armed the
 * death-link directly between the harness and a single child, the
 * harness would have to die for the watcher to fire, and then no one
 * would be left to read the sentinel.
 *
 * link line (PORT=hurd only):
 *   gcc -Wall -Wextra -Werror -pthread \
 *       -DPORT_HURD -DPID1_TEST_HELPER \
 *       -I/usr/include/x86_64-gnu/hurd \
 *       -I../pid1-include-stub \
 *       -o hurd-pdeath-probe hurd-pdeath-probe.c ../pid1/port_hurd.c \
 *       -lports -lfshelp -lhurduser -lmachuser
 *
 * the test does NOT go through the elisp binding; it links
 * port_hurd.c into its own address space and invokes the slot via
 * the published port_hurd_impl table.  this isolates the C body
 * from the module-loading dance and makes a failure here a failure
 * of the watcher itself, not of the elisp dispatch.
 *
 * exit 0 + "PASS" on success, exit 1 + "FAIL: ..." otherwise.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../pid1/port_layer.h"

/* the published Hurd backend table.  defined in pid1/port_hurd.c,
 * which this helper links directly.  the binding layer in pid1/
 * emacs-init.c does the same thing under PORT_HURD; we replicate
 * the same access pattern here, no module loading involved. */
extern const port_caps port_hurd_impl;

/* sentinel pipe used by the SIGUSR1 handler in the grandchild.
 * declared at file scope so the async-signal-safe handler can write
 * to it without passing it through a context pointer. */
static int g_sentinel_w = -1;

static void
on_sigusr1(int sig)
{
    (void)sig;
    if (g_sentinel_w >= 0) {
        char b = '!';
        ssize_t w = write(g_sentinel_w, &b, 1);
        (void)w;
    }
}

/* read with a timeout.  the spec asks for a 10s budget; we wrap
 * select() rather than alarm() so the harness does not perturb its
 * own signal disposition.  returns 0 on byte received, 1 on timeout,
 * 2 on read error. */
static int
read_byte_with_timeout(int fd, int seconds)
{
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    struct timeval tv = { seconds, 0 };
    int n = select(fd + 1, &rfds, NULL, NULL, &tv);
    if (n < 0) return 2;
    if (n == 0) return 1;
    char b;
    ssize_t r = read(fd, &b, 1);
    if (r <= 0) return 2;
    return 0;
}

int
main(void)
{
    /* one pipe carries the SIGUSR1 sentinel from grandchild back to
     * the harness; the read end stays in the harness, the write end
     * passes through parent A into grandchild B. */
    int sentinel[2];
    if (pipe(sentinel) != 0) {
        fprintf(stdout, "FAIL: pipe sentinel: %s\n", strerror(errno));
        return 1;
    }

    /* second pipe is a synchronisation barrier so the grandchild
     * gets a chance to arm the death link BEFORE parent A exits.
     * grandchild writes one byte after arm_parent_death returns;
     * parent A reads it (blocking) and only then _exit(0)'s. */
    int armed[2];
    if (pipe(armed) != 0) {
        fprintf(stdout, "FAIL: pipe armed: %s\n", strerror(errno));
        return 1;
    }

    pid_t parent_a = fork();
    if (parent_a < 0) {
        fprintf(stdout, "FAIL: fork parent_a: %s\n", strerror(errno));
        return 1;
    }

    if (parent_a == 0) {
        /* parent A: fork grandchild B, wait for B's "armed" byte,
         * then _exit(0).  the exit fires the dead-name notification
         * for B's watcher. */
        (void)close(sentinel[0]); /* read end belongs to harness */
        (void)close(armed[1]);    /* write end belongs to grandchild */

        pid_t b = fork();
        if (b < 0) {
            /* relay the failure to the harness via the armed pipe
             * (closed) and sentinel (closed); harness will see EOF on
             * sentinel and timeout-or-error.  exit non-zero. */
            _exit(2);
        }

        if (b == 0) {
            /* grandchild B: arm, then pause for SIGUSR1. */
            (void)close(armed[0]);     /* B does not read armed */
            g_sentinel_w = sentinel[1];

            struct sigaction sa = {0};
            sa.sa_handler = on_sigusr1;
            sigemptyset(&sa.sa_mask);
            sa.sa_flags = 0; /* explicitly DO want pause() interrupted */
            if (sigaction(SIGUSR1, &sa, NULL) != 0) {
                /* signal-handler setup failed; close sentinel so
                 * harness sees EOF rather than waiting 10s for a
                 * byte that will never come. */
                (void)close(g_sentinel_w);
                _exit(3);
            }

            /* arm via the port_hurd_impl table directly. */
            if (port_hurd_impl.arm_parent_death == NULL) {
                (void)close(g_sentinel_w);
                _exit(4);
            }
            int rc = port_hurd_impl.arm_parent_death(SIGUSR1);
            if (rc != 0) {
                /* arm failed; surface errno via a distinct exit so
                 * the harness can distinguish "armed but no signal"
                 * from "arm itself failed".  encode in low byte. */
                int e = errno & 0xff;
                (void)close(g_sentinel_w);
                _exit(16 + e);
            }

            /* tell parent A we are armed.  parent reads this, then
             * exits, and the watcher fires. */
            char b1 = '1';
            ssize_t w = write(armed[1], &b1, 1);
            (void)w;
            (void)close(armed[1]);

            /* pause() returns -1/EINTR when the SIGUSR1 handler
             * runs; loop just in case some other benign signal
             * arrives first. */
            for (;;) {
                int pr = pause();
                if (pr < 0 && errno == EINTR) {
                    /* handler ran; assume sentinel is written. */
                    break;
                }
                /* otherwise loop. */
            }
            _exit(0);
        }

        /* parent A continues here.  close write ends we no longer
         * need (sentinel[1] is grandchild's), then wait for the
         * "armed" byte from grandchild, then _exit so the death-
         * link fires. */
        (void)close(sentinel[1]);
        char ack;
        ssize_t r = read(armed[0], &ack, 1);
        (void)r;
        (void)close(armed[0]);
        _exit(0);
    }

    /* harness: close write ends we do not own, then watch sentinel
     * with a 10s budget. */
    (void)close(sentinel[1]);
    (void)close(armed[0]);
    (void)close(armed[1]);

    int rc = read_byte_with_timeout(sentinel[0], 10);
    (void)close(sentinel[0]);

    /* reap parent A; we never see grandchild B from the harness
     * because B was double-forked under A.  init reparents B and
     * reaps it.  this is fine for the test: the sentinel byte
     * proves B received the signal, and the only thing we need
     * from A is its exit status (which says "A exited cleanly,
     * the death-link fire was triggered by an exit, not a crash"). */
    int status = 0;
    pid_t reaped = waitpid(parent_a, &status, 0);
    if (reaped < 0) {
        fprintf(stdout, "FAIL: waitpid parent_a: %s\n", strerror(errno));
        return 1;
    }
    if (!WIFEXITED(status)) {
        fprintf(stdout,
                "FAIL: parent A did not exit cleanly (status=0x%x)\n",
                (unsigned)status);
        return 1;
    }
    if (WIFSIGNALED(status)) {
        fprintf(stdout,
                "FAIL: parent A died from signal %d\n",
                WTERMSIG(status));
        return 1;
    }

    if (rc == 1) {
        fprintf(stdout,
                "FAIL: no SIGUSR1 sentinel within 10s; watcher did not fire\n");
        return 1;
    }
    if (rc == 2) {
        fprintf(stdout,
                "FAIL: sentinel read error or EOF; grandchild aborted "
                "before signal (check exit code path in source)\n");
        return 1;
    }

    fprintf(stdout, "PASS\n");
    return 0;
}
