/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* port_hurd.c, the Hurd backend for port_layer.h.
 *
 * step 4 of the hurd port work order (docs/v04-item11-hurd-spike.md
 * lines 161-163) shipped mount + reboot + set_hostname.  step 5
 * (line 164: "port_hurd.c networking", ~2 weeks of pfinet RPC
 * learning curve) lands here: bring_up_lo, set_address, and
 * set_route_default route through Hurd's pfinet translator at
 * /servers/socket/2.  the suspend surface stays ENOSYS forever on
 * this port: Hurd has no /sys/power/state equivalent and the elisp
 * layer is supposed to render that as "not on this kernel".
 *
 * invariants shared by every body in this file:
 *
 *   - return 0 on success, -1 with errno set on failure.  same shape
 *     as port_linux.c so the supervisor-side callers do not branch on
 *     kernel.
 *   - mach kern_return_t values do NOT escape this file as errno.
 *     Hurd's glibc ships __hurd_fail which translates a kern_return_t
 *     into a POSIX errno; we go through that path so the elisp layer
 *     sees errnos it can render.
 *   - no malloc.  every byte of state is on the caller's stack.
 *
 * portability note: this file only ever compiles under -DPORT_HURD
 * (set by the Makefile when PORT=hurd).  the boot build on Linux
 * never links it.  the surfaces here use Hurd-only headers
 * (<hurd.h>, <mach.h>, <hurd/fsys.h>) so a stray inclusion on Linux
 * would fail loudly at the preprocessor; that is the intended fence.
 */

#define _GNU_SOURCE
#include "port_layer.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* POSIX networking headers.  Hurd's glibc ships these with the same
 * struct shapes as Linux's glibc (net/if.h: struct ifreq + IFNAMSIZ;
 * net/route.h: struct rtentry; netinet/in.h: struct sockaddr_in +
 * htonl).  the ioctl numbers (SIOCSIFFLAGS et al.) live in
 * <sys/ioctl.h> on Hurd as well; pfinet's iioctl-ops.c implements
 * exactly the SIOC* set Linux exposes, which is why the bodies below
 * read like the Linux backend with the link-line swapped.
 *
 * reference: hurd.git pfinet/iioctl-ops.c (S_iioctl_siocsifflags,
 * S_iioctl_siocsifaddr, S_iioctl_siocsifnetmask, S_iioctl_siocaddrt;
 * the ioctl mux in hurd/libtrivfs translates the userland ioctl(2)
 * to those RPCs transparently). */
#include <arpa/inet.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

/* Hurd-specific headers.  these only exist on a Hurd glibc toolchain.
 * a Linux build that accidentally pulled this TU in would fail at
 * preprocess time with "No such file or directory" against the first
 * one of these, which is the loud-failure we want. */
#include <hurd.h>
#include <hurd/fsys.h>
#include <hurd/process.h>
#include <mach.h>
#include <mach/mach_host.h>

