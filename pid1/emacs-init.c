/* emacs-init.c, PID 1 for GNU/Emacs OS.
 *
 * I do the minimum a kernel needs from PID 1, then I fork-and-exec
 * /usr/bin/emacs on /dev/tty1 and babysit it. If emacs dies, I respawn
 * it. I never exit. Exiting from PID 1 panics the kernel.
 *
 * Phase 2: same source, two outputs.
 *   - default build: standalone PID 1 binary (the boot path).
 *   - -DPID1_MODULE: emacs dynamic module that exposes the supervision
 *     primitives to elisp. main() is gone in that mode, replaced by
 *     emacs_module_init(). the helpers (mount, sethostname, lo, reap)
 *     are shared between the two compile modes; only the boot-path
 *     specific code (console, spawn_emacs, do_mount-with-mkdir, the
 *     supervision loop) stays guarded behind !PID1_MODULE.
 *
 * Things that are deliberate, not oversights:
 *   - no malloc(); the only dynamic state is on the stack
 *   - errno is checked on every syscall, even the "obvious" ones
 *   - SIGCHLD does the minimum legal work and sets a flag
 *   - mount() failures log but do not abort: a single broken pseudo-fs
 *     should not brick the box, the user can still get a console
 *   - /dev/console is the only place we report errors during early
 *     boot because /dev/tty1 may not exist yet
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/if.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef PID1_MODULE
#include <emacs-module.h>
#include <stdint.h>
/* required by the emacs module ABI; presence of this symbol is how
 * emacs verifies the .so is licensed compatibly. */
int plugin_is_GPL_compatible;
#endif

/* ---- shared helpers (used by both boot and module builds) -------- */

#ifndef PID1_MODULE
/* writes one line to /dev/console; opens fresh every call so we do not
 * carry an fd we forgot about. invariant: never blocks longer than the
 * console driver permits, safe from non-signal contexts only. boot
 * mode only because the module is loaded into a running emacs and uses
 * elisp signals for diagnostics instead. */
static void
console(const char *msg)
{
    int fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return;
    (void)write(fd, msg, strlen(msg));
    (void)write(fd, "\n", 1);
    (void)close(fd);
}
#endif

/* low-level mount wrapper used by both compile modes. boot path layers
 * a defensive mkdir on top via do_mount(); the module path exposes
 * this directly to elisp and lets the caller decide. invariant: caller
 * is root; returns 0 on success, -1 with errno set on failure. */
static int
raw_mount(const char *src, const char *tgt, const char *type,
          unsigned long flags, const char *opts)
{
    return mount(src, tgt, type, flags, opts);
}

#ifdef PID1_MODULE
/* sethostname wrapper. exists as a function so the module path can
 * call it without dragging in any boot-time logic. boot mode never
 * calls this (the kernel cmdline already pinned a hostname by the
 * time we run), so it is module-only to keep -Wunused-function happy
 * under STATIC=1 builds. invariant: returns 0 on success, -1 with
 * errno set on failure. */
static int
raw_set_hostname(const char *name, size_t len)
{
    return sethostname(name, len);
}
#endif

/* brings up the loopback interface via ioctl; touches no other iface.
 * invariant: returns 0 on success, -1 with errno set on the first
 * failing syscall. fd is always closed on every exit path. */
static int
raw_bring_up_lo(void)
{
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifreq r;
    memset(&r, 0, sizeof r);
    strncpy(r.ifr_name, "lo", IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFFLAGS, &r) < 0) {
        int saved = errno;
        (void)close(s);
        errno = saved;
        return -1;
    }
    r.ifr_flags |= IFF_UP | IFF_RUNNING;
    if (ioctl(s, SIOCSIFFLAGS, &r) < 0) {
        int saved = errno;
        (void)close(s);
        errno = saved;
        return -1;
    }
    (void)close(s);
    return 0;
}

/* ---- boot-only code -------------------------------------------- */

#ifndef PID1_MODULE

/* mounts a pseudo-filesystem; logs and continues on failure. mkdir
 * defensively because the rootfs may not have every mountpoint shipped
 * (this is PID 1, we have no luxury of trusting the image). invariant:
 * caller is root. */
static void
do_mount(const char *src, const char *tgt, const char *type,
         unsigned long flags, const char *opts)
{
    if (mkdir(tgt, 0755) < 0 && errno != EEXIST) {
        char buf[256];
        snprintf(buf, sizeof buf,
                 "pid1: mkdir %s failed: %s", tgt, strerror(errno));
        console(buf);
        /* keep going, mount may still succeed if the dir was created
         * by something we did not see */
    }
    if (raw_mount(src, tgt, type, flags, opts) < 0) {
        char buf[256];
        if (errno == EBUSY) {
            /* the modern guix initrd already mounts /sys, /dev (and
             * sometimes /proc) before handing off to the boot script,
             * so a second mount on the same target returns EBUSY.
             * that is not a failure for us, the kernel did the work
             * already. log it as informational so /boot-vm logs make
             * the chain of custody obvious, then move on. */
            snprintf(buf, sizeof buf,
                     "pid1: %s already mounted on %s (inherited from initrd)",
                     type, tgt);
            console(buf);
        } else {
            snprintf(buf, sizeof buf,
                     "pid1: mount %s -> %s (%s) failed: %s",
                     src, tgt, type, strerror(errno));
            console(buf);
        }
    }
}

/* parses /proc/cmdline for the gnu.system=PATH token the guix initrd
 * stamps on every boot, copies the path into out (NUL-terminated, capped
 * at out_len-1). returns 0 on success and out is populated; -1 if the
 * token is missing, the file is unreadable, the value would not fit, or
 * the value fails sanity validation (must start with /gnu/store/, no
 * ".." substring, length under PATH_MAX). on rejection we log to
 * /dev/console so the operator sees why /run/current-system is missing.
 * invariant: out is always NUL-terminated on success, untouched on
 * failure. used to find the system profile so we can lay down
 * /run/current-system without invoking guix activation.
 *
 * (B7, skeptic 2026-05-06) cmdline content is not trusted: a hostile
 * or malformed gnu.system value would otherwise let us symlink
 * /run/current-system at any path of the attacker's choosing, and
 * emacs would happily PATH= into it. validate before symlinking. */
