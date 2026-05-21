/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* hurd-pdeath-probe.c, end-to-end probe for the v0.9.9 v2
 * port_hurd_impl.arm_parent_death() body.
 *
 * note: when invoked under sshd, redirect stdout/stderr to a file
 * (e.g., ./hurd-pdeath-probe >/tmp/out 2>&1) so sshd does not wait
 * on the grandchild's inherited stdout fd.  the harness intentionally
 * does not redirect inside the binary so the operator can choose
 * where output goes.
 *
 * the question this answers:
 *
 *   when a child calls arm_parent_death(SIGUSR1) on Hurd and the
 *   parent then dies, does the watcher pthread actually deliver
 *   SIGUSR1 to the child via the MACH_NOTIFY_DEAD_NAME path?
 *
 * v1 (hurd/87a5ed5) harness was pathological: parent A forked B and
 * B immediately called proc_pid2task(getproc(), getppid(), ...).  on
 * a freshly-forked A the proc server had not yet registered A's pid,
 * so the lookup fired KERN_INVALID_NAME and the ESRCH short-circuit
 * raised SIGTERM in-process before any watcher was even spun.  v1
 * spawn_xorg production path is NOT affected (pid1 is the registered
 * ancestor of every spawn_xorg child since boot), so the bug was
 * harness-only.  v2 fix: parent A calls proc_child(getproc(), B_task)
 * after fork, before signaling the "arm now" gate, so the proc server
 * has B's pid -> task mapping (and transitively A's mapping since A
 * is the ancestor providing the registration) before B armes.
 *
 * shape: three processes, two pipes.
 *
 *   harness (the test binary)
 *     -> fork() -> parent (A)
 *                    -> fork() -> child (B)
 *                                   - waits on the "armed" pipe for
 *                                     the go-ahead byte from A.
 *                                   - installs SIGUSR1 handler that
 *                                     writes 1 byte to sentinel pipe.
 *                                   - calls port_hurd_impl.arm_parent_death
 *                                     (SIGUSR1).
 *                                   - pause() until the signal arrives.
 *                                   - on signal: handler wrote sentinel,
 *                                     main returns from pause and _exit(0).
 *                    - A: getppid B -> proc_pid2task -> proc_child
 *                      (primes proc server's view of B as A's
 *                      registered child; also re-confirms A's own
 *                      pid -> task registration in passing).
 *                    - A: write 1 byte to armed pipe so B can arm.
 *                    - A: sleep 2s, then _exit(0).  the exit fires
 *                      the death-link for B's watcher.
 *     - harness select()s on sentinel pipe with 10s budget.
 *     - harness waitpid()s A and asserts WIFEXITED && !WIFSIGNALED.
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

/* Hurd RPC bindings for the proc_child priming dance.  proc_pid2task
 * and proc_child both live in hurd/process.h via mig-generated
 * processUser.h.  getproc() lives in hurd.h.  these are Hurd-only
 * headers so the probe will only compile under PORT=hurd, matching
 * the link-line check in tests/Makefile. */
