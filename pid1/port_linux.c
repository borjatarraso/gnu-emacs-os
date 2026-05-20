/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* port_linux.c, the Linux backend for port_layer.h.
 *
 * every function here used to live in emacs-init.c as a raw_*
 * helper.  the move is verbatim: same body, same errno handling,
 * same fd-leak discipline.  the only change is that the wrappers
 * are now leaves of port_linux_impl instead of static functions in
 * the main translation unit.  if you find yourself diffing this
 * against an old emacs-init.c and seeing nothing of substance,
 * good: that is the point of step 1 of the Hurd port (see
 * docs/v04-item11-hurd-spike.md).
 *
 * invariants shared by every body in this file:
 *
 *   - return 0 on success, -1 on failure with errno set.
 *   - never leak the socket fd on any branch; even though the kernel
 *     would close it on process exit, PID 1 never exits, so a leak
 *     is forever.
 *   - read-modify-write on flag fields: clobbering NOARP or PROMISC
 *     is how you silently break debug setups; preserve and OR.
 *   - no malloc.  every byte of state is on the caller's stack or
 *     in a sub-IFNAMSIZ local.
 */

#define _GNU_SOURCE
#include "port_layer.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

/* low-level mount wrapper used by both compile modes.  caller is
 * root; returns 0 on success, -1 with errno set on failure.  the
 * boot path adds a defensive mkdir on top, the module path exposes
 * this directly to elisp and lets the caller decide. */
static int
linux_mount(const char *src, const char *tgt, const char *type,
            unsigned long flags, const char *opts)
{
    return mount(src, tgt, type, flags, opts);
}

/* sethostname wrapper.  returns 0 on success, -1 with errno set on
 * failure.  the caller has already trimmed and validated NAME; we
 * just forward to the kernel. */
static int
linux_set_hostname(const char *name, size_t len)
{
    return sethostname(name, len);
}

/* brings up the loopback interface via ioctl.  touches no other
 * iface.  fd is always closed on every exit path. */