static int
read_gnu_system_path(char *out, size_t out_len)
{
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    char buf[4096];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    (void)close(fd);
    if (n <= 0) return -1;
    buf[n] = '\0';
    /* search for the literal "gnu.system=" token. cannot use strstr on
     * its own because we also need the value bound, which is whitespace
     * (kernel cmdline tokens are separated by spaces and end at '\n'). */
    const char *key = "gnu.system=";
    char *p = strstr(buf, key);
    if (!p) return -1;
    p += strlen(key);
    char *end = p;
    while (*end && *end != ' ' && *end != '\t' && *end != '\n') end++;
    size_t vlen = (size_t)(end - p);
    if (vlen == 0 || vlen >= out_len) return -1;
    memcpy(out, p, vlen);
    out[vlen] = '\0';
    /* validation. order matters: prefix check first so the log line
     * shows the exact value the kernel handed us. PATH_MAX guard is
     * separately enforced because PATH_MAX < sizeof out is not
     * guaranteed by the caller (today it is, future-proof anyway). */
    int ok = 1;
    if (strncmp(out, "/gnu/store/", strlen("/gnu/store/")) != 0) ok = 0;
    if (ok && strstr(out, "..") != NULL) ok = 0;
    if (ok && vlen >= (size_t)PATH_MAX) ok = 0;
    if (!ok) {
        char msg[PATH_MAX + 64];
        snprintf(msg, sizeof msg,
                 "pid1: rejecting suspect gnu.system value %s", out);
        console(msg);
        out[0] = '\0';
        return -1;
    }
    return 0;
}

/* lays down /run/current-system as a symlink to the gnu.system= path.
 * guix's activation service normally does this, but we replace the boot
 * script before activation runs, so nothing under /run/current-system
 * exists unless we make it. without this every PATH=/run/current-system/
 * profile/bin in our envp dead-ends and emacs's executable-find returns
 * nil for everything. logs and continues on failure: a missing symlink
 * downgrades the user experience, it does not brick the boot.
 * invariant: caller has already mounted /run as tmpfs. */
static void
link_current_system(void)
{
    char target[PATH_MAX];
    if (read_gnu_system_path(target, sizeof target) < 0) {
        console("pid1: no gnu.system= in /proc/cmdline, "
                "/run/current-system not linked");
        return;
    }
    /* if a previous boot left the symlink we just unlink it; /run is a
     * fresh tmpfs every boot so this is mostly defensive. ignore ENOENT,
     * complain about anything else. */
    if (unlink("/run/current-system") < 0 && errno != ENOENT) {
        char buf[256];
        snprintf(buf, sizeof buf,
                 "pid1: unlink /run/current-system failed: %s",
                 strerror(errno));
        console(buf);
    }
    if (symlink(target, "/run/current-system") < 0) {
        char buf[PATH_MAX + 128];
        snprintf(buf, sizeof buf,
                 "pid1: symlink %s -> /run/current-system failed: %s",
                 target, strerror(errno));
        console(buf);
        return;
    }
    char ok[PATH_MAX + 64];
    snprintf(ok, sizeof ok,
             "pid1: /run/current-system -> %s", target);
    console(ok);
}

static volatile sig_atomic_t got_sigchld = 0;

/* sleeps for at least sec seconds, restarting on EINTR. plain sleep()
 * returns early when SIGCHLD wakes us, which would defeat the
 * crash-loop throttle: emacs dies, sigchld fires, sleep returns
 * immediately, we respawn at full speed and pin a CPU. invariant:
 * never sleeps less than the requested duration. */
static void
sleep_at_least(unsigned sec)
{
    struct timespec req = { (time_t)sec, 0 };
    struct timespec rem;
    while (nanosleep(&req, &rem) < 0 && errno == EINTR) {
        req = rem;
    }
}

/* signal-safe minimum: just set a flag for the main loop. invariant:
 * does no I/O, no malloc, no non-async-signal-safe calls. */
static void
on_sigchld(int sig)
{
    (void)sig;
    got_sigchld = 1;
}

/* path to the emacs binary. on a guix system /usr/bin/emacs does not
 * exist; the binary lives somewhere under /gnu/store. the boot gexp
 * passes the absolute store path as argv[1]. on a non-guix host the
 * fallback is /usr/bin/emacs. set by main() before spawn_emacs(). */
static const char *emacs_path = "/usr/bin/emacs";

/* extra args forwarded into emacs's argv after the binary path,
 * before the trailing NULL. populated from main()'s argv[4..]. the
 * boot gexp uses this to pass "-Q -l /gnu/store/...early-init.el
 * -l /gnu/store/...panic.el". NULL when no extras. */
static char *const *extra_argv = NULL;
static int extra_argc = 0;

/* fully-qualified env entry "PID1_MODULE_PATH=/gnu/store/...so" built
 * once at startup. spawn_emacs splices this into the execve envp so
 * early-init.el can find the module via getenv. NULL when no module
 * was passed; raw QEMU smoke tests leave it that way. capped at 4096
 * so a wild argv cannot smash the buffer. */
static char module_env_buf[4096];
static const char *module_env = NULL;

