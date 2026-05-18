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
#include <time.h>
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
/* NOT including <hurd/fsys.h> on purpose: that header is the user-side
 * fsys RPC stub set whose fsys_getroot prototype takes a separate
 * dotdot_nodePoly argument.  the MIG-generated fsys_S.h we include
 * below (server side) has the matching SERVER prototype we need to
 * implement; having both headers in scope is a compile-time conflict
 * ("conflicting types for 'fsys_getroot'").  every constant we used
 * to get out of <hurd/fsys.h> (FS_TRANS_*, FS_RETRY_*, fsys_t,
 * retry_type) comes from <hurd/hurd_types.h>, transitively included
 * through <hurd.h>. */
#include <hurd/ports.h>
#include <hurd/process.h>
#include <mach.h>
#include <mach/mach_host.h>
#include <mach/message.h>
#include <mach/mig_errors.h>

/* MIG-generated fsys server demuxer.  generated from
 * /usr/include/x86_64-gnu/hurd/fsys.defs at build time by the rule in
 * pid1/Makefile (PORT=hurd path).  the _S.h declares fsys_server(in,
 * out) plus the user-side prototypes (fsys_getroot, fsys_goaway, ...)
 * we implement below; weak EOPNOTSUPP defaults emitted into the
 * generated fsysServer.c via -DMIG_EOPNOTSUPP cover every stub we do
 * not need so the unused ones link cleanly without us having to write
 * a one-line body each.  see also docs/v08-hurd-peer-cred-design.md
 * section 3.5.7 for the rationale on using MIG for fsys but
 * hand-rolling our own GEOS_AUTH_SUBMIT_NONCE verb. */
#include "fsys_S.h"

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

/* forward declarations for the v0.8 design-2.2 auth surface.  the
 * constants and the submit_nonce wire struct are needed by
 * hurd_client_auth_handshake (this file's first user), but the bulk of
 * the publish + drain implementation lives below for narrative reasons
 * (the comment block sets up the slice 2 -> slice 3 rationale near the
 * code that actually publishes the translator).  hoisting just the
 * names + struct shape avoids a circular textual dependency without
 * disturbing that ordering. */
#define GEOS_AUTH_NONCE_LEN          16
#define GEOS_AUTH_SUBMIT_NONCE_MSGID 90001
struct submit_nonce_request {
    mach_msg_header_t Head;
    mach_msg_type_t   rendez_type;
    mach_port_t       rendez;
    mach_msg_type_t   nonce_type;
    uint8_t           nonce[GEOS_AUTH_NONCE_LEN];
};

/* peer credentials over AF_UNIX, server side of the v0.8 design-2.2
 * handshake (slice 5 rewrite).  design at
 * docs/v08-hurd-peer-cred-design.md section 3.5.2.
 *
 * the old slice-3 body recv'd a SCM_RIGHTS cmsg off the AF_UNIX socket
 * and called auth_server_authenticate inline; that path is retired
 * (pflocal cmsg dead, see runlog 2026-05-18-hurd-pflocal-cmsg-fail.md).
 * the slice-5 path consults the pending_auth[] table the per-tick
 * drain has populated as submit_nonce messages arrive on /servers/
 * geos-auth.  the auth_server_authenticate call moves into
 * S_geos_auth_submit_nonce (the drain handler); this body is now a
 * pure lookup keyed by NONCE.
 *
 * NONCE is the 16-byte rendezvous identifier the supervisor wrote to
 * the client on accept and passed through Fpid1_rpc_poll into this
 * call.  FD is retained for parity with the Linux signature but the
 * pending_auth lookup does not need it; (void)fd keeps -Wunused-
 * parameter quiet.
 *
 * retry: a submit_nonce message may not have arrived by the time
 * Fpid1_rpc_poll calls this slot (the client posts the mach_msg
 * between connect() and the first AF_UNIX send; the order between
 * that mach_msg and our accept-on-AF_UNIX is undefined).  if the
 * lookup misses, we sleep 200ms and retry up to 5 times (1s total
 * worst case).  this stays under the existing 2s SO_RCVTIMEO that
 * bounds every other read in Fpid1_rpc_poll.  exhausting the budget
 * returns -1 with errno=ETIMEDOUT; the caller closes the connection.
 *
 * rows in pending_auth[] also expire on a 5s TTL (see
 * pending_auth_gc), so an abandoned client handshake never wedges. */
static int
hurd_get_peer_cred(int fd, const uint8_t nonce[16],
                   uint32_t *uid_out, uint32_t *gid_out)
{
    (void)fd;
    if (nonce == NULL) { errno = EINVAL; return -1; }
    if (auth_port_obj == NULL) {
        /* publish_auth_port never ran; the supervisor would still
         * have called us through the port-> dispatch, but without
         * a live auth channel there is no way to populate
         * pending_auth[].  surface ENOSYS so Fpid1_rpc_poll closes
         * the connection without panicking the 200ms tick. */
        errno = ENOSYS;
        return -1;
    }

    /* retry budget: 5 ticks of 200ms each.  the constant lives here
     * rather than as a defined macro because the only consumer is this
     * function; promoting it would invite callers to rely on the
     * pacing, which is internal to the lookup. */
    for (int attempt = 0; attempt < 5; attempt++) {
        for (int i = 0; i < GEOS_AUTH_PENDING_MAX; i++) {
            if (pending_auth[i].expiry == 0) continue;
            if (memcmp(pending_auth[i].nonce, nonce,
                       GEOS_AUTH_NONCE_LEN) != 0) continue;
            /* row uid/gid are still the (uint32_t)-1 sentinel if the
             * drain handler recorded the nonce but auth_server_
             * authenticate has not run yet.  treat that as "match
             * pending, retry"; the sentinel narrows the race window
             * where submit_nonce arrived but the auth resolution has
             * not completed.  the slice-5 drain handler writes the
             * real uid/gid in the same critical section that inserts
             * the row, so the sentinel state is short-lived. */
            if (pending_auth[i].uid == (uint32_t)-1 &&
                pending_auth[i].gid == (uint32_t)-1) {
                break;  /* break inner loop, fall to sleep */
            }
            *uid_out = pending_auth[i].uid;
            *gid_out = pending_auth[i].gid;
            /* one-shot: drop the row.  re-handshake on the next
             * connection mints a fresh nonce. */
            memset(&pending_auth[i], 0, sizeof pending_auth[i]);
            return 0;
        }
        /* miss.  sleep 200 ms then retry.  the supervisor's tick is
         * also 200 ms, so this consumes at most 5 ticks of poll
         * budget per connection; under typical load the drain ran
         * before us and we never sleep at all. */
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 200 * 1000 * 1000 };
        (void)nanosleep(&ts, NULL);
    }
    errno = ETIMEDOUT;
    return -1;
}

