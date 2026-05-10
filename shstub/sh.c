/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* sh.c, the /bin/sh stub for GNU/Emacs Operating System (GEOS).
 *
 * legacy code paths still call /bin/sh -c "<cmd>" thousands of times
 * per boot. there is no real shell on this system. what i do here is
 * forward the command string into the running emacs as an eshell
 * evaluation, by execve()ing emacsclient with --eval. the form i send
 * is (eshell-command "<cmd>"), with the command string properly
 * escaped so emacs sees one string and not a syntax error.
 *
 * the only invocation i support is the POSIX `sh -c CMD` shape.
 * interactive sh, sh script.sh, sh -i, sh -s, all of those exit 2
 * with a one-line diagnostic. anything that needs a real script
 * needs to be ported to elisp; that is the whole point.
 *
 * things that are deliberate:
 *   - no malloc. one 8 KiB input cap, one 20 KiB output buffer, both
 *     on the stack. headroom math: 8192 input bytes * 2 (worst-case
 *     escape) = 16384, plus 17-byte prefix and 2-byte suffix = 16403,
 *     plus a 64-byte safety guard = 16467. 20 KiB rounds that up
 *     cleanly and leaves room for a future escape that needs more
 *     than 2 bytes per input.
 *   - no libc beyond execve, write, getenv, access, nanosleep,
 *     _exit, and the primitive memory ops i need to assemble the
 *     form. no printf, no strncat, no snprintf. snprintf in
 *     particular pulls in half of stdio and i do not need it.
 *     nanosleep was added for the emacs-server-socket readiness
 *     poll (see wait_for_emacs_server).
 *   - exit codes: 2 for misuse, 22 (EINVAL) for command too long, 127
 *     for exec failure or missing emacsclient. otherwise execve
 *     replaces the process and the parent never returns.
 *   - file descriptors: i never open anything. writes go to fd 2.
 *     execve carries 0/1/2 over to emacsclient. nothing to leak.
 */

/* nanosleep needs a feature-test macro to be declared under -std=c11.
 * 200809L is the smallest value that exposes it (POSIX.1-2008). */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* environ is POSIX but not declared in unistd.h under strict c11
 * without a feature macro. declaring it ourselves keeps -std=c11
 * pedantic happy without pulling in _GNU_SOURCE. */
extern char **environ;

#define CMD_MAX     8192   /* 8 KiB of user-supplied command */
#define FORM_MAX   20480   /* 20 KiB of assembled elisp form, see header */
#define FORM_GUARD    64   /* refuse to write within this of the end */

/* probe order for emacsclient. first existing path wins. if all three
 * miss, EMACSCLIENT env var is the last resort (handled inline). the
 * guix path is first because that is what shipped systems will use;
 * /usr/bin is second so dev hosts also work. */
static const char *const emacsclient_paths[] = {
    "/run/current-system/profile/bin/emacsclient",
    "/usr/bin/emacsclient",
    NULL,
};

/* write a NUL-terminated string to fd 2. invariant: never returns an
 * error to the caller; if the write fails there is nothing useful we
 * could do about it from a stub anyway. */
static void
err(const char *s)
{
    size_t n = 0;
    while (s[n] != '\0') n++;
    /* ignore short writes; stderr to a closed fd is not a crash case */
    (void)write(2, s, n);
}

/* (M-round-5, 2026-05-10) format a small unsigned int into BUF as
 * decimal and return the number of bytes written.  invariant: BUF
 * must be at least 11 bytes (max uint32 is 10 digits + NUL).  used
 * by errno-aware err paths so the diagnostic carries enough info to
 * debug ENOENT vs EACCES vs ENOMEM without pulling in snprintf. */
static size_t
itoa_u(unsigned int v, char *buf)
{
    char tmp[11];
    size_t i = 0;
    if (v == 0) { buf[0] = '0'; buf[1] = '\0'; return 1; }
    while (v > 0 && i < sizeof tmp) {
        tmp[i++] = (char)('0' + (v % 10));
        v /= 10;
    }
    size_t n = i;
    for (size_t j = 0; j < n; j++) buf[j] = tmp[n - 1 - j];
    buf[n] = '\0';
    return n;
}