/* phase 5a: optional Xorg server brought up before emacs so emacs is
 * an x client from the first frame. set from argv[3] in main(); empty
 * string means "do not start an X server, run emacs on /dev/console".
 * the path points at the Xorg binary itself, e.g.
 * /gnu/store/.../bin/Xorg. we keep the env vars Xorg needs (XKB dir,
 * module path, fontpath, config) in their own statics so spawn_xorg()
 * can read them at fork time without re-parsing argv. all of these
 * arrive as a single colon-joined argv slot ("Xorg:XKB:MODULES:FONT
 * :CONF") that we split in main() so the boot gexp does not have to
 * grow yet another argv position every time we add an X dependency. */
static const char *xorg_path = NULL;
static const char *xorg_xkb_dir = NULL;
static const char *xorg_module_path = NULL;
static const char *xorg_font_path = NULL;
static const char *xorg_conf_path = NULL;

/* DISPLAY=:0 lives in a static so we can splice it into emacs's envp
 * without an strdup. set in main() iff xorg_path is non-NULL. same
 * shape as module_env for consistency. */
static const char *display_env = NULL;

/* (B1, skeptic 2026-05-06) supervisor needs to know which child pid
 * is the X server so it can react to Xorg dying instead of treating
 * it as just another reaped orphan. set by xorg_bring_up() after a
 * successful spawn_xorg(); cleared to -1 once the supervisor sees
 * Xorg exit, before we respawn. -1 means "no X server is supposed
 * to be running" (boots without an X spec, or we crash-loop-tripped
 * and gave up).
 *
 * (B2) xorg_respawns_window tracks restart attempts inside a 60s
 * sliding window so a broken xorg.conf cannot pin the cpu by
 * fork-exec-die in a tight loop. window_start is the wall clock at
 * which the current 60s window opened; XORG_RESPAWN_CAP is how many
 * restarts are tolerated inside one window. exceeding it switches
 * us into "bare emacs on /dev/console" mode permanently for this
 * boot. */
static pid_t xorg_pid = -1;
#define XORG_RESPAWN_CAP 5
#define XORG_RESPAWN_WINDOW_SEC 60
static int xorg_respawns_window = 0;
static time_t xorg_window_start = 0;
static int xorg_disabled = 0;

/* fork+exec the X server (Xvfb in 5a, Xorg in 5c) on display :0.
 * invariant: never returns in the child; in the parent returns the
 * new pid, or -1 on fork() failure. caller waits on the X socket
 * before connecting clients.
 *
 * I picked Xvfb for phase 5a after fighting Xorg's fbdev driver
 * against the EFI framebuffer the kernel exposes in QEMU. the EFI
 * fb is read-only (FBIOPUT_VSCREENINFO returns success but the
 * kernel ignores the mode change), so Xorg's fbdev driver bails
 * with "AddScreen/ScreenInit failed for driver 0". loading bochs-drm
 * to get real KMS belongs in 5c with the rest of the rendering work.
 *
 * Xvfb tradeoff: pixels are not visible on the QEMU GTK display
 * (Xvfb renders to memory, not /dev/fb0). I get around that for the
 * 5a smoke test by having exwm-config.el message its status to
 * /dev/console after (exwm-enable), so the tty1 framebuffer console
 * prints "exwm enabled" as visual evidence on the GTK window.
 *
 * X server flag set, picked from the Xvfb manpage:
 *   :0                        display number, exported as DISPLAY=:0.
 *   -screen 0 1024x768x24     virtual screen the wm sees.
 *   -nolisten tcp             no remote x.
 *   -noreset                  pid1 respawns emacs INTO the same X.
 *   the -config / -modulepath / -logfile options that Xorg understands
 *   are NOT used by Xvfb; we drop them silently when xorg_path looks
 *   like Xvfb. detected via a tail-of-string compare.
 */
static int
path_ends_with(const char *path, const char *suffix)
{
    if (!path || !suffix) return 0;
    size_t pl = strlen(path), sl = strlen(suffix);
    if (sl > pl) return 0;
    return strcmp(path + (pl - sl), suffix) == 0;
}

static pid_t
spawn_xorg(void)
{
    pid_t pid = fork();
    if (pid < 0) {
        console("pid1: fork() for xorg failed");
        return -1;
    }
    if (pid == 0) {
        if (setsid() < 0) {
            console("pid1: setsid() failed in xorg child");
            _exit(127);
        }

        /* Xvfb logs to stderr. redirect to a file so the boot log on
         * /dev/console stays clean. /tmp is a tmpfs we just mounted. */
        int devnull = open("/dev/null", O_RDWR | O_CLOEXEC);
        if (devnull >= 0) {
            (void)dup2(devnull, 0);
            if (devnull > 2) (void)close(devnull);
        }
        int xlog = open("/tmp/Xorg.0.log",
                        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                        0644);
        if (xlog >= 0) {
            (void)dup2(xlog, 1);
            (void)dup2(xlog, 2);
            if (xlog > 2) (void)close(xlog);
        }

        int is_xvfb = path_ends_with(xorg_path, "/Xvfb")
                      || path_ends_with(xorg_path, "Xvfb");

        char *xargv[16];
        int xi = 0;
        xargv[xi++] = (char *)xorg_path;
        xargv[xi++] = ":0";
        if (is_xvfb) {
            xargv[xi++] = "-screen";
            xargv[xi++] = "0";
            xargv[xi++] = "1024x768x24";
            xargv[xi++] = "-nolisten";
            xargv[xi++] = "tcp";
            xargv[xi++] = "-noreset";
        } else {
            /* Xorg path: keep the original phase-5a flag set in case
             * we flip back when 5c lands a working KMS driver. */
            xargv[xi++] = "vt7";
            xargv[xi++] = "-keeptty";
            xargv[xi++] = "-nolisten";
            xargv[xi++] = "tcp";
            xargv[xi++] = "-noreset";
            xargv[xi++] = "-logfile";
            xargv[xi++] = "/tmp/Xorg.0.log";
            if (xorg_conf_path && xorg_conf_path[0] != '\0') {
                xargv[xi++] = "-config";
                xargv[xi++] = (char *)xorg_conf_path;
            }
            if (xorg_module_path && xorg_module_path[0] != '\0') {
                xargv[xi++] = "-modulepath";
                xargv[xi++] = (char *)xorg_module_path;
            }
        }
        xargv[xi] = NULL;

        char xkbdir_buf[1024];
        char fontpath_buf[1024];
        char *xenvp[8];
        int xei = 0;
        xenvp[xei++] = "HOME=/root";
        xenvp[xei++] = "USER=root";
        xenvp[xei++] = "PATH=/run/current-system/profile/bin:"
                       "/run/current-system/profile/sbin";
        if (xorg_xkb_dir && xorg_xkb_dir[0] != '\0') {
            int n = snprintf(xkbdir_buf, sizeof xkbdir_buf,
                             "XKB_BINDIR=%s", xorg_xkb_dir);
            if (n > 0 && (size_t)n < sizeof xkbdir_buf) {
                xenvp[xei++] = xkbdir_buf;
            }
        }
        if (xorg_font_path && xorg_font_path[0] != '\0') {
            int n = snprintf(fontpath_buf, sizeof fontpath_buf,
                             "XORG_FONT_PATH=%s", xorg_font_path);
            if (n > 0 && (size_t)n < sizeof fontpath_buf) {
                xenvp[xei++] = fontpath_buf;
            }
        }
        xenvp[xei] = NULL;

        execve(xorg_path, xargv, xenvp);
        console("pid1: execve(X server) failed");
        _exit(127);
    }
    return pid;
}

