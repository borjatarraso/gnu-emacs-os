/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* emacs-init.c, PID 1 for GNU/Emacs Operating System (GEOS).
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
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <linux/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "port_layer.h"

#ifdef PID1_MODULE
#include <crypt.h>
#include <emacs-module.h>
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
    /* FORTIFY makes write/close warn_unused_result-warn through (void)
     * casts, so explicitly drop the result into a sink variable that
     * we then cast away.  there is genuinely nothing to do if these
     * fail: we are already trying to report a problem to the only
     * channel we have. */
    int fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t r;
    r = write(fd, msg, strlen(msg)); (void)r;
    r = write(fd, "\n", 1);          (void)r;
    int c = close(fd);                (void)c;
}
#endif

/* the kernel-specific surfaces (mount, set_hostname, ifconfig, reboot,
 * suspend) used to live here as raw_* helpers.  they now live behind
 * port->X() in port_layer.h / port_linux.c, so the Hurd backend can
 * substitute its own implementations on the side branch without
 * touching this file.  see docs/v04-item11-hurd-spike.md step 1. */

#ifndef PID1_MODULE
/* read /etc/hostname (which guix's etc-service-type writes from the
 * operating-system host-name field), trim trailing whitespace, and
 * call sethostname. fall back to the hardcoded "lambda" if the file
 * is unreadable, empty, or whitespace-only. invariant: never errors
 * out the boot. failures log to /dev/console and continue. boot path
 * only because console() is gated on !PID1_MODULE; the module path
 * uses Fpid1_set_hostname driven from elisp instead. */
static void
set_hostname_at_boot(void)
{
    char buf[256];
    ssize_t n = -1;
    int fd = open("/etc/hostname", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        n = read(fd, buf, sizeof buf - 1);
        (void)close(fd);
    }
    /* trim trailing whitespace/newline. if nothing readable survives,
     * fall back to "lambda" so uname -a never shows (none). */
    if (n > 0) {
        buf[n] = '\0';
        while (n > 0
               && (buf[n - 1] == '\n' || buf[n - 1] == '\r'
                   || buf[n - 1] == ' ' || buf[n - 1] == '\t')) {
            buf[--n] = '\0';
        }
    }
    /* reject embedded NUL bytes. /etc/hostname is plain text by spec,
     * but if it contains a stray NUL we'd hand a truncated name to
     * sethostname(2) and confuse anything that later does
     * gethostname() + strlen. easier to fail closed.
     *
     * (M6, audit round-5 2026-05-10) also reject embedded \r and \n
     * in the middle of the name.  the trailing-trim loop above only
     * strips trailing whitespace, so a file like "foo\r\nbar" keeps
     * an embedded \r that sethostname accepts and gethostname later
     * surfaces as a control-char nodename, garbling shells, prompts,
     * and DNS PTR lookups.  fail closed and fall back to "lambda". */
    for (ssize_t i = 0; i < n; i++) {
        if (buf[i] == '\0' || buf[i] == '\r' || buf[i] == '\n') {
            n = 0;
            break;
        }
    }
    /* HOST_NAME_MAX bound. linux's HOST_NAME_MAX is 64 INCLUDING the
     * NUL terminator; sethostname(2) takes a length but utsname.nodename
     * is sized to HOST_NAME_MAX, so a 64-byte name leaves no room for
     * the NUL gethostname(3) writes. cap at 63 to keep
     * set/get round-tripping. */
    if (n > 63) {
        char msg[160];
        (void)snprintf(msg, sizeof msg,
                       "pid1: /etc/hostname is %zd bytes, max 63; using lambda",
                       n);
        console(msg);
        n = 0;
    }
    const char *name;
    size_t len;
    if (n > 0) {
        name = buf;
        len = (size_t)n;
    } else {
        name = "lambda";
        len = 6;
        console("pid1: /etc/hostname unreadable or empty, defaulting to lambda");
    }
    if (port->set_hostname(name, len) < 0) {
        char msg[384];
        (void)snprintf(msg, sizeof msg,
                       "pid1: sethostname(%s) failed: %s",
                       name, strerror(errno));
        console(msg);
        return;
    }
    {
        char msg[320];
        (void)snprintf(msg, sizeof msg, "pid1: hostname set to %s", name);
        console(msg);
    }
}
#endif