static int
linux_bring_up_lo(void)
{
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifreq r;
    memset(&r, 0, sizeof r);
    /* IFNAMSIZ is 16 on linux; "lo" is 3 bytes incl. NUL.  memcpy +
     * explicit terminator instead of strncpy: if a future change
     * extends this to a longer name, strncpy can leave the field
     * un-NUL-terminated when the source is exactly IFNAMSIZ long, and
     * the audit caught it as a latent trap. */
    memcpy(r.ifr_name, "lo", 3);
    r.ifr_name[IFNAMSIZ - 1] = '\0';
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

/* assign IPv4 address + netmask to IFNAME and bring it up.  ADDR_BE
 * is in network byte order; PREFIX is the CIDR length 0..32 from
 * which the netmask is computed.  invariant: SIOCSIFADDR before
 * SIOCSIFNETMASK before flags-up; the kernel rejects netmask before
 * address with EADDRNOTAVAIL on some 5.x trees. */
static int
linux_set_address(const char *ifname, uint32_t addr_be, int prefix)
{
    if (prefix < 0 || prefix > 32) { errno = EINVAL; return -1; }
    size_t nlen = strnlen(ifname, IFNAMSIZ);
    if (nlen == 0 || nlen >= IFNAMSIZ) { errno = EINVAL; return -1; }
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifreq r;
    memset(&r, 0, sizeof r);
    memcpy(r.ifr_name, ifname, nlen);
    r.ifr_name[IFNAMSIZ - 1] = '\0';
    struct sockaddr_in *sin = (struct sockaddr_in *)&r.ifr_addr;
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = addr_be;
    if (ioctl(s, SIOCSIFADDR, &r) < 0) {
        int saved = errno; (void)close(s); errno = saved; return -1;
    }
    /* prefix == 0 special-cased: shift by 32 on a 32-bit value is
     * undefined behavior in C, and -Wshift-count-overflow would
     * notice on a constant. */
    uint32_t mask_host = (prefix == 0)
        ? 0u
        : (uint32_t)(0xFFFFFFFFu << (32 - prefix));
    sin->sin_addr.s_addr = htonl(mask_host);
    if (ioctl(s, SIOCSIFNETMASK, &r) < 0) {
        int saved = errno; (void)close(s); errno = saved; return -1;
    }
    /* read-modify-write: preserve whatever flags the kernel had set
     * and only OR in UP|RUNNING.  clobbering flags is how you
     * accidentally drop NOARP or PROMISC. */
    if (ioctl(s, SIOCGIFFLAGS, &r) < 0) {
        int saved = errno; (void)close(s); errno = saved; return -1;
    }
    r.ifr_flags |= IFF_UP | IFF_RUNNING;
    if (ioctl(s, SIOCSIFFLAGS, &r) < 0) {
        int saved = errno; (void)close(s); errno = saved; return -1;
    }
    (void)close(s);
    return 0;
}

/* install a default IPv4 route via GW_BE through IFNAME.  SIOCADDRT
 * with rt_dst=0/0 is the kernel's idiom for "default gateway".  if a
 * default route already exists this returns -1 with errno=EEXIST;
 * caller decides whether to delete-then-add or surface the error. */
static int
linux_set_route_default(uint32_t gw_be, const char *ifname)
{
    if (!ifname) { errno = EINVAL; return -1; }
    size_t nlen = strnlen(ifname, IFNAMSIZ);
    if (nlen == 0 || nlen >= IFNAMSIZ) { errno = EINVAL; return -1; }
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct rtentry rt;
    memset(&rt, 0, sizeof rt);
    struct sockaddr_in *dst  = (struct sockaddr_in *)&rt.rt_dst;
    struct sockaddr_in *gw   = (struct sockaddr_in *)&rt.rt_gateway;
    struct sockaddr_in *mask = (struct sockaddr_in *)&rt.rt_genmask;
    dst->sin_family  = AF_INET;
    dst->sin_addr.s_addr = 0;
    mask->sin_family = AF_INET;
    mask->sin_addr.s_addr = 0;
    gw->sin_family   = AF_INET;
    gw->sin_addr.s_addr = gw_be;
    rt.rt_flags  = RTF_UP | RTF_GATEWAY;
    rt.rt_metric = 1;
    /* rt_dev is char *, not const char *, in the kernel ABI.  cast
     * is intentional and the buffer outlives the ioctl call.  zero the
     * whole IFNAMSIZ tail first: nlen < IFNAMSIZ here so the trailing
     * bytes would otherwise carry whatever the stack had when we
     * entered.  the kernel reads up to the first NUL, so this is
     * defence in depth rather than a current-bug fix (W1). */
    char ifbuf[IFNAMSIZ];
    memset(ifbuf, 0, sizeof ifbuf);
    memcpy(ifbuf, ifname, nlen);
    ifbuf[nlen] = '\0';
    rt.rt_dev = ifbuf;
    if (ioctl(s, SIOCADDRT, &rt) < 0) {
        int saved = errno; (void)close(s); errno = saved; return -1;
    }
    (void)close(s);
    return 0;
}

/* sync + reboot(2) wrapper.  CMD is one of RB_POWER_OFF or
 * RB_AUTOBOOT.  on success the kernel kills every process including
 * the caller, so a successful return is unreachable; we set errno
 * and return -1 only when reboot itself fails (typically EPERM if
 * CAP_SYS_BOOT was dropped).  sync() flushes dirty pages first;
 * cheap, and cheap insurance against losing /var writes. */
static int
linux_reboot_cmd(int cmd)
{
    sync();
    return reboot(cmd);
}

/* write STATE + newline to /sys/power/state; the kernel parses up to
 * the first newline.  write(2) returns when the kernel has finished
 * resuming, so a 0 return means we are awake again on the other side.
 * sync() up front so any pending /var/emacs writes hit disk before
 * the platform stops the CPU.
 *
 * (B1, skeptic review 2026-05-12) the prior version had a short-write
 * bug: when the first write returned w >= 0 with w != len, the inner
 * branch set err = EIO via `else if`, then fell through to the second
 * write which could succeed (w = w2 = 1) and mask the truncation; the
 * outer `if (w < 0)` then never fired and the function returned 0 on
 * a request the kernel never parsed.  the bug pre-existed in
 * raw_suspend, the relocation only exposed it.  the fix: sysfs
 * accepts the whole token in one write or none, so any short write is
 * a hard failure.  no loop, no second chance; close, set errno=EIO,
 * return -1. */
static int
linux_suspend(const char *state)
{
    sync();
    int fd = open("/sys/power/state", O_WRONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    size_t len = strlen(state);
    ssize_t w = write(fd, state, len);
    if (w < 0) {
        int err = errno;
        (void)close(fd);
        errno = err;
        return -1;
    }
    if ((size_t)w != len) {
        (void)close(fd);
        errno = EIO;
        return -1;
    }
    ssize_t w2 = write(fd, "\n", 1);
    if (w2 < 0) {
        int err = errno;
        (void)close(fd);
        errno = err;
        return -1;
    }
    if (w2 != 1) {
        (void)close(fd);
        errno = EIO;
        return -1;
    }
    if (close(fd) < 0)
        return -1;
    return 0;
}

/* peer credentials over AF_UNIX; SO_PEERCRED returns the kernel's
 * recorded ucred snapshot from the peer's connect() instant.  the
 * full contract lives in port_layer.h; see there for Hurd semantics
 * and the supervisor's ENOSYS handling.
 *
 * slice 5 of v0.8 design 2.2 grew this signature to take the 16-byte
 * NONCE the supervisor wrote to the client on accept.  the Linux body
 * ignores it; SO_PEERCRED is a server-side query that does not need
 * any client cooperation.  (void)nonce keeps -Wunused-parameter
 * -Werror quiet. */
static int
linux_get_peer_cred(int fd, const uint8_t nonce[16],
                    uint32_t *uid_out, uint32_t *gid_out)
{
    (void)nonce;
    struct ucred peer;
    socklen_t plen = sizeof peer;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &plen) < 0)
        return -1;
    if (uid_out) *uid_out = (uint32_t)peer.uid;
    if (gid_out) *gid_out = (uint32_t)peer.gid;
    return 0;
}