/* client-side half of the v0.8 peer-cred rendezvous dance, slice 4
 * rewrite.  design at docs/v08-hurd-peer-cred-design.md section 3.5.2.
 * the server counterpart is hurd_get_peer_cred (slice 5 will rewrite
 * that to read from the pending_auth table; today it still consults
 * auth_server_authenticate inline).
 *
 * slice 4 signature change: this function now takes a 16-byte nonce
 * the caller minted from the elisp side (rpc-client.el reads it off
 * the AF_UNIX socket with pid1-unix-recv-exactly after the supervisor
 * writes it on accept).  the Linux backend keeps the same prototype
 * but ignores the nonce.  port_layer.h slot updated to match.  the
 * main-side mirror change (Linux no-op signature update + Femacs
 * binding update + elisp call-site change) lands as a separate
 * pid1-engineer SPEC: see the runlog at
 * docs/runlogs/2026-05-18-hurd-client-handshake.md for the verbatim
 * spec.  fd is the AF_UNIX socket the elisp client just connected;
 * we do NOT read or write the socket here, only the nonce arrived
 * through it.  fd is retained for forward compatibility (the
 * fallback Option B body would have read the nonce off fd inline)
 * but cast to (void) here.
 *
 * the wire format (everything the supervisor's drain demuxer
 * recognises):
 *   msgh_id = 90001 (GEOS_AUTH_SUBMIT_NONCE_MSGID)
 *   msgh_bits = MACH_MSGH_BITS(MOVE_SEND, 0) | MACH_MSGH_BITS_COMPLEX
 *   msgh_remote_port = the supervisor's auth send right (from
 *                      file_name_lookup("/servers/geos-auth", 0, 0))
 *   msgh_local_port  = MACH_PORT_NULL (one-way; no reply expected)
 *   body: one mach_msg_type_t for the rendezvous port (one MOVE_SEND),
 *         one mach_msg_type_t for the nonce (16 inline bytes)
 *
 * lifecycle: every mach port this function touches gets dropped on
 * every exit branch.  the auth send right is acquired via
 * file_name_lookup and dropped after the mach_msg send.  the
 * rendezvous send right is minted via mach_port_insert_right and
 * transferred via MOVE_SEND in the message body; the kernel consumes
 * it on send-success.  on send-failure we deallocate ourselves so the
 * abort path does not leak.  the rendezvous RECEIVE right stays in
 * our task table just long enough to call auth_user_authenticate
 * against it, then dropped after the auth call returns. */