/* the loopback / address / route ioctl bodies used to live here.
 * they now live in port_linux.c behind port->bring_up_lo,
 * port->set_address, port->set_route_default. */

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
    if (port->mount(src, tgt, type, flags, opts) < 0) {
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
    /* (B4, audit round-5 2026-05-10) /proc/cmdline can exceed 4 KiB
     * on systems with many kernel parameters (verbose efistub args,
     * dracut early-storage tokens, distro-shipped kernel pinning).
     * a single 4 KiB read could land mid-token and cause us to miss
     * gnu.system=.  bump the buffer to 16 KiB and loop the read so
     * a partial-read kernel never breaks the parser. */
    char buf[16384];
    ssize_t n = 0;
    for (;;) {
        ssize_t r = read(fd, buf + n, sizeof buf - 1 - (size_t)n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        n += r;
        if ((size_t)n >= sizeof buf - 1) break;
    }
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

/* parse /proc/cmdline for the geos.mode= token. recognized values are
 * "ui" (default; spawn Xorg and run emacs as an X client), "console"
 * (skip Xorg, run emacs on /dev/console with TERM=linux), and
 * "recovery" (v0.4 item 10: skip Xorg AND skip the userland -l chain;
 * the operator lands on a bare *scratch* with panic.el available so a
 * broken defservice or defcustom cannot wedge the boot).  anything
 * else, including a missing token or an unreadable cmdline, defaults
 * to UI: matches the historical v0.1/v0.2 behaviour and means an
 * unmodified GRUB entry keeps the pretty boot.  invariant: pure read,
 * never blocks longer than the /proc read takes.  logs the chosen
 * mode to /dev/console so the operator sees the decision in the boot
 * trace. */
#define GEOS_MODE_UI       1
#define GEOS_MODE_CONSOLE  0
#define GEOS_MODE_RECOVERY 2

static int
read_geos_mode(void)
{
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        console("pid1: /proc/cmdline unreadable, defaulting to ui mode");
        return GEOS_MODE_UI;
    }
    /* (B4) /proc/cmdline can exceed 4 KiB on real systems; loop. */
    char buf[16384];
    ssize_t n = 0;
    for (;;) {
        ssize_t r = read(fd, buf + n, sizeof buf - 1 - (size_t)n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        n += r;
        if ((size_t)n >= sizeof buf - 1) break;
    }
    (void)close(fd);
    if (n <= 0) return GEOS_MODE_UI;
    buf[n] = '\0';
    const char *key = "geos.mode=";
    char *p = strstr(buf, key);
    /* default-on-absence is ui: the operating-system record bakes
     * geos.mode=ui into kernel-arguments, so this fallback only fires
     * on a hand-rolled boot or a corrupt cmdline. ui is the project
     * default, picking it on absence keeps both layers in agreement. */
    if (!p) return GEOS_MODE_UI;
    p += strlen(key);
    /* extract the token bound by whitespace/newline; we only care about
     * a small, fixed set of values so a 32-byte stack copy is plenty. */
    char val[32];
    size_t i = 0;
    while (i < sizeof val - 1
           && p[i] != '\0' && p[i] != ' ' && p[i] != '\t' && p[i] != '\n') {
        val[i] = p[i];
        i++;
    }
    val[i] = '\0';
    if (strcmp(val, "console") == 0) {
        console("pid1: geos.mode=console, skipping Xorg, emacs on /dev/console");
        return GEOS_MODE_CONSOLE;
    }
    if (strcmp(val, "ui") == 0) {
        console("pid1: geos.mode=ui, will spawn Xorg + EXWM");
        return GEOS_MODE_UI;
    }
    if (strcmp(val, "recovery") == 0) {
        console("pid1: geos.mode=recovery, skipping Xorg AND userland chain");
        return GEOS_MODE_RECOVERY;
    }
    /* unknown value: log and default. better than booting into a mode
     * the operator did not ask for. */
    {
        char msg[128];
        (void)snprintf(msg, sizeof msg,
                       "pid1: unknown geos.mode=%s, defaulting to ui", val);
        console(msg);
    }
    return GEOS_MODE_UI;
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

/* mount /var so the elisp state directory has somewhere to live.
 * probes /dev/disk/by-label/geos-var first (real persistence across
 * reboots); falls back to tmpfs so a fresh image without that label
 * still boots and works in degraded mode (state lost on reboot, but
 * the rest of the system functions). logs the choice with a marker
 * the smoke-test greps for ("pid1: /var on tmpfs" or "pid1: /var on
 * ext4"). invariant: caller is root, called once at boot from main()
 * after the do_mount block. never aborts boot: if even tmpfs fails we
 * log loudly and let early-init.el degrade gracefully when it cannot
 * write under /var/emacs. */
static void
mount_var(void)
{
    char buf[256];
    /* /var may not exist on a fresh root; the guix system image populates
     * it during activation, but we run BEFORE activation. mkdir is
     * idempotent for our purposes (EEXIST is success). */
    if (mkdir("/var", 0755) < 0 && errno != EEXIST) {
        snprintf(buf, sizeof buf,
                 "pid1: mkdir /var failed: %s", strerror(errno));
        console(buf);
        /* keep going: a pre-existing /var that is e.g. a symlink will
         * still mount fine. */
    }
    /* probe for the labelled partition. udev (in the initrd) populates
     * /dev/disk/by-label/ so the symlink is there iff a partition with
     * the geos-var label was found at boot. access() is good enough; we
     * do not need to stat the target. */
    const char *label_path = "/dev/disk/by-label/geos-var";
    if (access(label_path, F_OK) == 0) {
        if (port->mount(label_path, "/var", "ext4",
                        MS_NOSUID, NULL) == 0) {
            console("pid1: /var on ext4 (geos-var label)");
            return;
        }
        if (errno == EBUSY) {
            console("pid1: /var on ext4 (already mounted by initrd)");
            return;
        }
        snprintf(buf, sizeof buf,
                 "pid1: mount geos-var ext4 failed: %s, "
                 "falling through to tmpfs", strerror(errno));
        console(buf);
    }
    /* fallback. tmpfs is always available; the only way this fails is
     * an OOM kernel, in which case we have bigger problems. */
    if (port->mount("tmpfs", "/var", "tmpfs", MS_NOSUID,
                    "mode=0755") == 0) {
        console("pid1: /var on tmpfs (no geos-var label)");
        return;
    }
    if (errno == EBUSY) {
        console("pid1: /var on tmpfs (already mounted by initrd)");
        return;
    }
    snprintf(buf, sizeof buf,
             "pid1: /var mount failed entirely: %s", strerror(errno));
    console(buf);
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

/* v0.4 item 10: GEOS_MODE=ui|console|recovery in the same shape as
 * display_env and module_env so spawn_emacs's envp can splice it
 * without an strdup.  early-init.el reads this via (getenv "GEOS_MODE")
 * to decide whether to short-circuit the userland chain (recovery
 * mode drops command-line-args-left so subsequent -l files are
 * skipped).  set unconditionally from main() after read_geos_mode()
 * runs; "ui"/"console" are informational, "recovery" actually changes
 * elisp behaviour. */
static const char *geos_mode_env = NULL;

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
/* (B3, audit round-5 2026-05-10) track the last respawn time
 * separately so the window resets after a quiet period, not just
 * after WINDOW_SEC has elapsed since first respawn.  without this
 * the counter monotonically accrues against an ancient window
 * start until WINDOW_SEC fires once, meaning a long-stable system
 * with one ancient crash plus one new crash trips at the cap. */
static time_t xorg_last_respawn = 0;
static int xorg_disabled = 0;

/* emacs respawn cap, same shape as xorg's. an emacs that segfaults
 * during early init.el evaluation would otherwise fork-exec-die in a
 * tight loop, pinning a cpu and hiding the underlying error in a
 * tornado of /dev/console output. when the cap trips we drop to a
 * holding pattern that just reaps zombies and leaves the operator
 * a chance to debug from the framebuffer login (or, in qemu, to
 * read the serial log without it being overwritten every second). */
#define EMACS_RESPAWN_CAP 5
#define EMACS_RESPAWN_WINDOW_SEC 60
static int emacs_respawns_window = 0;
static time_t emacs_window_start = 0;
/* (B3, audit round-5 2026-05-10) same defence as xorg_last_respawn:
 * reset the window after a quiet stretch so an ancient crash plus one
 * new crash inside the never-decayed original window does not trip the
 * cap. */
static time_t emacs_last_respawn = 0;
static int emacs_holding = 0;

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

        /* (M5, audit round-5 2026-05-10) anchor on the path component
         * boundary.  the prior `path_ends_with(..., "Xvfb")' fallback
         * matched "/usr/local/MyXvfb" too, which would silently turn
         * a real Xorg into Xvfb-flag mode and drop -config etc.  the
         * bare-basename case ("Xvfb" with no slash) needs exact
         * strcmp, not a tail compare. */
        int is_xvfb = path_ends_with(xorg_path, "/Xvfb")
                      || (xorg_path && strcmp(xorg_path, "Xvfb") == 0);

        /* (W7, audit 2026-05-10) worst case in the Xorg branch is
         * 13 entries + NULL.  bumped from 16 to 20 for headroom and
         * added a runtime guard before each push so a future flag
         * addition cannot silently overflow.  the XARGV_PUSH macro
         * panics the boot rather than corrupting the stack frame. */
        #define XARGV_CAP 20
        char *xargv[XARGV_CAP];
        int xi = 0;
        #define XARGV_PUSH(s) do {                                           \
            if (xi >= XARGV_CAP - 1) {                                       \
                console("pid1: xargv overflow building X server argv");      \
                _exit(127);                                                  \
            }                                                                \
            xargv[xi++] = (char *)(s);                                       \
        } while (0)
        XARGV_PUSH(xorg_path);
        XARGV_PUSH(":0");
        if (is_xvfb) {
            XARGV_PUSH("-screen");
            XARGV_PUSH("0");
            XARGV_PUSH("1024x768x24");
            XARGV_PUSH("-nolisten");
            XARGV_PUSH("tcp");
            XARGV_PUSH("-noreset");
        } else {
            /* Xorg path: keep the original phase-5a flag set in case
             * we flip back when 5c lands a working KMS driver. */
            XARGV_PUSH("vt7");
            XARGV_PUSH("-keeptty");
            XARGV_PUSH("-nolisten");
            XARGV_PUSH("tcp");
            XARGV_PUSH("-noreset");
            XARGV_PUSH("-logfile");
            XARGV_PUSH("/tmp/Xorg.0.log");
            if (xorg_conf_path && xorg_conf_path[0] != '\0') {
                XARGV_PUSH("-config");
                XARGV_PUSH(xorg_conf_path);
            }
            if (xorg_module_path && xorg_module_path[0] != '\0') {
                XARGV_PUSH("-modulepath");
                XARGV_PUSH(xorg_module_path);
            }
        }
        xargv[xi] = NULL;
        #undef XARGV_PUSH
        #undef XARGV_CAP

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
 * with a worse error than "connect refused, retry".
 *
 * (M4, audit round-5 2026-05-10) also poll waitpid(xpid, ...) so we
 * exit early if the Xorg child died before binding the socket.
 * without this, an Xorg that crashes 50ms after fork wastes the full
 * 10s deadline before we report failure, then the supervisor respawns
 * it and we wait another 10s.  with the poll, a crash is detected on
 * the next 100ms tick.  pass -1 to skip the waitpid (preserves the
 * old shape for callers that have not captured the pid). */
static int
wait_for_x_socket(pid_t xpid)
{
    const char *path = "/tmp/.X11-unix/X0";
    for (int i = 0; i < 100; i++) {
        struct stat st;
        if (stat(path, &st) == 0) return 0;
        if (xpid > 0) {
            int status = 0;
            pid_t r = waitpid(xpid, &status, WNOHANG);
            if (r == xpid) {
                /* child reaped here, supervisor loop will not see it.
                 * caller must treat this as crash and not double-reap. */
                return -1;
            }
        }
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
    if (wait_for_x_socket(xpid) < 0) {
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
        || now - xorg_window_start > XORG_RESPAWN_WINDOW_SEC
        || (xorg_last_respawn != 0
            && now - xorg_last_respawn > XORG_RESPAWN_WINDOW_SEC)) {
        xorg_window_start = now;
        xorg_respawns_window = 0;
    }
    xorg_last_respawn = now;
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

/* (B6, skeptic 2026-05-10) record an emacs respawn against the rolling
 * window and decide whether the supervisor should keep trying.  same
 * shape as xorg_note_respawn: returns 1 if under cap, 0 if we just
 * tripped or already had.  callers that get 0 must stop forking emacs
 * and switch the supervisor to a holding pattern (zombie reaper, no
 * respawn) so the operator can read the failure on /dev/console. */
static int
emacs_note_respawn(void)
{
    time_t now = time(NULL);
    if (emacs_window_start == 0
        || now - emacs_window_start > EMACS_RESPAWN_WINDOW_SEC
        || (emacs_last_respawn != 0
            && now - emacs_last_respawn > EMACS_RESPAWN_WINDOW_SEC)) {
        emacs_window_start = now;
        emacs_respawns_window = 0;
    }
    emacs_last_respawn = now;
    emacs_respawns_window++;
    if (emacs_respawns_window > EMACS_RESPAWN_CAP) {
        if (!emacs_holding) {
            console("pid1: emacs crashloop, entering holding pattern; "
                    "supervisor will reap zombies but not respawn emacs");
        }
        emacs_holding = 1;
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
         * controlling tty; not fatal, emacs still works on the fds.
         * (W6, audit 2026-05-10) log errno on failure so the boot
         * trace tells us why the controlling-tty grab failed: EPERM
         * means another session already owns it; ENOTTY means the fd
         * is not a tty (would imply /dev/console resolved to a pipe). */
        if (ioctl(t, TIOCSCTTY, 0) < 0) {
            char buf[128];
            snprintf(buf, sizeof buf,
                     "pid1: TIOCSCTTY on console failed (%s), continuing",
                     strerror(errno));
            console(buf);
        }
        /* (W8, audit 2026-05-10) dup2(fd, fd) is documented as a no-op
         * by POSIX (returns fd, leaves the fd intact) so the prior "skip
         * when t == 0/1/2" guard was paranoia.  drop it; the code reads
         * cleaner and we lose nothing.  only close t if it is past
         * stdio so we do not yank the descriptor back out from under
         * ourselves. */
        if (dup2(t, 0) < 0) goto dup_fail;
        if (dup2(t, 1) < 0) goto dup_fail;
        if (dup2(t, 2) < 0) goto dup_fail;
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
         * cap is 128 so a runaway argv from a buggy gexp does not
         * blow the stack but we have room for the userland chain to
         * grow as v0.4 lands more buffers.  bumped from 64 once we
         * crossed 60+ -l files. */
        if (extra_argc > 128) {
            char buf[96];
            snprintf(buf, sizeof buf,
                     "pid1: extra argv truncated to 128 (was %d), check boot gexp",
                     extra_argc);
            console(buf);
            extra_argc = 128;
        }
        char *argv[128 + 3];
        int ai = 0;
        argv[ai++] = (char *)emacs_path;
        for (int i = 0; i < extra_argc; i++) argv[ai++] = extra_argv[i];
        if (extra_argc == 0) argv[ai++] = "-Q";
        argv[ai] = NULL;

        /* envp is fixed-size; we only ever splice PID1_MODULE_PATH,
         * DISPLAY and GEOS_MODE in if they were set. anything else
         * added in the future grows the array and the cap. */
        char *envp[8];
        int ei = 0;
        envp[ei++] = "TERM=linux";
        envp[ei++] = "HOME=/root";
        envp[ei++] = "USER=root";
        envp[ei++] = "PATH=/run/current-system/profile/bin:"
                     "/run/current-system/profile/sbin";
        if (module_env) envp[ei++] = (char *)module_env;
        if (display_env) envp[ei++] = (char *)display_env;
        if (geos_mode_env) envp[ei++] = (char *)geos_mode_env;
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

/* dump_file_to_console: shared helper for the two diagnostic dumps
 * below. reads PATH up to DUMP_MAX bytes, splits on newline, and
 * writes each non-empty line prefixed with TAG to /dev/console.
 *
 * (B2, audit 2026-05-10) no malloc: PID 1's own header invariant says
 * "no malloc", and the previous version called malloc twice per line
 * which made that claim false. we replace both buffers with file-
 * scope statics. PID 1's main() is single-threaded; both callers run
 * sequentially before the supervisor loop, so static reuse is safe.
 *
 * DUMP_MAX caps the slurp at 64 KiB which is the larger of the two
 * historical caps (Xorg.0.log). a file longer than that is truncated
 * at the byte boundary and the trailing partial line dropped, which
 * is preferable to either (a) skipping the dump entirely, or (b)
 * reaching for malloc and breaking the project invariant.
 *
 * invariant: never raises; bounded read, bounded line buffer. */
#define DUMP_MAX 65536
#define DUMP_LINE_MAX 1024
static char dump_buf[DUMP_MAX + 1];
static char dump_line[DUMP_LINE_MAX];
static void
dump_file_to_console(const char *path, const char *tag, size_t max)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        char miss[256];
        (void)snprintf(miss, sizeof miss, "%s: %s not readable", tag, path);
        console(miss);
        return;
    }
    if (max > DUMP_MAX) max = DUMP_MAX;
    ssize_t n = read(fd, dump_buf, max);
    (void)close(fd);
    if (n <= 0) {
        char empty[128];
        (void)snprintf(empty, sizeof empty, "%s: empty", tag);
        console(empty);
        return;
    }
    dump_buf[n] = '\0';
    char *line = dump_buf;
    while (line && *line) {
        char *end = strchr(line, '\n');
        if (end) *end = '\0';
        if (*line) {
            /* DUMP_LINE_MAX caps any single emitted line. real lines
             * in /proc/bus/input/devices and Xorg.0.log are well
             * under 500 bytes; truncation here is a "log noise"
             * outcome, not a correctness issue.  the explicit %.*s
             * precision keeps -Wformat-truncation quiet about line
             * pointing into a 64 KiB buffer. */
            int avail = (int)sizeof dump_line - 64;
            if (avail < 0) avail = 0;
            (void)snprintf(dump_line, sizeof dump_line,
                           "%s: %.*s", tag, avail, line);
            console(dump_line);
        }
        line = end ? end + 1 : NULL;
    }
}

/* dump /proc/bus/input/devices to /dev/console, prefixed "input:".
 * called once before xorg_bring_up to verify the kernel created
 * /dev/input/eventN nodes the xorg.conf references, and again after
 * a short post-Xorg sleep to catch late-enumerating devices like
 * usb-tablet. invariant: never raises, swallows I/O errors. */
static void
dump_input_devices(void)
{
    dump_file_to_console("/proc/bus/input/devices", "input", 8192);
}

/* dump /tmp/Xorg.0.log to /dev/console, prefixed "xorg:". called once
 * after xorg_bring_up so the serial trace tells us what input devices
 * Xorg actually opened, what driver matches it found, and what it
 * complained about. log is bounded at 64 KiB which is far more than
 * any normal Xorg startup ever produces. invariant: never raises.
 *
 * (W3, audit 2026-05-10) the prior version called sleep(2) here to
 * give Xorg time to flush. 2s of dead boot time hurts perceived
 * latency far more than a partially-flushed log hurts diagnostics:
 * if the log is short, that itself is a useful signal that Xorg has
 * not yet hit the InitInput phase. so we drop the sleep entirely. if
 * future debugging needs the full log, dump_file_to_console can be
 * re-invoked from elisp once emacs is up. */
static void
dump_xorg_log(void)
{
    dump_file_to_console("/tmp/Xorg.0.log", "xorg", 65536);
}

int
main(int argc, char **argv)
{
    /* pick the kernel backend before any port-> call.  `port` is now
     * NULL at file scope (B2, skeptic review 2026-05-12); the
     * port_require_or_abort guard right after this assignment turns a
     * forgotten registration into a loud crash at boot instead of a
     * silent Linux-default fallback that would mask a missing Hurd
     * backend registration on the side branch. */
    port = &port_linux_impl;
    port_require_or_abort();

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
    console("GNU/Emacs Operating System (GEOS) v0.3 booting...");
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

    /* /var hosts the elisp state directory (see core/state.el). do this
     * before link_current_system so a future state.el call early in the
     * boot has somewhere to land its first write. tmpfs fallback means
     * a missing geos-var partition is degraded mode, not a boot failure. */
    mount_var();

    /* /run/current-system is the canonical guix indirection that every
     * profile-aware path keys off of (PATH=/run/current-system/profile/
     * bin, fontconfig, locale archives, ...). guix's activation service
     * normally creates it, but our boot gexp execl's emacs-init before
     * activation runs, so we stand it up here from /proc/cmdline's
     * gnu.system= value. without this, executable-find inside emacs
     * returns nil for everything and the s-& launcher cannot find xterm. */
    link_current_system();

    /* loopback first so emacs's network code does not stall on probe */
    if (port->bring_up_lo() < 0) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "pid1: bring up lo failed: %s", strerror(errno));
        console(buf);
    }

    /* hostname before emacs starts: by the time the userland reads
     * /proc/sys/kernel/hostname (or runs uname -a), the value must
     * already be the operating-system's host-name, not the kernel's
     * compile-time "(none)". elisp/core/hostname.el ALSO calls
     * pid1-set-hostname for hot-update from M-x, but this is the
     * unconditional baseline that runs even if the module fails to
     * load. */
    set_hostname_at_boot();

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
        /* (W4 v2, skeptic round-4 2026-05-10) the prior fallback to
         * SIG_IGN looked clever (kernel auto-reaps zombies) but
         * silently broke the supervisor: under SIG_IGN, waitpid(-1)
         * returns ECHILD immediately even when our actual emacs and
         * Xorg children exit, so we never see r==emacs or r==xorg_pid
         * and the death-detection paths become unreachable.  the
         * supervisor degrades from event-driven to polling-with-busy-
         * sleep and the Xorg-died teardown branch never fires.
         *
         * better to abort hard.  PID 1 cannot do its job without
         * SIGCHLD and the operator deserves to know loudly, not
         * watch a half-broken supervisor for hours.  _exit makes
         * the kernel panic, which boots straight to a recoverable
         * state on any sensible kernel cmdline (panic=10 etc.). */
        char buf[128];
        snprintf(buf, sizeof buf,
                 "pid1: sigaction(SIGCHLD) failed: %s. cannot supervise. aborting.",
                 strerror(errno));
        console(buf);
        _exit(127);
    }

    /* boot mode toggle: /proc/cmdline geos.mode=console forces a
     * pure-text boot (no Xorg, emacs talks to /dev/console). default
     * (no token, or geos.mode=ui) keeps the v0.2 behaviour.  v0.4
     * item 10 adds geos.mode=recovery: same Xorg suppression as
     * console mode PLUS the userland -l chain is gated by an env
     * variable that early-init.el reads to abort further loading.
     * clearing xorg_path here also disables xorg_bring_up's respawn
     * path so a console- or recovery-mode boot never tries to start
     * an X server.  display_env stays NULL so spawn_emacs's envp
     * does not advertise a DISPLAY the user did not ask for. */
    int boot_mode = read_geos_mode();
    if (boot_mode == GEOS_MODE_CONSOLE) {
        xorg_path = NULL;
        xorg_disabled = 1;
        display_env = NULL;
        geos_mode_env = "GEOS_MODE=console";
    } else if (boot_mode == GEOS_MODE_RECOVERY) {
        xorg_path = NULL;
        xorg_disabled = 1;
        display_env = NULL;
        geos_mode_env = "GEOS_MODE=recovery";
    } else {
        geos_mode_env = "GEOS_MODE=ui";
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
        /* pre-Xorg diagnostic: kernel input device list. */
        dump_input_devices();
        if (xorg_bring_up() < 0) {
            console("pid1: continuing without DISPLAY");
        } else {
            /* post-Xorg diagnostics: re-dump input list (the usb-tablet
             * and psmouse can take a beat to enumerate after the boot
             * cmdline is processed) and dump Xorg.0.log so we see what
             * driver-match + screen-init reported. */
            dump_input_devices();
            dump_xorg_log();
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
        /* (B6) crashloop gate. once tripped we stay in the holding
         * pattern: just reap whatever shows up so zombies do not pile
         * up, but never fork emacs again. the operator gets a stable
         * /dev/console to read the failure off of, instead of a
         * one-line-per-second tornado of "emacs exited, respawning". */
        if (emacs_holding) {
            int st;
            pid_t z = waitpid(-1, &st, 0);
            if (z < 0 && errno == EINTR) continue;
            if (z < 0) {
                /* no children left at all (ECHILD) - sleep a bit so
                 * we are not spinning on the syscall.  we keep
                 * looping because Xorg may yet reparent something. */
                sleep_at_least(5);
            }
            continue;
        }
        if (!emacs_note_respawn()) {
            /* tripped this iteration; loop back to enter holding mode. */
            continue;
        }
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
                /* (W5) ECHILD here means waitpid found no children at
                 * all, but we just spawned emacs. either emacs was
                 * reaped between fork and our first waitpid (signal
                 * handler raced us), or sigaction(SIGCHLD) failed at
                 * boot and the kernel is auto-reaping. probe with
                 * kill(emacs,0): if it returns 0 the process is alive
                 * and we should keep waiting; ESRCH means dead, time
                 * to respawn. */
                if (kill(emacs, 0) == 0) {
                    /* alive but unwaitable; brief sleep and retry. */
                    sleep_at_least(1);
                    continue;
                }
                console("pid1: waitpid() failed and emacs is gone, respawning");
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
 * touching env again except for cleanup.
 *
 * (M3, audit round-5 2026-05-10) returns nil so callers can do
 * `return pid1_signal_errno(env, ...);' without subsequently calling
 * env->intern(env, "nil"), which is undefined after a non-local exit
 * is set.  the nil is captured BEFORE non_local_exit_signal so the
 * value is well-defined.  callers that don't return nil (e.g. those
 * that signal then continue cleanup) can ignore the return. */
static emacs_value
pid1_signal_errno(emacs_env *env, const char *prefix, int err)
{
    char buf[256];
    /* strerror is not async-signal-safe but we are not in a signal
     * handler here; we are in an elisp callback. fine. */
    snprintf(buf, sizeof buf, "%s: %s", prefix, strerror(err));
    emacs_value Qnil = env->intern(env, "nil");
    emacs_value sym = env->intern(env, "pid1-error");
    emacs_value msg = env->make_string(env, buf, (ptrdiff_t)strlen(buf));
    emacs_value list_args[1] = { msg };
    emacs_value data = env->funcall(env, env->intern(env, "list"),
                                    1, list_args);
    env->non_local_exit_signal(env, sym, data);
    return Qnil;
}

/* (B3, audit 2026-05-10) extract a lisp string into the caller's
 * BUF of capacity BUFSIZE.  no malloc: the previous version called
 * malloc on every Fpid1_* invocation, which a buggy elisp loop
 * could fragment Emacs's heap with.  the new shape pushes the
 * allocation onto the caller's stack, so the worst case is bounded
 * by the function's own stack frame.
 *
 * returns 0 on success (BUF is NUL-terminated), -1 on failure with
 * a non_local_exit already pending.  the caller MUST check before
 * touching env again, per the emacs module ABI. */
#define EXTRACT_BUF_MAX 4096
static int
extract_cstring_into(emacs_env *env, emacs_value v,
                     char *buf, size_t bufsize)
{
    ptrdiff_t need = 0;
    if (!env->copy_string_contents(env, v, NULL, &need)) {
        /* copy_string_contents already signalled wrong-type; nothing
         * for us to add.  caller checks non_local_exit. */
        return -1;
    }
    /* (M2, audit round-5 2026-05-10) per the module ABI it is undefined
     * to call any env-> function after a non-local-exit was raised but
     * before the caller checks it.  the size probe above can leave a
     * pending exit on, e.g., a finalized buffer; touching env again
     * here would crash emacs.  check first, drop on pending exit. */
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return -1;
    if (need < 1 || (size_t)need > bufsize) {
        pid1_signal_errno(env, "pid1: argument too long", ENAMETOOLONG);
        return -1;
    }
    if (!env->copy_string_contents(env, v, buf, &need)) {
        return -1;
    }
    return 0;
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

    /* (W12, audit 2026-05-10) cap iterations.  the original loop
     * could spin forever on a pathological signal storm: every EINTR
     * `continue's without consuming progress, and a runaway elisp
     * caller invoking pid1-reap from a signal handler could keep
     * resetting the syscall before it returned 0.  4096 is well above
     * any realistic burst (the kernel's RLIMIT_NPROC hard ceiling is
     * lower in practice) and keeps the function response bounded. */
    int iter_cap = 4096;
    for (; iter_cap > 0; iter_cap--) {
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
    if (iter_cap == 0) {
        /* tripped the cap; not strictly an error (we may have reaped
         * 4096 zombies legitimately) but unusual enough to surface.
         * cannot use console() here because it is gated to the boot
         * build; raise a one-line lisp message via emacs's own message
         * buffer so the operator sees it without crashing the call.
         * use strlen instead of a hardcoded length so a future edit
         * to the string does not ship a truncation bug. */
        const char *txt =
            "pid1: pid1-reap hit iteration cap, will resume next call";
        emacs_value msg = env->make_string(env, txt, (ptrdiff_t)strlen(txt));
        emacs_value margs[1] = { msg };
        (void)env->funcall(env, env->intern(env, "message"), 1, margs);
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
    /* (M3, audit round-5 2026-05-10) cache Qnil up front so we never
     * call env->intern after a non-local exit has been raised (ABI:
     * undefined), and so the per-error path is one return statement. */
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 5)
        return pid1_signal_errno(env, "pid1: pid1-mount needs 5 args", EINVAL);
    /* (M8, audit round-5 2026-05-10) frame still ~16 KiB.  the module
     * runs on the emacs main-thread stack (8 MiB by default on glibc),
     * not a signal stack, so this is safe.  noted explicitly because
     * the prior comment claimed PID 1's smaller stack budget, which
     * applies only to the standalone-binary build path, not the
     * module path. */
    char src[EXTRACT_BUF_MAX];
    char tgt[EXTRACT_BUF_MAX];
    char type[EXTRACT_BUF_MAX];
    char opts[EXTRACT_BUF_MAX];
    intmax_t flags_im = 0;
    int have_opts = 0;
    if (extract_cstring_into(env, args[0], src, sizeof src) < 0)
        return Qnil;
    if (extract_cstring_into(env, args[1], tgt, sizeof tgt) < 0)
        return Qnil;
    if (extract_cstring_into(env, args[2], type, sizeof type) < 0)
        return Qnil;
    flags_im = env->extract_integer(env, args[3]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    have_opts = env->is_not_nil(env, args[4]);
    if (have_opts) {
        if (extract_cstring_into(env, args[4], opts, sizeof opts) < 0)
            return Qnil;
    }

    int rc = port->mount(src, tgt, type, (unsigned long)flags_im,
                         have_opts ? opts : NULL);
    int err = errno;

    if (rc < 0)
        return pid1_signal_errno(env, "pid1: mount", err);
    return env->intern(env, "t");
}

/* (pid1-set-hostname NAME) -> t or signal pid1-error.
 * NAME is a string; passed through to sethostname(2). */
static emacs_value
Fpid1_set_hostname(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                   void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 1)
        return pid1_signal_errno(env, "pid1: pid1-set-hostname needs 1 arg",
                                 EINVAL);
    /* HOST_NAME_MAX is 64 on linux including NUL; 256 here is plenty
     * and leaves room for the pid1-set-hostname caller to send a
     * larger string and have us reject it cleanly via errno=EINVAL
     * from sethostname instead of silently truncating. */
    char name[256];
    if (extract_cstring_into(env, args[0], name, sizeof name) < 0)
        return Qnil;
    int rc = port->set_hostname(name, strlen(name));
    int err = errno;
    if (rc < 0)
        return pid1_signal_errno(env, "pid1: sethostname", err);
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
    if (port->bring_up_lo() < 0)
        return pid1_signal_errno(env, "pid1: bring up lo", errno);
    return env->intern(env, "t");
}

/* (pid1-set-address IFNAME ADDRESS PREFIX) -> t or signal pid1-error.
 * IFNAME is a string ("eth0").  ADDRESS is dotted-quad IPv4 ("10.0.0.5").
 * PREFIX is the CIDR prefix length 0..32.  resulting netmask is
 * derived from PREFIX so the elisp side does not have to know how to
 * format a netmask.  on success, the interface has the address +
 * netmask + IFF_UP|IFF_RUNNING set. */
static emacs_value
Fpid1_set_address(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                  void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 3)
        return pid1_signal_errno(env, "pid1: pid1-set-address needs 3 args",
                                 EINVAL);
    char ifname[IFNAMSIZ];
    if (extract_cstring_into(env, args[0], ifname, sizeof ifname) < 0)
        return Qnil;
    /* INET_ADDRSTRLEN is 16 incl. NUL; allow a small slop for callers
     * who pass trailing whitespace. inet_pton will reject anyway. */
    char addr[INET_ADDRSTRLEN + 8];
    if (extract_cstring_into(env, args[1], addr, sizeof addr) < 0)
        return Qnil;
    intmax_t prefix = env->extract_integer(env, args[2]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    struct in_addr ia;
    if (inet_pton(AF_INET, addr, &ia) != 1)
        return pid1_signal_errno(env, "pid1: pid1-set-address: bad address",
                                 EINVAL);
    if (port->set_address(ifname, ia.s_addr, (int)prefix) < 0)
        return pid1_signal_errno(env, "pid1: set-address", errno);
    return env->intern(env, "t");
}

/* (pid1-set-route-default GATEWAY IFNAME) -> t or signal pid1-error.
 * installs a default route via GATEWAY (dotted-quad IPv4) through
 * IFNAME. EEXIST means a default route is already present; the elisp
 * side typically wants to delete and re-add via a separate call (not
 * yet exposed); for now we surface the error. */
static emacs_value
Fpid1_set_route_default(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                        void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 2)
        return pid1_signal_errno(env,
                                 "pid1: pid1-set-route-default needs 2 args",
                                 EINVAL);
    char gws[INET_ADDRSTRLEN + 8];
    if (extract_cstring_into(env, args[0], gws, sizeof gws) < 0)
        return Qnil;
    char ifname[IFNAMSIZ];
    if (extract_cstring_into(env, args[1], ifname, sizeof ifname) < 0)
        return Qnil;
    struct in_addr ia;
    if (inet_pton(AF_INET, gws, &ia) != 1)
        return pid1_signal_errno(env,
                                 "pid1: pid1-set-route-default: bad gateway",
                                 EINVAL);
    if (port->set_route_default(ia.s_addr, ifname) < 0)
        return pid1_signal_errno(env, "pid1: set-route-default", errno);
    return env->intern(env, "t");
}

/* (pid1-crypt PLAINTEXT SALT) -> hash string, or signal pid1-error.
 * wraps crypt_r(3) from libxcrypt.  SALT is the full salt string
 * (e.g. "$y$j9T$AbCdEfGhIjKlMnOp") that selects the algorithm and
 * supplies the per-user salt bytes; the elisp side generates it.
 * we use crypt_r to avoid the static-buffer hazard of crypt(3); on
 * single-threaded emacs it doesn't matter for re-entrancy but the
 * struct-on-stack pattern keeps us tidy.  errno=EINVAL on a
 * malformed salt; crypt_r itself returns NULL and sets errno.
 * the returned hash is owned by the crypt_data struct on our stack;
 * we copy into a lisp string before the struct goes out of scope. */
static emacs_value
Fpid1_crypt(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 2)
        return pid1_signal_errno(env, "pid1: pid1-crypt needs 2 args",
                                 EINVAL);
    /* crypt_data is large (~32 KiB).  module runs on emacs's main
     * thread which has the full 8 MiB stack, so this is fine; doing
     * it on stack avoids a malloc per call. */
    static struct crypt_data cd;  /* zero-init via BSS, reused */
    char plain[256];
    char salt[128];
    if (extract_cstring_into(env, args[0], plain, sizeof plain) < 0)
        return Qnil;
    if (extract_cstring_into(env, args[1], salt, sizeof salt) < 0)
        return Qnil;
    /* zero the struct on entry: crypt_r reuses internal state across
     * calls if not zeroed, which would leak the previous password's
     * salt-prefix into the next call's output on some libxcrypt
     * builds. cheap insurance. */
    memset(&cd, 0, sizeof cd);
    char *out = crypt_r(plain, salt, &cd);
    if (!out || out[0] == '*')
        return pid1_signal_errno(env, "pid1: crypt", errno ? errno : EINVAL);
    return env->make_string(env, out, (ptrdiff_t)strlen(out));
}

/* (pid1-fsync-dir PATH) -> t or signal pid1-error.
 * opens the directory at PATH, fsync()s it, closes. used by elisp
 * state writers (see core/state.el) after rename(.tmp, final) to make
 * the rename durable on ext4. on tmpfs the fsync is a near-no-op but
 * still cheap, so we always call it; the elisp side does not need to
 * know which fs is under /var. */
static emacs_value
Fpid1_fsync_dir(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 1)
        return pid1_signal_errno(env, "pid1: pid1-fsync-dir needs 1 arg",
                                 EINVAL);
    char path[EXTRACT_BUF_MAX];
    if (extract_cstring_into(env, args[0], path, sizeof path) < 0)
        return Qnil;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return pid1_signal_errno(env, "pid1: open(O_DIRECTORY)", errno);
    int rc = fsync(fd);
    int err = errno;
    int c = close(fd);
    if (rc < 0)
        return pid1_signal_errno(env, "pid1: fsync", err);
    if (c < 0)
        return pid1_signal_errno(env, "pid1: close after fsync", errno);
    return env->intern(env, "t");
}

/* (pid1-chown PATH UID GID) -> t or signal pid1-error.
 * thin wrapper over chown(2).  v0.6 item 2 caller: session.el pre-
 * creates /var/emacs/users/NAME/ as root (mode 0700), then chowns
 * it to the spawned user so the per-user emacs can write its
 * init.el there.  the floor (uid >= 1000, gid >= 1000) mirrors
 * pid1-spawn-as-uid: this primitive must never be used to drop
 * a file to root or a system uid, because the elisp side has no
 * other call site for chown and we want defense in depth against
 * a callsite bug.  if a future caller needs to chown to a system
 * uid, add a separate primitive with explicit policy rather than
 * widening this one. */
static emacs_value
Fpid1_chown(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
            void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 3)
        return pid1_signal_errno(env, "pid1: pid1-chown needs 3 args",
                                 EINVAL);
    char path[EXTRACT_BUF_MAX];
    if (extract_cstring_into(env, args[0], path, sizeof path) < 0)
        return Qnil;
    intmax_t uid_im = env->extract_integer(env, args[1]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    intmax_t gid_im = env->extract_integer(env, args[2]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (uid_im < 1000)
        return pid1_signal_errno(env, "pid1: chown: uid below floor",
                                 EINVAL);
    if (gid_im < 1000)
        return pid1_signal_errno(env, "pid1: chown: gid below floor",
                                 EINVAL);
    if (uid_im > 0x7fffffff || gid_im > 0x7fffffff)
        return pid1_signal_errno(env, "pid1: chown: uid/gid out of range",
                                 EINVAL);
    if (chown(path, (uid_t)uid_im, (gid_t)gid_im) < 0)
        return pid1_signal_errno(env, "pid1: chown", errno);
    return env->intern(env, "t");
}

/* ---- v0.6 item 3: supervisor RPC channel ------------------------ */
/*
 * the user-emacs has no `pid1-*' access by design; privileged operations
 * (reboot, package install, passwd-set, etc.) are reachable only via
 * this socket.  authentication is peer-credential lookup, routed
 * through port->get_peer_cred so Hurd can swap in its own auth-port
 * handshake later: on Linux today the backend reads SO_PEERCRED, which
 * the kernel snapshots at the peer's connect() instant; authorisation
 * lives in elisp (rpc-server.el's verb dispatcher).
 *
 * wire format:
 *   request:  4-byte big-endian length, then LENGTH bytes of sexp text.
 *   reply:    same shape, supervisor -> client.
 *   cap:      RPC_PAYLOAD_MAX bytes (64 KiB).
 *
 * connection lifecycle:
 *   client connect(), send(len+payload), shutdown(SHUT_WR), read reply.
 *   server accept4(non-blocking), set blocking with SO_RCVTIMEO/
 *   SO_SNDTIMEO so a stalled client cannot wedge the supervisor for
 *   more than RPC_TIMEOUT_SEC seconds.
 *
 * single-listener: a supervisor has at most one rpc listen socket; the
 * static fd below holds it.  the listen fd is created by
 * pid1-rpc-listen and never closed (the supervisor lives until reboot).
 */

#define RPC_PAYLOAD_MAX (64 * 1024)
#define RPC_TIMEOUT_SEC 2

static int rpc_listen_fd = -1;

/* read exactly N bytes from FD into BUF, with the timeout already
 * configured via SO_RCVTIMEO.  returns 0 on success, -1 on any short
 * read or error; errno is set per read(2).  EOF mid-buffer reports
 * EPIPE. */
static int
rpc_read_full(int fd, void *buf, size_t n)
{
    uint8_t *p = buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) {
            errno = EPIPE;
            return -1;
        }
        got += (size_t)r;
    }
    return 0;
}

/* write exactly N bytes from BUF to FD.  same shape as rpc_read_full. */
static int
rpc_write_full(int fd, const void *buf, size_t n)
{
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = write(fd, p + sent, n - sent);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        sent += (size_t)w;
    }
    return 0;
}