/* append src to dst at *off, bounded by cap. returns 0 on success, -1
 * if the append would overflow. *off is advanced on success only.
 * invariant: dst[*off] is left as a valid byte position, never past
 * cap, so the caller can NUL-terminate after the loop. */
static int
append(char *dst, size_t *off, size_t cap, const char *src, size_t len)
{
    if (*off + len > cap) return -1;
    memcpy(dst + *off, src, len);
    *off += len;
    return 0;
}

/* build (eshell-command "ESCAPED") in out. returns the total length
 * written (excluding the trailing NUL we add), or -1 on overflow.
 * escaping rules per emacs reader: backslash and double-quote get a
 * leading backslash, literal LF becomes the two bytes \\ n, literal
 * CR becomes \\ r. everything else passes through verbatim, including
 * UTF-8: emacs reads source as utf-8 by default and eshell handles
 * the rest. */
static long
build_form(char *out, size_t cap, const char *cmd, size_t cmdlen)
{
    static const char prefix[] = "(eshell-command \"";
    static const char suffix[] = "\")";
    size_t off = 0;

    if (append(out, &off, cap, prefix, sizeof(prefix) - 1) < 0)
        return -1;

    for (size_t i = 0; i < cmdlen; i++) {
        /* leave room for at worst a 2-byte escape plus the suffix
         * plus a small guard. cheaper to check once per iteration
         * than to track exact remaining bytes. */
        if (off + 2 + sizeof(suffix) - 1 + FORM_GUARD > cap)
            return -1;

        unsigned char c = (unsigned char)cmd[i];
        switch (c) {
        case '\\':
            out[off++] = '\\'; out[off++] = '\\'; break;
        case '"':
            out[off++] = '\\'; out[off++] = '"';  break;
        case '\n':
            out[off++] = '\\'; out[off++] = 'n';  break;
        case '\r':
            out[off++] = '\\'; out[off++] = 'r';  break;
        default:
            out[off++] = (char)c;                  break;
        }
    }

    if (append(out, &off, cap, suffix, sizeof(suffix) - 1) < 0)
        return -1;
    if (off >= cap) return -1;
    out[off] = '\0';
    return (long)off;
}

/* find the first existing emacsclient. returns a pointer into either
 * emacsclient_paths[] or into the environment block. NULL if nothing
 * is reachable. access(F_OK) is enough; if it exists but is not
 * executable, execve will fail and we report that distinctly. */
static const char *
find_emacsclient(void)
{
    for (size_t i = 0; emacsclient_paths[i] != NULL; i++) {
        if (access(emacsclient_paths[i], F_OK) == 0)
            return emacsclient_paths[i];
    }
    const char *env = getenv("EMACSCLIENT");
    if (env != NULL && env[0] != '\0' && access(env, F_OK) == 0)
        return env;
    return NULL;
}

/* (W11/M-round-5, audit 2026-05-10) wait up to ~3 seconds for the
 * emacs server socket to appear.  in a normal boot it is already there
 * by the time anything calls /bin/sh, but a guix activation gexp can
 * fire /bin/sh between PID 1 mounting / and PID 1 fork+exec of emacs,
 * in which case emacsclient lands before the server.
 *
 * the previous version hardcoded /tmp/emacs0 and /run/user/0; if shstub
 * is ever called under non-zero euid (a setuid wrapper, future
 * multi-user world), access(F_OK) on the uid-0 paths could falsely
 * succeed against a stale or foreign socket and execve would then
 * fail.  we now read getuid() and skip the wait entirely for
 * non-zero uids, leaving emacsclient to handle its own discovery via
 * $XDG_RUNTIME_DIR.
 *
 * timeout: 30 iterations * 100 ms = 3.0 s.  matches the 3-second
 * promise in the header.  the previous 10-iter loop only delivered
 * 1.0 s, which is too tight for cold-boot when PID 1 fork+exec emacs
 * + emacs reaching server-start can take 1.5-2.0 s on slow hosts.
 *
 * returns 0 on success.  on timeout we fall through to execve so
 * emacsclient prints its own diagnostic and the caller's exit status
 * is meaningful, rather than this stub synthesising one. */