static int
hurd_client_auth_handshake(int fd, const uint8_t nonce[GEOS_AUTH_NONCE_LEN])
{
    (void)fd;
    if (nonce == NULL) {
        errno = EINVAL;
        return -1;
    }

    /* acquire the supervisor's auth send right.  this is the slot that
     * was unreachable before phase 4a fixed S_fsys_getroot; with the
     * MOVE_SEND fix in place, file_name_lookup returns a usable send
     * right (the libports-managed user-ref). */
    mach_port_t auth_send = file_name_lookup("/servers/geos-auth", 0, 0);
    if (auth_send == MACH_PORT_NULL) {
        /* errno set by file_name_lookup via __hurd_fail. */
        return -1;
    }

    /* allocate the rendezvous receive right + a fresh send right we
     * will MOVE into the message body.  the receive right stays in our
     * task; auth_user_authenticate calls mach_port_request_notification
     * on the receive side, so we must hold it across that call. */
    mach_port_t rendez_rcv = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &rendez_rcv);
    if (kr != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), auth_send);
        errno = (kr == KERN_RESOURCE_SHORTAGE) ? ENOMEM : EACCES;
        return -1;
    }
    kr = mach_port_insert_right(mach_task_self(), rendez_rcv, rendez_rcv,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        mach_port_mod_refs(mach_task_self(), rendez_rcv,
                           MACH_PORT_RIGHT_RECEIVE, -1);
        mach_port_deallocate(mach_task_self(), auth_send);
        errno = EACCES;
        return -1;
    }
    /* rendez_send: the kernel name of the send right we just minted.
     * insert_right with MAKE_SEND returns the new send right under the
     * same name as the receive right on gnumach, since names index a
     * single capability slot per task.  we MOVE this name into the
     * mach_msg body below; the kernel transfers ownership and the
     * send-ref count on our side returns to zero (the receive right
     * still holds at refcount 1). */
    mach_port_t rendez_send = rendez_rcv;

    /* hand-roll the submit_nonce request.  the legacy mach_msg_type_t
     * descriptor format is what gnumach parses; the newer
     * mach_msg_port_descriptor_t is XNU-only.  layout matches the one
     * in S_geos_auth_submit_nonce's `struct submit_nonce_request` so
     * the server-side demuxer can cast directly. */
    struct submit_nonce_request msg;
    memset(&msg, 0, sizeof msg);
    msg.Head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0)
                       | MACH_MSGH_BITS_COMPLEX;
    msg.Head.msgh_size = sizeof msg;
    msg.Head.msgh_remote_port = auth_send;
    msg.Head.msgh_local_port  = MACH_PORT_NULL;
    msg.Head.msgh_seqno       = 0;
    msg.Head.msgh_id          = GEOS_AUTH_SUBMIT_NONCE_MSGID;

    /* rendezvous port descriptor: one MOVE_SEND, in-line, short form. */
    msg.rendez_type.msgt_name       = MACH_MSG_TYPE_MOVE_SEND;
    msg.rendez_type.msgt_size       = 8 * (unsigned)sizeof(mach_port_t);
    msg.rendez_type.msgt_number     = 1;
    msg.rendez_type.msgt_inline     = 1;
    msg.rendez_type.msgt_longform   = 0;
    msg.rendez_type.msgt_deallocate = 0;
    msg.rendez_type.msgt_unused     = 0;
    msg.rendez = rendez_send;

    /* nonce descriptor: 16 inline bytes, msgt_size measured in bits. */
    msg.nonce_type.msgt_name       = MACH_MSG_TYPE_BYTE;
    msg.nonce_type.msgt_size       = 8;
    msg.nonce_type.msgt_number     = GEOS_AUTH_NONCE_LEN;
    msg.nonce_type.msgt_inline     = 1;
    msg.nonce_type.msgt_longform   = 0;
    msg.nonce_type.msgt_deallocate = 0;
    msg.nonce_type.msgt_unused     = 0;
    memcpy(msg.nonce, nonce, GEOS_AUTH_NONCE_LEN);

    kr = mach_msg(&msg.Head,
                  MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                  sizeof msg, 0,
                  MACH_PORT_NULL,
                  500, /* 500 ms send timeout; auth port should be
                        * up and the message is one-way, so this is a
                        * loud-failure budget rather than a real
                        * timeout. */
                  MACH_PORT_NULL);
    /* auth_send's send-ref was consumed by COPY_SEND; deallocate our
     * local ref to drop the user-ref count back to where the libports
     * vending left it.  COPY_SEND is the right poly for this slot
     * because we want both the kernel and our local task to be able
     * to drop their refs independently; MOVE_SEND on auth_send would
     * also work but would force us to skip the deallocate. */
    mach_port_deallocate(mach_task_self(), auth_send);

    if (kr != KERN_SUCCESS) {
        /* on send failure the kernel did NOT consume the MOVE_SEND
         * rendezvous descriptor; we still own it.  drop both the send
         * ref and the receive right we allocated. */
        mach_port_mod_refs(mach_task_self(), rendez_rcv,
                           MACH_PORT_RIGHT_RECEIVE, -1);
        if (kr == MACH_SEND_INVALID_DEST) {
            errno = EAGAIN;
        } else {
            errno = EACCES;
        }
        return -1;
    }

    /* register the client side with the auth server.  the supervisor's
     * drain will pick up our submit_nonce message and run the matching
     * auth_server_authenticate against the same rendezvous; the auth
     * server matches the two halves and we get a fresh auth port back.
     * MACH_SEND_INVALID_DEST means the auth server is briefly down
     * (boot-time race); surface EAGAIN so the caller can retry. */
    mach_port_t newport = MACH_PORT_NULL;
    auth_t self_auth = getauth();
    if (self_auth == MACH_PORT_NULL) {
        mach_port_mod_refs(mach_task_self(), rendez_rcv,
                           MACH_PORT_RIGHT_RECEIVE, -1);
        errno = EACCES;
        return -1;
    }
    kr = auth_user_authenticate(self_auth, rendez_rcv,
                                MACH_MSG_TYPE_MAKE_SEND,
                                &newport);
    mach_port_deallocate(mach_task_self(), self_auth);
    /* rendez_rcv has done its job; drop the receive right.  the
     * supervisor side dropped its matched receive on its auth path. */
    mach_port_mod_refs(mach_task_self(), rendez_rcv,
                       MACH_PORT_RIGHT_RECEIVE, -1);

    if (kr == KERN_SUCCESS) {
        if (MACH_PORT_VALID(newport))
            mach_port_deallocate(mach_task_self(), newport);
        return 0;
    }
    if (kr == MACH_SEND_INVALID_DEST) {
        errno = EAGAIN;
        return -1;
    }
    errno = EACCES;
    return -1;
}

/* slice 3 of v0.8 design 2.2: publish the supervisor's long-lived auth
 * port as an active translator at /servers/geos-auth via libports.  see
 * docs/v08-hurd-peer-cred-design.md sections 3.5.4 (per-tick drain)
 * and 3.5.7 (the slice 2 transport finding that forced this rewrite).
 *
 * the slice 2 attempt installed a bare mach_port_allocate'd receive
 * port via file_set_translator and got KERN_SUCCESS, but
 * file_name_lookup("/servers/geos-auth", 0, 0) silently bypassed the
 * "active translator" and returned the bare file node instead.  cause:
 * the kernel records that a translator exists but the lookup path
 * only routes traffic to it if there is a process at the other end
 * answering the fsys protocol.  a bare receive port with nothing
 * draining it is not such a process.
 *
 * slice 3 fixes this with libports.  every translator under /hurd/
 * uses the same shape:
 *
 *   - one ports_create_bucket() at startup; the bucket owns a portset
 *     plus the bookkeeping ports library needs (notify_port for
 *     dead-name notifications, a hash table from port-name to
 *     object).
 *   - one ports_create_class(...) per "kind" of port the server hands
 *     out.  we have exactly one kind: the auth root.
 *   - one ports_create_port(class, bucket, sizeof(struct port_info),
 *     &out) per actual port object the server vends.  again, one for
 *     us (the singleton auth root).  the object is a `struct
 *     port_info' the library zero-allocates and tracks; we get back
 *     a pointer to it.
 *   - to hand a send right to clients (via file_set_translator), we
 *     call ports_get_send_right(obj) which returns a freshly-vended
 *     send right name.  the receive right is owned by libports
 *     forever; we never touch it directly.
 *
 * we then call file_set_translator with that send right.  this time
 * file_name_lookup("/servers/geos-auth", 0, 0) issues fsys_getroot to
 * our send right, the message arrives on the bucket's portset, our
 * drain loop (hurd_auth_drain) pulls it out and dispatches via the
 * MIG-generated fsys_server() demuxer, which calls our S_fsys_getroot
 * stub, which returns another send right to the same auth port (so
 * the client ends up with a working send right to file_name_lookup
 * traffic against /servers/geos-auth).
 *
 * idempotency: if auth_port_obj is already non-NULL we return -1/EBUSY.
 * libports bucket state is non-trivial to tear down cleanly and the
 * supervisor only ever calls this once; a second call indicates a
 * caller bug we want to surface, not paper over.
 *
 * error translation: kern_return_t values from mach_port_*,
 * ports_create_*, and file_set_translator do NOT escape this function
 * as errno.  same convention the rest of this file uses; see
 * hurd_mount and hurd_reboot_cmd for the same pattern. */