/* poll for /tmp/.X11-unix/X0 to appear, up to ~10 seconds. invariant:
 * returns 0 if the socket showed up before the deadline, -1 otherwise.
 * the X server creates this socket once it is ready to accept clients,
 * so this is the cheapest reliable readiness check. we deliberately
 * do not connect()+disconnect() because a half-init server can accept
 * the connection then drop it, which trips emacs's x-open-connection
 * with a worse error than "connect refused, retry". */
static int
wait_for_x_socket(void)
{
    const char *path = "/tmp/.X11-unix/X0";
    for (int i = 0; i < 100; i++) {
        struct stat st;
        if (stat(path, &st) == 0) return 0;
        struct timespec ts = { 0, 100 * 1000 * 1000 }; /* 100ms */
        (void)nanosleep(&ts, NULL);
    }
    return -1;
}

/* (B1+B2, skeptic 2026-05-06) wrap the "mkdir socket dir + spawn_xorg
 * + wait for socket" sequence so the supervisor loop can call it on
 * Xorg-respawn without duplicating logic from main(). returns 0 on
 * success and updates xorg_pid + display_env. on failure returns -1,
 * leaves xorg_pid at -1, and clears display_env so spawn_emacs picks
 * up the no-DISPLAY fallback.
 *
 * the unlink of a stale /tmp/.X11-unix/X0 matters on respawn: if the
 * previous Xorg crashed before unlinking its socket, the new server
 * will fail BindToUnix with EADDRINUSE. on cold boot the file does
 * not exist so the unlink is a noop. */
static int
xorg_bring_up(void)
{
    if (xorg_disabled) return -1;
    if (!xorg_path) return -1;

    if (mkdir("/tmp/.X11-unix", 01777) < 0 && errno != EEXIST) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "pid1: mkdir /tmp/.X11-unix failed: %s",
                 strerror(errno));
        console(buf);
    }
    /* defensive unlink for respawn case; ignore ENOENT on cold boot. */
    if (unlink("/tmp/.X11-unix/X0") < 0 && errno != ENOENT) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "pid1: unlink stale X0 socket failed: %s",
                 strerror(errno));
        console(buf);
    }
    pid_t xpid = spawn_xorg();
    if (xpid < 0) {
        console("pid1: spawn_xorg failed");
        xorg_pid = -1;
        display_env = NULL;
        return -1;
    }
    if (wait_for_x_socket() < 0) {
        console("pid1: X socket /tmp/.X11-unix/X0 never appeared");
        /* leave the Xorg child running anyway: it might still be
         * coming up and a later session may use it. killing it here
         * would race the emacs spawn for /tmp/.X11-unix. but we still
         * track xpid so the supervisor reaps it cleanly. */
        xorg_pid = xpid;
        display_env = NULL;
        return -1;
    }
    xorg_pid = xpid;
    display_env = "DISPLAY=:0";
    console("pid1: X server up on :0");
    return 0;
}

/* (B2) record an Xorg respawn attempt against the rolling 60s window.
 * returns 1 if we are still under the cap and the caller may proceed,
 * 0 if the cap was exceeded and the caller must stop trying. logs the
 * crash-loop event once on the trip-over edge. invariant: monotonic in
 * the sense that once we return 0, xorg_disabled stays set for this
 * boot. */
static int
xorg_note_respawn(void)
{
    time_t now = time(NULL);
    if (xorg_window_start == 0
        || now - xorg_window_start > XORG_RESPAWN_WINDOW_SEC) {
        xorg_window_start = now;
        xorg_respawns_window = 0;
    }
    xorg_respawns_window++;
    if (xorg_respawns_window > XORG_RESPAWN_CAP) {
        if (!xorg_disabled) {
            console("pid1: Xorg crashloop, dropping to bare emacs "
                    "on /dev/console");
        }
        xorg_disabled = 1;
        display_env = NULL;
        xorg_pid = -1;
        return 0;
    }
    return 1;
}

/* fork+exec emacs on /dev/tty1 with a fresh session. invariant: never
 * returns in the child; in the parent returns the new pid, or -1 on
 * fork() failure. */