/* (pid1-rpc-listen PATH MODE) -> t or signal pid1-error.
 * creates an AF_UNIX SOCK_STREAM socket bound to PATH, listens with
 * backlog 8.  if PATH already exists it is unlink()ed first: the
 * supervisor is the canonical owner of the socket and a leftover from
 * a previous boot or a stale socket file would prevent bind.  this is
 * safe under the v0.6 deployment because /run is tmpfs (wiped each
 * boot) and the only writer to /run/geos/ is the supervisor itself.
 *
 * MODE is the file mode applied via chmod after bind.  bind respects
 * umask, which can clear group/other bits and break client connect
 * for non-root users; chmod-after-bind makes the mode explicit.  pass
 * #o666 if non-root clients need to connect (SO_PEERCRED is the real
 * authentication gate, the DAC mode is mostly cosmetic).
 *
 * the listen fd is stored in the module-static `rpc_listen_fd' and
 * lives until supervisor exit.  re-binding while already listening
 * returns EBUSY rather than silently replacing the fd, because a
 * second listen would race with whatever connections are still in
 * the kernel's accept queue. */
static emacs_value
Fpid1_rpc_listen(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                 void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 2)
        return pid1_signal_errno(env, "pid1: pid1-rpc-listen needs 2 args",
                                 EINVAL);
    char path[EXTRACT_BUF_MAX];
    if (extract_cstring_into(env, args[0], path, sizeof path) < 0)
        return Qnil;
    intmax_t mode_im = env->extract_integer(env, args[1]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (mode_im < 0 || mode_im > 0777)
        return pid1_signal_errno(env, "pid1: rpc-listen: bad mode",
                                 EINVAL);
    if (rpc_listen_fd >= 0)
        return pid1_signal_errno(env, "pid1: rpc-listen: already listening",
                                 EBUSY);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    if (strlen(path) >= sizeof addr.sun_path)
        return pid1_signal_errno(env, "pid1: rpc-listen: path too long",
                                 ENAMETOOLONG);
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, strlen(path));
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return pid1_signal_errno(env, "pid1: rpc-listen: socket", errno);
    if (unlink(path) < 0 && errno != ENOENT) {
        int err = errno;
        close(fd);
        return pid1_signal_errno(env, "pid1: rpc-listen: unlink", err);
    }
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        int err = errno;
        close(fd);
        return pid1_signal_errno(env, "pid1: rpc-listen: bind", err);
    }
    if (chmod(path, (mode_t)mode_im) < 0) {
        int err = errno;
        close(fd);
        unlink(path);
        return pid1_signal_errno(env, "pid1: rpc-listen: chmod", err);
    }
    if (listen(fd, 8) < 0) {
        int err = errno;
        close(fd);
        unlink(path);
        return pid1_signal_errno(env, "pid1: rpc-listen: listen", err);
    }
    rpc_listen_fd = fd;
    return env->intern(env, "t");
}