/* libports state.  the three slots are populated together by
 * hurd_publish_auth_port and are read by hurd_auth_drain and our
 * fsys_getroot stub.  NULL/empty until publish succeeds; non-NULL
 * means "auth channel live, drain at every tick". */
static struct port_bucket *auth_bucket = NULL;
static struct port_class  *auth_class  = NULL;
static struct port_info   *auth_port_obj = NULL;

/* pending-auth table.  populated by S_geos_auth_submit_nonce as it
 * extracts {uid, gid} via auth_server_authenticate; read by
 * hurd_get_peer_cred which keys on the 16-byte nonce.
 *
 * fixed-size array on purpose: PID 1 forbids malloc in hot paths and
 * the auth path is hot (every client connection).  16 concurrent
 * pending handshakes is well above what 200ms-tick poller can race;
 * a 17th evicts the oldest expired row first.  TTL is 5 seconds per
 * §3.5.5 ("an abandoned handshake should never wedge").
 *
 * not thread-safe by construction: emacs is single-threaded and
 * hurd_auth_drain runs exclusively from the elisp main loop.  if a
 * future libports threadpool ever serves requests in parallel, this
 * table needs a mutex.  documented in port_layer.h's auth_drain
 * docstring. */
#define GEOS_AUTH_PENDING_MAX 16
/* GEOS_AUTH_NONCE_LEN hoisted to top of file (above hurd_get_peer_cred)
 * so hurd_client_auth_handshake can reference it; do not redeclare. */
#define GEOS_AUTH_TTL_SECS    5

struct pending_auth_row {
    uint8_t   nonce[GEOS_AUTH_NONCE_LEN];
    uint32_t  uid;
    uint32_t  gid;
    time_t    expiry;       /* 0 = empty slot */
};

static struct pending_auth_row pending_auth[GEOS_AUTH_PENDING_MAX];

/* GEOS_AUTH_SUBMIT_NONCE_MSGID hoisted to top of file (above
 * hurd_get_peer_cred) so hurd_client_auth_handshake can reference it.
 * picked outside both the fsys subsystem range (22000-22999) and the
 * libports notify range (default 64-71) to avoid any chance of
 * overlap.  the value is documented at the top-of-file declaration
 * and referenced from the standalone test harness so the two sides
 * agree on the wire format. */

/* expose a hash of the table's contents for the standalone harness;
 * 0 means "no entries", any other value lets the harness assert that
 * a submit_nonce changed the table without us needing to leak the
 * uid/gid through a side channel.  not part of the production
 * interface; gated by a static-only forward declaration.  the harness
 * links against its own copy (tests/hurd-publish-auth-port.c carries
 * a mirror); production port_hurd.c never reaches the body via the
 * port_caps table, hence the unused-function attribute. */
static unsigned long pending_auth_fingerprint(void) __attribute__((unused));

/* the legacy GNU Mach msg-type descriptors we hand-roll for the
 * submit-nonce verb.  the format predates MIG's modern descriptors and
 * matches what GNU Mach's auth_server_authenticate uses (verified
 * against the side-channel probe at tests/hurd-mach-sidechannel.c).
 *
 * the fields are:
 *   msgt_name      = MACH_MSG_TYPE_*  (PORT_NAME, MOVE_SEND, BYTE, ...)
 *   msgt_size      = bits per element (32 for ports on 32-bit, 64 on
 *                    64-bit; 8 for bytes)
 *   msgt_number    = element count
 *   msgt_inline    = 1 (we always send inline)
 *   msgt_longform  = 0 (short form fits everything we send)
 *   msgt_deallocate= 0
 *
 * the wire struct itself (submit_nonce_request) is hoisted to the top
 * of this file so hurd_client_auth_handshake can reference it; the
 * server-side handler below casts incoming messages to the same shape. */

/* MIG-style empty reply: just a header + the standard RetCode type
 * descriptor + a 4-byte kern_return_t.  used to reply to submit-nonce
 * sends so the kernel does not stall waiting for a reply on a port we
 * never demuxed. */
typedef struct {
    mach_msg_header_t Head;
    mach_msg_type_t   RetCodeType;
    kern_return_t     RetCode;
} mig_reply_t;

/* RetCode type descriptor.  format taken from MIG's generated server
 * code for any routine: msgt_name=INTEGER_32, size=32, number=1,
 * inline=1, longform=0, deallocate=0.  hand-coded here because we do
 * not pull in MIG for our private verb (only for fsys); see §3.5.3. */
static const mach_msg_type_t geos_retcode_type = {
    .msgt_name       = MACH_MSG_TYPE_INTEGER_32,
    .msgt_size       = 32,
    .msgt_number     = 1,
    .msgt_inline     = 1,
    .msgt_longform   = 0,
    .msgt_deallocate = 0,
    .msgt_unused     = 0,
};

/* S_fsys_getroot: when a client task does
 * `file_name_lookup("/servers/geos-auth", 0, 0)`, libdiskfs in that
 * task sends fsys_getroot to the active-translator send right our
 * file_set_translator call planted.  the message lands in our libports
 * bucket; the MIG-generated fsys_server demuxer routes it here.
 *
 * the contract is: return a send right to the "root file" the
 * translator exposes, plus do_retry=FS_RETRY_NORMAL with an empty
 * retry_name to tell libdiskfs "you found it, do not look further".
 * we hand back a freshly minted send right to our auth port (the same
 * port the fsys_getroot arrived on); the client then does its
 * geos_auth_submit_nonce RPC against that send right.
 *
 * slice 4 phase 4a: the original slice 3 body used
 * `ports_get_right() + MAKE_SEND`, which dispatched cleanly through our
 * demuxer (the drain counter saw the request) but the client's
 * `file_name_lookup` never received a usable port back.  the working
 * pattern (also used by hurd_publish_auth_port for the translator's
 * own send right) is `ports_get_send_right()`: it vends a
 * libports-managed user-ref against the receive right, and we hand
 * that ref to the kernel with `MOVE_SEND` so the reply marshaller
 * transfers ownership cleanly.  `ports_get_right` returns the bare
 * port-name with no user-ref bump; the MIG reply path on this gnumach
 * build rejects the resulting descriptor and the client stays blocked
 * in fsys_getroot.  swapping to MOVE_SEND closes the loop.  the
 * full diagnostic walkthrough lives in the slice 4 runlog under
 * docs/runlogs/.
 *
 * lifecycle: `ports_get_send_right` bumps the libports user-ref count;
 * MOVE_SEND consumes the bump on the reply, so the steady-state ref
 * count returns to the libports-managed baseline.  do NOT
 * mach_port_deallocate the send-right name ourselves; that double-drops
 * the ref and trips the libports no-senders notification machinery the
 * next time the kernel does its periodic accounting.
 *
 * dotdot_node is the client's port to our parent directory; we have no
 * use for it and the MIG-generated demuxer counts on us dropping the
 * ref ourselves (it does NOT auto-deallocate input port rights on
 * success). */