/* client-side auth handshake.  the Linux peer-cred model is entirely
 * server-side (the supervisor reads SO_PEERCRED), so the client has
 * literally nothing to do here: no syscalls, no port allocations, no
 * wire bytes.  the function exists so the elisp rpc-client.el can
 * unconditionally call `pid1-client-auth-handshake' right after
 * connect(2) without having to branch on kernel; on Hurd the same
 * call performs the rendezvous-port dance against the auth server.
 *
 * slice 4 of v0.8 design-2.2 grew this signature to take a 16-byte
 * NONCE arg matching the Hurd backend's needs (the elisp side reads
 * the supervisor-minted nonce off the socket before calling the
 * handshake).  Linux ignores it; the (void) casts on FD + NONCE are
 * the standard -Wunused-parameter -Werror dance for a stub that
 * genuinely ignores its arguments. */
static int
linux_client_auth_handshake(int fd, const uint8_t nonce[16])
{
    (void)fd;
    (void)nonce;
    return 0;
}

/* publish the long-lived auth Mach port the design-2.2 handshake
 * needs.  Linux is a no-op: SO_PEERCRED is server-side and the
 * supervisor reads it directly off the AF_UNIX fd at accept(),
 * no out-of-band channel to set up.  the slot exists so the
 * elisp side can call `pid1-publish-auth-port' unconditionally
 * at supervisor startup; the Hurd backend opens a translator at
 * /servers/geos-auth (see port_layer.h docstring). */
static int
linux_publish_auth_port(void)
{
    return 0;
}

/* slice 3 of v0.8 design-2.2: drain pending messages on the auth port.
 * Linux has no auth port; no-op. */
static int
linux_auth_drain(void)
{
    return 0;
}

