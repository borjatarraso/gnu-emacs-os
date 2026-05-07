/* sh.c, the /bin/sh stub for GNU/Emacs OS.
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
 *   - no malloc. one 8 KiB input cap, one 16 KiB output buffer, both
 *     on the stack. enough headroom for worst case escaping (every
 *     byte doubles).
 *   - no libc beyond execve, write, getenv, access, _exit, and the
 *     primitive memory ops i need to assemble the form. no printf,
 *     no strncat, no snprintf. snprintf in particular pulls in half
 *     of stdio and i do not need it.
 *   - exit codes: 2 for misuse, 22 (EINVAL) for command too long, 127
 *     for exec failure or missing emacsclient. otherwise execve
 *     replaces the process and the parent never returns.
 *   - file descriptors: i never open anything. writes go to fd 2.
 *     execve carries 0/1/2 over to emacsclient. nothing to leak.
 */

#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* environ is POSIX but not declared in unistd.h under strict c11
 * without a feature macro. declaring it ourselves keeps -std=c11
 * pedantic happy without pulling in _GNU_SOURCE. */
extern char **environ;

#define CMD_MAX     8192   /* 8 KiB of user-supplied command */
#define FORM_MAX   16384   /* 16 KiB of assembled elisp form */
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
    if (cmdlen > CMD_MAX) {
        err("shstub: command longer than 8 KiB, refusing\n");
        errno = EINVAL;
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
     * E2BIG. all of them mean we have no shell to give the caller. */
    err("shstub: execve of emacsclient failed\n");
    _exit(127);
}