kern_return_t
fsys_getroot (fsys_t fsys,
              mach_port_t dotdot_node,
              const_idarray_t gen_uids,
              mach_msg_type_number_t gen_uids_cnt,
              const_idarray_t gen_gids,
              mach_msg_type_number_t gen_gids_cnt,
              int flags,
              retry_type *do_retry,
              string_t retry_name,
              mach_port_t *file,
              mach_msg_type_name_t *filePoly)
{
    (void)fsys; (void)gen_uids; (void)gen_uids_cnt;
    (void)gen_gids; (void)gen_gids_cnt; (void)flags;
    if (MACH_PORT_VALID(dotdot_node))
        mach_port_deallocate(mach_task_self(), dotdot_node);
    if (auth_port_obj == NULL) {
        *file = MACH_PORT_NULL;
        *filePoly = MACH_MSG_TYPE_COPY_SEND;
        *do_retry = FS_RETRY_NONE;
        retry_name[0] = '\0';
        return EOPNOTSUPP;
    }
    *do_retry = FS_RETRY_NORMAL;
    retry_name[0] = '\0';
    /* ports_get_send_right mints a fresh user-ref against the libports-
     * owned receive right and returns the kernel name of that send
     * right.  MOVE_SEND on the reply hands ownership of that ref to the
     * client task; the reply marshaller deallocates our side once the
     * message is on the wire.  if we used MAKE_SEND with a name that
     * has no user-ref we just bumped (the slice-3 `ports_get_right`
     * path), the kernel sees the receive right but cannot mint a fresh
     * send descriptor for it from our task's port table; the marshaller
     * fails silently and the client blocks. */
    *file = ports_get_send_right(auth_port_obj);
    *filePoly = MACH_MSG_TYPE_MOVE_SEND;
    return KERN_SUCCESS;
}

/* fingerprint hash over occupied pending_auth rows.  used by the
 * standalone harness to detect that submit_nonce mutated the table
 * without leaking uid/gid through any side channel.  pure data hash
 * over nonce+uid+gid; expiry intentionally excluded (the wall clock
 * makes runs non-deterministic). */
static unsigned long
pending_auth_fingerprint(void)
{
    unsigned long h = 1469598103934665603UL; /* FNV-1a 64-bit offset */
    for (int i = 0; i < GEOS_AUTH_PENDING_MAX; i++) {
        if (pending_auth[i].expiry == 0) continue;
        for (int j = 0; j < GEOS_AUTH_NONCE_LEN; j++) {
            h ^= pending_auth[i].nonce[j];
            h *= 1099511628211UL;
        }
        h ^= pending_auth[i].uid;
        h *= 1099511628211UL;
        h ^= pending_auth[i].gid;
        h *= 1099511628211UL;
    }
    return h;
}

/* drop the oldest-expiring row from the pending-auth table.  returns
 * the slot index that was vacated (or 0 if the table was already
 * empty enough that the caller can pick any slot).  used both as a
 * GC pass at the top of submit_nonce and as the eviction-on-full
 * fallback when 16 concurrent handshakes are queued. */
static int
pending_auth_gc(void)
{
    time_t now = time(NULL);
    int oldest_idx = 0;
    time_t oldest_expiry = pending_auth[0].expiry;
    for (int i = 0; i < GEOS_AUTH_PENDING_MAX; i++) {
        if (pending_auth[i].expiry != 0 && pending_auth[i].expiry < now) {
            memset(&pending_auth[i], 0, sizeof pending_auth[i]);
        }
        if (oldest_expiry == 0 ||
            (pending_auth[i].expiry != 0 &&
             pending_auth[i].expiry < oldest_expiry)) {
            oldest_idx = i;
            oldest_expiry = pending_auth[i].expiry;
        }
    }
    return oldest_idx;
}

/* find a free slot, evicting the oldest occupied one if all 16 are
 * taken.  always returns a valid index. */
static int
pending_auth_alloc_slot(void)
{
    (void)pending_auth_gc();
    for (int i = 0; i < GEOS_AUTH_PENDING_MAX; i++) {
        if (pending_auth[i].expiry == 0) return i;
    }
    /* table full of live rows; evict the oldest. */
    int idx = pending_auth_gc();
    memset(&pending_auth[idx], 0, sizeof pending_auth[idx]);
    return idx;
}

/* dispatch handler for our private geos_auth_submit_nonce verb.
 * called from hurd_auth_drain when a message with
 * msgh_id=GEOS_AUTH_SUBMIT_NONCE_MSGID arrives on the auth port.
 *
 * INP carries:
 *   - one MOVE_SEND port descriptor (the client's rendezvous send right)
 *   - 16 inline bytes (the nonce)
 *
 * we:
 *   1. run auth_server_authenticate against the rendezvous to extract
 *      the client's effective uid/gid set.  the auth server matches
 *      the rendezvous to whatever auth_user_authenticate call the
 *      client is making concurrently (the client's
 *      hurd_client_auth_handshake body); only the client task
 *      holding the matching receive right can complete the dance, so
 *      no other task can spoof a credential by guessing the nonce.
 *   2. on success, insert {nonce, uid[0], gid[0], now+TTL} into the
 *      pending_auth table.  slice 5's hurd_get_peer_cred looks up by
 *      nonce and reads back uid/gid.
 *   3. on failure, drop everything on the floor.  the client retries.
 *   4. send an empty reply back via OUTP so the kernel does not
 *      indefinitely block.  RetCode communicates success/failure but
 *      no caller actually reads it today (the client side is fire-
 *      and-forget; the AF_UNIX read of the matched uid/gid is the
 *      synchronization point).
 *
 * port lifecycle: the rendezvous send right arrived as MOVE_SEND, so
 * our task owns the ref now.  auth_server_authenticate consumes it
 * (it has to: the auth server needs the right to call
 * mach_port_request_notification on it).  if the call fails before
 * the auth server takes the right, we deallocate it ourselves. */