static int
wait_for_emacs_server(void)
{
    /* getuid() is signal-safe and always succeeds (POSIX). only the
     * uid-0 paths are well-known; any other uid we leave to
     * emacsclient + $XDG_RUNTIME_DIR. */
    if (getuid() != 0) return 0;
    static const char *const sock_paths[] = {
        "/tmp/emacs0/server",
        "/run/user/0/emacs/server",
        NULL,
    };
    for (int i = 0; i < 30; i++) {
        for (size_t j = 0; sock_paths[j] != NULL; j++) {
            if (access(sock_paths[j], F_OK) == 0) return 0;
        }
        struct timespec ts = { 0, 100 * 1000 * 1000 }; /* 100 ms */
        (void)nanosleep(&ts, NULL);
    }
    return -1;
}

int
main(int argc, char **argv)
{
    /* POSIX sh -c CMD: argv[0]=sh, argv[1]=-c, argv[2]=CMD.
     * a 4th argument would be $0 for the command, which i do not
     * support; if anything in the wild passes it, i would rather
     * fail loud than silently drop it. */
    if (argc < 3 || argv[1] == NULL || argv[2] == NULL ||
        argv[1][0] != '-' || argv[1][1] != 'c' || argv[1][2] != '\0') {
        err("shstub: only sh -c is supported\n");
        _exit(2);
    }
    if (argc > 3) {
        err("shstub: extra arguments after -c CMD are not supported\n");
        _exit(2);
    }

    const char *cmd = argv[2];
    size_t cmdlen = strlen(cmd);
    /* strict-less-than: CMD_MAX is the count of usable bytes, not a
     * "valid up to and including" index.  matters for the FORM_MAX
     * sizing above, which is computed as CMD_MAX*2 + headers + guard. */
    if (cmdlen >= CMD_MAX) {
        /* (M-round-5, 2026-05-10) dropped the now-cosmetic
         * `errno = EINVAL` line: _exit ignores errno and the parent
         * shell does not see it, so setting it served no purpose and
         * mirrored the misconception that exit codes carry errno
         * semantics.  the 22 in the exit code is the integer EINVAL
         * value, kept for back-compat with anything reading $?. */
        err("shstub: command at or beyond 8 KiB, refusing\n");
        _exit(22);
    }

    char form[FORM_MAX];
    long n = build_form(form, sizeof(form), cmd, cmdlen);
    if (n < 0) {
        err("shstub: assembled elisp form does not fit in 16 KiB\n");
        _exit(22);
    }

    const char *ec = find_emacsclient();
    if (ec == NULL) {
        err("shstub: emacsclient not found at "
            "/run/current-system/profile/bin/emacsclient or "
            "/usr/bin/emacsclient or $EMACSCLIENT\n");
        _exit(127);
    }

    /* (W11) wait briefly for the emacs server socket so a /bin/sh
     * call that races boot does not hard-fail.  on timeout, exec
     * anyway: emacsclient prints its own diagnostic, and we want
     * its exit code, not a synthesised one. */
    if (wait_for_emacs_server() < 0) {
        err("shstub: emacs server socket not ready, trying anyway\n");
    }

    /* emacsclient -e FORM: -e is the short form of --eval and saves
     * three bytes of argv. exit status of emacsclient is forwarded
     * by the kernel; we never get here unless execve itself fails. */
    char *new_argv[4];
    new_argv[0] = (char *)ec;
    new_argv[1] = (char *)"-e";
    new_argv[2] = form;
    new_argv[3] = NULL;

    execve(ec, new_argv, environ);

    /* execve only returns on failure. one of: ENOENT (path vanished
     * between access and execve), EACCES (not executable), ENOMEM,
     * E2BIG. all of them mean we have no shell to give the caller.
     *
     * (M-round-5, 2026-05-10) emit errno as a decimal so the operator
     * can distinguish the failure modes above without re-running under
     * strace.  no strerror() because that pulls in the locale machinery
     * and we want this stub to stay minimal. */
    char nbuf[11];
    (void)itoa_u((unsigned int)errno, nbuf);
    err("shstub: execve of emacsclient failed (errno=");
    (void)write(2, nbuf, strlen(nbuf));
    err(")\n");
    _exit(127);
}
