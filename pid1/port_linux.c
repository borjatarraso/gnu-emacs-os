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
     * is intentional and the buffer outlives the ioctl call. */
    char ifbuf[IFNAMSIZ];
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
 * the platform stops the CPU. */
static int
linux_suspend(const char *state)
{
    sync();
    int fd = open("/sys/power/state", O_WRONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    size_t len = strlen(state);
    ssize_t w = write(fd, state, len);
    int err = errno;
    if (w >= 0) {
        ssize_t w2 = write(fd, "\n", 1);
        if (w2 < 0) err = errno;
        else if ((size_t)w != len) err = EIO;
        else w = w2;
    }
    int c = close(fd);
    if (w < 0) {
        errno = err;
        return -1;
    }
    if (c < 0)
        return -1;
    return 0;
}

/* the table.  one assignment per slot, no NULLs.  the Hurd backend
 * will provide a parallel const port_caps port_hurd_impl with the
 * same shape. */
const port_caps port_linux_impl = {
    .mount             = linux_mount,
    .set_hostname      = linux_set_hostname,
    .bring_up_lo       = linux_bring_up_lo,
    .set_address       = linux_set_address,
    .set_route_default = linux_set_route_default,
    .reboot            = linux_reboot_cmd,
    .suspend           = linux_suspend,
};

/* the active pointer.  initialised to the Linux backend so a
 * caller that forgets to set it explicitly still gets a working
 * system; the boot path sets it again from main() as documentation
 * of intent, and the module path sets it from emacs_module_init()
 * for the same reason. */
const port_caps *port = &port_linux_impl;
