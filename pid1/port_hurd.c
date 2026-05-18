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
#include <sys/reboot.h>
#include <sys/socket.h>

/* Hurd-specific headers.  these only exist on a Hurd glibc toolchain.
 * a Linux build that accidentally pulled this TU in would fail at
 * preprocess time with "No such file or directory" against the first
 * one of these, which is the loud-failure we want. */
#include <hurd.h>
#include <hurd/auth.h>
#include <hurd/fshelp.h>
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
 *   /hurd/procfs    /proc translator.  exposes /proc/<pid>/ entries
 *                   and /proc/cmdline so the elisp layer's existing
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
 *   - passive-flags: also FS_TRANS_SET|FS_TRANS_FORCE so the on-disk
 *     translator record matches the active one.  pid1 reapplies the
 *     full set on every boot regardless, but persisting the passive
 *     copy keeps showtrans(1) honest and gives Hurd a fallback to
 *     lazy-start the translator if the active one ever dies between
 *     pid1 mounts and the first user access.
 *
 * Hurd's libc wraps the bare RPC in file_set_translator(), but that
 * call alone does NOT start a translator process: it only attaches a
 * record (the argz for passive, an existing fsys port for active).
 * to install an ACTIVE translator we have to fork+exec the translator
 * binary ourselves and hand its bootstrap port back to file_set_-
 * translator.  the standard libfshelp helper that does exactly that
 * dance is fshelp_start_translator(); we use it here.  the earlier
 * version of this file omitted the fshelp call and passed
 * MACH_PORT_NULL as the active port, which silently amounted to
 * "remove any active translator that happens to be there" rather
 * than "install one".  showtrans(1) on the target node would come
 * up empty after such a mount; the test caught it on 2026-05-17.
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

/* fshelp_start_translator callback.  the cookie carries the target
 * node port; libfshelp wants to know what underlying node the
 * translator will sit on top of, and the answer is "the file we
 * already opened with O_NOTRANS".  we hand it back as COPY_SEND so
 * our own reference stays valid for the subsequent file_set_-
 * translator call. */
static error_t
hurd_mount_open_node(int flags, file_t *node,
                     mach_msg_type_name_t *node_type,
                     task_t task, void *cookie)
{
    (void)flags;
    (void)task;
    *node = *(file_t *)cookie;
    *node_type = MACH_MSG_TYPE_COPY_SEND;
    return 0;
}