/* mount(2) becomes "bind a translator" on Hurd.
 *
 * the Hurd does not have a single mount(2) syscall.  a "mount" is
 * "attach a translator program to a node".  the translator is what
 * answers filesystem RPCs against that subtree.  the canonical
 * translators ship under /hurd/:
 *
 *   /hurd/ext2fs    backing-store filesystem (mounts an ext2/3/4
 *                   partition; the on-disk format is the same one
 *                   Linux writes).  used for the root fs and for
 *                   any extra disk like /var.
 *   /hurd/tmpfs     in-memory filesystem.  used for /run and /tmp.
 *   /hurd/procfs    /proc translator.  exposes /proc/<pid>/* and
 *                   /proc/cmdline so the elisp layer's existing
 *                   readers keep working without a branch.
 *   /hurd/pfinet    TCP/IP stack as a translator at /servers/socket/2.
 *                   touched in step 5, not here.
 *
 * the RPC that attaches a translator is file_set_translator on the
 * target node's fsys port.  the arguments are:
 *
 *   - target node (a file port to the mount point directory)
 *   - the translator command line: argz-encoded vector, e.g.
 *     "/hurd/ext2fs\0/dev/hd0s1\0".  argz is glibc's null-separated
 *     string vector type.
 *   - active-flags: FS_TRANS_SET to install fresh, optionally
 *     FS_TRANS_FORCE if a translator is already there.
 *   - passive-flags: 0 for our purposes (we are not persisting
 *     the translator to disk metadata; pid1 reapplies on every
 *     boot).
 *
 * Hurd's libc wraps this in file_set_translator(); the higher-level
 * convenience is fshelp_start_translator() but that does its own
 * fork+exec dance which we do not want from PID 1.  we go with the
 * lower-level call.
 *
 * mapping the linux mount() arguments:
 *
 *   src   -> goes into the translator argv as argv[1].  ext2fs takes
 *            the block-device path; tmpfs ignores it; procfs ignores
 *            it.  if src is NULL we treat it as the empty argument.
 *   tgt   -> the mount point.  open(tgt, O_NOTRANS) gets us the file
 *            port to attach the translator to.
 *   type  -> tells us which /hurd/<X> binary to launch.  "ext4" maps
 *            to /hurd/ext2fs (same on-disk format, ext2fs handles
 *            ext4 read-write on Hurd).  "tmpfs" -> /hurd/tmpfs.
 *            "proc" -> /hurd/procfs.  any unknown type -> ENODEV.
 *   flags -> ignored for the v0.4 line.  MS_RDONLY etc. map to
 *            ext2fs argv flags ("--readonly") but pid1 today never
 *            passes MS_RDONLY so we leave that translation for the
 *            day it matters.
 *   opts  -> passed straight to the translator as a single extra
 *            argv entry when non-NULL.  ext2fs accepts a comma list
 *            in --options=...; pid1 does not use it today.
 *
 * step-4 scope: i implement the common cases (ext2fs/tmpfs/procfs)
 * directly with a small mach RPC, no fork+exec.  what i do NOT do
 * yet:
 *
 *   - MS_REMOUNT (Hurd: file_set_translator with FS_TRANS_FORCE +
 *     same argz).  pid1 only remounts once, on /var; the elisp side
 *     can re-call us with a fresh set of args.
 *   - unmount.  pid1 has no umount path today; if step 5 needs one
 *     it lands then.
 *
 * the body below is structured so the Mach call sites are explicit
 * and the error path goes through __hurd_fail which lives in
 * Hurd's libc and translates kern_return_t to errno for us. */