/* (pid1-rpc-poll) -> nil or (:fd FD :uid UID :gid GID :payload STRING).
 * non-blocking accept on the listen socket; if no pending connection,
 * returns nil and the caller (the 200ms timer in rpc-server.el) tries
 * again next tick.  on a successful accept, switches the new fd to
 * blocking with SO_RCVTIMEO/SO_SNDTIMEO equal to RPC_TIMEOUT_SEC so a
 * slow client cannot wedge the supervisor; reads the 4-byte big-
 * endian length prefix; reads LENGTH payload bytes; reads peer
 * credentials via SO_PEERCRED.
 *
 * the returned :fd is owned by the caller: it MUST call pid1-rpc-reply
 * (or, on error, pid1-rpc-close-fd, which v0.6 omits in favor of always
 * replying with `(:status error ...)`) to close it.  leaked fds
 * accumulate against the supervisor's RLIMIT_NOFILE; a hardening pass
 * in v0.7 grows a generation counter or a finalizer.
 *
 * pid is deliberately not returned: a pid would let elisp dispatch on
 * "which process" which is racy under pid reuse.  uid/gid are stable
 * for the lifetime of the connection. */
static emacs_value
Fpid1_rpc_poll(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)nargs; (void)args; (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (rpc_listen_fd < 0)
        return pid1_signal_errno(env, "pid1: rpc-poll: not listening", EBADF);
    int conn = accept4(rpc_listen_fd, NULL, NULL, SOCK_CLOEXEC);
    if (conn < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return Qnil;
        return pid1_signal_errno(env, "pid1: rpc-poll: accept", errno);
    }
    /* blocking + timeout: bound the wedge time a slow client can cause. */
    struct timeval tv;
    tv.tv_sec = RPC_TIMEOUT_SEC;
    tv.tv_usec = 0;
    if (setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0 ||
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv) < 0) {
        int err = errno;
        close(conn);
        return pid1_signal_errno(env, "pid1: rpc-poll: timeout setup", err);
    }
    /* peer credentials, through the port layer.  on Linux this is
     * getsockopt(SO_PEERCRED) returning a ucred snapshot taken at the
     * peer's connect() instant, so a setuid race between connect and
     * accept cannot fool us.  on Hurd the backend returns -1 with
     * errno=ENOSYS until a real auth-port handshake lands; we treat
     * that one errno as "refuse this client and keep the poller alive"
     * (close the fd and return nil, same shape as "no pending
     * connection"), because pid1-rpc-poll runs on a 200ms timer and
     * surfacing ENOSYS as pid1-error would panic the tick forever.
     * any other errno (a real socket failure on a backend that
     * normally implements the call) still routes through pid1-error
     * because that is a genuine bug worth surfacing.
     *
     * (uint32_t)-1 sentinel rather than 0: the header says UID_OUT/
     * GID_OUT are unspecified on failure, and if a future refactor
     * ever propagates the failure values, leaking uid 0 (root) by
     * default would be the worst possible footgun.  -1 is "nobody"
     * on every kernel we target. */
    uint32_t peer_uid = (uint32_t)-1, peer_gid = (uint32_t)-1;
    if (port->get_peer_cred(conn, &peer_uid, &peer_gid) < 0) {
        int err = errno;
        if (err == ENOSYS) {
            /* log the refusal once per boot: the 200ms tick would
             * otherwise spew the same line at 5 Hz for every probe
             * during the lifetime of an unsupported kernel.  static
             * bool is safe because emacs is single-threaded. */
            static int warned_enosys = 0;
            if (!warned_enosys) {
                warned_enosys = 1;
                static const char m[] =
                    "pid1: rpc-poll: peer cred unsupported on this kernel, "
                    "refusing clients\n";
                ssize_t r = write(2, m, sizeof m - 1); (void)r;
            }
            close(conn);
            return Qnil;
        }
        close(conn);
        return pid1_signal_errno(env, "pid1: rpc-poll: get_peer_cred", err);
    }
    uint8_t lbuf[4];
    if (rpc_read_full(conn, lbuf, 4) < 0) {
        int err = errno;
        close(conn);
        return pid1_signal_errno(env, "pid1: rpc-poll: read length", err);
    }
    uint32_t plen32 =
        ((uint32_t)lbuf[0] << 24) | ((uint32_t)lbuf[1] << 16) |
        ((uint32_t)lbuf[2] <<  8) | ((uint32_t)lbuf[3]);
    if (plen32 == 0 || plen32 > RPC_PAYLOAD_MAX) {
        close(conn);
        return pid1_signal_errno(env, "pid1: rpc-poll: bad length", EMSGSIZE);
    }
    /* read on stack up to 64 KiB.  larger main loop frame than the
     * other Fpid1_* but pid1 has 8 MiB default stack and is not
     * recursive in this path. */
    char payload[RPC_PAYLOAD_MAX];
    if (rpc_read_full(conn, payload, plen32) < 0) {
        int err = errno;
        close(conn);
        return pid1_signal_errno(env, "pid1: rpc-poll: read payload", err);
    }
    /* build the plist (:fd FD :uid U :gid G :payload "BYTES"). */
    emacs_value Qcons = env->intern(env, "cons");
    emacs_value kw_fd      = env->intern(env, ":fd");
    emacs_value kw_uid     = env->intern(env, ":uid");
    emacs_value kw_gid     = env->intern(env, ":gid");
    emacs_value kw_payload = env->intern(env, ":payload");
    emacs_value v_fd  = env->make_integer(env, conn);
    emacs_value v_uid = env->make_integer(env, (intmax_t)peer_uid);
    emacs_value v_gid = env->make_integer(env, (intmax_t)peer_gid);
    emacs_value v_pl  = env->make_string(env, payload, (ptrdiff_t)plen32);
    /* (list :fd FD :uid U :gid G :payload P) via cons chain. */
    emacs_value list_args[8] = {
        kw_fd, v_fd, kw_uid, v_uid, kw_gid, v_gid, kw_payload, v_pl
    };
    emacs_value plist = env->funcall(env, env->intern(env, "list"),
                                     8, list_args);
    (void)Qcons;
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
        close(conn);
        return Qnil;
    }
    return plist;
}