static pid_t
spawn_emacs(void)
{
    pid_t pid = fork();
    if (pid < 0) {
        console("pid1: fork() failed");
        return -1;
    }
    if (pid == 0) {
        if (setsid() < 0) {
            console("pid1: setsid() failed in child");
            _exit(127);
        }
        /* /dev/console is where the kernel routes the primary
         * terminal (the LAST console= on the cmdline wins). this is
         * tty1 on real hardware and ttyS0 in -nographic QEMU runs,
         * which means the same code works for /boot-vm and a real
         * machine without recompiling. fall back to /dev/tty1 if
         * /dev/console is missing for any reason. */
        int t = open("/dev/console", O_RDWR | O_NOCTTY);
        if (t < 0) t = open("/dev/tty1", O_RDWR | O_NOCTTY);
        if (t < 0) {
            console("pid1: open /dev/console and /dev/tty1 both failed");
            _exit(127);
        }
        /* TIOCSCTTY can fail if we are already a session leader on a
         * controlling tty; not fatal, emacs still works on the fds. */
        (void)ioctl(t, TIOCSCTTY, 0);
        /* if the kernel handoff left fd 0/1/2 open, dup2 closes the
         * old fd before re-targeting; if t happens to equal 0/1/2, the
         * dup2 onto itself is a no-op and we keep going. only close t
         * when it is a separate descriptor. */
        if (t != 0 && dup2(t, 0) < 0) goto dup_fail;
        if (t != 1 && dup2(t, 1) < 0) goto dup_fail;
        if (t != 2 && dup2(t, 2) < 0) goto dup_fail;
        if (t > 2) (void)close(t);
        goto exec_emacs;
    dup_fail:
        console("pid1: dup2 onto tty1 failed");
        _exit(127);
    exec_emacs:
        ; /* labels need a statement before declarations in c11 */

        /* build emacs's argv. layout: [emacs_path, extra_argv...,
         * "-Q" if no extras, NULL]. the boot gexp passes "-Q -l ..."
         * via extras; for raw QEMU smoke tests with no extras we
         * still want -Q so a stale ~/.emacs.d does not derail us.
         * stack array bounded by extra_argc + 3 so no malloc here.
         * cap is 64 so a runaway argv from a buggy gexp does not
         * blow the stack. */
        if (extra_argc > 64) extra_argc = 64;
        char *argv[64 + 3];
        int ai = 0;
        argv[ai++] = (char *)emacs_path;
        for (int i = 0; i < extra_argc; i++) argv[ai++] = extra_argv[i];
        if (extra_argc == 0) argv[ai++] = "-Q";
        argv[ai] = NULL;

        /* envp is fixed-size; we only ever splice PID1_MODULE_PATH and
         * DISPLAY in if they were set. anything else added in the
         * future grows the array and the cap. */
        char *envp[8];
        int ei = 0;
        envp[ei++] = "TERM=linux";
        envp[ei++] = "HOME=/root";
        envp[ei++] = "USER=root";
        envp[ei++] = "PATH=/run/current-system/profile/bin:"
                     "/run/current-system/profile/sbin";
        if (module_env) envp[ei++] = (char *)module_env;
        if (display_env) envp[ei++] = (char *)display_env;
        envp[ei] = NULL;
        execve(emacs_path, argv, envp);
        console("pid1: execve(emacs) failed");
        _exit(127);
    }
    return pid;
}

/* split a colon-joined "Xorg:XKB:MOD:FONT:CONF" string in place. mutates
 * the buffer by writing NULs in place of ':' and stashes the start of
 * each field into the corresponding global. invariant: empty fields
 * leave the global as the empty string (not NULL), so callers can use
 * "[0] != '\0'" to tell "set" from "unset". returns 0 on success. */
static int
parse_xorg_spec(char *spec)
{
    if (!spec || spec[0] == '\0') return -1;
    char *fields[5] = { NULL, NULL, NULL, NULL, NULL };
    int fi = 0;
    fields[fi++] = spec;
    for (char *p = spec; *p && fi < 5; p++) {
        if (*p == ':') {
            *p = '\0';
            fields[fi++] = p + 1;
        }
    }
    /* leftover ':' past the 5th field are part of the last value
     * unchanged. that is fine: a path with a colon would be a real
     * problem upstream. */
    xorg_path        = fields[0] ? fields[0] : "";
    xorg_xkb_dir     = fields[1] ? fields[1] : "";
    xorg_module_path = fields[2] ? fields[2] : "";
    xorg_font_path   = fields[3] ? fields[3] : "";
    xorg_conf_path   = fields[4] ? fields[4] : "";
    if (xorg_path[0] == '\0') {
        xorg_path = NULL;
        return -1;
    }
    return 0;
}