static int
hurd_mount(const char *src, const char *tgt, const char *type,
           unsigned long flags, const char *opts)
{
    (void)flags;
    if (!tgt || !type) { errno = EINVAL; return -1; }

    /* pick the translator binary from the linux-style type string.
     * the table is intentionally small: the boot path mounts /proc,
     * /sys (no-op on hurd, see below), /dev, /run, /tmp and /var, so
     * three translators cover every caller today.  unknown types
     * fall through to ENODEV which surfaces in pid1's log the same
     * way an unknown linux fs type would. */
    const char *trans_bin;
    if (strcmp(type, "ext2") == 0 || strcmp(type, "ext3") == 0 ||
        strcmp(type, "ext4") == 0) {
        trans_bin = "/hurd/ext2fs";
    } else if (strcmp(type, "tmpfs") == 0) {
        trans_bin = "/hurd/tmpfs";
    } else if (strcmp(type, "proc") == 0 || strcmp(type, "procfs") == 0) {
        trans_bin = "/hurd/procfs";
    } else if (strcmp(type, "sysfs") == 0) {
        /* hurd has no sysfs equivalent.  the elisp layer is supposed
         * to detect this via geos-port-unimplemented; from C we just
         * skip the mount.  return 0 so the supervisor does not panic
         * on the missing surface.  callers that actually need sysfs
         * data already branch on geos-kernel and will not look here. */
        return 0;
    } else if (strcmp(type, "devpts") == 0) {
        /* hurd's term translator covers /dev/pts.  for v0.4 we let
         * the existing /dev nodes serve and treat this as a no-op,
         * same shape as the sysfs case.  step 6 (smoke test) may
         * surface this as a missing pty path; we cross that bridge
         * when buffers/services actually need ptys on hurd. */
        return 0;
    } else {
        errno = ENODEV;
        return -1;
    }

    /* open the target node with O_NOTRANS so we get a port to the
     * UNDERLYING node rather than to whatever translator is already
     * sitting on it.  without O_NOTRANS attaching a new translator
     * would chain it behind the existing one, which is not what
     * "mount" means in the linux sense. */
    file_t target = file_name_lookup(tgt, O_NOTRANS, 0);
    if (target == MACH_PORT_NULL) {
        /* file_name_lookup sets errno via __hurd_fail on failure; the
         * MACH_PORT_NULL path means lookup itself bailed.  capture errno
         * immediately so any future logging/cleanup inserted between
         * here and the return cannot trash it.  matches the saved-errno
         * discipline of the ioctl error paths below. */
        int saved = errno;
        errno = saved;
        return -1;
    }

    /* build the translator argz: NUL-separated vector of strings
     * terminated by a double-NUL.  argv[0] = translator binary,
     * argv[1] = source (when non-empty), argv[2] = opts (when set).
     * we hand-build this on the stack: bounded at 4 KiB which covers
     * every plausible mount line. */
    char argz[4096];
    size_t argz_len = 0;
    size_t bin_len = strlen(trans_bin) + 1;
    if (bin_len > sizeof argz) {
        mach_port_deallocate(mach_task_self(), target);
        errno = E2BIG; return -1;
    }
    memcpy(argz, trans_bin, bin_len);
    argz_len = bin_len;
    if (src && src[0] != '\0') {
        size_t l = strlen(src) + 1;
        if (argz_len + l > sizeof argz) {
            mach_port_deallocate(mach_task_self(), target);
            errno = E2BIG; return -1;
        }
        memcpy(argz + argz_len, src, l);
        argz_len += l;
    }
    if (opts && opts[0] != '\0') {
        size_t l = strlen(opts) + 1;
        if (argz_len + l > sizeof argz) {
            mach_port_deallocate(mach_task_self(), target);
            errno = E2BIG; return -1;
        }
        memcpy(argz + argz_len, opts, l);
        argz_len += l;
    }

    /* file_set_translator wants two argz buffers: the "passive"
     * translator (stored on disk so it survives reboot) and the
     * "active" one (installed right now in memory).  we set the
     * active one with FS_TRANS_SET|FS_TRANS_FORCE so a stale
     * translator (e.g. from a previous boot attempt that did not
     * finish unmounting) gets replaced rather than chained behind.
     * passive flags are 0: pid1 reinstalls every translator at
     * every boot, baking a passive copy on disk would just create
     * skew between the system.scm intent and the on-disk state. */
    error_t rc = file_set_translator(target,
                                     0, FS_TRANS_SET | FS_TRANS_FORCE,
                                     0,
                                     argz, argz_len,
                                     MACH_PORT_NULL,
                                     MACH_MSG_TYPE_COPY_SEND);
    /* drop the file port either way: success or failure, we are
     * done with it.  leaving it dangling is a slow leak in PID 1
     * which lives forever. */
    mach_port_deallocate(mach_task_self(), target);

    if (rc) {
        /* error_t on Hurd is a typedef for kern_return_t (32-bit signed
         * with the high-bit subsystem tag).  the Hurd glibc convention
         * is that some surfaces (file_name_lookup) translate to POSIX
         * errno via __hurd_fail before returning, but file_set_translator
         * passes the underlying kern_return_t straight through.  raw
         * values like KERN_PROTECTION_FAILURE / MIG_TYPE_ERROR are NOT
         * valid POSIX errnos and would surface as garbage to the elisp
         * layer.  we translate the common cases explicitly, defaulting
         * to EIO; same shape as hurd_reboot_cmd's switch below. */
        switch (rc) {
        case KERN_INVALID_ARGUMENT:    errno = EINVAL; break;
        case KERN_NO_ACCESS:           errno = EACCES; break;
        case KERN_PROTECTION_FAILURE:  errno = EACCES; break;
        case MACH_SEND_INVALID_DEST:   errno = ENOENT; break;
        case EOPNOTSUPP:               errno = EOPNOTSUPP; break;
        case KERN_INVALID_VALUE:       errno = EOPNOTSUPP; break;
        default:                       errno = EIO; break;
        }
        return -1;
    }
    return 0;
}