static void
S_geos_auth_submit_nonce(struct submit_nonce_request *inp,
                         mig_reply_t *outp)
{
    /* always-set reply header.  msgh_size is overwritten below to
     * sizeof the reply struct; msgh_id = inp->msgh_id + 100 mirrors
     * the MIG convention for reply ids on subsystem 900xx.  msgh_bits
     * swaps remote/local: the reply travels back on inp's old
     * remote port (the reply-port the kernel filled in for us). */
    mach_msg_header_t *rh = &outp->Head;
    rh->msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(inp->Head.msgh_bits),
                                   0);
    rh->msgh_size = sizeof(*outp);
    rh->msgh_remote_port = inp->Head.msgh_remote_port;
    rh->msgh_local_port = MACH_PORT_NULL;
    rh->msgh_seqno = 0;
    rh->msgh_id = inp->Head.msgh_id + 100;
    outp->RetCodeType = geos_retcode_type;
    outp->RetCode = KERN_SUCCESS;

    /* sanity: must have the rendezvous-port descriptor plus the
     * 16-byte nonce descriptor we documented.  a malformed message
     * gets a MIG_BAD_ARGUMENTS reply but does NOT crash the drain. */
    if (inp->Head.msgh_size < sizeof(*inp)) {
        outp->RetCode = MIG_BAD_ARGUMENTS;
        return;
    }
    /* dispose of the rendezvous regardless of outcome; the auth
     * server takes its own ref when authenticate succeeds. */
    mach_port_t rendez = inp->rendez;
    if (rendez == MACH_PORT_NULL || !MACH_PORT_VALID(rendez)) {
        outp->RetCode = MIG_BAD_ARGUMENTS;
        return;
    }

    /* slice 5: the real auth_server_authenticate dance.  the auth
     * server pairs our call (server side, holding the rendezvous
     * MOVE_SEND right that arrived in the message) with the client's
     * concurrent auth_user_authenticate call (client side, holding
     * the matching receive right).  on match, the auth server returns
     * a fresh "newport" send right (which we never use; the AF_UNIX
     * stream is the actual channel) plus the four out-array sets of
     * uid/gid.  we record euid[0]/egid[0] into pending_auth so the
     * supervisor's next hurd_get_peer_cred tick reads them back.
     *
     * the 13-arg signature is libc's auth_server_authenticate from
     * <hurd/auth.h>; the parameter order matches GNU Mach's
     * generated auth_S.h server-routine call (rendezvous +
     * disposition, newport-receive + disposition, then the four
     * (buf,cnt) pairs in euid/auid/egid/agid order).  newport is
     * MACH_PORT_NULL here because we don't want a new auth port back;
     * passing NULL with MACH_MSG_TYPE_COPY_SEND tells the server we
     * are uninterested in the returned send right.
     *
     * port lifecycle: auth_server_authenticate consumes the
     * rendezvous send right (it has to: it does a
     * mach_port_request_notification on it to detect a crashed
     * client).  the four uid/gid arrays come back as out-of-line
     * vm_allocate'd memory; we vm_deallocate them after copying the
     * one byte we care about.  on failure paths before the call
     * succeeds, we deallocate rendez ourselves; the buffers are
     * untouched. */
    auth_t self_auth = getauth();
    if (self_auth == MACH_PORT_NULL) {
        (void)mach_port_deallocate(mach_task_self(), rendez);
        outp->RetCode = KERN_RESOURCE_SHORTAGE;
        return;
    }

    uid_t  *euid_buf = NULL, *auid_buf = NULL;
    gid_t  *egid_buf = NULL, *agid_buf = NULL;
    mach_msg_type_number_t n_euid = 0, n_auid = 0, n_egid = 0, n_agid = 0;

    kern_return_t kr = auth_server_authenticate(self_auth,
                                                rendez,
                                                MACH_MSG_TYPE_MOVE_SEND,
                                                MACH_PORT_NULL,
                                                MACH_MSG_TYPE_COPY_SEND,
                                                &euid_buf, &n_euid,
                                                &auid_buf, &n_auid,
                                                &egid_buf, &n_egid,
                                                &agid_buf, &n_agid);
    (void)mach_port_deallocate(mach_task_self(), self_auth);

    if (kr != KERN_SUCCESS) {
        /* auth server failed to match the rendezvous.  drop the
         * rendez send right (the server did not take it) and bail.
         * the client's next handshake attempt is independent. */
        (void)mach_port_deallocate(mach_task_self(), rendez);
        outp->RetCode = kr;
        return;
    }

    /* empty effective-set means "nobody"; design 3.2 step 7 says
     * surface EACCES.  no row gets recorded; the client times out
     * on hurd_get_peer_cred's 5x200ms retry budget. */
    if (n_euid == 0 || n_egid == 0) {
        if (euid_buf) vm_deallocate(mach_task_self(),
                                    (vm_address_t)euid_buf,
                                    n_euid * sizeof(uid_t));
        if (auid_buf) vm_deallocate(mach_task_self(),
                                    (vm_address_t)auid_buf,
                                    n_auid * sizeof(uid_t));
        if (egid_buf) vm_deallocate(mach_task_self(),
                                    (vm_address_t)egid_buf,
                                    n_egid * sizeof(gid_t));
        if (agid_buf) vm_deallocate(mach_task_self(),
                                    (vm_address_t)agid_buf,
                                    n_agid * sizeof(gid_t));
        outp->RetCode = EACCES;
        return;
    }

    /* record the row.  uid[0]/gid[0] are the effective set's first
     * entries, which Hurd userland convention treats as the
     * primary effective uid/gid. */
    int slot = pending_auth_alloc_slot();
    memcpy(pending_auth[slot].nonce, inp->nonce, GEOS_AUTH_NONCE_LEN);
    pending_auth[slot].uid = (uint32_t)euid_buf[0];
    pending_auth[slot].gid = (uint32_t)egid_buf[0];
    pending_auth[slot].expiry = time(NULL) + GEOS_AUTH_TTL_SECS;

    /* clean up the four out-of-line buffers.  vm_deallocate is a
     * Mach RPC against our own task; cheap (sub-microsecond) but
     * required to avoid leaking address space on every handshake. */
    vm_deallocate(mach_task_self(), (vm_address_t)euid_buf,
                  n_euid * sizeof(uid_t));
    vm_deallocate(mach_task_self(), (vm_address_t)auid_buf,
                  n_auid * sizeof(uid_t));
    vm_deallocate(mach_task_self(), (vm_address_t)egid_buf,
                  n_egid * sizeof(gid_t));
    vm_deallocate(mach_task_self(), (vm_address_t)agid_buf,
                  n_agid * sizeof(gid_t));
}