int
main(int argc, char **argv)
{
    /* argv layout from the guix boot gexp:
     *   argv[1] = absolute store path of the emacs binary
     *   argv[2] = absolute store path of pid1-module.so, or "" if no
     *             module yet (phase 1 uses ""; phase 2+ passes a path)
     *   argv[3] = colon-joined Xorg spec
     *               "<Xorg-bin>:<xkb-bindir>:<modulepath>:<fontpath>:<conf>"
     *             empty string means "no X server, run emacs on /dev/console"
     *             (phases 1..4 use ""; phase 5a+ passes a real spec)
     *   argv[4..] = additional args forwarded into emacs's argv,
     *               typically "-Q" "-l" early-init.el "-l" panic.el
     * raw QEMU smoke tests run without any args and fall back to the
     * /usr/bin/emacs default with no module, no Xorg, and no extras. */
    if (argc > 1 && argv[1] && argv[1][0] != '\0') {
        emacs_path = argv[1];
    }
    if (argc > 2 && argv[2] && argv[2][0] != '\0') {
        /* build "PID1_MODULE_PATH=<path>" once into a static buffer.
         * snprintf truncates instead of overflowing; truncation here
         * means a wildly-long store path, which would already have
         * been a problem upstream. */
        int n = snprintf(module_env_buf, sizeof module_env_buf,
                         "PID1_MODULE_PATH=%s", argv[2]);
        if (n < 0 || (size_t)n >= sizeof module_env_buf) {
            console("pid1: PID1_MODULE_PATH too long, skipping");
        } else {
            module_env = module_env_buf;
        }
    }
    if (argc > 3 && argv[3] && argv[3][0] != '\0') {
        /* parse_xorg_spec mutates argv[3] in place. argv lives in the
         * kernel-supplied region so this is fine, no copy needed. */
        if (parse_xorg_spec(argv[3]) == 0) {
            /* DISPLAY=:0 is fixed: spawn_xorg always launches :0. */
            display_env = "DISPLAY=:0";
        } else {
            console("pid1: malformed xorg spec, skipping X server");
        }
    }
    if (argc > 4) {
        extra_argv = (char *const *)&argv[4];
        extra_argc = argc - 4;
    }

    /* the kernel hands us /dev/console as a character device node it
     * mounted on the initial root, so this banner works before we
     * mount our own /dev. if it does not work, the boot is going to
     * fail silently and the user gets no breadcrumb, which is the
     * unhappy path I have to live with.
     *
     * two-stage announcement:
     *   1. one-liner that lands right after the initrd's "loading
     *      '/gnu/store/...-system/boot'..." message, so the user sees
     *      a recognizable hand-off line without having to read a wall
     *      of dashes first.
     *   2. the full banner with separator dashes and a 2-second pause,
     *      giving a human enough time to read it before the verbose
     *      mount/X/emacs spew begins. two seconds is the sweet spot:
     *      longer is annoying on a reboot loop, shorter is unread. */
    console("GNU/Emacs OS v0.1 (GEOS) booting...");
    console("--------------------------------------------------------");
    console("GNU/Emacs Operating System (GEOS). Maintainer <borja.tarraso@member.fsf.org>");
    console("--------------------------------------------------------");
    sleep(2);

    /* set a sane umask; the kernel inherits whatever the caller had */
    umask(022);

    /* pseudo-filesystems the kernel does not mount on its own */
    do_mount("proc",     "/proc",    "proc",     MS_NOSUID|MS_NOEXEC|MS_NODEV, NULL);
    do_mount("sysfs",    "/sys",     "sysfs",    MS_NOSUID|MS_NOEXEC|MS_NODEV, NULL);
    do_mount("devtmpfs", "/dev",     "devtmpfs", MS_NOSUID,                     "mode=0755");
    do_mount("tmpfs",    "/run",     "tmpfs",    MS_NOSUID|MS_NODEV,            "mode=0755");
    do_mount("tmpfs",    "/tmp",     "tmpfs",    MS_NOSUID|MS_NODEV,            NULL);
    do_mount("devpts",   "/dev/pts", "devpts",   MS_NOSUID|MS_NOEXEC,           "gid=5,mode=0620");

    /* /run/current-system is the canonical guix indirection that every
     * profile-aware path keys off of (PATH=/run/current-system/profile/
     * bin, fontconfig, locale archives, ...). guix's activation service
     * normally creates it, but our boot gexp execl's emacs-init before
     * activation runs, so we stand it up here from /proc/cmdline's
     * gnu.system= value. without this, executable-find inside emacs
     * returns nil for everything and the s-& launcher cannot find xterm. */
    link_current_system();

    /* loopback first so emacs's network code does not stall on probe */
    if (raw_bring_up_lo() < 0) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "pid1: bring up lo failed: %s", strerror(errno));
        console(buf);
    }

    /* SIGCHLD: reap orphans reparented to us when their parents died */
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sigchld;
    /* deliberately no SA_RESTART: we want waitpid() to return EINTR so
     * the main loop notices got_sigchld and reaps reparented orphans
     * promptly instead of letting them queue while we block on emacs. */
    sa.sa_flags = SA_NOCLDSTOP;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGCHLD, &sa, NULL) < 0) {
        console("pid1: sigaction(SIGCHLD) failed, orphans will pile up");
    }

    /* phase 5a: start Xorg if argv[3] gave us a spec. critical that
     * this happens BEFORE the first spawn_emacs(), so emacs's first
     * frame is already an X frame and exwm-enable can grab the root
     * window without a tty -> X frame transition. failures here are
     * non-fatal: we log to /dev/console and fall back to "no DISPLAY",
     * which means emacs comes up on the serial console as before.
     *
     * the heavy lifting (mkdir socket dir, spawn_xorg, wait_for_x_socket)
     * is in xorg_bring_up() so the supervisor can re-call it on Xorg
     * death without duplicating the boot path. */
    if (xorg_path) {
        if (xorg_bring_up() < 0) {
            console("pid1: continuing without DISPLAY");
        }
    }

    console("pid1: entering supervisor loop");

    /* main loop: keep emacs alive forever. anything reparented to us
     * is harvested by waitpid(-1) below.
     *
     * (B1, skeptic 2026-05-06) we waitpid(-1) instead of waitpid(emacs)
     * because Xorg is also our child and we need to react to its death,
     * not just have it silently reaped by reap_orphans. when Xorg dies
     * we SIGTERM emacs (it is talking to a dead :0; a second of grace
     * then SIGKILL), then bring Xorg back up and let the outer loop
     * respawn emacs. when emacs dies we just respawn emacs.
     *
     * we do NOT waitpid(emacs) tightly first to avoid the case where
     * Xorg dies while emacs is still alive and we never notice until
     * the user closes their x frame; -1 lets either signal land. */
    for (;;) {
        pid_t emacs = spawn_emacs();
        if (emacs < 0) {
            sleep_at_least(1);
            continue;
        }
        int emacs_dead = 0;
        while (!emacs_dead) {
            int status;
            pid_t r = waitpid(-1, &status, 0);
            if (r < 0 && errno == EINTR) {
                if (got_sigchld) got_sigchld = 0;
                continue;
            }
            if (r < 0) {
                /* ECHILD here means emacs already vanished without
                 * being seen; treat as a death and respawn. anything
                 * else is unexpected, log and respawn anyway so we
                 * never wedge here. */
                console("pid1: waitpid() failed, respawning emacs anyway");
                emacs_dead = 1;
                break;
            }
            if (r == emacs) {
                console("pid1: emacs exited, respawning");
                emacs_dead = 1;
                break;
            }
            if (r == xorg_pid) {
                char buf[128];
                snprintf(buf, sizeof buf,
                         "pid1: Xorg died (pid=%d, status=%d), tearing "
                         "down emacs and respawning both",
                         (int)r, status);
                console(buf);
                xorg_pid = -1;
                /* SIGTERM emacs and give it 5s to exit cleanly so the
                 * supervisor does not race spawn_xorg with a still-
                 * connected client. if it does not exit, SIGKILL.
                 * we keep waitpid'ing inside the grace loop because
                 * other reparented children might also exit during it. */
                (void)kill(emacs, SIGTERM);
                int waited_ms = 0;
                while (waited_ms < 5000) {
                    int gs;
                    pid_t gr = waitpid(emacs, &gs, WNOHANG);
                    if (gr == emacs) break;
                    if (gr < 0 && errno != EINTR) break;
                    /* drain anything else that exits during the grace */
                    while (waitpid(-1, NULL, WNOHANG) > 0) { }
                    struct timespec ts = { 0, 100 * 1000 * 1000 };
                    (void)nanosleep(&ts, NULL);
                    waited_ms += 100;
                }
                if (waitpid(emacs, NULL, WNOHANG) == 0) {
                    console("pid1: emacs did not exit on SIGTERM, "
                            "sending SIGKILL");
                    (void)kill(emacs, SIGKILL);
                    (void)waitpid(emacs, NULL, 0);
                }
                emacs_dead = 1;
                /* respawn Xorg before falling through to the outer
                 * loop's spawn_emacs so the new emacs sees DISPLAY=:0
                 * again. crashloop cap is checked here, not in
                 * xorg_bring_up, so a respawn that succeeds at startup
                 * but dies fast still counts. */
                if (xorg_note_respawn()) {
                    if (xorg_bring_up() < 0) {
                        console("pid1: Xorg respawn failed, "
                                "continuing without DISPLAY");
                    }
                }
                break;
            }
            /* unrelated child reaped (orphan reparented to us) */
        }
        /* throttle: if emacs crash-loops we do not want to pin the cpu.
         * sleep_at_least() defends against SIGCHLD waking sleep early,
         * which would let us respawn at full speed and saturate the box. */
        sleep_at_least(1);
    }

    /* unreachable. if we ever return from main() the kernel panics. */
    return 0;
}