static int
hurd_mount(const char *src, const char *tgt, const char *type,
           unsigned long flags, const char *opts)
{
    (void)flags;
    if (!tgt || !type) { errno = EINVAL; return -1; }

    /* pick the translator binary from the linux-style type string,
     * and decide whether src is a meaningful argv entry for that
     * translator.  the table is intentionally small: the boot path
     * mounts /proc, /sys (no-op on hurd, see below), /dev, /run,
     * /tmp and /var, so three translators cover every caller today.
     * unknown types fall through to ENODEV which surfaces in pid1's
     * log the same way an unknown linux fs type would.
     *
     * the src interpretation differs per translator:
     *
     *   /hurd/ext2fs  src is the block-device path (e.g.
     *                 "/dev/hd0s1"); required, mount fails without
     *                 it.  this matches the linux mount(2) shape.
     *   /hurd/tmpfs   the first non-option argument is the maximum
     *                 size in bytes.  the linux mount(2) convention
     *                 of passing "none" as src does NOT translate;
     *                 tmpfs would parse "none" as a number and
     *                 reject it with EINVAL.  drop src for tmpfs
     *                 unless it is purely numeric.
     *   /hurd/procfs  ignores positional args entirely; drop src. */
    const char *trans_bin;
    int src_is_arg = 0;          /* 1 = pass src as argv[1] to translator */
    if (strcmp(type, "ext2") == 0 || strcmp(type, "ext3") == 0 ||
        strcmp(type, "ext4") == 0) {
        trans_bin = "/hurd/ext2fs";
        src_is_arg = 1;
    } else if (strcmp(type, "tmpfs") == 0) {
        trans_bin = "/hurd/tmpfs";
        /* only forward src if it is a bare unsigned-decimal integer
         * (with optional K/M/G suffix); anything else is the linux
         * placeholder "none" or a device path and would break tmpfs's
         * argument parser.  if src does NOT look like a size, fall
         * through to the default-size append below: /hurd/tmpfs has
         * no built-in default and rejects mounts with no size arg,
         * unlike linux tmpfs which defaults to half of RAM.  256M
         * matches the size pid1's /run + /tmp + /var/tmp on linux
         * tend to settle at, plenty of headroom for boot state. */
        if (src) {
            const char *p = src;
            if (*p >= '0' && *p <= '9') {
                while (*p >= '0' && *p <= '9') p++;
                if (*p == '\0' ||
                    ((*p == 'K' || *p == 'M' || *p == 'G' ||
                      *p == 'k' || *p == 'm' || *p == 'g') &&
                     *(p + 1) == '\0'))
                    src_is_arg = 1;
            }
        }
    } else if (strcmp(type, "proc") == 0 || strcmp(type, "procfs") == 0) {
        trans_bin = "/hurd/procfs";
        /* src deliberately not forwarded: procfs ignores it. */
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
    } else if (strcmp(type, "devtmpfs") == 0) {
        /* hurd's /dev is populated at boot time by the hurd boot
         * translator tree, not by an in-kernel devtmpfs.  every
         * device node pid1 cares about (/dev/console, /dev/null,
         * /dev/tty, the storage nodes) is already there when
         * pid1's mount loop runs.  no-op rather than -1: matches
         * the contract that pid1's boot mount block does not fail
         * on a missing-on-this-kernel fs type.  if a hurd port
         * later needs a writable in-memory /dev (it should not;
         * the hurd boot tree is read-write already) the cleanest
         * shape is to mount /hurd/tmpfs over /dev separately, not
         * to fake devtmpfs here. */
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
    if (src_is_arg && src && src[0] != '\0') {
        size_t l = strlen(src) + 1;
        if (argz_len + l > sizeof argz) {
            mach_port_deallocate(mach_task_self(), target);
            errno = E2BIG; return -1;
        }
        memcpy(argz + argz_len, src, l);
        argz_len += l;
    } else if (strcmp(type, "tmpfs") == 0) {
        /* tmpfs default size: see comment in the trans_bin table.
         * appended as a discrete argz entry (the translator parses
         * argv positionally). */
        static const char default_tmpfs_size[] = "256M";
        size_t l = sizeof default_tmpfs_size;  /* includes NUL */
        if (argz_len + l > sizeof argz) {
            mach_port_deallocate(mach_task_self(), target);
            errno = E2BIG; return -1;
        }
        memcpy(argz + argz_len, default_tmpfs_size, l);
        argz_len += l;
    }
    /* opts: linux mount(2) "-o key=val,key=val".  /hurd/tmpfs treats
     * unknown positional words as additional size arguments and dies
     * with "too many arguments" the moment we forward "mode=0755", so
     * for tmpfs we drop opts on the floor entirely.  the first PID-1
     * boot on real GNU/Hurd (docs/runlogs/2026-05-18-hurd-pid1-boot-
     * result.md) caught this exactly: /run and /var mounts called with
     * opts="mode=0755" got the "too many arguments" rejection from
     * /hurd/tmpfs and the supervisor came up with no /run, no /var.
     *
     * proper fix would be to parse opts into key=val pairs and forward
     * the ones /hurd/tmpfs actually understands (--readonly, --writable,
     * the standard libdiskfs options).  /hurd/tmpfs has no --mode
     * equivalent so the linux "mode=" key has nowhere to go regardless;
     * the root-dir mode is whatever the translator initialises.  for
     * /run this means 01777 instead of 0755, which is over-permissive
     * but not exploitable on a single-user system; the v0.7.x followup
     * tightens that.  for /tmp the existing call passes NULL opts and
     * the default 01777 is correct.
     *
     * non-tmpfs paths (ext2fs, procfs after future opts support, ...)
     * forward opts as before. */
    if (opts && opts[0] != '\0' && strcmp(type, "tmpfs") != 0) {
        size_t l = strlen(opts) + 1;
        if (argz_len + l > sizeof argz) {
            mach_port_deallocate(mach_task_self(), target);
            errno = E2BIG; return -1;
        }
        memcpy(argz + argz_len, opts, l);
        argz_len += l;
    }

    /* start the translator process and get its bootstrap port.
     * fshelp_start_translator does the fork+exec, sets up the
     * translator's stdin/stdout/stderr from ours, and blocks until
     * the translator either responds (returning its control port in
     * active_control) or the timeout fires.  60s is what settrans(1)
     * defaults to; pid1 has no tighter requirement at boot. */
    fsys_t active_control = MACH_PORT_NULL;
    error_t rc_start = fshelp_start_translator(hurd_mount_open_node,
                                               &target,
                                               (char *)trans_bin,
                                               argz, argz_len,
                                               60000,
                                               &active_control);
    if (rc_start) {
        mach_port_deallocate(mach_task_self(), target);
        switch (rc_start) {
        case KERN_INVALID_ARGUMENT:   errno = EINVAL; break;
        case EDIED:                   errno = EIO;    break;
        case ETIMEDOUT:               errno = ETIMEDOUT; break;
        default:
            if (rc_start > 0 && rc_start < 256) errno = (int)rc_start;
            else                                errno = EIO;
            break;
        }
        return -1;
    }

    /* now bind the running translator to the node.  pass it as the
     * active port (with FS_TRANS_SET|FS_TRANS_FORCE so any stale
     * translator is replaced rather than chained behind), AND record
     * the argz as the passive translator so showtrans(1) reflects
     * the mount and Hurd can lazy-restart from disk if the active
     * process ever exits.  pid1 reapplies the active path on every
     * boot regardless; the on-disk record is a safety net. */
    error_t rc = file_set_translator(target,
                                     FS_TRANS_SET | FS_TRANS_FORCE,
                                     FS_TRANS_SET | FS_TRANS_FORCE,
                                     0,
                                     argz, argz_len,
                                     active_control,
                                     MACH_MSG_TYPE_COPY_SEND);
    /* drop ports either way: success or failure, we are done with
     * them.  leaving them dangling is a slow leak in PID 1 which
     * lives forever.  the active_control send right was minted by
     * fshelp; we copy-sent it into file_set_translator so the kernel
     * holds its own ref now.  our local ref drops here. */
    mach_port_deallocate(mach_task_self(), target);
    if (active_control != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), active_control);

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

/* interface-name normalization at the kernel seam.  the elisp
 * supervisor speaks Linux-shaped ifnames ("eth0", "wlp3s0", "lo") and
 * pfinet on Debian Hurd disagrees: pfinet keys hardware interfaces by
 * the devnode translator path that was passed to /hurd/pfinet at
 * settrans time, which on a stock Debian Hurd install is "/dev/eth0".
 * loopback is the exception: pfinet special-cases the literal "lo"
 * regardless of devnode configuration.  runtime-verified 2026-05-17:
 * `pid1-set-address "eth0" ...` returns ENODEV; `pid1-set-address
 * "/dev/eth0" ...` succeeds.
 *
 * the right place to translate is here, not in elisp: the elisp
 * caller is kernel-agnostic by construction (geos-kernel dispatches
 * before this code is reached), and a per-kernel oddity belongs to
 * the per-kernel backend.  the Linux backend does nothing of the kind
 * because the Linux kernel accepts the bare ifname directly.
 *
 * rule: if IN starts with '/', pass through unchanged (already an
 * absolute devnode path, caller knows what it wants); if IN equals
 * "lo", pass through unchanged (pfinet special case); otherwise
 * prepend "/dev/".  the OUT buffer is IFNAMSIZ-bounded; failures
 * (buffer too small for the prefixed name) return -1 with EINVAL,
 * matching the rest of this file's contract. */
static int
hurd_normalize_ifname(const char *in, char *out, size_t outsz)
{
    if (!in || !out || outsz == 0) { errno = EINVAL; return -1; }
    size_t inlen = strnlen(in, IFNAMSIZ);
    if (inlen == 0 || inlen >= IFNAMSIZ) { errno = EINVAL; return -1; }
    int prepend = (in[0] != '/' && !(inlen == 2 && in[0] == 'l' && in[1] == 'o'));
    if (prepend) {
        const char prefix[] = "/dev/";
        size_t plen = sizeof prefix - 1;
        if (plen + inlen + 1 > outsz) { errno = EINVAL; return -1; }
        memcpy(out, prefix, plen);
        memcpy(out + plen, in, inlen);
        out[plen + inlen] = '\0';
    } else {
        if (inlen + 1 > outsz) { errno = EINVAL; return -1; }
        memcpy(out, in, inlen);
        out[inlen] = '\0';
    }
    return 0;
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
    struct ifreq r;
    memset(&r, 0, sizeof r);
    /* normalize at the seam: "eth0" -> "/dev/eth0" for pfinet's
     * devnode-keyed lookup, "lo" passes through unchanged. */
    if (hurd_normalize_ifname(ifname, r.ifr_name, IFNAMSIZ) < 0) return -1;
    int s = hurd_pfinet_open();
    if (s < 0) return -1;
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
 * does.  on Hurd the ioctl(SIOCADDRT) marshalling uses ifrtreq_t
 * (defined in <net/route.h> on Hurd's glibc) rather than Linux's
 * struct rtentry; the field layout is flat in_addr_t plus a flat
 * char[IF_NAMESIZE] ifname rather than the sockaddr-tagged-union
 * Linux uses, but the semantic content is identical.
 *
 * reference: hurd.git/pfinet/iioctl-ops.c S_iioctl_siocaddrt; the
 * Hurd ifrtreq_t definition is the canonical one for pfinet's RPC
 * ABI.  the Linux backend uses the rtentry shape because that is
 * what Linux's net/route.h exposes; the two shapes carry the same
 * routing intent, just different wire-level marshalling. */
static int
hurd_set_route_default(uint32_t gw_be, const char *ifname)
{
    ifrtreq_t rt;
    memset(&rt, 0, sizeof rt);
    /* normalize at the seam: "eth0" -> "/dev/eth0" for pfinet's
     * devnode-keyed lookup.  IF_NAMESIZE on Hurd matches IFNAMSIZ
     * (both 16), so the same bound applies to rt.ifname as to
     * ifr_name above. */
    if (hurd_normalize_ifname(ifname, rt.ifname, sizeof rt.ifname) < 0) return -1;
    int s = hurd_pfinet_open();
    if (s < 0) return -1;
    /* default route: destination 0.0.0.0/0 via gw_be.  in_addr_t is
     * already network byte order per POSIX; gw_be comes in network
     * byte order from the port-layer contract so no htonl needed. */
    rt.rt_dest    = 0;
    rt.rt_mask    = 0;
    rt.rt_gateway = gw_be;
    rt.rt_flags   = RTF_UP | RTF_GATEWAY;
    rt.rt_metric  = 1;
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
    /* the Mach host port for the reboot RPC.  this is the privileged
     * "host control" port, not the unprivileged host name port that
     * `mach_host_self()` returns.  gnumach refuses `host_reboot` from
     * the unprivileged port with KERN_INVALID_HOST.
     *
     * the standard route to the privileged port on Hurd is the proc
     * server: `get_privileged_ports(&host_priv, NULL)` asks
     * `/hurd/proc` for the cached host control port (proc seeds it
     * from gnumach at bootstrap, and re-vends it to any task whose
     * authority lets it ask).  root suffices on a default Debian
     * Hurd; non-root callers get KERN_NO_ACCESS, which we map to
     * EACCES so the elisp layer can surface a useful message instead
     * of "invalid argument" when an unprivileged user hits the RPC.
     *
     * we deallocate the send right on every exit path: success is
     * unreachable (the kernel stops scheduling us) but defensive
     * cleanup keeps the body honest.  the first verification of this
     * slot on 2026-05-18 hit EINVAL with the old `mach_host_self()`
     * path; that runlog is `docs/runlogs/2026-05-18-hurd-pid1-host-
     * reboot-einval.md` and was the trigger for switching to
     * `get_privileged_ports`. */
    mach_port_t host_priv = MACH_PORT_NULL;
    error_t rc = get_privileged_ports(&host_priv, NULL);
    if (rc) {
        switch (rc) {
        case KERN_NO_ACCESS:       errno = EACCES; break;
        case KERN_INVALID_HOST:    errno = EINVAL; break;
        default:                   errno = EIO;    break;
        }
        return -1;
    }
    rc = host_reboot(host_priv, flag);
    mach_port_deallocate(mach_task_self(), host_priv);
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

/* peer credentials over AF_UNIX, server side of the v0.8 handshake.
 * design at docs/v08-hurd-peer-cred-design.md section 3.2: client
 * sends a 1-byte placeholder with the rendezvous send right attached
 * as SCM_RIGHTS cmsg; we recv that, hand the rendezvous to the auth
 * server, and extract the client's effective uid/gid.  empty cred
 * set, missing cmsg, or auth rejection all map to EACCES; auth
 * server unreachable maps to EAGAIN so the poller can retry. */
static int
hurd_get_peer_cred(int fd, uint32_t *uid_out, uint32_t *gid_out)
{
    char placeholder = 0;
    struct iovec iov = { .iov_base = &placeholder, .iov_len = 1 };
    char cbuf[CMSG_SPACE(sizeof(mach_port_t))];
    memset(cbuf, 0, sizeof cbuf);
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf;
    msg.msg_controllen = sizeof cbuf;

    ssize_t got = recvmsg(fd, &msg, 0);
    if (got < 0) return -1;  /* errno set by recvmsg */

    struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
    if (!cm) { errno = EACCES; return -1; }
    if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS ||
        cm->cmsg_len != CMSG_LEN(sizeof(mach_port_t))) {
        errno = EACCES; return -1;
    }
    /* exactly one port: a second cmsg or a trailing port would mean a
     * malformed client we do not want to trust. */
    if (CMSG_NXTHDR(&msg, cm) != NULL) { errno = EACCES; return -1; }

    mach_port_t rendez = MACH_PORT_NULL;
    memcpy(&rendez, CMSG_DATA(cm), sizeof rendez);
    if (rendez == MACH_PORT_NULL) { errno = EACCES; return -1; }

    uid_t *euid_buf = NULL, *auid_buf = NULL;
    gid_t *egid_buf = NULL, *agid_buf = NULL;
    mach_msg_type_number_t n_euid = 0, n_auid = 0, n_egid = 0, n_agid = 0;

    error_t rc = auth_server_authenticate(getauth(),
                                          rendez, MACH_MSG_TYPE_COPY_SEND,
                                          &euid_buf, &n_euid,
                                          &auid_buf, &n_auid,
                                          &egid_buf, &n_egid,
                                          &agid_buf, &n_agid);
    /* the rendezvous send right has done its job; drop our ref on every
     * exit path regardless of the auth outcome. */
    mach_port_deallocate(mach_task_self(), rendez);

    if (rc == KERN_SUCCESS) {
        int ret;
        if (n_euid >= 1 && n_egid >= 1) {
            *uid_out = (uint32_t)euid_buf[0];
            *gid_out = (uint32_t)egid_buf[0];
            ret = 0;
        } else {
            errno = EACCES;
            ret = -1;
        }
        /* the four arrays are out-of-line vm allocations the stub made
         * on our behalf; only present on KERN_SUCCESS, and the kernel
         * will leak them into our address space if we forget. */
        vm_deallocate(mach_task_self(), (vm_address_t)euid_buf,
                      n_euid * sizeof(*euid_buf));
        vm_deallocate(mach_task_self(), (vm_address_t)auid_buf,
                      n_auid * sizeof(*auid_buf));
        vm_deallocate(mach_task_self(), (vm_address_t)egid_buf,
                      n_egid * sizeof(*egid_buf));
        vm_deallocate(mach_task_self(), (vm_address_t)agid_buf,
                      n_agid * sizeof(*agid_buf));
        return ret;
    }

    if (rc == MACH_SEND_INVALID_DEST) {
        errno = EAGAIN;
        return -1;
    }
    errno = EACCES;
    return -1;
}

/* client-side half of the v0.8 peer-cred rendezvous dance; design and
 * prose at docs/v08-hurd-peer-cred-design.md section 3.3.  the server
 * counterpart is hurd_get_peer_cred above.  one rendezvous receive
 * right is allocated, send-rightified, shipped over the AF_UNIX cmsg
 * channel with a single-NUL placeholder iov, and registered with the
 * gnumach auth server via auth_user_authenticate; every exit branch
 * deallocates whichever Mach ports it allocated. */
static int
hurd_client_auth_handshake(int fd)
{
    mach_port_t rendez = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &rendez);
    if (kr != KERN_SUCCESS) {
        errno = (kr == MACH_SEND_INVALID_DEST) ? EAGAIN : EACCES;
        return -1;
    }

    kr = mach_port_insert_right(mach_task_self(), rendez, rendez,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), rendez);
        errno = EACCES;
        return -1;
    }

    /* sendmsg payload: a single NUL placeholder byte so pflocal has
     * something to attach the ancillary data to, plus one SCM_RIGHTS
     * cmsg carrying the rendezvous send right as a single int.  the
     * union enforces correct alignment for the cmsghdr buffer (raw
     * char[] is not guaranteed cmsghdr-aligned on every ABI). */
    char placeholder = '\0';
    struct iovec iov = { .iov_base = &placeholder, .iov_len = 1 };
    union {
        struct cmsghdr h;
        char buf[CMSG_SPACE(sizeof(int))];
    } cmsg_u;
    memset(&cmsg_u, 0, sizeof cmsg_u);
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_u.buf;
    msg.msg_controllen = sizeof cmsg_u.buf;

    struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type  = SCM_RIGHTS;
    cm->cmsg_len   = CMSG_LEN(sizeof(int));
    int rendez_as_int = (int)rendez;
    memcpy(CMSG_DATA(cm), &rendez_as_int, sizeof rendez_as_int);

    if (sendmsg(fd, &msg, 0) < 0) {
        int saved = errno;
        mach_port_deallocate(mach_task_self(), rendez);
        errno = saved;
        return -1;
    }

    /* register the client side with the auth server.  on success the
     * server hands back a reply_port we have no further use for; drop
     * the ref alongside rendez.  MACH_SEND_INVALID_DEST means the auth
     * server is momentarily unreachable (boot-time race per design
     * section 4); surface EAGAIN so the caller can retry on the next
     * tick rather than hard-fail the connection. */
    mach_port_t reply_port = MACH_PORT_NULL;
    kr = auth_user_authenticate(getauth(), rendez,
                                MACH_MSG_TYPE_COPY_SEND,
                                &reply_port);
    mach_port_deallocate(mach_task_self(), rendez);

    if (kr == KERN_SUCCESS) {
        if (MACH_PORT_VALID(reply_port))
            mach_port_deallocate(mach_task_self(), reply_port);
        return 0;
    }
    if (kr == MACH_SEND_INVALID_DEST) {
        errno = EAGAIN;
        return -1;
    }
    errno = EACCES;
    return -1;
}