/* (pid1-rpc-reply FD PAYLOAD) -> t or signal pid1-error.
 * writes the 4-byte length prefix + PAYLOAD bytes back to FD, then
 * closes FD.  PAYLOAD is the reply sexp serialised by elisp (the C
 * side does not parse it).  FD must be a value previously returned
 * by pid1-rpc-poll's :fd slot; using anything else is undefined and
 * may close an unrelated fd (the supervisor's own).  the elisp
 * caller is expected to keep the integer opaque. */
static emacs_value
Fpid1_rpc_reply(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 2)
        return pid1_signal_errno(env, "pid1: pid1-rpc-reply needs 2 args",
                                 EINVAL);
    intmax_t fd_im = env->extract_integer(env, args[0]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (fd_im < 0 || fd_im > 0x7fffffff)
        return pid1_signal_errno(env, "pid1: rpc-reply: bad fd", EBADF);
    int fd = (int)fd_im;
    ptrdiff_t need = 0;
    if (!env->copy_string_contents(env, args[1], NULL, &need))
        return Qnil;
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (need < 1) {
        close(fd);
        return pid1_signal_errno(env, "pid1: rpc-reply: empty payload",
                                 EINVAL);
    }
    /* copy_string_contents returns N+1 (includes trailing NUL).  the
     * wire payload is the bytes WITHOUT the NUL; subtract one. */
    size_t plen = (size_t)(need - 1);
    if (plen > RPC_PAYLOAD_MAX) {
        close(fd);
        return pid1_signal_errno(env, "pid1: rpc-reply: payload too big",
                                 EMSGSIZE);
    }
    char payload[RPC_PAYLOAD_MAX + 1];
    if (!env->copy_string_contents(env, args[1], payload, &need)) {
        close(fd);
        return Qnil;
    }
    uint8_t lbuf[4];
    lbuf[0] = (uint8_t)(plen >> 24);
    lbuf[1] = (uint8_t)(plen >> 16);
    lbuf[2] = (uint8_t)(plen >> 8);
    lbuf[3] = (uint8_t)(plen);
    if (rpc_write_full(fd, lbuf, 4) < 0) {
        int err = errno;
        close(fd);
        return pid1_signal_errno(env, "pid1: rpc-reply: write length", err);
    }
    if (rpc_write_full(fd, payload, plen) < 0) {
        int err = errno;
        close(fd);
        return pid1_signal_errno(env, "pid1: rpc-reply: write payload", err);
    }
    close(fd);
    return env->intern(env, "t");
}