#endif /* !PID1_MODULE */

/* ---- module-only code ------------------------------------------- */

#ifdef PID1_MODULE

/* signal pid1-error with a single string data argument. invariant:
 * sets a non-local exit on env; caller must return to elisp without
 * touching env again except for cleanup. */
static void
pid1_signal_errno(emacs_env *env, const char *prefix, int err)
{
    char buf[256];
    /* strerror is not async-signal-safe but we are not in a signal
     * handler here; we are in an elisp callback. fine. */
    snprintf(buf, sizeof buf, "%s: %s", prefix, strerror(err));
    emacs_value sym = env->intern(env, "pid1-error");
    emacs_value msg = env->make_string(env, buf, (ptrdiff_t)strlen(buf));
    emacs_value list_args[1] = { msg };
    emacs_value data = env->funcall(env, env->intern(env, "list"),
                                    1, list_args);
    env->non_local_exit_signal(env, sym, data);
}

/* extract a lisp string into a freshly heap-allocated nul-terminated
 * c string. returns NULL on either a non-string argument or oom; in
 * both cases sets a non-local exit. caller must free the result. */
static char *
extract_cstring(emacs_env *env, emacs_value v)
{
    ptrdiff_t need = 0;
    if (!env->copy_string_contents(env, v, NULL, &need)) {
        /* copy_string_contents already signaled if it was the wrong
         * type; if it was an oom we surface our own signal. either
         * way, abort the call. */
        return NULL;
    }
    char *buf = malloc((size_t)need);
    if (!buf) {
        pid1_signal_errno(env, "pid1: malloc", ENOMEM);
        return NULL;
    }
    if (!env->copy_string_contents(env, v, buf, &need)) {
        free(buf);
        return NULL;
    }
    return buf;
}

/* (pid1-reap) -> list of (pid . status) cons pairs.
 * loops waitpid(-1, &status, WNOHANG) until it returns 0 or -1.
 * returns nil if no zombies are pending. ECHILD is treated as "no
 * children", same as no zombies. */
static emacs_value
Fpid1_reap(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)args; (void)data;

    emacs_value Qnil = env->intern(env, "nil");
    emacs_value Qcons = env->intern(env, "cons");
    /* build the list head-first then reverse with `nreverse'. simpler
     * than walking with a tail pointer at the c level. */
    emacs_value acc = Qnil;
    int any_appended = 0;

    for (;;) {
        int status = 0;
        pid_t pid = waitpid(-1, &status, WNOHANG);
        if (pid == 0) break;
        if (pid < 0) {
            if (errno == ECHILD) break;
            if (errno == EINTR) continue;
            pid1_signal_errno(env, "pid1: waitpid", errno);
            return Qnil;
        }
        emacs_value pair_args[2] = {
            env->make_integer(env, (intmax_t)pid),
            env->make_integer(env, (intmax_t)status),
        };
        emacs_value pair = env->funcall(env, Qcons, 2, pair_args);
        emacs_value cons_args[2] = { pair, acc };
        acc = env->funcall(env, Qcons, 2, cons_args);
        any_appended = 1;
    }

    if (!any_appended) return Qnil;
    emacs_value rev_args[1] = { acc };
    return env->funcall(env, env->intern(env, "nreverse"), 1, rev_args);
}