/* sethostname(2) is POSIX and Hurd's glibc implements it via the
 * proc server's proc_sethostname RPC under the hood.  same body as
 * the Linux backend.  keeping it in the port table even though it is
 * trivially portable is the right call: the supervisor calls
 * port->set_hostname unconditionally and the symmetry across
 * backends is what keeps the dispatch clean. */
static int
hurd_set_hostname(const char *name, size_t len)
{
    return sethostname(name, len);
}

/* pfinet socket-open helper.  every networking verb wants a UDP/IPv4
 * socket on the pfinet translator at /servers/socket/2; the
 * AF_INET / SOCK_DGRAM path goes through glibc's hurd/sockets.c which
 * does a `file_name_lookup ("/servers/socket/2", ...)` and a
 * `socket_create` Mach RPC against the resulting translator port.  the
 * cost is one RPC round trip per open versus Linux's direct in-kernel
 * fd allocation, but pid1 calls these verbs only at boot and from
 * *network* user actions; the round trip is irrelevant.
 *
 * reference: glibc.git/sysdeps/mach/hurd/socket.c, which is the
 * implementation socket(2) resolves to on Hurd.  glibc sets errno via
 * __hurd_fail when the underlying RPC fails, so callers can use plain
 * errno semantics; we do NOT need to translate kern_return_t here.
 *
 * returning -1 with errno preserved on failure matches the linux
 * backend exactly, which lets the supervisor-side panic-handle path
 * render the same diagnostic regardless of kernel. */
static int
hurd_pfinet_open(void)
{
    /* AF_INET + SOCK_DGRAM is the standard pfinet entry point; the
     * dummy protocol arg is 0 (IPPROTO_IP) per POSIX, which pfinet
     * accepts for both UDP and the ioctl-only "no transport" use we
     * actually want here.  the fd is O_CLOEXEC-equivalent on Hurd by
     * default (the Mach port is not inherited across a posix_spawn
     * unless explicitly placed in the file_actions), so we do not
     * have to FD_CLOEXEC after the fact the way a Linux build might. */
    return socket(AF_INET, SOCK_DGRAM, 0);
}

/* bring up the loopback interface via pfinet.  the linux backend
 * (port_linux.c:linux_bring_up_lo) does SIOCGIFFLAGS / OR in
 * IFF_UP|IFF_RUNNING / SIOCSIFFLAGS against a UDP socket.  the Hurd
 * path is identical in shape: pfinet's iioctl-ops.c implements both
 * SIOCGIFFLAGS (S_iioctl_siocgifflags) and SIOCSIFFLAGS
 * (S_iioctl_siocsifflags) with the same ifreq layout, and glibc's
 * ioctl-mux in sysdeps/mach/hurd/ioctl.c translates the userland
 * ioctl(fd, SIOC*, &ifreq) into the appropriate RPC on the file port
 * bound to the fd.
 *
 * reference: hurd.git/pfinet/iioctl-ops.c (the S_iioctl_siocgifflags
 * and S_iioctl_siocsifflags handlers; both take a struct ifreq with
 * ifr_name populated and read/write ifr_flags).
 *
 * the read-modify-write discipline matches the linux body: pfinet
 * preserves flags pid1 does not know about (NOARP, PROMISC, ...) and
 * we must too, so we read, OR in UP|RUNNING, and write back.  fd is
 * always closed on every exit path; PID 1 lives forever and a leaked
 * Mach port is just as bad as a leaked Linux fd. */