/* the reboot and suspend bodies used to live here as raw_reboot /
 * raw_suspend.  they now live in port_linux.c behind port->reboot
 * and port->suspend.  the elisp-facing wrappers below are unchanged
 * except for the call through the port struct. */

static emacs_value
Fpid1_suspend(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
              void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 1)
        return pid1_signal_errno(env, "pid1: pid1-suspend needs 1 arg",
                                 EINVAL);
    char state[16];
    if (extract_cstring_into(env, args[0], state, sizeof state) < 0)
        return Qnil;
    /* whitelist the four kernel-supported tokens to keep us from
     * writing arbitrary bytes into a sysfs node.  the kernel itself
     * rejects unknown tokens with EINVAL, but the whitelist gives us
     * a cleaner *panic* message and protects against typos that
     * could in theory match a future kernel knob added to
     * /sys/power/state with a non-suspend semantic. */
    int ok = (strcmp(state, "mem") == 0 ||
              strcmp(state, "freeze") == 0 ||
              strcmp(state, "standby") == 0 ||
              strcmp(state, "disk") == 0);
    if (!ok)
        return pid1_signal_errno(env, "pid1: suspend: unknown state",
                                 EINVAL);
    if (port->suspend(state) < 0)
        return pid1_signal_errno(env, "pid1: suspend", errno);
    return env->intern(env, "t");
}

/* (pid1-poweroff) -> never returns on success, signals pid1-error
 * on EPERM/ENOSYS. ACPI in QEMU translates RB_POWER_OFF into a
 * machine-shutdown event and qemu exits. on bare metal the firmware
 * actually cuts power. either way, the VM/host stops. */