/* slice 2 of v0.8 design 2.2: publish the supervisor's long-lived auth
 * port as an active translator at /servers/geos-auth.  see
 * docs/v08-hurd-peer-cred-design.md section 3.5.1 (Option A picked) and
 * section 3.5.4 (slice 3 will drain it via a non-blocking mach_msg
 * inside Fpid1_rpc_poll).
 *
 * the chosen mechanism is the "active translator" variant of
 * file_set_translator: we hand it a SEND right and the filesystem
 * records that send right as the live translator.  any client doing
 * file_name_lookup("/servers/geos-auth", 0, 0) gets a fresh send right
 * to that same port routed back via fsys_getroot.  this is exactly the
 * shape /hurd/auth itself uses to expose the auth server.
 *
 * mechanics, in order:
 *
 *   1. mach_port_allocate(MACH_PORT_RIGHT_RECEIVE) for the receive
 *      right the supervisor will mach_msg-drain from on the next tick
 *      (slice 3).  stashed in a file-static slot so the drain code can
 *      reach it without re-allocating.
 *   2. mach_port_insert_right(MAKE_SEND) bumps the user-ref count for
 *      the send side; without this we cannot hand out send rights to
 *      clients later (file_set_translator copies one for the fs record
 *      but a clean MAKE_SEND keeps the supervisor's own send ref for
 *      diagnostics and for any future direct-publish path).
 *   3. open("/servers/geos-auth", O_CREAT|O_WRONLY, 0600) + close to
 *      guarantee the file exists.  /servers/ is part of the stock
 *      Debian Hurd boot tree; a missing /servers/ would be a wildly
 *      broken system and we surface that as ENOENT rather than try to
 *      mkdir it ourselves.
 *   4. file_name_lookup("/servers/geos-auth", O_NOTRANS, 0) gets us a
 *      file port to the underlying node (NOT to any translator already
 *      sitting there: O_NOTRANS gives us the bare file).
 *   5. file_set_translator(file, 0, FS_TRANS_SET|FS_TRANS_FORCE, 0,
 *                          NULL, 0, send_right, COPY_SEND) installs
 *      our send right as the active translator.  passive_flags=0 +
 *      passive=NULL means "do not also write a passive translator
 *      record to disk"; if the supervisor exits the active translator
 *      goes with it, which is exactly what we want (a stale send
 *      right pointing at a dead supervisor would be worse than no
 *      translator at all; the next supervisor reinstalls fresh).
 *
 * the static slot hurd_auth_port:
 *
 *   slice 3 (see design 3.5.4) reads this from inside Fpid1_rpc_poll
 *   via mach_msg(MACH_RCV_MSG|MACH_RCV_TIMEOUT, timeout=0, ...).  the
 *   slot stays MACH_PORT_NULL until the publish succeeds; on success
 *   it holds the RECEIVE right (not a send right -- send rights are
 *   what file_set_translator vended to the kernel and what clients
 *   will hold).
 *
 * idempotency: if hurd_auth_port is already non-NULL on entry we return
 * -1/EBUSY.  the supervisor calls this exactly once at startup; a
 * second call indicates a wiring bug we want to surface, not to paper
 * over by silently reusing the existing port (which would also leak
 * the new allocation if we got that far).
 *
 * error translation: kern_return_t values from mach_port_* and
 * file_set_translator do NOT escape this function as errno.  same
 * convention the rest of this file uses; see hurd_mount and
 * hurd_reboot_cmd for the same pattern. */