/* our top-level demuxer: chained fsys_server_routine (for fsys_getroot
 * from libdiskfs) then ports_notify_server (for libports' own
 * bookkeeping notifications: no-senders on the auth port, dead-name on
 * cached client send rights).  our private submit_nonce verb is
 * dispatched by its msgh_id without going through MIG, since
 * hand-rolling one message is cheaper than carrying MIG just for it
 * (§3.5.3).
 *
 * MIG's user-facing demuxer API on this libmig build is the table
 * lookup helper fsys_server_routine(InHeadP): it returns a
 * mig_routine_t (function pointer) if the msgh_id falls inside the
 * fsys subsystem range (22000-22011), NULL otherwise.  the boolean
 * fsys_server() that some older MIG vintages emit is absent here, so
 * we drive the routine pointer ourselves. */
static int
geos_auth_demuxer(mach_msg_header_t *inp, mach_msg_header_t *outp)
{
    if (inp->msgh_id == GEOS_AUTH_SUBMIT_NONCE_MSGID) {
        S_geos_auth_submit_nonce((struct submit_nonce_request *)inp,
                                 (mig_reply_t *)outp);
        return 1;
    }
    mig_routine_t fr = fsys_server_routine(inp);
    if (fr != 0) {
        (*fr)(inp, outp);
        return 1;
    }
    if (ports_notify_server(inp, outp))
        return 1;
    /* unknown id: leave outp untouched and return 0 so libports knows
     * we did not handle it.  the bucket reports the unhandled id and
     * drops the message (any reply port included gets deallocated by
     * libports' default rejection path). */
    return 0;
}