static emacs_value
Fpid1_poweroff(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
               void *data)
{
    (void)nargs; (void)args; (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (port->reboot(RB_POWER_OFF) < 0)
        return pid1_signal_errno(env, "pid1: poweroff", errno);
    return Qnil;
}

/* (pid1-reboot) -> never returns on success. RB_AUTOBOOT triggers
 * the kernel's restart path; under qemu that drops the guest and
 * the launcher loop terminates. for an in-place restart of just
 * emacs use a different command, this is the global one. */
static emacs_value
Fpid1_reboot(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
             void *data)
{
    (void)nargs; (void)args; (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (port->reboot(RB_AUTOBOOT) < 0)
        return pid1_signal_errno(env, "pid1: reboot", errno);
    return Qnil;
}

/* signal pid1-error with an arbitrary literal message (no strerror
 * suffix). used by parent-side validation paths that do not have an
 * errno to report, like "uid below floor".  invariant: sets a non-local
 * exit on env, returns nil, same contract as pid1_signal_errno. */
static emacs_value
pid1_signal_msg(emacs_env *env, const char *msg)
{
    emacs_value Qnil = env->intern(env, "nil");
    emacs_value sym = env->intern(env, "pid1-error");
    emacs_value s = env->make_string(env, msg, (ptrdiff_t)strlen(msg));
    emacs_value largs[1] = { s };
    emacs_value data = env->funcall(env, env->intern(env, "list"), 1, largs);
    env->non_local_exit_signal(env, sym, data);
    return Qnil;
}

/* (M, v0.5 spawn binding) pre-built console prefixes for the child-
 * side failure path.  the child cannot malloc, cannot call printf,
 * cannot signal pid1-error; it can only call syscalls and write
 * pre-built bytes.  these strings let the child report which stage
 * of the post-fork sequence failed without formatting at runtime.
 * the trailing ": errno=" is appended in the child by an itoa loop
 * over the integer errno value, followed by "\n". */
static const char child_pfx_setgid[]    = "pid1: spawn-as-uid: setgid: errno=";
static const char child_pfx_setgroups[] = "pid1: spawn-as-uid: setgroups: errno=";
static const char child_pfx_setuid[]    = "pid1: spawn-as-uid: setuid: errno=";
static const char child_pfx_chdir[]     = "pid1: spawn-as-uid: chdir: errno=";
static const char child_pfx_execve[]    = "pid1: spawn-as-uid: execve: errno=";

/* write an errno-tagged line to a pre-opened fd from the child path.
 * invariant: no malloc, no stdio; only write().  err can be any int.
 * if fd < 0 we silently no-op.  used for any logging that happens
 * AFTER setresuid in the child, because at that point we cannot
 * re-open /dev/console (typically mode 600 root:root, EACCES). */
static void
child_log_fd(int fd, const char *prefix, int err)
{
    if (fd < 0) return;
    /* itoa into a tiny local buffer.  errno fits in 32 bits worst
     * case, ten digits plus sign plus NUL is 12; we have 16 to spare. */
    char num[16];
    int ni = (int)sizeof num;
    num[--ni] = '\0';
    int neg = 0;
    unsigned int v;
    if (err < 0) { neg = 1; v = (unsigned int)(-(long)err); }
    else         { v = (unsigned int)err; }
    if (v == 0) {
        num[--ni] = '0';
    } else {
        while (v > 0 && ni > 0) { num[--ni] = (char)('0' + (v % 10u)); v /= 10u; }
    }
    if (neg && ni > 0) num[--ni] = '-';
    ssize_t r;
    r = write(fd, prefix, strlen(prefix));     (void)r;
    r = write(fd, num + ni, strlen(num + ni)); (void)r;
    r = write(fd, "\n", 1);                    (void)r;
}

/* write an errno-tagged line to /dev/console from the child path.
 * invariant: no malloc, no stdio; only open/write/close.  if the open
 * fails we silently give up; the supervisor will still see exit-status
 * 127.  ONLY safe for use BEFORE setresuid: an unprivileged child
 * cannot open /dev/console (mode 600 root:root) and the failure log
 * would silently vanish.  for post-setresuid logging use child_log_fd
 * against a fd opened earlier while still root. */
static void
child_log(const char *prefix, int err)
{
    int fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return;
    child_log_fd(fd, prefix, err);
    int c = close(fd); (void)c;
}

/* parse /etc/passwd for ROW where pw_name == name.  on match, copies
 * the home directory into HOMEBUF (size HOMESIZE) and returns 0.
 * returns -1 with errno set on read/format errors, +1 if NAME is not
 * found in the file.  parent-side only; uses malloc-free fixed
 * buffers because /etc/passwd lines are bounded in practice (the
 * kernel's getpwnam_r expects buffers of ~1 KiB and we are not
 * fancier than getpwnam_r).  NAMEMAX columns 0 and 5 are the only
 * ones we read. */
static int
passwd_lookup_home(const char *name, char *homebuf, size_t homesize)
{
    FILE *f = fopen("/etc/passwd", "re");
    if (!f) return -1;
    /* a /etc/passwd line is conventionally well under 1 KiB.  4 KiB
     * is the same cap getent uses on glibc; anything longer is
     * malformed. */
    char line[4096];
    size_t namelen = strlen(name);
    while (fgets(line, (int)sizeof line, f)) {
        /* split on ':' in place.  we want field 0 (name) and field 5
         * (home).  do not write past the buffer; lines without a
         * trailing newline are tolerated. */
        char *fields[7];
        int nf = 0;
        char *p = line;
        fields[nf++] = p;
        while (*p && nf < 7) {
            if (*p == ':') { *p = '\0'; fields[nf++] = p + 1; }
            p++;
        }
        if (nf < 6) continue;
        /* strip trailing newline from whichever was the last field. */
        char *last = fields[nf - 1];
        size_t ll = strlen(last);
        while (ll > 0 && (last[ll-1] == '\n' || last[ll-1] == '\r'))
            last[--ll] = '\0';
        if (strlen(fields[0]) != namelen) continue;
        if (memcmp(fields[0], name, namelen) != 0) continue;
        size_t hl = strlen(fields[5]);
        if (hl + 1 > homesize) { fclose(f); errno = ENAMETOOLONG; return -1; }
        memcpy(homebuf, fields[5], hl + 1);
        fclose(f);
        return 0;
    }
    fclose(f);
    return 1;
}

/* collect supplementary group ids from /etc/group where NAME appears
 * in the comma-separated member list.  on success returns the count
 * written to OUT and *OUTN, where OUT is caller-owned with capacity
 * OUTCAP.  the primary GID is always included as out[0]; the spec is
 * generous about duplicates and the kernel deduplicates internally.
 * returns -1 with errno set on error.  parent-side only. */
static int
group_collect(const char *name, gid_t primary, gid_t *out, size_t outcap,
              size_t *outn)
{
    if (outcap < 1) { errno = EINVAL; return -1; }
    size_t n = 0;
    out[n++] = primary;
    FILE *f = fopen("/etc/group", "re");
    if (!f) return -1;
    char line[8192];
    size_t namelen = strlen(name);
    while (fgets(line, (int)sizeof line, f)) {
        /* /etc/group: groupname:passwd:gid:members
         * members is comma-separated, possibly empty. */
        char *fields[4];
        int nf = 0;
        char *p = line;
        fields[nf++] = p;
        while (*p && nf < 4) {
            if (*p == ':') { *p = '\0'; fields[nf++] = p + 1; }
            p++;
        }
        if (nf < 4) continue;
        char *members = fields[3];
        size_t ml = strlen(members);
        while (ml > 0 && (members[ml-1] == '\n' || members[ml-1] == '\r'))
            members[--ml] = '\0';
        /* walk the comma-separated list looking for an exact-token
         * match against NAME.  do this without strtok to avoid the
         * static-state hazard if some future caller is also using it. */
        char *m = members;
        while (*m) {
            char *q = m;
            while (*q && *q != ',') q++;
            size_t tl = (size_t)(q - m);
            if (tl == namelen && memcmp(m, name, namelen) == 0) {
                long g = strtol(fields[2], NULL, 10);
                if (g < 0) g = 0;
                gid_t gv = (gid_t)g;
                /* dedupe against primary, which already sits at out[0]. */
                int dup = 0;
                for (size_t i = 0; i < n; i++)
                    if (out[i] == gv) { dup = 1; break; }
                if (!dup) {
                    if (n >= outcap) { fclose(f); errno = E2BIG; return -1; }
                    out[n++] = gv;
                }
                break;
            }
            if (*q == ',') m = q + 1; else m = q;
        }
    }
    fclose(f);
    *outn = n;
    return 0;
}

/* (pid1-spawn-as-uid UID GID NAME PROGRAM ARGV ENV) -> child pid int.
 * v0.5 session-spawn ABI (see docs/v05-session-spawn-abi.md).
 * invariant: every privilege-transition syscall happens in the child
 * in the exact order setgid -> setgroups -> setuid, then env-scrub
 * (via execve with a parent-built envp), then chdir, then fd close,
 * then execve.  every allocation happens in the parent before fork;
 * the child path uses only the parent-built buffers, raw syscalls,
 * and _exit.  parent-side errors signal pid1-error; child-side
 * failures write one line to /dev/console and _exit(127).
 * uid floor is 1000.  gid floor is 1000 (mirrors uid; passwd-add-user
 * allocates primary gids from the same range, and a uid=1000 child
 * with gid=0 would otherwise have write access to anything mode 070). */
static emacs_value
Fpid1_spawn_as_uid(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                   void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 6)
        return pid1_signal_errno(env, "pid1: pid1-spawn-as-uid needs 6 args",
                                 EINVAL);

    /* --- parent step 1: arg extraction + validation. --- */
    intmax_t uid_im = env->extract_integer(env, args[0]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    intmax_t gid_im = env->extract_integer(env, args[1]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    /* uid/gid floor for v0.5.  the spec reserves a future module flag
     * pid1-spawn-allow-system for v0.6+; until then refuse anything
     * that could become root by accident.  legitimate users in v0.5
     * have both uid and gid >= 1000 (passwd-add-user allocates from
     * the same range).  the message strings are matched by login.el's
     * error handler, do not rephrase. */
    if (uid_im < 1000)
        return pid1_signal_msg(env, "pid1: spawn-as-uid: uid below floor");
    if (gid_im < 1000)
        return pid1_signal_msg(env, "pid1: spawn-as-uid: gid below floor");
    if (gid_im < 0 || uid_im > 0x7fffffff || gid_im > 0x7fffffff)
        return pid1_signal_errno(env, "pid1: spawn-as-uid: bad uid/gid",
                                 EINVAL);
    uid_t uid = (uid_t)uid_im;
    gid_t gid = (gid_t)gid_im;

    char name[256];
    char program[4096];
    if (extract_cstring_into(env, args[2], name, sizeof name) < 0)
        return Qnil;
    if (extract_cstring_into(env, args[3], program, sizeof program) < 0)
        return Qnil;
    /* empty NAME would otherwise pass the character-reject loop with
     * zero iterations and then fail later with "user not found", which
     * is the wrong error message.  catch it here. */
    if (name[0] == '\0') {
        return pid1_signal_errno(env, "pid1: spawn-as-uid: bad name (empty)",
                                 EINVAL);
    }
    /* reject embedded slashes or NULs in NAME so a clever caller can
     * not slip "../root" past the passwd lookup.  copy_string_contents
     * already rejects raw NUL but leaving the check in for clarity. */
    for (size_t i = 0; name[i]; i++) {
        if (name[i] == '/' || name[i] == ':' || name[i] == '\n' ||
            name[i] == '\r' || name[i] == ' ') {
            return pid1_signal_errno(env, "pid1: spawn-as-uid: bad name",
                                     EINVAL);
        }
    }

    /* --- parent step 2/3: passwd lookup for home. --- */
    char home[4096];
    {
        int rc = passwd_lookup_home(name, home, sizeof home);
        if (rc < 0)
            return pid1_signal_errno(env, "pid1: spawn-as-uid: passwd lookup",
                                     errno);
        if (rc > 0)
            return pid1_signal_msg(env,
                "pid1: spawn-as-uid: passwd lookup: user not found");
    }

    /* --- parent step 2: supplementary groups from /etc/group. ---
     * NGROUPS_MAX on linux is the system cap, but we keep our own
     * smaller bound because setgroups copies into a kernel-side
     * fixed buffer and we want the cap to be deterministic across
     * kernels.  64 is what login(1) historically used. */
    gid_t groups[64];
    size_t ngroups = 0;
    if (group_collect(name, gid, groups, sizeof groups / sizeof groups[0],
                      &ngroups) < 0)
        return pid1_signal_errno(env, "pid1: spawn-as-uid: group lookup",
                                 errno);

    /* --- parent step 4: build envp from ENV.  ENV is a lisp list of
     * "KEY=VALUE" strings.  we malloc the char** + each string in the
     * parent.  comment per project rule: malloc is acceptable here
     * because this binding is a startup-rare path (one call per user
     * login, not a hot path).  every allocation is freed on every
     * exit, including the parent-side error branches; the child does
     * NOT free, since exec/execve releases the address space. --- */
    emacs_value Qcar = env->intern(env, "car");
    emacs_value Qcdr = env->intern(env, "cdr");
    emacs_value Qlength = env->intern(env, "length");
    char **envp = NULL;
    char **child_argv = NULL;
    intmax_t envn = 0;
    intmax_t argn = 0;

    {
        emacs_value la[1] = { args[5] };
        emacs_value len = env->funcall(env, Qlength, 1, la);
        envn = env->extract_integer(env, len);
        if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
            return Qnil;
        if (envn < 0 || envn > 4096) {
            return pid1_signal_errno(env,
                "pid1: spawn-as-uid: env list bad length", EINVAL);
        }
    }
    {
        emacs_value la[1] = { args[4] };
        emacs_value len = env->funcall(env, Qlength, 1, la);
        argn = env->extract_integer(env, len);
        if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
            return Qnil;
        if (argn < 1 || argn > 4096) {
            return pid1_signal_errno(env,
                "pid1: spawn-as-uid: argv list bad length", EINVAL);
        }
    }

    envp = (char **)calloc((size_t)envn + 1, sizeof *envp);
    if (!envp) {
        return pid1_signal_errno(env, "pid1: spawn-as-uid: calloc envp",
                                 errno ? errno : ENOMEM);
    }
    child_argv = (char **)calloc((size_t)argn + 1, sizeof *child_argv);
    if (!child_argv) {
        int e = errno ? errno : ENOMEM;
        free(envp);
        return pid1_signal_errno(env, "pid1: spawn-as-uid: calloc argv", e);
    }

    /* helper: free what we built so far on the parent error path.
     * inline because we want it visible in the local control flow,
     * goto pattern matches the rest of the file's defensive style. */
#define SPAWN_PARENT_FREE() do {                                     \
        if (envp) {                                                  \
            for (intmax_t i = 0; i < envn; i++) free(envp[i]);       \
            free(envp);                                              \
            envp = NULL;                                             \
        }                                                            \
        if (child_argv) {                                            \
            for (intmax_t i = 0; i < argn; i++) free(child_argv[i]); \
            free(child_argv);                                        \
            child_argv = NULL;                                       \
        }                                                            \
    } while (0)

    /* walk ENV list, copy each "KEY=VALUE" string into a heap dup. */
    {
        emacs_value cur = args[5];
        for (intmax_t i = 0; i < envn; i++) {
            emacs_value ca[1] = { cur };
            emacs_value item = env->funcall(env, Qcar, 1, ca);
            if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
            ptrdiff_t need = 0;
            if (!env->copy_string_contents(env, item, NULL, &need)) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
            if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
            if (need < 1 || need > 65536) {
                SPAWN_PARENT_FREE();
                return pid1_signal_errno(env,
                    "pid1: spawn-as-uid: env entry too long", ENAMETOOLONG);
            }
            envp[i] = (char *)malloc((size_t)need);
            if (!envp[i]) {
                int e = errno ? errno : ENOMEM;
                SPAWN_PARENT_FREE();
                return pid1_signal_errno(env,
                    "pid1: spawn-as-uid: malloc env entry", e);
            }
            if (!env->copy_string_contents(env, item, envp[i], &need)) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
            /* reject embedded NUL, missing '=', or leading '=' so the
             * child env is well-formed before we hand it to execve.  a
             * leading '=' means an empty key, which POSIX leaves undef
             * and execve will happily pass on to a child that has no
             * way to look it up.  refuse it here. */
            if (envp[i][0] == '=') {
                SPAWN_PARENT_FREE();
                return pid1_signal_errno(env,
                    "pid1: spawn-as-uid: bad env entry", EINVAL);
            }
            int saw_eq = 0;
            for (ptrdiff_t k = 0; k + 1 < need; k++) {
                if (envp[i][k] == '\0') {
                    SPAWN_PARENT_FREE();
                    return pid1_signal_errno(env,
                        "pid1: spawn-as-uid: env entry has NUL", EINVAL);
                }
                if (envp[i][k] == '=') saw_eq = 1;
            }
            if (!saw_eq) {
                SPAWN_PARENT_FREE();
                return pid1_signal_errno(env,
                    "pid1: spawn-as-uid: env entry missing '='", EINVAL);
            }
            emacs_value da[1] = { cur };
            cur = env->funcall(env, Qcdr, 1, da);
            if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
        }
        envp[envn] = NULL;
    }

    /* --- parent step 5: walk ARGV list the same way. --- */
    {
        emacs_value cur = args[4];
        for (intmax_t i = 0; i < argn; i++) {
            emacs_value ca[1] = { cur };
            emacs_value item = env->funcall(env, Qcar, 1, ca);
            if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
            ptrdiff_t need = 0;
            if (!env->copy_string_contents(env, item, NULL, &need)) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
            if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
            if (need < 1 || need > 65536) {
                SPAWN_PARENT_FREE();
                return pid1_signal_errno(env,
                    "pid1: spawn-as-uid: argv entry too long", ENAMETOOLONG);
            }
            child_argv[i] = (char *)malloc((size_t)need);
            if (!child_argv[i]) {
                int e = errno ? errno : ENOMEM;
                SPAWN_PARENT_FREE();
                return pid1_signal_errno(env,
                    "pid1: spawn-as-uid: malloc argv entry", e);
            }
            if (!env->copy_string_contents(env, item, child_argv[i], &need)) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
            emacs_value da[1] = { cur };
            cur = env->funcall(env, Qcdr, 1, da);
            if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
                SPAWN_PARENT_FREE();
                return Qnil;
            }
        }
        child_argv[argn] = NULL;
    }

    /* compute the fd-close upper bound in the parent so the child does
     * not have to call sysconf or getrlimit (both AS-safe on glibc but
     * not strictly required to be).  RLIMIT_NOFILE soft is what open()
     * would honor anyway; cap at 65536 in case the limit is INFINITY. */
    rlim_t maxfd_rl = 1024;
    {
        struct rlimit rl;
        if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
            maxfd_rl = rl.rlim_cur;
            if (maxfd_rl == RLIM_INFINITY || maxfd_rl > 65536)
                maxfd_rl = 65536;
        }
    }
    int maxfd = (int)maxfd_rl;

    /* --- parent step 6: fork. --- */
    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        SPAWN_PARENT_FREE();
        return pid1_signal_errno(env, "pid1: spawn-as-uid: fork", e);
    }

    if (pid == 0) {
        /* --- CHILD PATH.  no malloc, no env->* calls, no stdio. ---
         * everything from here uses syscalls and the parent-built
         * buffers (home, child_argv, envp, groups, program).  on any
         * error we write a line to /dev/console and _exit(127); the
         * supervisor's reaper picks up the exit status. */

        /* step 7: setsid.  EPERM means we are already a session
         * leader (true for any pid1-spawned child whose pgid was
         * inherited), which is fine; ignore. */
        if (setsid() < 0 && errno != EPERM) {
            /* not fatal per spec, but worth a line. */
            child_log("pid1: spawn-as-uid: setsid: errno=", errno);
        }

        /* pre-open /dev/console for the post-setresuid log path.
         * after setresuid the child is unprivileged and an open of
         * /dev/console (mode 600 root:root in normal configs) returns
         * EACCES, so any failure line we tried to write later would
         * silently vanish.  open() is async-signal-safe, which keeps
         * us inside the post-fork rules.  if the open itself fails we
         * proceed with console_fd = -1; child_log_fd no-ops on it.
         * O_CLOEXEC keeps it from leaking past the eventual execve. */
        int console_fd = open("/dev/console", O_WRONLY | O_CLOEXEC);

        /* step 8: setresgid.  MUST be before setuid; once euid is
         * non-zero, setgid/setgroups silently refuse. */
        if (setresgid(gid, gid, gid) < 0) {
            child_log(child_pfx_setgid, errno);
            _exit(127);
        }

        /* step 9: setgroups.  also before setuid for the same reason. */
        if (setgroups(ngroups, groups) < 0) {
            child_log(child_pfx_setgroups, errno);
            _exit(127);
        }

        /* step 10: setresuid.  after this we are unprivileged. */
        if (setresuid(uid, uid, uid) < 0) {
            child_log(child_pfx_setuid, errno);
            _exit(127);
        }

        /* step 12: chdir to home; failure is logged but non-fatal,
         * per spec we fall back to "/".  step 11 (env scrub) is
         * implicit: execve replaces our env entirely with envp.
         * post-setresuid: use console_fd, not child_log, because the
         * unprivileged child cannot re-open /dev/console. */
        if (chdir(home) < 0) {
            child_log_fd(console_fd, child_pfx_chdir, errno);
            if (chdir("/") < 0) {
                child_log_fd(console_fd,
                    "pid1: spawn-as-uid: chdir(/): errno=", errno);
                _exit(127);
            }
        }

        /* step 13: close fds >= 3.  fds 0/1/2 stay inherited from
         * pid1 (all pointing at /dev/console per the spec's v0.5
         * decision).  loop bounded by the parent-computed maxfd so
         * the child does not need any post-fork syscalls beyond
         * close() in this stage.
         *
         * close fds 3..maxfd-1 unconditionally.  the child should
         * inherit only stdin/stdout/stderr (0/1/2, all /dev/console)
         * and console_fd (the pre-opened error channel, fd N).  if
         * future maintenance wants a fd to survive this loop, gate
         * the close on `fd != console_fd' or whitelist explicitly.
         * NOT silently dup2(logfd, 3) and hope. */
        for (int fd = 3; fd < maxfd; fd++) {
            if (fd == console_fd) continue;
            (void)close(fd);
        }

        /* step 14: execve.  if it returns, we failed; log and exit.
         * post-setresuid path, so route the log through console_fd. */
        (void)execve(program, child_argv, envp);
        child_log_fd(console_fd, child_pfx_execve, errno);
        _exit(127);
    }

    /* --- parent step 15: return the pid.  free the buffers; the
     * child has its own copy via fork's COW. --- */
    SPAWN_PARENT_FREE();