/* byte size of block device NAME by reading /sys/block/<name>/size.
 * sysfs publishes the value in 512-byte sectors regardless of the
 * physical sector size (the ABI doc spells this out at
 * Documentation/ABI/stable/sysfs-block), so the 512 multiplier is the
 * stable contract.  uint64_t for the multiply because a 16 TB disk
 * has ~3.1e10 sectors and uint32_t * 512 wraps somewhere past 8 TB.
 *
 * NAME validation: bare device names only, no NULL, no empty string,
 * no '/' or "..".  the elisp caller already extracted a bare name from
 * a /dev/ scan; the check here is defence in depth so a future
 * callsite that grew a "/dev/" prefix can't escape into arbitrary
 * sysfs paths.  the explicit ".." reject also covers the case where
 * a synthetic NAME of ".." or ".." would otherwise resolve up the
 * sysfs tree to something unrelated.  EINVAL on bad input.
 *
 * the fd is closed on every exit path; PID 1 never exits, so a fd
 * leak is forever. */
static int
linux_disk_size_bytes(const char *name, uint64_t *out)
{
    if (!name || !out) { errno = EINVAL; return -1; }
    size_t nlen = strlen(name);
    if (nlen == 0) { errno = EINVAL; return -1; }
    /* NAME_MAX on linux is 255, but sysfs block names cap much shorter.
     * cap at 200 here so the snprintf below into a 4096 buffer is
     * trivially safe and a runaway caller hitting us with a 4-KiB
     * "name" gets a clean EINVAL instead of a truncated path. */
    if (nlen > 200) { errno = EINVAL; return -1; }
    /* reject anything that looks like a path component.  '/' is the
     * obvious one; ".." would let a caller climb out of /sys/block
     * (e.g. NAME="..", path becomes "/sys/block/../size" which is
     * "/sys/size"); leading '.' alone is fine because sysfs has no
     * dotfiles in /sys/block but we still reject ".." outright. */
    if (strchr(name, '/') != NULL) { errno = EINVAL; return -1; }
    if (strcmp(name, "..") == 0 || strcmp(name, ".") == 0) {
        errno = EINVAL; return -1;
    }

    char path[4096];
    int pn = snprintf(path, sizeof path, "/sys/block/%s/size", name);
    if (pn < 0 || (size_t)pn >= sizeof path) {
        /* snprintf truncated; treat as EINVAL.  with the 200-byte cap
         * above this branch is unreachable today, but leave the check
         * in so a future cap bump can't ship a silent truncation. */
        errno = EINVAL;
        return -1;
    }

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;  /* open's errno (ENOENT, EACCES, ...) */

    /* /sys/block/<name>/size is a single decimal number plus newline.
     * a 64-bit count tops out at 20 digits; 32 bytes is a comfortable
     * cap that catches "someone wrote garbage into the sysfs node"
     * without overflowing the stack buffer.
     *
     * pid1 has live signal handlers (SIGCHLD reaper at minimum) so a
     * single read() can return short with EINTR or just a partial
     * count.  loop until EOF or buffer-full, accumulating; treat
     * "filled the cap without EOF" as malformed sysfs content (EIO). */
    char buf[32];
    size_t total = 0;
    for (;;) {
        if (total >= sizeof buf - 1) {
            /* 31 bytes of digits is already past any sane sysfs size
             * token.  refuse to keep reading. */
            (void)close(fd);
            errno = EIO;
            return -1;
        }
        ssize_t r = read(fd, buf + total, sizeof buf - 1 - total);
        if (r < 0) {
            if (errno == EINTR) continue;
            int saved = errno;
            (void)close(fd);
            errno = saved;
            return -1;
        }
        if (r == 0) break;
        total += (size_t)r;
    }
    (void)close(fd);
    if (total == 0) { errno = EIO; return -1; }
    buf[total] = '\0';

    /* strtoull is the right tool: it sets errno=ERANGE on overflow and
     * gives us an endptr so we can confirm we consumed the whole token.
     * sysfs writes "<decimal>\n", so the legal terminator set is
     * "\n" or "\0".  anything else is parse failure. */
    errno = 0;
    char *endp = NULL;
    unsigned long long sectors = strtoull(buf, &endp, 10);
    if (errno != 0) {
        /* ERANGE from strtoull, surface as EIO (the value is parseable
         * but doesn't fit; both meanings are "sysfs gave us junk"). */
        errno = EIO;
        return -1;
    }
    if (endp == buf) { errno = EIO; return -1; }  /* no digits at all */
    /* skip a single trailing newline if present, then require NUL */
    if (*endp == '\n') endp++;
    if (*endp != '\0') { errno = EIO; return -1; }

    /* 512-byte sectors.  do the multiply in uint64_t so a 16-TB disk
     * (32 Gi sectors) does not wrap.  strtoull is unsigned long long,
     * cast to uint64_t before the multiply is paranoia on platforms
     * where unsigned long long is wider than 64 bits (none we ship to
     * today, but the cost is zero). */
    *out = (uint64_t)sectors * (uint64_t)512;
    return 0;
}