/* (pid1-mount SRC TGT TYPE FLAGS OPTS) -> t or signal pid1-error.
 * OPTS may be nil, in which case NULL is passed to mount(2). FLAGS is
 * an integer interpreted as the unsigned long mountflags arg. */
static emacs_value
Fpid1_mount(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)data;
    if (nargs != 5) {
        pid1_signal_errno(env, "pid1: pid1-mount needs 5 args", EINVAL);
        return env->intern(env, "nil");
    }
    /* extract args one at a time and bail on first failure: per the
     * emacs module ABI, once non_local_exit is set, subsequent env
     * calls are undefined, so chained extract_cstring without a check
     * after each is a real bug, not a defensive nit. */
    char *src = NULL, *tgt = NULL, *type = NULL, *opts = NULL;
    intmax_t flags_im = 0;
    int have_opts = 0;
    src = extract_cstring(env, args[0]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) goto bail;
    tgt = extract_cstring(env, args[1]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) goto bail;
    type = extract_cstring(env, args[2]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) goto bail;
    flags_im = env->extract_integer(env, args[3]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) goto bail;
    have_opts = env->is_not_nil(env, args[4]);
    if (have_opts) {
        opts = extract_cstring(env, args[4]);
        if (env->non_local_exit_check(env) != emacs_funcall_exit_return) goto bail;
    }
    goto extracted;
bail:
    free(src); free(tgt); free(type); free(opts);
    return env->intern(env, "nil");
extracted:
    ;

    int rc = raw_mount(src, tgt, type, (unsigned long)flags_im, opts);
    int err = errno;
    free(src); free(tgt); free(type); free(opts);

    if (rc < 0) {
        pid1_signal_errno(env, "pid1: mount", err);
        return env->intern(env, "nil");
    }
    return env->intern(env, "t");
}

/* (pid1-set-hostname NAME) -> t or signal pid1-error.
 * NAME is a string; passed through to sethostname(2). */
static emacs_value
Fpid1_set_hostname(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                   void *data)
{
    (void)data;
    if (nargs != 1) {
        pid1_signal_errno(env, "pid1: pid1-set-hostname needs 1 arg", EINVAL);
        return env->intern(env, "nil");
    }
    char *name = extract_cstring(env, args[0]);
    if (!name) return env->intern(env, "nil");
    int rc = raw_set_hostname(name, strlen(name));
    int err = errno;
    free(name);
    if (rc < 0) {
        pid1_signal_errno(env, "pid1: sethostname", err);
        return env->intern(env, "nil");
    }
    return env->intern(env, "t");
}

/* (pid1-bring-up-lo) -> t or signal pid1-error. wraps the same body
 * the boot path uses; lets a running emacs re-up loopback after a
 * kernel module reload or a netns dance. */
static emacs_value
Fpid1_bring_up_lo(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                  void *data)
{
    (void)nargs; (void)args; (void)data;
    if (raw_bring_up_lo() < 0) {
        pid1_signal_errno(env, "pid1: bring up lo", errno);
        return env->intern(env, "nil");
    }
    return env->intern(env, "t");
}

/* binds NAME to FUNC at top level via (defalias NAME FUNC). assumes
 * env is non-null and not in non-local-exit state. named with a pid1_
 * prefix because the bare name `bind` collides with libc's bind(2)
 * pulled in via <sys/socket.h>. */
static void
pid1_defalias(emacs_env *env, const char *name, emacs_value func)
{
    emacs_value sym = env->intern(env, name);
    emacs_value args[2] = { sym, func };
    (void)env->funcall(env, env->intern(env, "defalias"), 2, args);
}

/* module entry point. emacs calls this once at module-load time.
 * invariant: returns 0 on success, non-zero on a setup error. we do
 * not allocate anything that needs to outlive this call: the bound
 * functions are owned by emacs after defalias. */
int
emacs_module_init(struct emacs_runtime *ert)
{
    /* version sanity: the runtime struct can grow over emacs releases.
     * if it shrinks below what we compiled against, refuse to load. */
    if ((size_t)ert->size < sizeof (struct emacs_runtime)) {
        return 1;
    }
    emacs_env *env = ert->get_environment(ert);
    if (!env) return 2;
    if ((size_t)env->size < sizeof (emacs_env)) return 3;

    emacs_value reap = env->make_function(env, 0, 0, Fpid1_reap,
        "Reap zombies via waitpid(WNOHANG). Return list of (PID . STATUS).",
        NULL);
    pid1_defalias(env, "pid1-reap", reap);

    emacs_value mnt = env->make_function(env, 5, 5, Fpid1_mount,
        "Call mount(2). Args: SRC TGT TYPE FLAGS OPTS. Return t.",
        NULL);
    pid1_defalias(env, "pid1-mount", mnt);

    emacs_value sh = env->make_function(env, 1, 1, Fpid1_set_hostname,
        "Call sethostname(2) with NAME. Return t.",
        NULL);
    pid1_defalias(env, "pid1-set-hostname", sh);

    emacs_value lo = env->make_function(env, 0, 0, Fpid1_bring_up_lo,
        "Bring up the loopback interface. Return t.",
        NULL);
    pid1_defalias(env, "pid1-bring-up-lo", lo);

    /* provide the feature so (require 'pid1-module) works after
     * (module-load ...) without a separate elisp wrapper. */
    emacs_value feat_args[1] = { env->intern(env, "pid1-module") };
    (void)env->funcall(env, env->intern(env, "provide"), 1, feat_args);

    return 0;
}

#endif /* PID1_MODULE */