#undef SPAWN_PARENT_FREE

    return env->make_integer(env, (intmax_t)pid);
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
    /* pick the kernel backend before any port-> call.  same contract
     * as main()'s assignment: `port` starts NULL, we assign exactly
     * once here, and port_require_or_abort() turns a missed
     * assignment into an abort at module-load time rather than a
     * NULL-deref crash on the first pid1-* call from elisp (B2,
     * skeptic review 2026-05-12). */
    port = &port_linux_impl;
    port_require_or_abort();

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

    emacs_value sa = env->make_function(env, 3, 3, Fpid1_set_address,
        "Assign IPv4 ADDRESS/PREFIX to IFNAME and bring it up. Return t.",
        NULL);
    pid1_defalias(env, "pid1-set-address", sa);

    emacs_value srd = env->make_function(env, 2, 2, Fpid1_set_route_default,
        "Install default route via GATEWAY through IFNAME. Return t.",
        NULL);
    pid1_defalias(env, "pid1-set-route-default", srd);

    emacs_value cr = env->make_function(env, 2, 2, Fpid1_crypt,
        "Hash PLAINTEXT with SALT via crypt_r(3). Returns the encoded hash.",
        NULL);
    pid1_defalias(env, "pid1-crypt", cr);

    emacs_value fsd = env->make_function(env, 1, 1, Fpid1_fsync_dir,
        "fsync the directory at PATH. Return t. Use after rename to commit durably.",
        NULL);
    pid1_defalias(env, "pid1-fsync-dir", fsd);

    emacs_value chn = env->make_function(env, 3, 3, Fpid1_chown,
        "chown(2) PATH to UID:GID. Floor 1000 on both. Return t.",
        NULL);
    pid1_defalias(env, "pid1-chown", chn);

    emacs_value off = env->make_function(env, 0, 0, Fpid1_poweroff,
        "Sync, then reboot(RB_POWER_OFF). Does not return on success.",
        NULL);
    pid1_defalias(env, "pid1-poweroff", off);

    emacs_value rb = env->make_function(env, 0, 0, Fpid1_reboot,
        "Sync, then reboot(RB_AUTOBOOT). Does not return on success.",
        NULL);
    pid1_defalias(env, "pid1-reboot", rb);

    emacs_value sus = env->make_function(env, 1, 1, Fpid1_suspend,
        "Sync, then write STATE to /sys/power/state. Returns t on resume. "
        "STATE is one of \"mem\", \"freeze\", \"standby\", \"disk\".",
        NULL);
    pid1_defalias(env, "pid1-suspend", sus);

    emacs_value spw = env->make_function(env, 6, 6, Fpid1_spawn_as_uid,
        "pid1-spawn-as-uid: spawn child as uid/gid per v0.5 ABI",
        NULL);
    pid1_defalias(env, "pid1-spawn-as-uid", spw);

    emacs_value rlsn = env->make_function(env, 2, 2, Fpid1_rpc_listen,
        "Bind an AF_UNIX SOCK_STREAM socket at PATH with file MODE. "
        "Return t.  Singleton; second call returns EBUSY.",
        NULL);
    pid1_defalias(env, "pid1-rpc-listen", rlsn);

    emacs_value rpol = env->make_function(env, 0, 0, Fpid1_rpc_poll,
        "Non-blocking accept on the rpc socket.  Return nil or a "
        "plist (:fd FD :uid UID :gid GID :payload STRING).",
        NULL);
    pid1_defalias(env, "pid1-rpc-poll", rpol);

    emacs_value rrep = env->make_function(env, 2, 2, Fpid1_rpc_reply,
        "Write PAYLOAD back on FD and close.  FD must come from "
        "pid1-rpc-poll's :fd slot.  Return t.",
        NULL);
    pid1_defalias(env, "pid1-rpc-reply", rrep);

    /* provide the feature so (require 'pid1-module) works after
     * (module-load ...) without a separate elisp wrapper. */
    emacs_value feat_args[1] = { env->intern(env, "pid1-module") };
    (void)env->funcall(env, env->intern(env, "provide"), 1, feat_args);

    return 0;
}

#endif /* PID1_MODULE */