/* the table.  one assignment per slot, no NULLs.  the Hurd backend
 * will provide a parallel const port_caps port_hurd_impl with the
 * same shape. */
const port_caps port_linux_impl = {
    .kernel_name           = "linux",
    .mount                 = linux_mount,
    .set_hostname          = linux_set_hostname,
    .bring_up_lo           = linux_bring_up_lo,
    .set_address           = linux_set_address,
    .set_route_default     = linux_set_route_default,
    .reboot                = linux_reboot_cmd,
    .suspend               = linux_suspend,
    .get_peer_cred         = linux_get_peer_cred,
    .client_auth_handshake = linux_client_auth_handshake,
    .publish_auth_port     = linux_publish_auth_port,
    .auth_drain            = linux_auth_drain,
    .disk_size_bytes       = linux_disk_size_bytes,
};

/* the active pointer.  starts NULL; main() and emacs_module_init()
 * must assign &port_linux_impl (or the Hurd equivalent) exactly once
 * before any port-> call.
 *
 * (B2, skeptic review 2026-05-12) the prior version defaulted this to
 * &port_linux_impl "so a caller that forgets to set it explicitly
 * still gets a working system".  that is exactly the footgun the
 * Hurd port needs to avoid: a Hurd-on-Mach build that forgets to
 * register port_hurd_impl would silently run with Linux syscall
 * wrappers, which would either fail with confusing errnos or, worse,
 * appear to succeed against whatever syscalls the Hurd glibc
 * translates.  NULL means "fail loud at first deref" and the loud
 * fail lives in port_require_or_abort below. */
const port_caps *port = NULL;

/* call this once at startup from main() / emacs_module_init() after
 * assigning `port`.  enforces the "exactly one assignment before any
 * port-> call" invariant declared in port_layer.h.  on failure we
 * abort instead of trying to recover: a missing port table is a
 * build-config bug, not a runtime condition, and the only safe move
 * from PID 1 is to crash early enough that the kernel still has
 * /dev/console open. */
void
port_require_or_abort(void)
{
    if (port == NULL) {
        /* write directly: console() lives in emacs-init.c behind
         * !PID1_MODULE, and from here we cannot tell which TU we are
         * linked into.  the message is what the post-mortem needs to
         * see; the abort() that follows is what the kernel needs to
         * panic on cleanly. */
        static const char m[] =
            "pid1: port table not registered before first call; aborting\n";
        ssize_t r = write(2, m, sizeof m - 1); (void)r;
        abort();
    }
    /* (skeptic N2) a backend that forgets `.kernel_name = ...` in its
     * designated-initializer table would zero the slot to NULL.  glibc's
     * snprintf("%s", NULL) yields "(null)" on most builds, and the elisp
     * side would intern the symbol `(null)` for `geos-kernel'; that is
     * silent corruption of the very identity port_caps exists to make
     * authoritative.  catch it here with the same loud-and-early posture
     * as the NULL-port check above. */
    if (port->kernel_name == NULL) {
        static const char m[] =
            "pid1: port table has NULL kernel_name; backend init bug, "
            "aborting\n";
        ssize_t r = write(2, m, sizeof m - 1); (void)r;
        abort();
    }
}
