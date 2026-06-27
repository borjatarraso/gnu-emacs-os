/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2025-2026  Borja Tarraso <borja.tarraso@member.fsf.org>
 * Copyright (C) 2026  Adrian Yanes <ayanes@gnu.org>
 *
 * This file is part of GEOS.
 *
 * GEOS is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * GEOS is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with GEOS.  If not, see <https://www.gnu.org/licenses/>.
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
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#ifdef PORT_HURD
/* Hurd has no <sys/mount.h>: mount() is not a Hurd syscall (translators
 * replace the role of mount in the file-system namespace).  the MS_*
 * flag literals are still constructed at call sites in emacs-init.c
 * and dispatched through port->mount(); port_hurd.c's mount slot
 * ignores most flag bits because translator semantics map differently.
 * we define the same numeric values Linux uses so the bits on the wire
 * keep their meaning across backends, even though the Hurd backend
 * does not act on them today. */
#define MS_RDONLY  1
#define MS_NOSUID  2
#define MS_NODEV   4
#define MS_NOEXEC  8
#define MS_REMOUNT 32
#else
#include <sys/mount.h>
#endif
#include <sys/reboot.h>
#ifdef PORT_HURD
/* Hurd's <sys/reboot.h> defines RB_AUTOBOOT (0), RB_HALT, RB_SINGLE,
 * RB_KDB, RB_DEBUGGER, but not RB_POWER_OFF.  pid1's Fpid1_reboot /
 * Fpid1_poweroff dispatch the command word through port->reboot(),
 * which on Hurd is the host_reboot Mach RPC: port_hurd_impl translates
 * our command word into the appropriate Mach reboot command, so the
 * literal values here only need to be distinguishable bit patterns.
 * the Linux RB_AUTOBOOT macro is a magic 0x01234567 and RB_POWER_OFF
 * is 0x4321fedc; we use the same so the wire shape stays identical
 * across kernels and a future tcpdump-style debug dump would not
 * look different on Hurd. */
#ifndef RB_AUTOBOOT
#define RB_AUTOBOOT  0x01234567
#endif
#ifndef RB_POWER_OFF
#define RB_POWER_OFF 0x4321fedc
#endif
#endif
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "port_layer.h"

/* Hurd's libc deliberately does not define PATH_MAX: Hurd paths are
 * unbounded, so any bound would be a lie.  Linux defines it via
 * <linux/limits.h> (4096).  the call sites in this file all bound-
 * check the result against PATH_MAX, so a synthetic 4096 here keeps
 * the bound honest on Hurd too: a path longer than that gets the
 * same "path too long" rejection it would on Linux. */
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

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

/* per-kernel source for the gnu.system / geos.mode tokens.  on Linux
 * the guix initrd stamps them onto /proc/cmdline so we read straight
 * from there.  on Hurd there is no init= cmdline knob (see
 * docs/runlogs/2026-05-18-hurd-pid1-boot-design.md): /hurd/startup
 * unconditionally exec's /sbin/init, so the install path writes a
 * small key=value file at /etc/geos-cmdline and we read that instead.
 * the two source paths share the same parse + validation code; only
 * the path is per-kernel, exposed as a compile-time constant so the
 * boot path has no runtime branch around it.  a not-yet-installed
 * Hurd VM has no /etc/geos-cmdline, in which case the reader degrades
 * the same way it would on a malformed Linux cmdline (returns -1,
 * link_current_system skips the symlink, read_geos_mode defaults to
 * ui on both kernels; on Hurd UI v0.9.8+ pid1 spawns Xvfb because
 * native Xorg is blocked on the input-driver gap, see
 * docs/runlogs/2026-05-21-hurd-xorg-probe.md).
 *
 * trust model: /proc/cmdline is kernel-provided and not writeable at
 * runtime.  /etc/geos-cmdline is a regular file the installer drops
 * with root-only perms by convention.  pid1 does NOT chmod-check the
 * file; the prefix + ".." + PATH_MAX validation in
 * read_gnu_system_path IS the security boundary, identical to the
 * existing Linux path.  if the rootfs is compromised to the point
 * where the attacker can rewrite /etc/geos-cmdline, they can already
 * rewrite /sbin/init too, so the file's perms are not the chokepoint. */
#ifdef PORT_HURD
#define GEOS_CMDLINE_PATH "/etc/geos-cmdline"
#else
#define GEOS_CMDLINE_PATH "/proc/cmdline"
#endif