static int
hurd_publish_auth_port(void)
{
    if (auth_port_obj != NULL) {
        errno = EBUSY;
        return -1;
    }

    /* step 1: create the libports bucket + class.  bucket owns the
     * portset everything goes onto; class owns the cleanup callback
     * (NULL: we never destroy the auth port). */
    auth_bucket = ports_create_bucket();
    if (auth_bucket == NULL) {
        errno = ENOMEM;
        return -1;
    }
    auth_class = ports_create_class(NULL, NULL);
    if (auth_class == NULL) {
        /* libports has no public bucket-destroy; the bucket leaks until
         * process exit, which is acceptable for an unreachable
         * one-shot startup failure. */
        auth_bucket = NULL;
        errno = ENOMEM;
        return -1;
    }

    /* step 2: create the singleton auth port object.  sizeof(struct
     * port_info) is the canonical minimum size; libports does NOT
     * allocate trailing user data unless you ask for more. */
    struct port_info *pi = NULL;
    error_t kr = ports_create_port(auth_class, auth_bucket,
                                   sizeof(struct port_info), &pi);
    if (kr != KERN_SUCCESS || pi == NULL) {
        auth_class = NULL;
        auth_bucket = NULL;
        errno = (kr == KERN_RESOURCE_SHORTAGE) ? ENOMEM : EIO;
        return -1;
    }

    /* step 3: ensure /servers/geos-auth exists as a bare file node.
     * an existing file is fine (O_CREAT without O_EXCL); a missing
     * /servers/ directory surfaces as ENOENT from open(2) which we
     * propagate, since fabricating /servers/ ourselves would mask a
     * broken bootstrap.  mode 0600: the filesystem keys the
     * translator on the node not on its permissions, but tighter is
     * cheaper to keep clean than looser. */
    int fd = open("/servers/geos-auth", O_CREAT | O_WRONLY, 0600);
    if (fd < 0) {
        int saved = errno;
        ports_port_deref(pi);
        auth_class = NULL;
        auth_bucket = NULL;
        errno = saved;
        return -1;
    }
    (void)close(fd);

    /* step 4: get a file port to the bare node (O_NOTRANS so we do
     * not chain behind any pre-existing translator).  any pre-existing
     * translator gets FS_TRANS_FORCE-replaced in step 5. */
    file_t node = file_name_lookup("/servers/geos-auth", O_NOTRANS, 0);
    if (node == MACH_PORT_NULL) {
        int saved = errno;
        ports_port_deref(pi);
        auth_class = NULL;
        auth_bucket = NULL;
        errno = saved ? saved : EIO;
        return -1;
    }

    /* step 5: install a libports-vended send right as the active
     * translator.  passive fields zeroed so no on-disk passive record
     * is written.
     *
     * MOVE_SEND vs COPY_SEND: ports_get_send_right returns a fresh
     * user-ref each time; we hand the ref straight to the kernel via
     * MOVE_SEND so our task's user-ref count drops back to the
     * libports-managed baseline.  COPY_SEND would mint a second ref
     * we would then have to ports-deallocate, which is more code for
     * no behaviour difference. */
    mach_port_t send_right = ports_get_send_right(pi);
    kr = file_set_translator(node,
                             0,                          /* passive_flags */
                             FS_TRANS_SET | FS_TRANS_FORCE, /* active_flags */
                             0,                          /* oldtrans_flags */
                             NULL, 0,                    /* passive argz */
                             send_right,                 /* active port */
                             MACH_MSG_TYPE_MOVE_SEND);
    (void)mach_port_deallocate(mach_task_self(), node);

    if (kr != KERN_SUCCESS) {
        /* MOVE_SEND was already consumed by the (failed) call, so we
         * do not deallocate send_right ourselves.  the port object
         * deref releases libports' bookkeeping; the underlying
         * receive right then has no holders and the kernel reclaims
         * it.  mapping mirrors hurd_mount's error switch. */
        ports_port_deref(pi);
        auth_class = NULL;
        auth_bucket = NULL;
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

    /* commit: slot reflects "published".  hurd_auth_drain reads this
     * to gate its mach_msg loop. */
    auth_port_obj = pi;
    memset(pending_auth, 0, sizeof pending_auth);
    return 0;
}

/* slice 3 per-tick drain.  pulled exactly once per Fpid1_rpc_poll
 * tick, bounded at GEOS_AUTH_DRAIN_BATCH messages so an adversarial
 * fsys_getroot/submit_nonce flood cannot starve the AF_UNIX accept
 * path that the same tick services right after.  see
 * docs/v08-hurd-peer-cred-design.md section 3.5.4 for the rationale.
 *
 * non-blocking by construction: MACH_RCV_TIMEOUT with timeout=0 means
 * "return MACH_RCV_TIMED_OUT immediately if the queue is empty"; the
 * common-case cost is one kernel trap returning an error code.  the
 * tick budget impact when the channel is idle is negligible (sub-
 * microsecond).
 *
 * reply lifecycle: our demuxer fills the outp header + reply payload;
 * if reply.msgh_remote_port is valid we send it back via the same
 * mach_msg call.  the MIG-generated fsys_server demuxer follows the
 * same convention (the reply port is in the original request's
 * msgh_remote_port; we forward it through to outp), so the chained
 * dispatch works without us tracking reply ports separately. */
#define GEOS_AUTH_DRAIN_BATCH 16
#define GEOS_AUTH_DRAIN_BUF   8192

static int
hurd_auth_drain(void)
{
    if (auth_port_obj == NULL || auth_bucket == NULL) {
        /* publish_auth_port has not run yet (or failed).  surface
         * ENOSYS so the supervisor's tick can skip the drain without
         * panicking; same shape the get_peer_cred slot uses today. */
        errno = ENOSYS;
        return -1;
    }

    /* one stack-allocated buffer used for both receive and reply.
     * 8 KiB is roomy: fsys_getroot's request is ~80 B, reply is
     * 1112 B, our submit_nonce request is ~80 B.  no malloc anywhere
     * in the drain (PID 1 hot-path rule). */
    union {
        mach_msg_header_t hdr;
        uint8_t buf[GEOS_AUTH_DRAIN_BUF];
    } in_msg, out_msg;

    for (int i = 0; i < GEOS_AUTH_DRAIN_BATCH; i++) {
        /* zero both buffers every iteration.  the previous iteration's
         * reply may have left a stale msgh_remote_port name in
         * out_msg; without the memset the next read could resurrect
         * it when the demuxer takes a swallow-message path that does
         * not touch the reply header.  documented in
         * the slice 4 runlog under docs/runlogs/ for the diagnostic
         * walkthrough that named the bug. */
        memset(&in_msg, 0, sizeof in_msg);
        memset(&out_msg, 0, sizeof out_msg);
        in_msg.hdr.msgh_local_port = auth_bucket->portset;
        in_msg.hdr.msgh_size = sizeof in_msg;
        /* MACH_RCV_LARGE was dropped from the flag set on slice 4
         * cleanup: without a real large-buffer retry path the flag is
         * just a way to leave an oversize message queued, which then
         * keeps bouncing back and chews the drain batch.  without
         * MACH_RCV_LARGE gnumach destroys the over-sized message and
         * returns MACH_RCV_TOO_LARGE; the next iteration sees a fresh
         * queue.  any verb we support fits well under
         * GEOS_AUTH_DRAIN_BUF (fsys_getroot request is ~80 B, reply
         * ~1100 B; submit_nonce request is ~80 B). */
        kern_return_t kr = mach_msg(&in_msg.hdr,
                                    MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                    0,
                                    sizeof in_msg,
                                    auth_bucket->portset,
                                    0,                /* timeout = 0 ms */
                                    MACH_PORT_NULL);
        if (kr == MACH_RCV_TIMED_OUT)
            return 0;
        if (kr == MACH_RCV_TOO_LARGE) {
            /* gnumach destroyed the oversize message (no MACH_RCV_LARGE
             * means "drop, do not requeue"); skip and keep draining. */
            continue;
        }
        if (kr != KERN_SUCCESS) {
            errno = EIO;
            return -1;
        }

        /* fill outp.head defaults so a demuxer that fails to set
         * msgh_size/bits does not produce a bogus reply.  the
         * MIG-generated demuxers always do set them on success; the
         * memset above plus this explicit zero are belt-and-braces. */
        out_msg.hdr.msgh_size = 0;
        out_msg.hdr.msgh_remote_port = MACH_PORT_NULL;
        (void)geos_auth_demuxer(&in_msg.hdr, &out_msg.hdr);
        /* send reply iff the demuxer left a valid remote port (i.e.
         * the original message had a reply port and the demuxer
         * accepted the call).  one-way messages like
         * submit_nonce-with-no-reply-port short-circuit here.  every
         * MIG-generated reply header carries the original request's
         * msgh_remote_port as the reply destination; the send-once
         * right is consumed by mach_msg, so we do NOT need to
         * mach_port_deallocate it afterwards. */
        if (MACH_PORT_VALID(out_msg.hdr.msgh_remote_port) &&
            out_msg.hdr.msgh_size > 0) {
            kern_return_t sr = mach_msg(&out_msg.hdr,
                                        MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                        out_msg.hdr.msgh_size, 0,
                                        MACH_PORT_NULL,
                                        0, MACH_PORT_NULL);
            if (sr != KERN_SUCCESS) {
                /* send-once right was consumed by mach_msg on every
                 * error code that touches the port table (the kernel
                 * destroys the descriptor even when the send fails).
                 * the only thing left to clean is the reply payload,
                 * which lives on our stack and unwinds with the loop.
                 * NOT deallocating msgh_remote_port here is deliberate;
                 * double-deallocating a send-once right is the
                 * canonical drain crash mode. */
            }
        }
    }
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
    .auth_drain            = hurd_auth_drain,
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