static int
hurd_bring_up_lo(void)
{
    int s = hurd_pfinet_open();
    if (s < 0) return -1;
    struct ifreq r;
    memset(&r, 0, sizeof r);
    /* IFNAMSIZ is 16 on Hurd as well (net/if.h matches the Linux ABI
     * here; pfinet pulls the same upper bound in iioctl-ops.c).  "lo"
     * is 3 bytes incl. NUL.  memcpy + explicit terminator instead of
     * strncpy: the same trap that bit the Linux backend bites here
     * too if a future change extends this to a longer iface name. */
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

/* assign IPv4 address + netmask to IFNAME and bring it up.  same
 * three-ioctl sequence as the linux backend (SIOCSIFADDR /
 * SIOCSIFNETMASK / SIOCSIFFLAGS), routed through pfinet.  pfinet
 * handles all three: hurd.git/pfinet/iioctl-ops.c ships
 * S_iioctl_siocsifaddr, S_iioctl_siocsifnetmask, and
 * S_iioctl_siocsifflags as the corresponding RPC handlers, and
 * glibc's ioctl mux dispatches based on the SIOC* number.
 *
 * the ordering invariant (address before netmask before flags-up) is
 * the same on Hurd as on Linux: pfinet rejects a netmask set before
 * the address with errno=EADDRNOTAVAIL, which mirrors the Linux 5.x
 * kernel behaviour the linux backend documents.  keeping the order
 * matched also keeps the supervisor's elisp logging shape consistent
 * across kernels (W4 carry-over from the port-layer refactor).
 *
 * CIDR-to-netmask conversion is identical to the linux backend; the
 * shift-by-32 UB trap (prefix == 0) is special-cased the same way. */
static int
hurd_set_address(const char *ifname, uint32_t addr_be, int prefix)
{
    if (prefix < 0 || prefix > 32) { errno = EINVAL; return -1; }
    if (!ifname) { errno = EINVAL; return -1; }
    size_t nlen = strnlen(ifname, IFNAMSIZ);
    if (nlen == 0 || nlen >= IFNAMSIZ) { errno = EINVAL; return -1; }
    int s = hurd_pfinet_open();
    if (s < 0) return -1;
    struct ifreq r;
    memset(&r, 0, sizeof r);
    memcpy(r.ifr_name, ifname, nlen);
    r.ifr_name[IFNAMSIZ - 1] = '\0';
    struct sockaddr_in *sin = (struct sockaddr_in *)&r.ifr_addr;
    sin->sin_family = AF_INET;
    /* addr_be arrives in network byte order (supervisor contract, matches
     * port_linux.c); the mask is built host-order below and htonl'd. */
    sin->sin_addr.s_addr = addr_be;
    /* SIOCSIFADDR -> pfinet S_iioctl_siocsifaddr.  pfinet stores the
     * address on the named device's struct device and the route table
     * gets the implicit /prefix route from the netmask write that
     * follows. */
    if (ioctl(s, SIOCSIFADDR, &r) < 0) {
        int saved = errno; (void)close(s); errno = saved; return -1;
    }
    /* prefix == 0 special-cased: shift by 32 on a 32-bit value is
     * undefined behavior in C; the linux backend has the same guard. */
    uint32_t mask_host = (prefix == 0)
        ? 0u
        : (uint32_t)(0xFFFFFFFFu << (32 - prefix));
    sin->sin_addr.s_addr = htonl(mask_host);
    /* SIOCSIFNETMASK -> pfinet S_iioctl_siocsifnetmask. */
    if (ioctl(s, SIOCSIFNETMASK, &r) < 0) {
        int saved = errno; (void)close(s); errno = saved; return -1;
    }
    /* read-modify-write on flags: same reason as the linux backend
     * (do not clobber NOARP / PROMISC).  SIOCGIFFLAGS and SIOCSIFFLAGS
     * both go through pfinet's iioctl-ops.c. */
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

/* install a default IPv4 route via GW_BE through IFNAME.  the linux
 * backend uses SIOCADDRT with rt_dst=0/0; the Hurd backend uses the
 * same ioctl through pfinet.  pfinet's iioctl-ops.c ships
 * S_iioctl_siocaddrt (and S_iioctl_siocdelrt for the symmetric
 * delete), accepting the same struct rtentry layout the Linux kernel
 * does.  rt_dev points into a caller-owned buffer that must outlive
 * the ioctl call; pfinet copies it server-side as part of the RPC
 * marshalling, so once ioctl() returns we are free to drop the
 * buffer.
 *
 * reference: hurd.git/pfinet/iioctl-ops.c S_iioctl_siocaddrt; the
 * struct rtentry definition is the standard <net/route.h> one,
 * shared with Linux at the ABI level.
 *
 * one subtlety: the Hurd struct rtentry has rt_dev as a char * (same
 * as Linux), and pfinet treats a NULL rt_dev as "pick the iface that
 * owns the matching local network".  pid1's caller always passes an
 * ifname, so this branch never fires here, but the comment is for
 * the future skeptic pass that asks "why don't we let pfinet pick
 * the device?" - because the supervisor decides bind order, not the
 * kernel. */
static int
hurd_set_route_default(uint32_t gw_be, const char *ifname)
{
    if (!ifname) { errno = EINVAL; return -1; }
    size_t nlen = strnlen(ifname, IFNAMSIZ);
    if (nlen == 0 || nlen >= IFNAMSIZ) { errno = EINVAL; return -1; }
    int s = hurd_pfinet_open();
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
    /* rt_dev is char *; we hand the kernel a buffer that lives on our
     * stack frame for the duration of the ioctl call.  zero the whole
     * IFNAMSIZ tail first so the trailing bytes do not leak stack
     * garbage to pfinet; pfinet reads up to the first NUL but defence
     * in depth is cheap and matches the W1 fix on the linux side. */
    char ifbuf[IFNAMSIZ];
    memset(ifbuf, 0, sizeof ifbuf);
    memcpy(ifbuf, ifname, nlen);
    ifbuf[nlen] = '\0';
    rt.rt_dev = ifbuf;
    /* SIOCADDRT -> pfinet S_iioctl_siocaddrt.  EEXIST surfaces if a
     * default route already exists; the supervisor decides whether to
     * delete-then-add or surface, same as on Linux. */
    if (ioctl(s, SIOCADDRT, &rt) < 0) {
        int saved = errno; (void)close(s); errno = saved; return -1;
    }
    (void)close(s);
    return 0;
}

/* host_reboot Mach RPC.  the linux backend's reboot(2) takes a
 * LINUX_REBOOT_CMD_* code; the Hurd path takes a Mach RB_* flag.
 * the mapping pid1 cares about is:
 *
 *   LINUX_REBOOT_CMD_RESTART   -> RB_AUTOBOOT (warm reboot)
 *   LINUX_REBOOT_CMD_POWER_OFF -> RB_HALT (Hurd lacks a "power off"
 *                                 distinct from halt; halt is what
 *                                 emacs-init.c's power-off path wants
 *                                 on a hosted Mach VM).
 *
 * the caller passes the linux constants today.  rather than build a
 * dispatch table here, i compare against the same numeric values the
 * linux header defines (they are not Hurd-portable include-wise).  if
 * pid1 ever grows a fourth reboot mode, this dispatch needs a real
 * lookup table.
 *
 * the LINUX_REBOOT_CMD_* values are part of the kernel ABI; their
 * numeric values are documented and stable across linux history:
 *   RESTART   = 0x01234567
 *   HALT      = 0xCDEF0123
 *   POWER_OFF = 0x4321FEDC
 *
 * a caller that hands us a value outside the three known LINUX_REBOOT_CMD_*
 * constants is a supervisor-side bug, not a request.  the skeptic pass on
 * step 5 (docs/v04-item11-hurd-spike.md wraparound) made this explicit:
 * we fail loudly with EINVAL rather than warm-reboot on a typo. */
static int
hurd_reboot_cmd(int cmd)
{
    sync();
    int flag;
    /* the linux constants are uint32_t in spirit; we accept int and
     * compare against the cast-to-int versions to keep the compiler
     * happy under -Wsign-compare.  the high-bit values cast to
     * negative ints on a 32-bit signed type, which is fine since the
     * caller is passing them through int as well. */
    if (cmd == (int)0xCDEF0123) {
        /* LINUX_REBOOT_CMD_HALT.  Mach has RB_HALT; some Hurd headers
         * also expose RB_POWERDOWN but it is not universal, and mach's
         * idea of "power off" on a hosted VM ends up halting the kernel
         * and letting the VM monitor stop the cpu.  RB_HALT is the
         * portable choice. */
        flag = RB_HALT;
    } else if (cmd == (int)0x4321FEDC) {
        /* LINUX_REBOOT_CMD_POWER_OFF.  same RB_HALT mapping as above on
         * a hosted Mach VM; the distinction matters on bare metal but
         * pid1 today only runs hosted. */
        flag = RB_HALT;
    } else if (cmd == (int)0x01234567) {
        /* LINUX_REBOOT_CMD_RESTART -> warm reboot. */
        flag = RB_AUTOBOOT;
    } else {
        /* unknown cmd: bail before host_reboot.  the supervisor passes
         * one of three constants; anything else is a caller bug we want
         * the elisp layer to surface, not a silent warm reboot. */
        errno = EINVAL;
        return -1;
    }
    /* the Mach host port for the reboot RPC.  mach_host_self()
     * returns a send right to the host control port; this is what
     * gnumach uses to authorise the RPC (the caller must hold the
     * privileged host port, which PID 1 does by default since it
     * inherits it from the kernel-launched task).
     *
     * we deallocate the send right on every exit path: success is
     * unreachable (the kernel stops scheduling us) but defensive
     * cleanup keeps the body honest. */
    mach_port_t host = mach_host_self();
    error_t rc = host_reboot(host, flag);
    mach_port_deallocate(mach_task_self(), host);
    if (rc) {
        /* error_t from host_reboot is a kern_return_t, NOT a POSIX
         * errno.  the convention in Hurd's libc is that
         * host_reboot returning non-zero is "permission denied" or
         * "kernel busy"; we map the common kern_return_t values into
         * sensible errnos here.
         *
         *   KERN_INVALID_HOST    -> EINVAL
         *   KERN_NO_ACCESS       -> EACCES
         *   anything else        -> EIO
         */
        switch (rc) {
        case KERN_INVALID_HOST:    errno = EINVAL; break;
        case KERN_NO_ACCESS:       errno = EACCES; break;
        default:                   errno = EIO; break;
        }
        return -1;
    }
    /* unreachable; the kernel kills us before we return. */
    return 0;
}

/* suspend has no Hurd equivalent.  we return ENOSYS so the elisp
 * layer renders M-x geos-suspend as "not on this kernel" rather
 * than silently no-op'ing.  the (void)state cast keeps
 * -Wunused-parameter -Werror clean (W5, skeptic review on the
 * port-layer refactor). */
static int
hurd_suspend(const char *state)
{
    (void)state;
    errno = ENOSYS;
    return -1;
}

/* the table.  same shape as port_linux_impl, every slot populated.
 * the symmetry is what lets emacs-init.c pick one or the other at
 * compile time without touching the call sites. */
const port_caps port_hurd_impl = {
    .mount             = hurd_mount,
    .set_hostname      = hurd_set_hostname,
    .bring_up_lo       = hurd_bring_up_lo,
    .set_address       = hurd_set_address,
    .set_route_default = hurd_set_route_default,
    .reboot            = hurd_reboot_cmd,
    .suspend           = hurd_suspend,
};

/* the active pointer + the require-or-abort helper live in
 * port_linux.c when building for Linux and here when building for
 * Hurd.  same NULL-by-default contract, same loud-failure message:
 * if main()/emacs_module_init() forgot to set port, we want to
 * abort BEFORE the first port-> dispatch silently null-derefs.
 *
 * keeping these in the backend TU (rather than in port_layer.h or
 * a shared port_common.c) means each backend takes responsibility
 * for the require-check, and a build that links neither backend
 * fails at the linker stage rather than at runtime: there is no
 * `port` symbol to satisfy the extern in port_layer.h. */
const port_caps *port = NULL;

void
port_require_or_abort(void)
{
    if (port == NULL) {
        static const char m[] =
            "pid1: port table not registered before first call; aborting\n";
        ssize_t r = write(2, m, sizeof m - 1); (void)r;
        abort();
    }
}