static mach_port_t hurd_auth_port = MACH_PORT_NULL;

static int
hurd_publish_auth_port(void)
{
    if (hurd_auth_port != MACH_PORT_NULL) {
        errno = EBUSY;
        return -1;
    }

    /* step 1: allocate the receive right that slice 3 will drain. */
    mach_port_t recv = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &recv);
    if (kr != KERN_SUCCESS) {
        errno = (kr == KERN_RESOURCE_SHORTAGE) ? ENOMEM : EIO;
        return -1;
    }

    /* step 2: mint a send right against the same name.  COPY_SEND on
     * file_set_translator below would also vend the kernel a send right,
     * but having our own send-right user-ref keeps the supervisor able
     * to mint additional send rights without re-running this dance. */
    kr = mach_port_insert_right(mach_task_self(), recv, recv,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        /* drop the receive right we just allocated; do NOT leak. */
        (void)mach_port_mod_refs(mach_task_self(), recv,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        errno = EIO;
        return -1;
    }

    /* step 3: ensure /servers/geos-auth exists as a bare file node.
     * an existing file is fine (O_CREAT without O_EXCL); a missing
     * /servers/ directory surfaces as ENOENT from open(2) which we
     * propagate, since fabricating /servers/ ourselves would mask a
     * broken bootstrap.  mode 0600: only root reads/writes the node;
     * the actual translator publishing happens regardless of the
     * file mode (the filesystem keys the translator on the node, not
     * on its permissions), so 0600 is purely "no point exposing the
     * empty file to other users". */
    int fd = open("/servers/geos-auth", O_CREAT | O_WRONLY, 0600);
    if (fd < 0) {
        int saved = errno;
        (void)mach_port_deallocate(mach_task_self(), recv);
        (void)mach_port_mod_refs(mach_task_self(), recv,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        errno = saved;
        return -1;
    }
    (void)close(fd);

    /* step 4: get a file port to the bare node (O_NOTRANS so we do not
     * chain behind any pre-existing translator).  any pre-existing
     * translator gets FS_TRANS_FORCE-replaced in step 5. */
    file_t node = file_name_lookup("/servers/geos-auth", O_NOTRANS, 0);
    if (node == MACH_PORT_NULL) {
        int saved = errno;
        (void)mach_port_deallocate(mach_task_self(), recv);
        (void)mach_port_mod_refs(mach_task_self(), recv,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        errno = saved ? saved : EIO;
        return -1;
    }

    /* step 5: install the send right as the active translator.  passive
     * fields zeroed so no on-disk passive record is written (the
     * supervisor is the only source of truth; if it dies the next boot
     * republishes).  COPY_SEND on the active port disposition: the
     * kernel takes its own ref, ours stays valid through the call. */
    kr = file_set_translator(node,
                             0,                          /* passive_flags */
                             FS_TRANS_SET | FS_TRANS_FORCE, /* active_flags */
                             0,                          /* oldtrans_flags */
                             NULL, 0,                    /* passive argz */
                             recv,                       /* active port */
                             MACH_MSG_TYPE_COPY_SEND);
    (void)mach_port_deallocate(mach_task_self(), node);

    if (kr != KERN_SUCCESS) {
        /* unwind the receive + send rights; nothing got published, so
         * the supervisor's state stays at "no auth port" for the next
         * call.  mapping mirrors hurd_mount's error switch. */
        (void)mach_port_deallocate(mach_task_self(), recv);
        (void)mach_port_mod_refs(mach_task_self(), recv,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        switch (kr) {
        case KERN_INVALID_ARGUMENT:    errno = EINVAL; break;
        case KERN_NO_ACCESS:           errno = EACCES; break;
        case KERN_PROTECTION_FAILURE:  errno = EACCES; break;
        case MACH_SEND_INVALID_DEST:   errno = ENOENT; break;
        case EOPNOTSUPP:               errno = EOPNOTSUPP; break;
        default:                       errno = EIO; break;
        }
        return -1;
    }

    /* commit: slot reflects "published".  slice 3 reads this. */
    hurd_auth_port = recv;
    return 0;
}

/* the table.  same shape as port_linux_impl, every slot populated.
 * the symmetry is what lets emacs-init.c pick one or the other at
 * compile time without touching the call sites. */
const port_caps port_hurd_impl = {
    .kernel_name           = "hurd",
    .mount                 = hurd_mount,
    .set_hostname          = hurd_set_hostname,
    .bring_up_lo           = hurd_bring_up_lo,
    .set_address           = hurd_set_address,
    .set_route_default     = hurd_set_route_default,
    .reboot                = hurd_reboot_cmd,
    .suspend               = hurd_suspend,
    .get_peer_cred         = hurd_get_peer_cred,
    .client_auth_handshake = hurd_client_auth_handshake,
    .publish_auth_port     = hurd_publish_auth_port,
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