#include <hurd.h>
#include <hurd/process.h>
#include <mach.h>

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

    /* second pipe is the "arm now" gate.  parent A writes one byte
     * AFTER it has called proc_child(getproc(), B_task) so the proc
     * server knows B's pid -> task mapping before B's arm_parent_death
     * runs proc_pid2task on A's pid.  grandchild reads (blocking) and
     * only then calls arm_parent_death. */
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
        /* parent A: fork grandchild B, prime the proc server, signal
         * the gate, sleep, _exit.  NOTE: do NOT close armed[0] before
         * the fork; if we do, B inherits a closed gate fd and the
         * read() returns EBADF immediately.  the post-fork branches
         * each close the end they do not own. */
        (void)close(sentinel[0]); /* read end belongs to harness */

        pid_t b = fork();
        if (b < 0) {
            /* relay the failure to the harness via the sentinel
             * (closed); harness will see EOF and timeout-or-error. */
            _exit(2);
        }

        if (b == 0) {
            /* grandchild B: wait for the "arm now" gate, arm, pause
             * for SIGUSR1.  we MUST NOT call arm_parent_death before
             * the gate fires; the gate is what guarantees A has
             * already done proc_child(B_task) and the proc server's
             * pid registrations are primed.  B keeps armed[0] (the
             * read end) and closes armed[1] (A's write end). */
            (void)close(armed[1]);     /* B does not write armed */
            g_sentinel_w = sentinel[1];

            char gate = 0;
            ssize_t gr = read(armed[0], &gate, 1);
            (void)close(armed[0]);
            if (gr != 1) {
                /* A died before priming; close sentinel and exit so
                 * harness sees EOF rather than waiting 10s. */
                (void)close(g_sentinel_w);
                _exit(5);
            }

            struct sigaction sa;
            memset(&sa, 0, sizeof sa);
            sa.sa_handler = on_sigusr1;
            sigemptyset(&sa.sa_mask);
            sa.sa_flags = 0; /* explicitly DO want pause() interrupted */
            if (sigaction(SIGUSR1, &sa, NULL) != 0) {
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

            /* pause() returns -1/EINTR when the SIGUSR1 handler
             * runs; loop just in case some other benign signal
             * arrives first. */
            for (;;) {
                int pr = pause();
                if (pr < 0 && errno == EINTR) {
                    break;
                }
                /* otherwise loop. */
            }
            _exit(0);
        }

        /* parent A continues here.  close ends we no longer need:
         * sentinel[1] is grandchild's write end, armed[0] is the read
         * end which belongs to B.  armed[0] gets closed HERE (post
         * fork) rather than pre-fork because B needs to inherit a
         * live read fd before the fork. */
        (void)close(sentinel[1]);
        (void)close(armed[0]);    /* A only writes the gate */

        /* prime: getproc -> proc_pid2task(B) -> proc_child(B_task).
         * A is the registered ancestor of B (the harness is A's
         * parent and is registered from its own bootstrap), so the
         * pid2task lookup on B from A's perspective is race-free.
         * proc_child then explicitly registers B as a child of A,
         * which also re-confirms A's own registration in passing.
         * after proc_child returns, B's subsequent
         * proc_pid2task(A_pid) will succeed deterministically. */
        process_t proc = getproc();
        if (proc == MACH_PORT_NULL) {
            /* cannot prime; abort A so the harness sees the failure. */
            _exit(11);
        }
        task_t b_task = MACH_PORT_NULL;
        /* small retry loop on the pid2task in case the proc server
         * has not yet registered B (the race we are working around
         * for B's view of A also exists for A's view of B in the
         * narrow window right after fork). */
        kern_return_t kr = KERN_SUCCESS;
        for (int i = 0; i < 10; i++) {
            kr = proc_pid2task(proc, b, &b_task);
            if (kr != KERN_INVALID_NAME) break;
            struct timespec ts = { 0, 100 * 1000 * 1000 };
            (void)nanosleep(&ts, NULL);
        }
        if (kr != KERN_SUCCESS) {
            _exit(12);
        }
        kr = proc_child(proc, b_task);
        (void)mach_port_deallocate(mach_task_self(), b_task);
        /* EBUSY (0x40000010) on this Debian Hurd 0.9 / gnumach
         * 1.8+git20260224 means B is already registered as A's child
         * by the implicit fork relationship.  the proc-server's
         * "make B a child of A" call is a no-op when it is already
         * true.  KERN_SUCCESS-or-EBUSY is the canonical contract
         * shape: both mean "B is now A's registered child". */
        if (kr != KERN_SUCCESS && kr != EBUSY) {
            _exit(13);
        }

        /* gate open: tell B it is safe to arm. */
        char go = '1';
        ssize_t w = write(armed[1], &go, 1);
        (void)w;
        (void)close(armed[1]);

        /* sleep 2s before exit so B has a comfortable window to
         * complete arm_parent_death and enter pause() before the
         * dead-name notification races the watcher pthread setup. */
        struct timespec slp = { 2, 0 };
        (void)nanosleep(&slp, NULL);
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
    if (WEXITSTATUS(status) != 0) {
        /* A used 11/12/13 to signal proc-server priming failures
         * (getproc / proc_pid2task / proc_child).  surface the code. */
        fprintf(stdout,
                "FAIL: parent A exited non-zero (status=%d) "
                "11/12/13=getproc/pid2task/proc_child priming\n",
                WEXITSTATUS(status));
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