#ifndef PID1_MODULE
/* read /etc/hostname (which guix's etc-service-type writes from the
 * operating-system host-name field), trim trailing whitespace, and
 * call sethostname. fall back to the hardcoded "lambda" if the file
 * is unreadable, empty, or whitespace-only. invariant: never errors
 * out the boot. failures log to /dev/console and continue. boot path
 * only because console() is gated on !PID1_MODULE; the module path
 * uses Fpid1_set_hostname driven from elisp instead.
 *
 * on Hurd, sethostname can return EROFS (the glibc-hurd wrapper's
 * /etc/hostname persistence step hits the read-only root at init
 * time, before the rootfs is remounted rw).  we log and continue.
 * core/hostname.el's `hostname-apply' runs at supervisor load time
 * and re-calls `pid1-set-hostname' (the module binding wired into
 * the same port->set_hostname slot), so the proc-server gets the
 * right value once the rootfs is writable; no C-side retry
 * machinery is needed. */
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
    /* access(F_OK) gate: on Hurd, mkdir on a directory that already
     * exists under a read-only root returns EROFS, NOT EEXIST, so the
     * existing if-clause's EEXIST guard never fires and the boot log
     * fills with "pid1: mkdir /tmp failed: Read-only file system"
     * lines for every standard dir that was already there.  the access
     * pre-check skips mkdir entirely when the dir exists.  on Linux
     * mkdir-on-existing-dir returns EEXIST cleanly, so this gate is a
     * cheap no-op there. */
    if (access(tgt, F_OK) != 0 &&
        mkdir(tgt, 0755) < 0 && errno != EEXIST) {
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

/* parses GEOS_CMDLINE_PATH for the gnu.system=PATH token the guix
 * initrd stamps on every boot (Linux) or that the Hurd installer
 * writes into /etc/geos-cmdline.  copies the path into out
 * (NUL-terminated, capped at out_len-1). returns 0 on success and out
 * is populated; -1 if the token is missing, the file is unreadable,
 * the value would not fit, or the value fails sanity validation (must
 * start with /gnu/store/, no ".." substring, length under PATH_MAX).
 * on rejection we log to /dev/console so the operator sees why
 * /run/current-system is missing. invariant: out is always
 * NUL-terminated on success, untouched on failure. used to find the
 * system profile so we can lay down /run/current-system without
 * invoking guix activation.
 *
 * (B7, skeptic 2026-05-06) cmdline content is not trusted: a hostile
 * or malformed gnu.system value would otherwise let us symlink
 * /run/current-system at any path of the attacker's choosing, and
 * emacs would happily PATH= into it. validate before symlinking. */
static int
read_gnu_system_path(char *out, size_t out_len)
{
    int fd = open(GEOS_CMDLINE_PATH, O_RDONLY | O_CLOEXEC);
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

/* parse GEOS_CMDLINE_PATH for the geos.mode= token. recognized values
 * are "ui" (default; spawn an X server and run emacs as an X client),
 * "console" (skip the X server, run emacs on /dev/console with
 * TERM=linux), and "recovery" (v0.4 item 10: skip the X server AND
 * skip the userland -l chain; the operator lands on a bare *scratch*
 * with panic.el available so a broken defservice or defcustom cannot
 * wedge the boot).  anything else, including a missing token or an
 * unreadable cmdline source, defaults to UI on both kernels: matches
 * the historical v0.1/v0.2 behaviour and means an unmodified GRUB
 * entry keeps the pretty boot.  on Hurd the cmdline source is
 * /etc/geos-cmdline, which is absent on a not-yet-installed VM; the
 * absence falls through to the same UI default.  v0.9.8 ships the
 * Xvfb spawn path on Hurd UI (the v0.7.x force-console-mode override
 * in main() is gone); native Xorg on Hurd is blocked on the
 * input-driver gap (see docs/runlogs/2026-05-21-hurd-xorg-probe.md
 * probes E3/E4/I and HURD_PORT.md).  invariant: pure read, never
 * blocks longer than the open+read takes.  logs the chosen mode to
 * /dev/console so the operator sees the decision in the boot
 * trace. */
#define GEOS_MODE_UI       1
#define GEOS_MODE_CONSOLE  0
#define GEOS_MODE_RECOVERY 2

static int
read_geos_mode(void)
{
    int fd = open(GEOS_CMDLINE_PATH, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        /* both kernels default to UI on a missing cmdline source.  on
         * Linux this is /proc/cmdline (kernel-supplied, normally
         * present); on Hurd it is /etc/geos-cmdline, which is absent
         * on a not-yet-installed VM and so is the expected case for a
         * manual Hurd install.  v0.9.8 ships the Xvfb spawn path on
         * Hurd UI, so the default is no longer immediately overridden
         * (the v0.7.x force-console block in main() is gone as of
         * v0.9.8); the log line below is now accurate on both
         * kernels.  see docs/runlogs/2026-05-21-hurd-xorg-probe.md. */
        console("pid1: " GEOS_CMDLINE_PATH " unreadable, defaulting to ui mode");
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
        /* on Linux this means real Xorg + EXWM; on Hurd (v0.9.8+) it
         * means Xvfb + EXWM because native Xorg is blocked on the
         * input-driver gap (see docs/runlogs/2026-05-21-hurd-xorg-
         * probe.md probes E3/E4/I).  the userland code does not
         * branch on kernel; the difference is purely which X server
         * binary pid1 spawns. */
        console("pid1: geos.mode=ui, will spawn X server + EXWM");
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
#ifdef PORT_HURD
        /* on Hurd the cmdline source is /etc/geos-cmdline, which is
         * absent on a not-yet-installed VM; that is the expected case
         * for the v0.7.x boot bring-up, not an error.  log at INFO so
         * the operator sees why /run/current-system stays missing and
         * does not chase a phantom guix-system on a manual Hurd
         * install.  see docs/runlogs/2026-05-18-hurd-pid1-boot-
         * design.md. */
        console("pid1: INFO no gnu.system= in " GEOS_CMDLINE_PATH ", "
                "/run/current-system not linked (expected on manual Hurd install)");
#else
        console("pid1: no gnu.system= in " GEOS_CMDLINE_PATH ", "
                "/run/current-system not linked");
#endif
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
     * idempotent for our purposes (EEXIST is success).
     *
     * the access(F_OK) gate ahead of mkdir is for the Hurd case where
     * the root filesystem is still mounted read-only at PID-1 time (no
     * Debian checkroot.sh runs because /sbin/init is no longer
     * sysvinit's init).  mkdir on a RO root returns EROFS, NOT EEXIST,
     * even when the directory already exists; the unguarded version
     * dumped a "pid1: mkdir /var failed: Read-only file system" line on
     * every Hurd boot even though /var was right there.  on Linux this
     * gate is dead weight (mkdir on an existing dir returns EEXIST which
     * the if-clause already skips) but the cost is one access() syscall
     * which doesn't move the needle on boot time. */
    if (access("/var", F_OK) != 0 &&
        mkdir("/var", 0755) < 0 && errno != EEXIST) {
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

/* v0.9.24 follow-on #7 (2026-05-30): tripped by the signal handler
 * below when sysvinit's `shutdown -h now` (or any external SIGTERM /
 * SIGUSR1 / SIGUSR2 to pid 1) starts the shutdown chain.  the
 * supervisor loop reads this flag at the top of each iteration and
 * breaks out instead of respawning emacs, so a closing emacs on the
 * shutdown path does not get re-forked into a doomed bringup that
 * tries to remount /var and re-run supervise-autostart.  see
 * docs/runlogs/2026-05-30-hurd-pselect-soak-35min.md lines 535-619
 * for the original /dev/console pollution this closes. */
static volatile sig_atomic_t shutting_down = 0;

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

/* SIGTERM / SIGUSR1 / SIGUSR2 land here when something external (the
 * sysvinit-shaped `shutdown` binary on Hurd, or a future GEOS-native
 * caller that wants to signal pid 1) initiates a shutdown.  signal-safe
 * minimum: just set the shutting_down flag.  the supervisor loop
 * checks it before each respawn cycle and breaks out cleanly.
 * invariant: does no I/O, no malloc, no non-async-signal-safe calls.
 * the same handler is installed for all three signals because the only
 * thing pid 1 does in response is "stop respawning emacs"; the actual
 * halt or poweroff happens elsewhere (port->reboot from a Femacs
 * binding, or the kernel cutting power outright). */
static void
on_shutdown_signal(int sig)
{
    (void)sig;
    shutting_down = 1;
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

/* v0.7.x hurd port: GEOS_KERNEL=<linux|hurd> spliced into the child
 * env so core/port.el's `geos-kernel' defvar resolves to the right
 * symbol on the elisp side.  before this existed the elisp seam
 * defaulted to 'linux on every boot regardless of which port_caps
 * was linked in, so a Hurd build would have linked the Mach-RPC C
 * backend but kept reading /sys/block from the elisp side.  set
 * unconditionally from main() right after `port' is assigned, by
 * snprintf'ing "GEOS_KERNEL=" + port->kernel_name into the buffer
 * below.  per-user spawn (session.el) forwards GEOS_KERNEL through
 * from the supervisor's env so it lands in each per-user emacs
 * automatically; the env splice here is what gets it there in the
 * first place. */
static char geos_kernel_env_buf[64];
static const char *geos_kernel_env = NULL;

/* v0.9.20 slice A: unconditional sentinel that the supervised emacs is
 * a child of pid1.  before this splice, the elisp `pid1-as-emacs-p'
 * predicate keyed on PID1_MODULE_PATH, which STATIC=1 builds never set
 * (the inline-primitives path deliberately skips the dlopen, see the
 * argv[2] guard around line 1640).  consequence: every supervision
 * gate downstream (supervise-finalize, autostart, /var ownership,
 * session.el's pid1-spawn path) silently fell through to the dev-host
 * no-op branch under STATIC builds.  caught on the v0.9.19 full-chain
 * boot when hurd-essentials' :autostart sshd never came up.
 *
 * GEOS_PID1=1 is a fixed string literal because there is nothing
 * variable to splice; this is purely "pid1 spawned this emacs".  the
 * pointer is a global so the envp[] splice below treats it the same
 * shape as module_env/geos_kernel_env (assigned-or-NULL).  it is
 * always non-NULL: pid1 always wants to mark its supervised emacs. */
static const char *geos_pid1_env = "GEOS_PID1=1";

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

        /* arm the "die when parent dies" link before exec.  on Linux
         * this is prctl(PR_SET_PDEATHSIG); on Hurd the v0.9.8 slot
         * returns ENOSYS until the MACH_NOTIFY_DEAD_NAME watcher-thread
         * lands in v0.9.9 (see docs/runlogs/2026-05-21-hurd-xorg-probe.md
         * probe F2 + decision points).  ENOSYS is tolerated as a
         * defence-in-depth gap: if pid1 dies the kernel reboots anyway,
         * so an orphaned X server is moot.  any other errno is a real
         * failure (out-of-range signal, kernel reject) and kills the
         * child with the same _exit(127) we use for other pre-exec
         * failures. */
        if (port->arm_parent_death(SIGTERM) < 0) {
            if (errno == ENOSYS) {
                console("pid1: arm_parent_death not implemented on this kernel, "
                        "Xorg child will outlive pid1 death (defence in depth gap, "
                        "not load-bearing)");
            } else {
                console("pid1: arm_parent_death failed in xorg child");
                _exit(127);
            }
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

        /* envp is fixed-size; we splice PID1_MODULE_PATH, DISPLAY,
         * GEOS_MODE, GEOS_KERNEL, GEOS_PID1 in if they were set.  4
         * fixed entries + up to 5 conditional + trailing NULL = 10
         * slots worst-case today.  the cap is sized at 13 to leave
         * headroom for the next env splice (skeptic B2: a missing
         * bump on the next addition would write envp[ei] = NULL one
         * past the array and the bug class is "supervisor execve
         * overruns envp" which brick-installs).  raise the cap
         * together with any new envp[ei++] line. */
        char *envp[13];
        int ei = 0;
        envp[ei++] = "TERM=linux";
        envp[ei++] = "HOME=/root";
        envp[ei++] = "USER=root";
        envp[ei++] = "PATH=/run/current-system/profile/bin:"
                     "/run/current-system/profile/sbin";
        if (module_env) envp[ei++] = (char *)module_env;
        if (display_env) envp[ei++] = (char *)display_env;
        if (geos_mode_env) envp[ei++] = (char *)geos_mode_env;
        if (geos_kernel_env) envp[ei++] = (char *)geos_kernel_env;
        /* GEOS_PID1=1: const string literal at file scope, never
         * NULL.  shape-parallel with the splices above; the if is
         * defensive but in practice always taken. */
        if (geos_pid1_env) envp[ei++] = (char *)geos_pid1_env;
        envp[ei] = NULL;
        execve(emacs_path, argv, envp);
        /* execve only returns on failure; if it succeeded the child is
         * already emacs and this line is dead.  bare "execve failed"
         * was the v0.7.x line; the 2026-05-18 first-Hurd-PID-1 boot
         * crashloop made me realize a bare failure with no errno gives
         * the operator nothing to act on.  emit the path and strerror
         * so the next boot's runlog shows EACCES vs ENOEXEC vs ENOENT
         * vs Hurd-specific surprises directly. */
        {
            /* errno first, path second.  emacs_path can in principle
             * be PATH_MAX (4096) bytes when it points at a /gnu/store
             * hash path; if snprintf has to truncate, drop the path
             * tail rather than the errno (skeptic 2026-05-18). */
            char buf[320];
            int saved_errno = errno;
            (void)snprintf(buf, sizeof buf,
                           "pid1: execve failed (%s): %s",
                           strerror(saved_errno), emacs_path);
            console(buf);
        }
        _exit(127);
    }
    return pid;
}

/* args-file fallback for kernels that do not give pid1 a useful argv.
 *
 * contract:
 *   - only called when the kernel did not hand us a usable argv[1]
 *     (no absolute path in slot 1, i.e. either /hurd/startup gave us
 *     argc==1 or a sysvinit runlevel token).  when the kernel did
 *     give us a usable chain (Linux/Guix passes argc >= 5 with
 *     absolute store paths), this function is never reached.
 *   - reads /etc/geos/init.args (path passed as PATH for testability).
 *     file format: newline-delimited args, one per line, no quoting.
 *     blank lines and lines starting with '#' are comments.  the first
 *     non-comment line maps to argv[1] (emacs path), the second to
 *     argv[2] (module path), the third to argv[3] (xorg spec), the
 *     fourth onward becomes the extra_argv chain.
 *   - slurps into a static buffer (BUF_BYTES, 8 KiB).  no malloc on
 *     this path, per the project-wide "no malloc in pid1 hot paths"
 *     invariant in the pid1 dir notes.
 *   - populates the caller-supplied OUT_ARGV[OUT_CAP] with pointers
 *     into the static buffer.  OUT_ARGV[0] is initialized to a
 *     placeholder string up-front (BEFORE any failure check) so a
 *     caller that mistakenly reads it after a -1 return gets a
 *     well-formed string instead of garbage; correct callers always
 *     overwrite slot 0 with the real argv[0] before exec().  *OUT_ARGC
 *     receives the number of slots populated INCLUDING slot 0, i.e.
 *     it has the same meaning as the kernel's argc.
 *   - returns 0 on success (any number of args >= 1 parsed), -1 on
 *     "fall through to the existing no-args path".
 *
 * failure modes (all log one console() line with a "pid1: init.args "
 * prefix and a strerror() suffix where applicable, then return -1):
 *   - open() ENOENT: silent fall-through.  no init.args means the
 *     kernel argv path applies.  this is the Linux production case:
 *     /etc/geos/init.args does not exist, the open() ENOENTs, we
 *     return -1, and main() never touches synth_argv.
 *   - open() other errno: logged with strerror, fall through.
 *     (this includes ELOOP from O_NOFOLLOW when init.args is a
 *     symlink: we refuse symlinks because a PID 1 boot file from /etc
 *     should be a real root-owned regular file, not a hop into some
 *     other directory an attacker may have written to.)
 *   - fstat() non-regular or non-root-owned: logged "refusing", fall
 *     through.  the installer must write init.args as root (uid 0,
 *     mode 0644 is fine); an installer running as a non-root user
 *     will not satisfy this check and the boot will silently use the
 *     default argv instead.
 *   - read() error or short read: logged, fall through.
 *   - file empty (no non-comment lines): logged, fall through.
 *   - file larger than BUF_BYTES: logged "too large" and we fall through.
 *     8 KiB is the largest a sane args file should ever be; hitting
 *     the cap means something is wrong upstream and silently parsing
 *     a truncated buffer could exec a half-line path.
 *   - more than OUT_CAP-1 args: logged "capping" and we keep the
 *     first OUT_CAP-1 entries.
 *
 * the function MUST be safe to call before /dev/console redirection
 * happens: console() opens fresh each time. */
static char init_args_buf[8192];
static int
parse_init_args(const char *path, char **out_argv, int out_cap, int *out_argc)
{
    if (!path || !out_argv || out_cap < 2 || !out_argc) return -1;
    out_argv[0] = (char *)"emacs-init";

    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        /* ENOENT is the Linux production path: file just is not there,
         * say nothing.  any other errno gets logged so a bad mode bit
         * (or a symlink, which O_NOFOLLOW will refuse with ELOOP) on
         * the file shows up in the boot log instead of being lost. */
        if (errno == ENOENT) return -1;
        int saved = errno;
        char msg[256];
        (void)snprintf(msg, sizeof msg,
                       "pid1: init.args open failed (%s): %s",
                       strerror(saved), path);
        console(msg);
        return -1;
    }
    {
        struct stat st;
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != 0) {
            console("pid1: init.args is not a root-owned regular file, refusing");
            (void)close(fd);
            return -1;
        }
    }

    /* read up to sizeof - 1 so we can always NUL-terminate.  loop the
     * read because short reads from a regular file are rare but legal
     * (interrupted by a signal, etc) and 1am-debugging me would rather
     * have one robust loop than a single read() that "almost always
     * works". */
    size_t have = 0;
    int truncated = 0;
    for (;;) {
        if (have >= sizeof init_args_buf - 1) {
            /* buffer full.  drain the rest of the file to see if there
             * was more; if so, log truncation.  this matters because a
             * silently-truncated boot chain is the kind of bug that
             * eats a whole afternoon. */
            char drain[256];
            ssize_t d = read(fd, drain, sizeof drain);
            if (d > 0) truncated = 1;
            if (d <= 0) break;
            continue;
        }
        ssize_t n = read(fd, init_args_buf + have,
                         sizeof init_args_buf - 1 - have);
        if (n < 0) {
            if (errno == EINTR) continue;
            int saved = errno;
            char msg[256];
            (void)snprintf(msg, sizeof msg,
                           "pid1: init.args read failed (%s): %s",
                           strerror(saved), path);
            console(msg);
            (void)close(fd);
            return -1;
        }
        if (n == 0) break;
        have += (size_t)n;
    }
    (void)close(fd);

    if (truncated) {
        char msg[160];
        (void)snprintf(msg, sizeof msg,
                       "pid1: init.args too large (> %zu bytes), "
                       "falling through to default argv",
                       sizeof init_args_buf - 1);
        console(msg);
        return -1;
    }

    if (have == 0) {
        console("pid1: init.args is empty, falling through");
        return -1;
    }
    init_args_buf[have] = '\0';

    /* walk the buffer.  NUL-terminate every line in place by replacing
     * '\n' with '\0'.  slot 0 is reserved for argv[0] (caller fills it),
     * so we start writing at slot 1.  cap at out_cap - 1 user args. */
    int ai = 1;
    int capped = 0;
    int orig_count = 0;
    char *line = init_args_buf;
    while (line && *line) {
        char *end = strchr(line, '\n');
        if (end) *end = '\0';
        /* trim a trailing CR so init.args files edited on a Windows
         * host do not silently corrupt the first emacs_path lookup
         * with a stray byte. */
        size_t llen = strlen(line);
        if (llen > 0 && line[llen - 1] == '\r') {
            line[llen - 1] = '\0';
            llen--;
        }
        /* skip blank and comment lines (no incrementing of ai). */
        if (llen == 0 || line[0] == '#') {
            line = end ? end + 1 : NULL;
            continue;
        }
        orig_count++;
        if (ai < out_cap) {
            out_argv[ai++] = line;
        } else {
            capped = 1;
            /* do not break; we want to count the overflow so the log
             * line can name a real number. */
        }
        line = end ? end + 1 : NULL;
    }

    if (capped) {
        char msg[160];
        (void)snprintf(msg, sizeof msg,
                       "pid1: init.args has %d args, capping at %d",
                       orig_count, out_cap - 1);
        console(msg);
    }

    if (ai <= 1) {
        /* nothing parseable.  every line was blank or a comment. */
        console("pid1: init.args has no non-comment lines, falling through");
        return -1;
    }

    *out_argc = ai;
    return 0;
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

/* extract /dev/input/eventN from an "H: Handlers=..." line. returns 0
 * on success, -1 if no event node is present. */
static int
handlers_event_path(const char *handlers, char *path, size_t pathlen)
{
    const char *ev;
    char *end;
    unsigned long n;

    if (!handlers || !path || pathlen < 20)
        return -1;
    ev = strstr(handlers, "event");
    if (!ev)
        return -1;
    ev += 5;
    n = strtoul(ev, &end, 10);
    if (end == ev || n > 1024)
        return -1;
    if (snprintf(path, pathlen, "/dev/input/event%lu", n) >= (int)pathlen)
        return -1;
    return 0;
}

/* parse /proc/bus/input/devices and publish stable symlinks for Xorg:
 *   /run/geos/input-kbd -> the kbd handler device
 *   /run/geos/input-ptr -> the QEMU usb-tablet (absolute pointer)
 * eventN numbering shifts across qemu hosts; these names do not. */
static void
setup_input_symlinks(void)
{
    static const char *kbd_link = "/run/geos/input-kbd";
    static const char *ptr_link = "/run/geos/input-ptr";
    FILE *f;
    char line[512];
    char name[256];
    char handlers[256];
    char kbd_tgt[PATH_MAX];
    char ptr_tgt[PATH_MAX];
    int have_kbd = 0;
    int have_ptr = 0;

    kbd_tgt[0] = '\0';
    ptr_tgt[0] = '\0';
    name[0] = '\0';
    handlers[0] = '\0';

    f = fopen("/proc/bus/input/devices", "r");
    if (!f) {
        console("pid1: setup_input_symlinks: cannot open "
                "/proc/bus/input/devices");
        return;
    }

    while (fgets(line, sizeof line, f)) {
        if (line[0] == '\n' || line[0] == '\0') {
            if (name[0] && handlers[0]) {
                char evpath[PATH_MAX];
                if (!have_kbd && strstr(handlers, "kbd")
                    && handlers_event_path(handlers, evpath, sizeof evpath) == 0
                    && strstr(name, "keyboard")) {
                    size_t n = strlen(evpath);
                    if (n >= sizeof kbd_tgt)
                        n = sizeof kbd_tgt - 1;
                    memcpy(kbd_tgt, evpath, n);
                    kbd_tgt[n] = '\0';
                    have_kbd = 1;
                }
                if (!have_ptr && strstr(name, "USB Tablet")
                    && handlers_event_path(handlers, evpath, sizeof evpath) == 0) {
                    size_t n = strlen(evpath);
                    if (n >= sizeof ptr_tgt)
                        n = sizeof ptr_tgt - 1;
                    memcpy(ptr_tgt, evpath, n);
                    ptr_tgt[n] = '\0';
                    have_ptr = 1;
                }
            }
            name[0] = '\0';
            handlers[0] = '\0';
            continue;
        }
        if (strncmp(line, "N: Name=", 8) == 0) {
            const char *p = line + 8;
            size_t n = strcspn(p, "\n");
            if (n >= sizeof name)
                n = sizeof name - 1;
            memcpy(name, p, n);
            name[n] = '\0';
            continue;
        }
        if (strncmp(line, "H: Handlers=", 12) == 0) {
            const char *p = line + 12;
            size_t n = strcspn(p, "\n");
            if (n >= sizeof handlers)
                n = sizeof handlers - 1;
            memcpy(handlers, p, n);
            handlers[n] = '\0';
        }
    }
    fclose(f);

    /* last block if file does not end with a blank line */
    if (name[0] && handlers[0]) {
        char evpath[PATH_MAX];
        if (!have_kbd && strstr(handlers, "kbd")
            && handlers_event_path(handlers, evpath, sizeof evpath) == 0
            && strstr(name, "keyboard")) {
            size_t n = strlen(evpath);
            if (n >= sizeof kbd_tgt)
                n = sizeof kbd_tgt - 1;
            memcpy(kbd_tgt, evpath, n);
            kbd_tgt[n] = '\0';
            have_kbd = 1;
        }
        if (!have_ptr && strstr(name, "USB Tablet")
            && handlers_event_path(handlers, evpath, sizeof evpath) == 0) {
            size_t n = strlen(evpath);
            if (n >= sizeof ptr_tgt)
                n = sizeof ptr_tgt - 1;
            memcpy(ptr_tgt, evpath, n);
            ptr_tgt[n] = '\0';
            have_ptr = 1;
        }
    }

    if (mkdir("/run/geos", 0755) < 0 && errno != EEXIST) {
        console("pid1: mkdir /run/geos failed for input symlinks");
        return;
    }

    if (have_kbd) {
        char msg[PATH_MAX + 64];
        unlink(kbd_link);
        if (symlink(kbd_tgt, kbd_link) == 0) {
            snprintf(msg, sizeof msg, "pid1: input-kbd -> %s", kbd_tgt);
            console(msg);
        } else {
            console("pid1: symlink input-kbd failed");
        }
    } else {
        console("pid1: input-kbd not found in /proc/bus/input/devices");
    }

    if (have_ptr) {
        char msg[PATH_MAX + 64];
        unlink(ptr_link);
        if (symlink(ptr_tgt, ptr_link) == 0) {
            snprintf(msg, sizeof msg, "pid1: input-ptr -> %s", ptr_tgt);
            console(msg);
        } else {
            console("pid1: symlink input-ptr failed");
        }
    } else {
        console("pid1: input-ptr (usb-tablet) not found");
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
     * backend registration on the side branch.
     *
     * the PORT_HURD compile-time switch comes from the Makefile when
     * the operator runs `make PORT=hurd`.  Linux builds (the default,
     * and the main branch) keep the existing port_linux_impl symbol;
     * the Hurd build (-DPORT_HURD set by the PORT block in pid1/Makefile)
     * picks port_hurd_impl which port_hurd.c on the hurd branch
     * defines.  no runtime branch, no env lookup: the choice is baked
     * at compile time and the binary carries exactly one backend. */
#ifdef PORT_HURD
    port = &port_hurd_impl;
#else
    port = &port_linux_impl;
#endif
    port_require_or_abort();

    /* build "GEOS_KERNEL=<name>" from the active backend's identity.
     * truncation here would silently fall back to the elisp 'linux
     * default, which is precisely the footgun this splice exists to
     * close (skeptic B1).  treat it the same way as a NULL port table:
     * loud message on /dev/console + abort, since the only way to hit
     * it is a backend that names itself with >50 characters, which is
     * a build-config bug not a runtime condition.  the buffer is 64
     * bytes; "GEOS_KERNEL=" is 12, leaving 51 for the name + NUL. */
    {
        int n = snprintf(geos_kernel_env_buf, sizeof geos_kernel_env_buf,
                         "GEOS_KERNEL=%s", port->kernel_name);
        if (n <= 0 || (size_t)n >= sizeof geos_kernel_env_buf) {
            console("pid1: GEOS_KERNEL splice failed or truncated; "
                    "backend kernel_name unusable, aborting");
            abort();
        }
        geos_kernel_env = geos_kernel_env_buf;
    }

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
    /* argv[1..3] are only accepted if they LOOK like paths (start with
     * '/').  on Hurd, /hurd/startup hands /sbin/init the sysvinit-style
     * runlevel argument (e.g. "6" after a `shutdown -r now`); on a
     * Debian Hurd boot the first thing the supervisor gets is argv =
     * ["/sbin/init", "6"] and the old unconditional `emacs_path =
     * argv[1]` made us execve("6") in a tight crashloop (ENOENT).  the
     * guix boot gexp always passes absolute store paths, so the '/'
     * prefix check is forward-compatible with that caller too.  same
     * guard on argv[2] (PID1_MODULE_PATH) and argv[3] (xorg spec, also
     * absolute by construction) since `telinit 1` / `telinit 3` would
     * otherwise land "1" / "3" in those slots.  caught on the
     * 2026-05-18 second boot, see
     * docs/runlogs/2026-05-18-hurd-pid1-boot-result.md. */

    /* v0.9.11 args-file fallback for Hurd: when argv[1] is not an
     * absolute path we treat that as "no boot chain" (this is what
     * /hurd/startup hands us: argc==1, or a sysvinit runlevel token
     * like "6" in argv[1]).  if the installer dropped
     * /etc/geos/init.args we slurp it and synthesize an argv that the
     * splice block below treats normally.  on Linux the file does not
     * exist, parse_init_args ENOENTs silently, and the splice block
     * runs against the original argv unchanged.  a partial-but-
     * absolute kernel argv (e.g. argc==3 with a real store path in
     * argv[1]) is still more authoritative than the file and is left
     * alone.
     *
     * synth_argv is sized 1 (argv[0]) + 131 file lines = 132 slots.
     * synth_argv[0] is the original argv[0] so /proc/self/cmdline and
     * any future argv[0]-keyed code path keeps working.  the static
     * lifetime is fine: main() never returns.  no malloc on this hot
     * path, per the project-wide pid1 invariant. */
    static char *synth_argv[132];
    if (argc < 2 || !argv[1] || argv[1][0] != '/') {
        int synth_argc = 0;
        if (parse_init_args("/etc/geos/init.args",
                            synth_argv,
                            (int)(sizeof synth_argv / sizeof synth_argv[0]),
                            &synth_argc) == 0) {
            synth_argv[0] = (argc > 0 && argv && argv[0])
                ? argv[0]
                : (char *)"emacs-init";
            argv = synth_argv;
            argc = synth_argc;
        }
    }

    if (argc > 1 && argv[1] && argv[1][0] == '/') {
        emacs_path = argv[1];
    } else if (argc > 1 && argv[1] && argv[1][0] != '\0') {
        char msg[160];
        (void)snprintf(msg, sizeof msg,
                       "pid1: argv[1] (%s) is not an absolute path, "
                       "using %s", argv[1], emacs_path);
        console(msg);
    }
    /* same '/' guard as argv[1]: argv[2] (module path) and argv[3]
     * (Xorg spec) are absolute by construction when the guix gexp is
     * the caller, and we must reject sysvinit-style runlevel tokens
     * that /hurd/startup would otherwise drop here. */
    if (argc > 2 && argv[2] && argv[2][0] == '/') {
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
    if (argc > 3 && argv[3] && argv[3][0] == '/') {
        /* parse_xorg_spec mutates argv[3] in place. argv[3] points
         * into either the kernel-supplied region or init_args_buf
         * (when the v0.9.11 synth_argv path fired); both are
         * writable for the lifetime of pid1, so the in-place mutate
         * is safe either way. */
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

    /* pseudo-filesystems the kernel does not mount on its own.
     *
     * Linux vs Hurd divergence (see docs/ARCHITECTURE.md Level 3 and
     * docs/runlogs/2026-05-18-hurd-pid1-boot-design.md): on Linux we
     * mount proc/sysfs/devtmpfs/devpts plus the two tmpfs trees.  on
     * Hurd /proc is already a translator (/hurd/procfs), /sys does
     * not exist as a tree, and devtmpfs/devpts are not Hurd
     * filesystems, so attempting any of those four would just burn a
     * log line on every boot for no gain.  /run and /tmp stay because
     * port->mount routes those through the Hurd translator path that
     * the 2026-05-17 runtime sweep promoted to YES in HURD_PORT.md. */
#ifdef PORT_HURD
    /* / boots read-only on Debian GNU/Hurd; checkroot.sh would normally
     * fsysopts-remount it rw but we replaced /sbin/init so it never
     * runs.  do the flip ourselves before the mount block, otherwise
     * every tmpfs mount EIO's and sethostname EROFS's.  see v0.9.11
     * VM-verify round 8 and docs/runlogs/2026-05-18-hurd-pid1-boot-
     * result.md.  log and continue on failure: degraded boot beats no
     * boot.
     *
     * invariant for the call site: port is non-NULL (port_require_or_-
     * abort has run by here), console() is wired (the banner two
     * blocks up already used it), umask is set; no other state is
     * required.  do not move this above port_require_or_abort. */
    if (port->remount_root_rw() < 0) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "pid1: remount-rw / failed: %s (mount block will degrade)",
                 strerror(errno));
        console(buf);
    } else {
        console("pid1: / remounted read-write");
    }
#endif
#ifndef PORT_HURD
    do_mount("proc",     "/proc",    "proc",     MS_NOSUID|MS_NOEXEC|MS_NODEV, NULL);
    do_mount("sysfs",    "/sys",     "sysfs",    MS_NOSUID|MS_NOEXEC|MS_NODEV, NULL);
    do_mount("devtmpfs", "/dev",     "devtmpfs", MS_NOSUID,                     "mode=0755");
#endif
    do_mount("tmpfs",    "/run",     "tmpfs",    MS_NOSUID|MS_NODEV,            "mode=0755");
    do_mount("tmpfs",    "/tmp",     "tmpfs",    MS_NOSUID|MS_NODEV,            NULL);
#ifndef PORT_HURD
    do_mount("devpts",   "/dev/pts", "devpts",   MS_NOSUID|MS_NOEXEC,           "gid=5,mode=0620");
#endif

#ifdef PORT_HURD
    /* post-mount runtime-dir creation block.  this is where we put
     * back the Debian-postinst state that lived under /run on the
     * underlying ext2 and got occluded by the tmpfs mount above.
     * one entry today (sshd's privsep chroot); v0.9.12 will refactor
     * this into a table driven by an /etc/geos/tmpfiles.d-equivalent
     * once we have a second consumer (see task #168 in the runlog).
     *
     * /run/sshd, 0755 root:root, is openssh-server's privsep empty
     * chroot.  OpenSSH 10.x sshd-session calls chroot("/run/sshd") as
     * the very first step of its preauth sandbox, and a missing dir
     * fatals the child before the SSH banner ever goes out (caught
     * 2026-05-21 by v0.9.11 VM-verify round 6, auth.log "fatal:
     * chroot(...): No such file or directory [preauth]" on every
     * connection).  doing the mkdir here in C means it lands
     * deterministically before emacs even starts and we do not have
     * to litigate an elisp-side make-directory race against Hurd's
     * tmpfs translator (round 7 tried that and still failed).  EEXIST
     * is fine (idempotent on dev-loop re-runs), anything else just
     * logs and continues because pid1 not booting over one sshd-only
     * chroot dir is the wrong shape of failure. */
    if (mkdir("/run/sshd", 0755) < 0 && errno != EEXIST) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "pid1: mkdir /run/sshd failed: %s", strerror(errno));
        console(buf);
    } else {
        console("pid1: /run/sshd 0755 ready (openssh privsep chroot)");
    }
#endif

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

    /* v0.9.24 follow-on #7: install shutdown-signal handlers so the
     * supervisor knows not to respawn emacs after an external shutdown.
     * the kernel default-ignores SIGTERM / SIGUSR1 / SIGUSR2 for pid 1
     * unless a handler is installed, so without these three sigaction
     * calls the signals never reach on_shutdown_signal and the
     * shutting_down flag never gets set.  failures are NON-fatal here:
     * if sigaction fails we just keep the old behaviour (respawn after
     * shutdown, which pollutes the serial log but does not break the
     * box), so we log to /dev/console and continue rather than
     * _exit(127) the way the SIGCHLD branch above does. */
    {
        struct sigaction sashut;
        memset(&sashut, 0, sizeof sashut);
        sashut.sa_handler = on_shutdown_signal;
        /* no SA_RESTART for the same reason as SIGCHLD: we want
         * waitpid() to return EINTR so the supervisor loop reaches the
         * shutting_down check at the top of the for(;;) body. */
        sashut.sa_flags = 0;
        sigemptyset(&sashut.sa_mask);
        const int shut_sigs[] = { SIGTERM, SIGUSR1, SIGUSR2 };
        for (size_t i = 0; i < sizeof shut_sigs / sizeof shut_sigs[0]; i++) {
            if (sigaction(shut_sigs[i], &sashut, NULL) < 0) {
                char buf[128];
                snprintf(buf, sizeof buf,
                         "pid1: sigaction(shutdown sig=%d) failed: %s; "
                         "respawn-after-shutdown gate disabled",
                         shut_sigs[i], strerror(errno));
                console(buf);
            }
        }
    }

    /* boot mode toggle: cmdline geos.mode=console forces a pure-text
     * boot (no Xorg, emacs talks to /dev/console). default (no token,
     * or geos.mode=ui) keeps the v0.2 behaviour.  v0.4 item 10 adds
     * geos.mode=recovery: same Xorg suppression as console mode PLUS
     * the userland -l chain is gated by an env variable that
     * early-init.el reads to abort further loading.  clearing
     * xorg_path here also disables xorg_bring_up's respawn path so a
     * console- or recovery-mode boot never tries to start an X
     * server.  display_env stays NULL so spawn_emacs's envp does not
     * advertise a DISPLAY the user did not ask for.
     *
     * Hurd UI path (v0.9.8): on Hurd we boot Xvfb instead of a real
     * Xorg.  native Xorg on hurd-amd64 is blocked on the input-driver
     * gap (kbd_drv.so's "set event mode" ioctl returns EBADF against
     * /dev/cons/kbd and there is no evdev/libinput driver on the
     * hurd-amd64 package set; see docs/runlogs/2026-05-21-hurd-xorg-
     * probe.md probes E3/E4/I).  Xvfb works fully on Debian Hurd 0.9
     * (probes C+D: xdpyinfo against :99 returns 23 extensions
     * including RANDR/COMPOSITE/GLX), so the v0.9.8 default for a
     * Hurd UI boot is /usr/bin/Xvfb.  if argv[3] gave us an explicit
     * xorg spec it wins; otherwise we fall back to Xvfb at the
     * Debian default install path.  the existing spawn_xorg code
     * already detects Xvfb via path_ends_with and drops the
     * Xorg-specific flags. */
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

#ifdef PORT_HURD
    /* v0.9.8: if we are in UI mode on Hurd and the caller did not pass
     * an explicit Xorg spec via argv[3], default to /usr/bin/Xvfb (the
     * Debian Hurd 0.9 package path, 2:21.1.22-1 in the canonical
     * image).  the xkb / module / font / conf strings are all empty
     * because spawn_xorg detects Xvfb via path_ends_with("/Xvfb") and
     * skips every flag that only Xorg understands.  display_env is
     * set so spawn_emacs's envp advertises DISPLAY=:0.  receipt:
     * docs/runlogs/2026-05-21-hurd-xorg-probe.md probes C+D.
     *
     * (W6, skeptic 2026-05-21) access-check the Xvfb binary before
     * committing to spawn it.  if the operator removed the Debian
     * xvfb package from the Hurd image, leaving xorg_path pointing at
     * a non-existent binary would have spawn_xorg execve-fail in a
     * rapid loop until the supervisor's respawn cap tripped, with
     * only a one-line "execve failed" diagnostic to show for it.
     * cheaper to detect the gap here and fall back to console mode
     * with a clear console() line so the operator knows what
     * happened. */
    if (boot_mode == GEOS_MODE_UI && xorg_path == NULL) {
        if (access("/usr/bin/Xvfb", X_OK) == 0) {
            xorg_path = "/usr/bin/Xvfb";
            xorg_xkb_dir = "";
            xorg_module_path = "";
            xorg_font_path = "";
            xorg_conf_path = "";
            display_env = "DISPLAY=:0";
            console("pid1: Hurd UI default, spawning /usr/bin/Xvfb");
        } else {
            int access_err = errno;
            console("pid1: Hurd UI requested but /usr/bin/Xvfb not "
                    "executable, falling back to console mode "
                    "(install the xvfb package to enable UI)");
            (void)access_err;  /* errno already reported via the line above */
            xorg_path = NULL;
            xorg_disabled = 1;
            display_env = NULL;
            boot_mode = GEOS_MODE_CONSOLE;
            geos_mode_env = "GEOS_MODE=console";
        }
    }
#endif

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
        /* pre-Xorg diagnostic: kernel input device list + stable symlinks
         * for xorg-modesetting.conf (/run/geos/input-{kbd,ptr}). */
        dump_input_devices();
        setup_input_symlinks();
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
        /* v0.9.24 follow-on #7: short-circuit the respawn path on
         * shutdown.  on_shutdown_signal sets this flag from SIGTERM /
         * SIGUSR1 / SIGUSR2 (the conventional init shutdown signals).
         * without this gate, `shutdown -h now` killing the supervised
         * emacs would have us re-fork emacs into a doomed bringup
         * cycle (fresh pids, /var remount, supervise-autostart re-run)
         * that pollutes /dev/console while the kernel is on its way
         * out.  shape mirrors `emacs_holding` below: keep reaping
         * zombies so reparented children do not pile up, but never
         * fork emacs again.  we do NOT return from main(): the kernel
         * caller that initiated shutdown (or the operator via
         * geos-poweroff / geos-reboot) is responsible for the actual
         * halt syscall, and returning here would panic the kernel
         * unnecessarily on what would otherwise be a clean shutdown
         * window. */
        if (shutting_down) {
            static int announced = 0;
            if (!announced) {
                console("pid1: shutting down, not respawning emacs");
                announced = 1;
            }
            int st;
            pid_t z = waitpid(-1, &st, 0);
            if (z < 0 && errno == EINTR) continue;
            if (z < 0) {
                /* no children left at all (ECHILD); sleep so we are not
                 * spinning on the syscall, then loop back to await the
                 * halt that whoever signalled us is bringing. */
                sleep_at_least(5);
            }
            continue;
        }
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
#define RPC_HANDSHAKE_TIMEOUT_MS 1000

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
    /* slice 3 of v0.8 design-2.2: drain the design-2.2 auth port before
     * accepting any AF_UNIX connection.  on Linux the call is a one-line
     * return-0; on Hurd it pulls up to 16 mach messages off the libports
     * bucket bound to /servers/geos-auth, dispatching fsys_getroot and
     * geos_auth_submit_nonce.  ENOSYS means publish_auth_port has not
     * succeeded yet (or never will, on a backend that does not need a
     * separate channel); we silently skip in that case, same shape as
     * get_peer_cred's ENOSYS branch below.  any other errno is a real
     * failure on a backend that normally implements the drain, so still
     * surfaced via pid1_signal_errno. */
    if (port->auth_drain() < 0 && errno != ENOSYS) {
        return pid1_signal_errno(env, "pid1: rpc-poll: auth_drain", errno);
    }
    int conn = accept4(rpc_listen_fd, NULL, NULL, SOCK_CLOEXEC);
    if (conn < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return Qnil;
        return pid1_signal_errno(env, "pid1: rpc-poll: accept", errno);
    }
    /* blocking + timeout: bound the wedge time a slow client can cause.
     * SO_RCVTIMEO/SO_SNDTIMEO are POSIX-optional; Hurd's pflocal returns
     * ENOPROTOOPT (verified 2026-05-17 on Debian GNU/Hurd 2026-03).  on
     * a kernel that doesn't support the timeout, the read/write below
     * just block as long as the peer holds the connection open; that
     * removes a safety bound but is a degradation, not a correctness
     * bug, and it is strictly better than panicking the 200ms tick on
     * every client connection.  any other errno is a real failure on a
     * backend that normally implements the call, so still surfaced. */
    struct timeval tv;
    tv.tv_sec = RPC_TIMEOUT_SEC;
    tv.tv_usec = 0;
    if (setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0
        && errno != ENOPROTOOPT) {
        int err = errno;
        close(conn);
        return pid1_signal_errno(env, "pid1: rpc-poll: SO_RCVTIMEO", err);
    }
    if (setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv) < 0
        && errno != ENOPROTOOPT) {
        int err = errno;
        close(conn);
        return pid1_signal_errno(env, "pid1: rpc-poll: SO_SNDTIMEO", err);
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
    /* slice 5 of v0.8 design 2.2: mint a 16-byte rendezvous NONCE and
     * write it to the client before any other byte hits the wire.  the
     * client (rpc-client.el) reads exactly 16 bytes with
     * pid1-unix-recv-exactly, then passes them to
     * pid1-client-auth-handshake which uses them as the matching
     * identifier on the Hurd auth_user_authenticate dance.  on Linux
     * the bytes are read and discarded by the client; the supervisor's
     * Linux get_peer_cred backend ignores NONCE and continues to use
     * SO_PEERCRED.  the NONCE must arrive at the client before our
     * peer-cred read; the order is mint -> send -> get_peer_cred so the
     * Hurd backend's pending_auth[] lookup has a chance to find the
     * row the client has posted via the mach side channel.
     *
     * getentropy(2) is glibc-portable (Hurd's glibc ships it) and the
     * call is bounded to 256 bytes per the manpage, well above our 16.
     * a getentropy failure here is "the kernel ran out of entropy",
     * which on Linux is essentially never; treat it as a transient
     * client error (close the fd, return nil to the poller) rather
     * than panicking the 200ms tick.
     *
     * the send(2) uses MSG_NOSIGNAL so a client that disconnected
     * between accept and our first write does not raise SIGPIPE on
     * the supervisor.  short writes on a fresh SOCK_STREAM connection
     * with 16 bytes of payload should not happen on any sane kernel,
     * but we still check: a short write is treated as a client error
     * (close the fd, return nil) for the same reason as getentropy. */
    uint8_t nonce[16];
    if (getentropy(nonce, sizeof nonce) < 0) {
        close(conn);
        return Qnil;
    }
    /* gate the send: pflocal has no SO_SNDTIMEO, so a peer that never
     * read()s would block us for the full tick without this poll. */
    struct pollfd pfd = { .fd = conn, .events = POLLOUT };
    int pr = poll(&pfd, 1, RPC_HANDSHAKE_TIMEOUT_MS);
    if (pr <= 0 || !(pfd.revents & POLLOUT)) {
        static const char m[] =
            "pid1: rpc-poll: handshake poll timeout, dropping client\n";
        ssize_t r = write(2, m, sizeof m - 1); (void)r;
        close(conn);
        return Qnil;
    }
    ssize_t nw = send(conn, nonce, sizeof nonce, MSG_NOSIGNAL);
    if (nw != (ssize_t)sizeof nonce) {
        close(conn);
        return Qnil;
    }
    if (port->get_peer_cred(conn, nonce, &peer_uid, &peer_gid) < 0) {
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
    /* off-stack: 64 KiB per-call frame was the B3 skeptic flag from
     * v0.8.1.  static is safe here because emacs is single-threaded
     * (same justification as the warned_enosys flag above) and this
     * function is not reentrant: the only caller is rpc-server--tick's
     * `while pending` loop, which calls pid1-rpc-poll serially, and
     * nothing in this body funcalls back into user lisp before the
     * payload bytes are copied into v_pl via make_string.  trade-off:
     * 64 KiB BSS per supervisor (cheap, only touched pages commit) in
     * exchange for the stack-frame win. */
    static char payload[RPC_PAYLOAD_MAX];
    if (rpc_read_full(conn, payload, plen32) < 0) {
        int err = errno;
        close(conn);
        return pid1_signal_errno(env, "pid1: rpc-poll: read payload", err);
    }
    /* build the plist (:fd FD :uid U :gid G :payload "BYTES"). */
    emacs_value kw_fd      = env->intern(env, ":fd");
    emacs_value kw_uid     = env->intern(env, ":uid");
    emacs_value kw_gid     = env->intern(env, ":gid");
    emacs_value kw_payload = env->intern(env, ":payload");
    emacs_value v_fd  = env->make_integer(env, conn);
    emacs_value v_uid = env->make_integer(env, (intmax_t)peer_uid);
    emacs_value v_gid = env->make_integer(env, (intmax_t)peer_gid);
    emacs_value v_pl  = env->make_string(env, payload, (ptrdiff_t)plen32);
    /* gate before the funcall: OOM during make_string can leave a
     * non-local exit pending; without this check, funcall would run
     * with an exit already raised, which is undefined per the module
     * API.  out-of-range length cannot happen here because plen32
     * was already clamped to RPC_PAYLOAD_MAX above; OOM under
     * sustained pressure is the residual risk this check covers.
     * matches the same shape as the post-funcall check below. */
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) {
        close(conn);
        return Qnil;
    }
    emacs_value list_args[8] = {
        kw_fd, v_fd, kw_uid, v_uid, kw_gid, v_gid, kw_payload, v_pl
    };
    emacs_value plist = env->funcall(env, env->intern(env, "list"),
                                     8, list_args);
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

/* (pid1-client-auth-handshake FD &optional NONCE) -> t, or signal
 * pid1-error.
 *
 * the client-side counterpart of get_peer_cred.  on Linux this is a
 * single no-op return (no syscalls, no bytes on the wire); NONCE is
 * ignored.  on Hurd this triggers the rendezvous-port dance against
 * the gnumach auth server; the supervisor's drain reads the matching
 * submit_nonce message off /servers/geos-auth and uses NONCE to bind
 * the auth result to the right AF_UNIX connection.  the design
 * rationale is at docs/v08-hurd-peer-cred-design.md.
 *
 * slice 4 of v0.8 design-2.2 grew the binding to take NONCE as a
 * second arg.  it must be a 16-byte unibyte string; the elisp side
 * (rpc-client.el) reads it off the socket with pid1-unix-recv-exactly
 * immediately after connect.  shorter or longer strings get EINVAL.
 *
 * precondition on the caller: this binding must be invoked AFTER
 * pid1-unix-connect returns the fd AND BEFORE the first pid1-unix-send
 * on that fd, exactly once per RPC connection.  the call is
 * unconditional across kernels: branching on geos-kernel is the
 * port_caps's job, not the elisp caller's. */
static emacs_value
Fpid1_client_auth_handshake(emacs_env *env, ptrdiff_t nargs,
                            emacs_value *args, void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    /* arity 1 or 2: legacy callers on main pass FD only, slice 4
     * callers (rpc-client.el under the v0.8 supervisor wire change)
     * pass (FD NONCE).  the binding accepts both during the transition
     * window so a partial rebase between the hurd branch and main does
     * not strand either caller. */
    if (nargs != 1 && nargs != 2)
        return pid1_signal_errno(env,
                                 "pid1: client-auth-handshake: nargs",
                                 EINVAL);
    intmax_t fd_im = env->extract_integer(env, args[0]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (fd_im < 0 || fd_im > 0x7fffffff)
        return pid1_signal_errno(env,
                                 "pid1: client-auth-handshake: fd out of range",
                                 EINVAL);
    int fd = (int)fd_im;

    /* NONCE: unibyte string of exactly 16 bytes.  default is all-zero
     * when the caller did not supply one (legacy arity-1 path) since
     * Linux ignores it and Hurd does not yet have a multi-user caller
     * outside the freeze-test on the side branch. */
    uint8_t nbuf[16];
    memset(nbuf, 0, sizeof nbuf);
    if (nargs == 2) {
        ptrdiff_t need = 0;
        if (!env->copy_string_contents(env, args[1], NULL, &need))
            return pid1_signal_errno(env,
                                     "pid1: client-auth-handshake: nonce probe",
                                     EINVAL);
        if (need != 17)  /* 16 bytes + trailing NUL */
            return pid1_signal_errno(env,
                                     "pid1: client-auth-handshake: nonce len",
                                     EINVAL);
        char tmp[17];
        if (!env->copy_string_contents(env, args[1], tmp, &need))
            return pid1_signal_errno(env,
                                     "pid1: client-auth-handshake: nonce copy",
                                     EINVAL);
        memcpy(nbuf, tmp, 16);
    }
    if (port->client_auth_handshake(fd, nbuf) < 0)
        return pid1_signal_errno(env,
                                 "pid1: client-auth-handshake", errno);
    return env->intern(env, "t");
}

/* (pid1-publish-auth-port) -> t, or signal pid1-error with errno.
 *
 * one-shot.  the supervisor calls this once at startup, before the
 * first pid1-rpc-poll tick, to publish the long-lived auth Mach
 * port the design-2.2 handshake depends on.  Linux is a no-op
 * (SO_PEERCRED is server-side, no out-of-band channel to set up);
 * the Hurd backend opens a translator at /servers/geos-auth.  the
 * full design rationale lives at docs/v08-hurd-peer-cred-design.md
 * section 3.5.
 *
 * not yet wired into elisp callers; slice 2 of the v0.8 design-2.2
 * rollout lands the Hurd translator body, slice 3 wires the
 * supervisor's startup path to invoke this. */
static emacs_value
Fpid1_publish_auth_port(emacs_env *env, ptrdiff_t nargs,
                        emacs_value *args, void *data)
{
    (void)data; (void)args;
    if (nargs != 0)
        return pid1_signal_errno(env,
                                 "pid1: publish-auth-port: nargs",
                                 EINVAL);
    if (port->publish_auth_port() < 0) {
        /* W2: ENOSYS is "no auth port concept on this kernel" (Linux,
         * or a future backend that does not need one).  surface it
         * silently as t, matching the Fpid1_auth_drain convention.
         * panicking supervisor startup over a missing translator on a
         * kernel that does not need one is the worst possible failure
         * mode here. */
        if (errno == ENOSYS)
            return env->intern(env, "t");
        return pid1_signal_errno(env,
                                 "pid1: publish-auth-port", errno);
    }
    return env->intern(env, "t");
}

/* (pid1-auth-drain) -> t, or signal pid1-error with errno.
 *
 * slice 3 of v0.8 design-2.2.  drain pending Mach messages on the auth
 * port.  Linux is a no-op (no auth port to drain).  Hurd pulls up to a
 * small batch of messages off the libports bucket attached to
 * /servers/geos-auth and dispatches them via the chained fsys_server
 * + ports_notify_server + private geos_auth_submit_nonce demuxer.
 *
 * the supervisor's own pid1-rpc-poll calls port->auth_drain() at the
 * top of every tick; this elisp binding exists so a test harness or
 * an out-of-band drain can run the same code path explicitly without
 * waiting for the 200ms tick.  ENOSYS surfaces as t (silently skip),
 * matching the rpc-poll convention; every other errno is forwarded
 * as pid1-error so the freeze-tests can distinguish "no drain yet"
 * from "drain failed". */
static emacs_value
Fpid1_auth_drain(emacs_env *env, ptrdiff_t nargs,
                 emacs_value *args, void *data)
{
    (void)data; (void)args;
    if (nargs != 0)
        return pid1_signal_errno(env,
                                 "pid1: auth-drain: nargs",
                                 EINVAL);
    if (port->auth_drain() < 0) {
        if (errno == ENOSYS)
            return env->intern(env, "t");
        return pid1_signal_errno(env, "pid1: auth-drain", errno);
    }
    return env->intern(env, "t");
}

/* AF_UNIX client-side IO bindings for the v0.8 rpc-client rewrite.
 * the elisp side used to lean on make-network-process, which hides
 * the fd behind a process object so we cannot run the Hurd peer-cred
 * handshake against the same fd we will then send/recv on.  these
 * bindings give elisp the raw fd from socket() to close(), so the
 * existing pid1-client-auth-handshake (above) runs on a fd we own.
 *
 * the recv cap matches geos-rpc's 64 KiB sexp ceiling at
 * core/rpc-client.el; bumping one without the other lets the elisp
 * loop ask for more than C can hand back and the wire format breaks.
 * stack-allocated buffers only; the dynamic module shares the no-
 * malloc-in-hot-paths rule with the standalone PID 1 binary. */
#define PID1_UNIX_RECV_MAX (64 * 1024)

/* (pid1-unix-connect PATH) -> FD or signal pid1-error.
 * invariant: returns an open AF_UNIX SOCK_STREAM fd connected to PATH;
 * on any failure the fd, if it was opened, is closed before signalling. */
static emacs_value
Fpid1_unix_connect(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                   void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 1)
        return pid1_signal_errno(env, "pid1: unix-connect needs 1 arg",
                                 EINVAL);
    /* size probe + size-bounded copy; sun_path is 108 on Linux, the
     * usable slot is 107 chars + NUL, which extract_cstring_into
     * enforces via its bufsize check. */
    char path[sizeof ((struct sockaddr_un *)0)->sun_path];
    if (extract_cstring_into(env, args[0], path, sizeof path) < 0)
        return Qnil;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return pid1_signal_errno(env, "pid1: unix-connect: socket", errno);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    /* path is NUL-terminated and at most sizeof addr.sun_path - 1 long
     * because extract_cstring_into capped at sizeof path which equals
     * sizeof addr.sun_path; the terminator stays inside sun_path. */
    memcpy(addr.sun_path, path, strlen(path));
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        int err = errno;
        close(fd);
        return pid1_signal_errno(env, "pid1: unix-connect: connect", err);
    }
    return env->make_integer(env, fd);
}

/* (pid1-unix-send FD BYTES) -> N-written or signal pid1-error.
 * invariant: loops send(MSG_NOSIGNAL) until BYTES is drained or any
 * non-EINTR errno surfaces; MSG_NOSIGNAL is load-bearing because the
 * user-emacs has no SIGPIPE handler and a peer-closed socket would
 * otherwise kill the process. */
static emacs_value
Fpid1_unix_send(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 2)
        return pid1_signal_errno(env, "pid1: unix-send needs 2 args",
                                 EINVAL);
    intmax_t fd_im = env->extract_integer(env, args[0]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (fd_im < 0 || fd_im > 0x7fffffff)
        return pid1_signal_errno(env, "pid1: unix-send: fd out of range",
                                 EBADF);
    int fd = (int)fd_im;
    ptrdiff_t need = 0;
    if (!env->copy_string_contents(env, args[1], NULL, &need))
        return Qnil;
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    /* copy_string_contents reports N+1 to include the trailing NUL.
     * the wire payload excludes the NUL; the elisp caller pre-encodes
     * binary bytes into a unibyte string and we ship those bytes raw. */
    if (need < 1)
        return pid1_signal_errno(env, "pid1: unix-send: empty payload",
                                 EINVAL);
    size_t plen = (size_t)(need - 1);
    if (plen > PID1_UNIX_RECV_MAX)
        return pid1_signal_errno(env, "pid1: unix-send: payload too big",
                                 EMSGSIZE);
    char payload[PID1_UNIX_RECV_MAX + 1];
    if (!env->copy_string_contents(env, args[1], payload, &need))
        return Qnil;
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    size_t sent = 0;
    while (sent < plen) {
        ssize_t w = send(fd, payload + sent, plen - sent, MSG_NOSIGNAL);
        if (w < 0) {
            if (errno == EINTR) continue;
            return pid1_signal_errno(env, "pid1: unix-send: send", errno);
        }
        sent += (size_t)w;
    }
    return env->make_integer(env, (intmax_t)sent);
}

/* (pid1-unix-recv FD NMAX TIMEOUT-MS) -> unibyte-string or signal.
 * invariant: one recv() call (looped on EINTR) bounded by SO_RCVTIMEO;
 * a 0-byte return is the wire-format-poisoning EOF and surfaces as
 * ECONNRESET so the elisp side does not silently treat an empty
 * payload as a valid reply. */
static emacs_value
Fpid1_unix_recv(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 3)
        return pid1_signal_errno(env, "pid1: unix-recv needs 3 args",
                                 EINVAL);
    intmax_t fd_im = env->extract_integer(env, args[0]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (fd_im < 0 || fd_im > 0x7fffffff)
        return pid1_signal_errno(env, "pid1: unix-recv: fd out of range",
                                 EBADF);
    int fd = (int)fd_im;
    intmax_t nmax_im = env->extract_integer(env, args[1]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (nmax_im < 1 || nmax_im > PID1_UNIX_RECV_MAX)
        return pid1_signal_errno(env, "pid1: unix-recv: nmax out of range",
                                 EINVAL);
    intmax_t to_im = env->extract_integer(env, args[2]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (to_im < 0 || to_im > 3600000)
        return pid1_signal_errno(env, "pid1: unix-recv: timeout out of range",
                                 EINVAL);
    struct timeval tv;
    tv.tv_sec  = (time_t)(to_im / 1000);
    tv.tv_usec = (suseconds_t)((to_im % 1000) * 1000);
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0
        && errno != ENOPROTOOPT)
        return pid1_signal_errno(env, "pid1: unix-recv: SO_RCVTIMEO",
                                 errno);
    char buf[PID1_UNIX_RECV_MAX];
    ssize_t r;
    do {
        r = recv(fd, buf, (size_t)nmax_im, 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0)
        return pid1_signal_errno(env, "pid1: unix-recv: recv", errno);
    if (r == 0)
        return pid1_signal_errno(env, "pid1: unix-recv: peer closed",
                                 ECONNRESET);
    return env->make_unibyte_string(env, buf, (ptrdiff_t)r);
}

/* (pid1-unix-recv-exactly FD N TIMEOUT-MS) -> unibyte-string or signal.
 * invariant: loops recv() until N bytes are buffered or the socket
 * dies; saves the elisp side from reimplementing a partial-read loop
 * around the 4-byte length prefix + sexp body that geos-rpc reads. */
static emacs_value
Fpid1_unix_recv_exactly(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                        void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 3)
        return pid1_signal_errno(env, "pid1: unix-recv-exactly needs 3 args",
                                 EINVAL);
    intmax_t fd_im = env->extract_integer(env, args[0]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (fd_im < 0 || fd_im > 0x7fffffff)
        return pid1_signal_errno(env,
                                 "pid1: unix-recv-exactly: fd out of range",
                                 EBADF);
    int fd = (int)fd_im;
    intmax_t n_im = env->extract_integer(env, args[1]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (n_im < 1 || n_im > PID1_UNIX_RECV_MAX)
        return pid1_signal_errno(env,
                                 "pid1: unix-recv-exactly: n out of range",
                                 EINVAL);
    intmax_t to_im = env->extract_integer(env, args[2]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (to_im < 0 || to_im > 3600000)
        return pid1_signal_errno(env,
                                 "pid1: unix-recv-exactly: timeout out of range",
                                 EINVAL);
    struct timeval tv;
    tv.tv_sec  = (time_t)(to_im / 1000);
    tv.tv_usec = (suseconds_t)((to_im % 1000) * 1000);
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0
        && errno != ENOPROTOOPT)
        return pid1_signal_errno(env,
                                 "pid1: unix-recv-exactly: SO_RCVTIMEO",
                                 errno);
    char buf[PID1_UNIX_RECV_MAX];
    size_t want = (size_t)n_im;
    size_t got  = 0;
    while (got < want) {
        ssize_t r = recv(fd, buf + got, want - got, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            return pid1_signal_errno(env,
                                     "pid1: unix-recv-exactly: recv",
                                     errno);
        }
        if (r == 0)
            return pid1_signal_errno(env,
                                     "pid1: unix-recv-exactly: peer closed",
                                     ECONNRESET);
        got += (size_t)r;
    }
    return env->make_unibyte_string(env, buf, (ptrdiff_t)got);
}

/* (pid1-unix-close FD) -> t or signal pid1-error.
 * invariant: a -1 from close means EBADF (caller bug, signal loud)
 * or EIO on a dirty close of a buffered socket; both indicate the fd
 * lifecycle is wrong and should not be swallowed. */
static emacs_value
Fpid1_unix_close(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                 void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 1)
        return pid1_signal_errno(env, "pid1: unix-close needs 1 arg",
                                 EINVAL);
    intmax_t fd_im = env->extract_integer(env, args[0]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return Qnil;
    if (fd_im < 0 || fd_im > 0x7fffffff)
        return pid1_signal_errno(env, "pid1: unix-close: fd out of range",
                                 EBADF);
    int fd = (int)fd_im;
    if (close(fd) < 0)
        return pid1_signal_errno(env, "pid1: unix-close: close", errno);
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

/* (pid1-disk-size-bytes NAME) -> integer byte count or nil.
 * NAME is the bare block-device name (e.g. "sda", "wd0"), no "/dev/"
 * prefix.  on Linux dispatches to port->disk_size_bytes which reads
 * /sys/block/<NAME>/size and multiplies by 512.  the elisp consumers
 * in emacs-init/buffers/disks.el and emacs-init/install/disk.el
 * render nil as "?" in the size column, so a missing/unreadable disk
 * surfaces as a soft "?" instead of a panic.  this is a userland
 * read, not a privileged syscall whose failure should crash PID 1.
 *
 * the NAME_MAX dance: linux NAME_MAX is 255, sysfs block names are
 * much shorter (a typical "sda" is 3 bytes), the 256-byte buffer here
 * fits any legal name and rejects overlong input cleanly via
 * extract_cstring_into's ENAMETOOLONG branch.
 *
 * the INT64_MAX guard: env->make_integer takes intmax_t (signed
 * 64-bit on every platform we ship to), our out is uint64_t.  a disk
 * bigger than 2^63 bytes (~9.2 ZB) is not physically reachable today
 * but the cast would silently produce a negative integer on overflow,
 * which the elisp side would render as a nonsense size.  belt-and-
 * suspenders nil return matches the "nil = ?" convention. */
static emacs_value
Fpid1_disk_size_bytes(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                      void *data)
{
    (void)data;
    emacs_value Qnil = env->intern(env, "nil");
    if (nargs != 1)
        return pid1_signal_errno(env,
                                 "pid1: pid1-disk-size-bytes needs 1 arg",
                                 EINVAL);
    /* 256 covers NAME_MAX + NUL with one byte to spare; the port-layer
     * validator caps tighter anyway (200 bytes on linux). */
    char name[256];
    if (extract_cstring_into(env, args[0], name, sizeof name) < 0) {
        /* extract_cstring_into raises pid1-error on overflow via
         * pid1_signal_errno (ENAMETOOLONG).  this binding's documented
         * contract is "integer on success, nil on any failure" so the
         * elisp consumer can render "?" without a condition-case.  clear
         * the pending non-local exit before returning soft nil. */
        env->non_local_exit_clear(env);
        return Qnil;
    }
    uint64_t out = 0;
    if (port->disk_size_bytes(name, &out) < 0)
        return Qnil;
    /* defensive overflow check, see docstring above */
    if (out > (uint64_t)INT64_MAX)
        return Qnil;
    return env->make_integer(env, (intmax_t)out);
}

/* (pid1-arm-parent-death SIGNAL) -> t on success, raises pid1-error
 * on failure.  SIGNAL is an integer POSIX signal number (typically
 * SIGTERM = 15).  on Linux dispatches to port->arm_parent_death which
 * calls prctl(PR_SET_PDEATHSIG, SIGNAL).  on Hurd the slot returns -1
 * with errno=ENOSYS until the v0.9.9 MACH_NOTIFY_DEAD_NAME watcher-
 * thread lands; ENOSYS is surfaced as a pid1-error the caller is
 * expected to catch (defence-in-depth, not load-bearing).
 *
 * CAVEAT: this changes the calling process's state.  prctl arms the
 * pdeathsig against THIS process's parent, so calling it from the
 * supervisor emacs would set up a death-link from the supervisor to
 * pid1.  the intended call site is the post-fork child inside
 * spawn_xorg() (which calls port->arm_parent_death directly without
 * going through this binding).  the binding exists so the slot is
 * testable and the dispatch table is exercised; callers from elisp
 * MUST know what they are doing.  the freeze-test file
 * iso-build/freeze-tests/freeze-test-arm-parent-death.el is the
 * documented caller. */
static emacs_value
Fpid1_arm_parent_death(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                       void *data)
{
    (void)data;
    if (nargs != 1)
        return pid1_signal_errno(env,
                                 "pid1: pid1-arm-parent-death needs 1 arg",
                                 EINVAL);
    intmax_t sig = env->extract_integer(env, args[0]);
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
        return env->intern(env, "nil");
    /* POSIX signal range is 1..NSIG-1.  on glibc Linux NSIG = 65 so the
     * inclusive upper bound is 64 (SIGRTMAX); SIGRTMIN is 34, the rest
     * of the range is the standard signals.  use NSIG so a future glibc
     * change is picked up automatically; the literal 64 was opaque (W2,
     * skeptic 2026-05-21).  the kernel will reject out-of-range on its
     * own with EINVAL, but a fast pre-check gives a clearer error
     * message and avoids the syscall round-trip on obviously bogus
     * input. */
    if (sig < 1 || sig > NSIG - 1)
        return pid1_signal_errno(env,
                                 "pid1: pid1-arm-parent-death: signal out of range",
                                 EINVAL);
    if (port->arm_parent_death((int)sig) < 0)
        return pid1_signal_errno(env, "pid1: arm-parent-death", errno);
    return env->intern(env, "t");
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
     * skeptic review 2026-05-12).  PORT_HURD is set on the cc line
     * by `make PORT=hurd module`; the Linux module build (default,
     * and the main branch) sees neither the #ifdef true-arm nor the
     * Hurd symbol. */
#ifdef PORT_HURD
    port = &port_hurd_impl;
#else
    port = &port_linux_impl;
#endif
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

    emacs_value dsb = env->make_function(env, 1, 1, Fpid1_disk_size_bytes,
        "Byte size of block device NAME (bare name, no \"/dev/\" prefix). "
        "Returns an integer on success, nil on any failure (the elisp "
        "side renders nil as \"?\" in the size column).  Linux: reads "
        "/sys/block/NAME/size and multiplies by 512.  Hurd: dispatches "
        "to file_get_storage_info on the storeio file_t (side branch).",
        NULL);
    pid1_defalias(env, "pid1-disk-size-bytes", dsb);

    emacs_value apd = env->make_function(env, 1, 1, Fpid1_arm_parent_death,
        "Arm a \"die when parent dies\" link on THIS process.  SIGNAL is "
        "an integer POSIX signal number (typically SIGTERM = 15) the "
        "kernel will deliver when the parent dies.  Linux: dispatches to "
        "prctl(PR_SET_PDEATHSIG).  Hurd: returns ENOSYS until v0.9.9 "
        "wires the MACH_NOTIFY_DEAD_NAME watcher thread.  CAVEAT: this "
        "mutates the calling process's state; the intended call site is "
        "the post-fork child inside pid1's own spawn paths, which calls "
        "the port slot directly without going through this binding.  the "
        "binding exists so the slot is testable from elisp.",
        NULL);
    pid1_defalias(env, "pid1-arm-parent-death", apd);

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

    emacs_value cah = env->make_function(env, 1, 2,
        Fpid1_client_auth_handshake,
        "Run the client-side auth handshake for an open RPC socket FD. "
        "Optional NONCE is a 16-byte unibyte string the elisp side read "
        "off the socket immediately after connect (required on Hurd "
        "for multi-user; default all-zero on Linux).  On Linux this is "
        "a no-op (SO_PEERCRED is server-side; NONCE is ignored).  On "
        "Hurd this performs the rendezvous-port + auth_user_authenticate "
        "dance against the gnumach auth server.  Return t.",
        NULL);
    pid1_defalias(env, "pid1-client-auth-handshake", cah);

    emacs_value pap = env->make_function(env, 0, 0,
        Fpid1_publish_auth_port,
        "Publish the supervisor's long-lived auth Mach port (one-shot, "
        "call from supervisor startup before the first pid1-rpc-poll). "
        "Linux no-op.  Hurd opens a translator at /servers/geos-auth.",
        NULL);
    pid1_defalias(env, "pid1-publish-auth-port", pap);

    emacs_value ad = env->make_function(env, 0, 0,
        Fpid1_auth_drain,
        "Drain pending Mach messages on the design-2.2 auth port.  "
        "Linux no-op.  Hurd dispatches fsys_getroot and "
        "geos_auth_submit_nonce off the libports bucket attached to "
        "/servers/geos-auth.  Return t.",
        NULL);
    pid1_defalias(env, "pid1-auth-drain", ad);

    emacs_value uc = env->make_function(env, 1, 1, Fpid1_unix_connect,
        "Open an AF_UNIX SOCK_STREAM and connect to PATH.  Return FD.",
        NULL);
    pid1_defalias(env, "pid1-unix-connect", uc);

    emacs_value us = env->make_function(env, 2, 2, Fpid1_unix_send,
        "Send BYTES on FD with MSG_NOSIGNAL.  Return bytes written.",
        NULL);
    pid1_defalias(env, "pid1-unix-send", us);

    emacs_value ur = env->make_function(env, 3, 3, Fpid1_unix_recv,
        "Recv up to NMAX bytes from FD with SO_RCVTIMEO of TIMEOUT-MS. "
        "Return a unibyte string.  Peer close signals ECONNRESET.",
        NULL);
    pid1_defalias(env, "pid1-unix-recv", ur);

    emacs_value urx = env->make_function(env, 3, 3, Fpid1_unix_recv_exactly,
        "Recv exactly N bytes from FD with SO_RCVTIMEO of TIMEOUT-MS. "
        "Return a unibyte string.  Short read signals ECONNRESET.",
        NULL);
    pid1_defalias(env, "pid1-unix-recv-exactly", urx);

    emacs_value ucl = env->make_function(env, 1, 1, Fpid1_unix_close,
        "Close FD.  Return t.  Errors surface so caller bugs are loud.",
        NULL);
    pid1_defalias(env, "pid1-unix-close", ucl);

    /* provide the feature so (require 'pid1-module) works after
     * (module-load ...) without a separate elisp wrapper. */
    emacs_value feat_args[1] = { env->intern(env, "pid1-module") };
    (void)env->funcall(env, env->intern(env, "provide"), 1, feat_args);

    return 0;
}

#endif /* PID1_MODULE */
