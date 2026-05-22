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
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
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
#include <hurd/fs.h>
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
#include <mach/error.h>
#include <mach/mach_host.h>
#include <mach/message.h>
#include <mach/mig_errors.h>
#include <mach/notify.h>

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

/* fsys_server is the MIG-emitted boolean wrapper around the
 * fsys_server_routines[] table.  fsys_S.h declares only the table
 * lookup helper fsys_server_routine (a static __inline that returns
 * the routine pointer for a given msgh_id); the boolean wrapper that
 * actually fills in the reply-header fields (msgh_bits with
 * REPLY-as-REMOTE, msgh_size to the reply struct, msgh_remote_port
 * to InP->msgh_reply_port, msgh_local_port to NULL, msgh_seqno to 0,
 * msgh_id to InP->msgh_id + 100) is emitted in fsysServer.c but not
 * exported in the header.  declare it here so geos_auth_demuxer can
 * call it; the bare routine pointer alone only sets RetCode plus
 * data fields and leaves msgh_remote_port at its memset-zero value,
 * which silently swallows the reply and wedges the client. */
extern boolean_t fsys_server(mach_msg_header_t *InHeadP,
                             mach_msg_header_t *OutHeadP);

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

/* remount / read-write via fsys_set_options("--writable") on the
 * root fsys port.  this is the moral equivalent of `fsysopts /
 * --writable` from the shell, except pid1 has to do the RPC by
 * hand because there is no shell to run yet.
 *
 * why pid1 needs this: on a stock Debian GNU/Hurd 0.9 boot, /sbin/
 * init normally runs /etc/init.d/checkroot.sh which fsysopts-remounts
 * / rw before any other service comes up.  pid1 replaced /sbin/init,
 * so checkroot.sh never runs, and / stays read-only the moment we
 * reach the do_mount block.  every tmpfs translator-attach against
 * a RO / fails with EIO (the translator record cannot be written),
 * sethostname returns EROFS (the proc server's sethostname path
 * touches /etc), and once emacs comes up native-comp aborts on a
 * RO /tmp.  the cascade was captured live in v0.9.11 VM-verify
 * round 8; see docs/runlogs/2026-05-18-hurd-pid1-boot-result.md
 * for the exact trail of EIO/EROFS lines that drove this slice.
 *
 * the RPC dance: file_name_lookup("/", 0, 0) gives a file port to
 * the root directory; file_getcontrol on that port returns the
 * fsys (filesystem control) port for whichever translator is
 * serving / right now (on a Debian Hurd boot that is /hurd/ext2fs
 * sitting on hd0s1 or hd0s2).  file_name_lookup on a Hurd / always
 * returns the underlying root fsys node rather than a chained
 * translator, because / has no overlay translator by convention;
 * if a future setup violates that and stacks a unionfs on /, this
 * call would target the topmost translator and the underlying ext2
 * would still be RO.  the supervisor would notice via the cascaded
 * EIO/EROFS just like today; not our problem to solve in pid1.
 *
 * fsys_set_options(fsys, opts, opts_len, do_children) takes an
 * argz-style options string.  for a one-shot flag we just pass
 * "--writable" with a NUL terminator (opts_len = strlen + 1) and
 * do_children = 0 because there are no chained translators under /
 * we want to recurse into.  /hurd/ext2fs handles --writable by
 * flipping its internal RW flag and the on-disk superblock state
 * mark; subsequent writes through the translator succeed.
 *
 * errno translation contract: error_t comes back as a Mach
 * kern_return_t, NOT a POSIX errno, and raw values like
 * KERN_PROTECTION_FAILURE (0x1) would surface as garbage in the
 * elisp layer.  same translation table as hurd_mount's tail:
 *   KERN_INVALID_ARGUMENT  -> EINVAL
 *   KERN_NO_ACCESS         -> EACCES
 *   KERN_PROTECTION_FAILURE-> EACCES
 *   MACH_SEND_INVALID_DEST -> ENOENT
 *   EOPNOTSUPP             -> EOPNOTSUPP (already a POSIX errno;
 *                            passed through unchanged so the elisp
 *                            layer can distinguish "fsys does not
 *                            support remount" from generic IO)
 *   anything else          -> EIO
 *
 * port lifetime: root_node is a file port we own after the lookup;
 * deallocate it as soon as file_getcontrol returns (success or
 * failure).  root_fsys is a SEND right we own after file_getcontrol
 * succeeds; deallocate it after fsys_set_options returns.  pid1
 * lives forever so a leaked Mach port at boot would never be reaped;
 * the boot-once posture does not excuse the leak, it just hides it.
 *
 * second-call behaviour: fsys_set_options("--writable") on an
 * already-rw ext2fs is documented as a no-op return 0, but other
 * translators (tmpfs, unionfs) have not been verified.  pid1 calls
 * this exactly once per boot, before do_mount; that is the only
 * contract the caller side enforces. */
static int
hurd_remount_root_rw(void)
{
    static const char opts[] = "--writable";
    /* file_name_lookup with flags=0, mode=0 means "follow translators,
     * read-only port, no creation".  on Hurd a port to / is always
     * grantable because everyone can lookup /; the RO posture of the
     * fs does not prevent obtaining a file port to its root. */
    file_t root_node = file_name_lookup("/", 0, 0);
    if (root_node == MACH_PORT_NULL) {
        /* file_name_lookup already translated to a POSIX errno via
         * __hurd_fail; nothing to save, errno is already what we want
         * the caller to see. */
        return -1;
    }

    /* the MACH_PORT_NULL initializer is load-bearing on the rc != 0
     * path below.  MIG-generated out-param stubs by convention leave
     * the port unset on failure, but a future translator rewrite that
     * sends a port AND a non-zero rc would leak the port if we trusted
     * file_getcontrol to always write something.  do NOT remove the
     * explicit zero-init. */
    fsys_t root_fsys = MACH_PORT_NULL;
    error_t rc = file_getcontrol(root_node, &root_fsys);
    /* drop the file port now; we are done with it whether or not we
     * got the fsys port back.  the kernel ref count on the underlying
     * node stays positive via the fsys port we just acquired (on
     * success) or via pfinet/proc/root callers (on failure). */
    mach_port_deallocate(mach_task_self(), root_node);
    if (rc) {
        switch (rc) {
        case KERN_INVALID_ARGUMENT:    errno = EINVAL; break;
        case KERN_NO_ACCESS:           errno = EACCES; break;
        case KERN_PROTECTION_FAILURE:  errno = EACCES; break;
        case MACH_SEND_INVALID_DEST:   errno = ENOENT; break;
        case EOPNOTSUPP:               errno = EOPNOTSUPP; break;
        default:                       errno = EIO; break;
        }
        return -1;
    }

    /* opts_len includes the trailing NUL: fsys_set_options takes an
     * argz vector and a length, and a single-string argz is exactly
     * "string\0" with len = strlen+1.  do_children = 0 because there
     * are no nested translators under / we want to walk into. */
    rc = fsys_set_options(root_fsys, (char *)opts, sizeof opts, 0);
    /* drop the fsys port either way.  ext2fs holds its own kernel-side
     * refs on the translator process; our send right was a transient
     * handle for this one RPC. */
    mach_port_deallocate(mach_task_self(), root_fsys);
    if (rc) {
        switch (rc) {
        case KERN_INVALID_ARGUMENT:    errno = EINVAL; break;
        case KERN_NO_ACCESS:           errno = EACCES; break;
        case KERN_PROTECTION_FAILURE:  errno = EACCES; break;
        case MACH_SEND_INVALID_DEST:   errno = ENOENT; break;
        case EOPNOTSUPP:               errno = EOPNOTSUPP; break;
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
/* the port slot is mach_port_name_inlined_t (an 8-byte union holding
 * a 4-byte name + 4 bytes padding) and the matching type descriptor's
 * msgt_size is 64.  MIG-generated request structs use this shape for
 * every port descriptor on 64-bit Hurd; declaring the slot as the
 * bare 4-byte mach_port_t leaves four bytes of trailing padding the
 * kernel reads as the next 32 bits of port name, and the send fails
 * with MACH_SEND_INVALID_DEST.  hurd-gotchas.md catalogues the
 * 2026-05-18 slice-5 trace where this was first caught. */
struct submit_nonce_request {
    mach_msg_header_t        Head;
    mach_msg_type_t          rendez_type;
    mach_port_name_inlined_t rendez;
    mach_msg_type_t          nonce_type;
    uint8_t                  nonce[GEOS_AUTH_NONCE_LEN];
};

/* publish/pending state hoisted for hurd_get_peer_cred.  the canonical
 * definitions and the long-form rationale live near the libports
 * publish_auth_port block ~line 1167; we duplicate just the names +
 * struct shape here because hurd_get_peer_cred is keyed on the table
 * and we want the lookup body to stay co-located with the slice-5
 * design comment above it.  keep these in sync with the canonical
 * defs; the compiler will catch any drift via redeclaration errors. */
#define GEOS_AUTH_PENDING_MAX 16
struct pending_auth_row {
    uint8_t   nonce[GEOS_AUTH_NONCE_LEN];
    uint32_t  uid;
    uint32_t  gid;
    time_t    expiry;       /* 0 = empty slot */
};
static struct port_info *auth_port_obj;
static struct pending_auth_row pending_auth[GEOS_AUTH_PENDING_MAX];

/* hurd_auth_drain forward decl: hurd_get_peer_cred's retry loop kicks
 * the drain on every iteration; the drain body itself lives below near
 * the libports publish/demuxer machinery for narrative reasons.
 * re-entry from the retry site is safe: stack-only buffers, no
 * per-call statics, mach_msg with timeout=0 returns cleanly. */
static int hurd_auth_drain(void);

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
        /* drain on every retry: Fpid1_rpc_poll only kicks auth_drain
         * once per tick, but our 200ms-per-attempt budget needs a fresh
         * mach_msg sweep at each step so a late-arriving submit_nonce
         * gets recorded before we re-scan pending_auth[]. */
        (void)hurd_auth_drain();
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

    /* rendezvous port descriptor: one MOVE_SEND, in-line, short form.
     * msgt_size is 64 (bits) to match the mach_port_name_inlined_t
     * port-slot width that gnumach reads; see the struct definition's
     * comment for why the bare mach_port_t spelling silently breaks. */
    msg.rendez_type.msgt_name       = MACH_MSG_TYPE_MOVE_SEND;
    msg.rendez_type.msgt_size       = 64;
    msg.rendez_type.msgt_number     = 1;
    msg.rendez_type.msgt_inline     = 1;
    msg.rendez_type.msgt_longform   = 0;
    msg.rendez_type.msgt_deallocate = 0;
    msg.rendez_type.msgt_unused     = 0;
    msg.rendez.name = rendez_send;

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
/* auth_port_obj hoisted to top of file (above hurd_get_peer_cred) so
 * the slice-5 lookup can reference it without a circular textual
 * dependency; defined as the canonical tentative-definition there,
 * which the linker resolves to a single zero-init slot. */

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
/* GEOS_AUTH_PENDING_MAX, struct pending_auth_row, and the
 * pending_auth[] array itself are hoisted above hurd_get_peer_cred
 * (this file's first user) so the lookup body stays co-located with
 * the slice-5 design comment.  GEOS_AUTH_NONCE_LEN is hoisted there
 * too; do not redeclare. */
#define GEOS_AUTH_TTL_SECS    5

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
        /* Debian Hurd 0.9 enum retry_type defines NORMAL/REAUTH/MAGICAL
         * only; FS_RETRY_NONE does not exist.  the "no further dir_lookup
         * needed" idiom in fs.defs is FS_RETRY_NORMAL with empty name. */
        *do_retry = FS_RETRY_NORMAL;
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
    mach_port_t rendez = inp->rendez.name;
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
 * MIG's user-facing demuxer API on this libmig build has two layers:
 * fsys_server_routine(InHeadP) returns a mig_routine_t pointer if the
 * msgh_id falls inside the fsys subsystem range (22000-22011), NULL
 * otherwise; the boolean fsys_server(InHeadP, OutHeadP) wrapper IS
 * emitted in fsysServer.c (despite the slice-3-era comment that said
 * otherwise) and is the one that fills the reply-header fields before
 * invoking the routine.  call the wrapper, not the routine: the inner
 * routine writes RetCode + data only and leaves msgh_remote_port at
 * the caller's zero, which silently drops the reply on the floor and
 * wedges the client (hurd-gotchas.md captures the slice-5 trace that
 * caught this). */
static int
geos_auth_demuxer(mach_msg_header_t *inp, mach_msg_header_t *outp)
{
    if (inp->msgh_id == GEOS_AUTH_SUBMIT_NONCE_MSGID) {
        S_geos_auth_submit_nonce((struct submit_nonce_request *)inp,
                                 (mig_reply_t *)outp);
        return 1;
    }
    if (fsys_server_routine(inp) != 0) {
        (void)fsys_server(inp, outp);
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

/* byte size of block device NAME via file_get_storage_info on a
 * storeio file_t.  the 2026-05-20 probe at docs/runlogs/
 * 2026-05-20-hurd-storeio-getsize.md falsified the cookbook (which
 * said device_get_status with DEV_GET_SIZE on the file_name_lookup
 * file_t); the file_t returned by file_name_lookup speaks the fs/io
 * protocol, not the Mach device protocol, and the cookbook RPC
 * returns MIG_BAD_ID (-303).  the working RPC is
 * file_get_storage_info from <hurd/fs.h>: it works on the same
 * file_t and returns enough structure (block_size in ints[2], a
 * sequence of (start, length) run pairs in offsets[]) that the size
 * is just `ints[2] * sum(offsets[2k+1])`.
 *
 * NAME validation: exact match for port_linux.c's contract (bare
 * device name, no NULL, no empty, no '/', no "..", no ".", cap at
 * 200 bytes).  the elisp caller already extracts the bare form from
 * a /dev/ scan; the check here is defence in depth so a future
 * callsite that grew a "/dev/" prefix can't escape into arbitrary
 * filesystem paths.  EINVAL on bad input.
 *
 * lifecycle: file_name_lookup returns MACH_PORT_NULL with errno set
 * on failure (ENOENT for a missing node, ENXIO for a node whose
 * translator is dead; the probe's /dev/cd0 + /dev/hd0 cases hit the
 * ENXIO path on the canonical image).  file_get_storage_info OOL-
 * allocates the four return arrays in our address space; we must
 * vm_deallocate each one and mach_port_deallocate each port right
 * in ports[] on every exit path, success or failure.  the supervisor
 * is long-lived; a Mach port or vm_allocation leak per disk lookup
 * would compound forever.
 *
 * overflow guards: the multiply ints[2] * run can wrap on a multi-TB
 * disk if either operand is interpreted as 32-bit; widen to uint64_t
 * first and check both the per-run multiply and the running-total
 * add against UINT64_MAX.  on overflow we surface EIO; the alternative
 * (returning a truncated size) would silently mis-size the disk in
 * the *disks* buffer.
 *
 * the libhurduser convention is that the error_t returned by an RPC
 * stub is already a POSIX errno (the stubs translate kern_return_t
 * via __hurd_fail internally), so assigning err directly to errno is
 * safe.  no mig_errors.h translation table here. */
static int
hurd_disk_size_bytes(const char *name, uint64_t *out)
{
    if (name == NULL || name[0] == '\0') { errno = EINVAL; return -1; }
    if (out == NULL) { errno = EINVAL; return -1; }
    size_t nlen = strlen(name);
    if (nlen > 200) { errno = EINVAL; return -1; }
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        errno = EINVAL; return -1;
    }
    for (size_t i = 0; i < nlen; i++) {
        if (name[i] == '/') { errno = EINVAL; return -1; }
    }

    /* build /dev/<name>.  256 fits any legal NAME (cap 200) plus the
     * 5-byte "/dev/" prefix plus NUL with margin. */
    char path[256];
    int pn = snprintf(path, sizeof path, "/dev/%s", name);
    if (pn < 0 || (size_t)pn >= sizeof path) { errno = EINVAL; return -1; }

    /* file_name_lookup returns MACH_PORT_NULL with errno set on
     * failure (ENOENT for missing node, ENXIO for translator-less
     * node, per the 2026-05-20 probe). */
    file_t f = file_name_lookup(path, O_READ, 0);
    if (f == MACH_PORT_NULL) return -1;  /* errno already set */

    /* OOL return arrays.  the kernel allocates these in our address
     * space; we must vm_deallocate each one before returning, even
     * on the error paths.  declared up front so the cleanup block can
     * walk them unconditionally. */
    mach_port_t *ports = NULL;
    mach_msg_type_number_t portsCnt = 0;
    int *ints = NULL;
    mach_msg_type_number_t intsCnt = 0;
    off_t *offsets = NULL;
    mach_msg_type_number_t offsetsCnt = 0;
    char *data = NULL;
    mach_msg_type_number_t dataCnt = 0;

    error_t err = file_get_storage_info(f, &ports, &portsCnt,
                                        &ints, &intsCnt,
                                        &offsets, &offsetsCnt,
                                        &data, &dataCnt);
    int rc = -1;
    int saved_errno = 0;

    if (err) {
        /* libhurduser error_t is already a POSIX errno. */
        saved_errno = err;
        goto cleanup;
    }

    /* invariants: need at least ints[2] for block_size, and at least
     * one (start, length) pair in offsets[].  the probe at
     * docs/runlogs/2026-05-20-hurd-storeio-getsize.md confirmed
     * intsCnt=6 and offsetsCnt=2 for wd0 and wd0s2; we accept any
     * shape that satisfies the minimums and has an even offsetsCnt
     * (start/length pairs). */
    if (intsCnt < 3 || offsetsCnt < 2 || (offsetsCnt % 2) != 0) {
        saved_errno = EIO;
        goto cleanup;
    }

    /* compute total_bytes = ints[2] * sum(offsets[2k+1]) over the
     * offsetsCnt/2 runs.  uint64_t accumulator so multi-TB disks do
     * not wrap.  ints[2] is a signed int in the RPC signature but
     * always non-negative in practice (block sizes are 512, 4096, ...);
     * cast through (unsigned) before widening to keep -Wsign-conversion
     * happy and to clamp any pathological negative to a huge positive
     * value that the overflow guard below will catch as EIO. */
    uint64_t bs = (uint64_t)(unsigned)ints[2];
    uint64_t total = 0;
    for (mach_msg_type_number_t k = 0; k < offsetsCnt; k += 2) {
        uint64_t run = (uint64_t)offsets[k + 1];
        /* per-run overflow: bs * run is the per-run byte count. */
        if (bs != 0 && run > UINT64_MAX / bs) {
            saved_errno = EIO;
            goto cleanup;
        }
        uint64_t add = bs * run;
        /* running-total overflow: total + add must fit. */
        if (add > UINT64_MAX - total) {
            saved_errno = EIO;
            goto cleanup;
        }
        total += add;
    }

    *out = total;
    rc = 0;

cleanup:
    /* OOL cleanup: vm_deallocate each array, mach_port_deallocate
     * each port right in ports[], then mach_port_deallocate the
     * file_t.  this is the standard libhurduser pattern; cleanup
     * runs on every path including error so we do not leak Mach
     * resources on a long-running supervisor.  per-element loop on
     * the ports[] array is required because vm_deallocate releases
     * the storage but does not deref the port rights it holds. */
    if (ports != NULL && portsCnt > 0) {
        for (mach_msg_type_number_t i = 0; i < portsCnt; i++) {
            mach_port_deallocate(mach_task_self(), ports[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)ports,
                      portsCnt * sizeof(*ports));
    }
    if (ints != NULL && intsCnt > 0) {
        vm_deallocate(mach_task_self(), (vm_address_t)ints,
                      intsCnt * sizeof(*ints));
    }
    if (offsets != NULL && offsetsCnt > 0) {
        vm_deallocate(mach_task_self(), (vm_address_t)offsets,
                      offsetsCnt * sizeof(*offsets));
    }
    if (data != NULL && dataCnt > 0) {
        vm_deallocate(mach_task_self(), (vm_address_t)data, dataCnt);
    }
    mach_port_deallocate(mach_task_self(), f);

    if (rc < 0) {
        errno = saved_errno;
    }
    return rc;
}

/* arm a "die when parent dies" link from the child of a fork()+exec()
 * sequence.  intended call site: in the child, after setsid() and
 * before exec(), inside spawn_xorg() and similar future spawn paths.
 * SIGNAL is the POSIX signal number to deliver to the child (typically
 * SIGTERM) when the parent process (pid1, or whoever getppid() returns
 * at arm time) dies.
 *
 * v0.9.9 v2 body (this commit): the real Mach dead-name notify path,
 * post-VM-verify falsification.  v1 (hurd/87a5ed5) FAILed VM-verify
 * on canonical Debian Hurd 0.9 for three load-bearing reasons; this
 * v2 body corrects each.
 *
 *   1. parent_task send right OWNERSHIP TRANSFERS TO THE WATCHER.
 *      v1 deallocated parent_task right after request_notification
 *      returned, on the assumption that the kernel had recorded the
 *      task by name and no longer needed our send right alive.  WRONG:
 *      mach/mach_port.defs:228-251 binds the notification to the
 *      ipc_entry in OUR ipc_space, not to a kernel-private table.
 *      when we dealloc parent_task its user-ref hits zero, the entry
 *      is freed, the recorded send-once is consumed silently, and the
 *      dead-name notification never arrives.  fix: the watcher holds
 *      parent_task alive for its lifetime and deallocates on exit.
 *
 *   2. RE-ENTRY IS BANNED.  v1 destroyed the prev receive right via
 *      mach_port_mod_refs(-1) under the assumption that the old
 *      watcher's blocked mach_msg would wake with MACH_RCV_PORT_DIED.
 *      WRONG: gnumach keys mach_msg receive wakeup on message arrival,
 *      not on receive-rights destruction.  100 back-to-back arm calls
 *      leaked +100 pthreads and +800 MiB of stack reservation.  fix:
 *      arm is idempotent on same-signal (returns 0, no-op), EALREADY
 *      on different-signal.  watcher count is always exactly 1 per
 *      process.  no pthread_cancel, no pthread_kill, no thread join.
 *
 *   3. PROC_PID2TASK RACE.  v1 test harness forked B and immediately
 *      armed; proc_pid2task fired KERN_INVALID_NAME because the proc
 *      server had not yet registered A's pid.  PRODUCTION spawn_xorg
 *      path is not affected (pid1 is the proc-server-registered
 *      ancestor of all tasks from boot).  fix lives in the test
 *      harness, not here: harness calls proc_child(getproc(), B_task)
 *      after fork to prime the lookup chain.
 *
 * call shape:
 *
 *   1. pid_t ppid = getppid().
 *
 *   2. process_t proc = getproc() (cached send right; do NOT
 *      deallocate).  proc_pid2task(proc, ppid, &parent_task) cited at
 *      /usr/include/x86_64-gnu/hurd/process.defs:234.  on any of the
 *      "parent-gone" code set {ESRCH wire, EIO wire, KERN_INVALID_NAME}
 *      (see hurd_pdeath_kr_is_parent_gone for the wire-value ground
 *      truth), retry with 100ms nanosleep up to 10 times (1s total)
 *      so a fresh-forked caller does not race the proc server's
 *      registration of its own pid.  on the persistent same set:
 *      pthread_kill(self, signal); errno=ESRCH; return -1.  ESRCH
 *      is the one stable errno callers see when the parent task is
 *      unreachable, regardless of which encoding the kernel surfaces.
 *      the v0.9.9 third-iteration VM-verify on Debian Hurd 0.9 /
 *      gnumach 1.8+git20260224 showed proc_pid2task returns its
 *      errors WRAPPED in the err_hurd subsystem (NOT err_kern as the
 *      v2.2 attempt at hurd/6e50576 assumed).  Hurd's <errno.h>
 *      defines the POSIX errno macros to those wrapped values
 *      directly, so the guard compares kr against ESRCH (0x40000003)
 *      and EIO (0x40000005) by symbol.  observed wire values:
 *        proc_pid2task(bogus pid) -> 0x40000003 = ESRCH
 *        proc_pid2task(stale pid) -> 0x40000005 = EIO
 *      the textbook bare-value KERN_INVALID_NAME (0xf) stays in the
 *      recognised set for kernels that surface it; not observed on
 *      Debian Hurd 0.9 in practice.  parent_task is a SEND right we
 *      own; the watcher will take ownership in step 6 and we MUST NOT
 *      deallocate it on the success path.
 *
 *   3. mach_port_allocate(self, MACH_PORT_RIGHT_RECEIVE, &notify_port).
 *      this is the receive right the kernel will send the dead-name
 *      notification to.  the watcher takes ownership; main body
 *      deallocates only on error.
 *
 *   4. mach_port_request_notification(self, parent_task,
 *          MACH_NOTIFY_DEAD_NAME, 0, notify_port,
 *          MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev).  cited:
 *          /usr/include/x86_64-gnu/mach/mach_port.defs:247 (the routine)
 *          and /usr/include/x86_64-gnu/mach/notify.defs:106 (the msgid,
 *          MACH_NOTIFY_DEAD_NAME = 0100 octal = 64 decimal).
 *      kernel reads parent_task by name (no transfer), mints a send-
 *      once from our receive right, and hands us back the previous
 *      notify port as `prev` which we MUST deallocate if VALID.
 *      `prev` ownership stays with main on every path (re-entry-
 *      rejected or success); the watcher never sees it.
 *
 *   5. RE-ENTRY CHECK under g_arm_lock.  if g_arm.active: clean up
 *      the resources we just allocated (deallocate parent_task,
 *      deallocate prev if VALID, mod_refs(-1) notify_port), and:
 *        - if g_arm.signal == sig: return 0 (idempotent no-op)
 *        - else:                   errno=EALREADY; return -1
 *      the previous arm stays live; we deliberately do NOT touch it.
 *
 *   6. heap-allocate hurd_pdeath_watcher_ctx with notify_port,
 *      parent_task_name (the send right's name; ownership now
 *      transferred to the watcher), and signal.
 *
 *   7. pthread_create detached.  on failure: free ctx, deallocate
 *      parent_task, mod_refs(-1) notify_port, unlock, errno from
 *      prc, return -1.
 *
 *   8. write g_arm and unlock.  if MACH_PORT_VALID(prev): deallocate
 *      before the unlock (lock ownership is irrelevant for the
 *      dealloc, but doing it under the lock keeps the cleanup grouped
 *      with the g_arm write).  return 0.
 *
 * watcher body: blocks in mach_msg(MACH_RCV_MSG, ctx->notify_port,
 * TIMEOUT_NONE).  TIMEOUT_NONE is safe because re-entry is banned;
 * nothing else tries to wake this thread.  on MACH_NOTIFY_DEAD_NAME
 * matching ctx->parent_task_name: kill(getpid(), signal), deallocate
 * BOTH parent_task_name AND notify_port, free ctx, pthread_exit.
 * on any other mach_msg outcome: log to /dev/console, deallocate
 * both rights, free ctx, pthread_exit.  the watcher OWNS both rights
 * from step 6 onward and is the sole place either gets released.
 *
 * ESRCH short-circuit: documented in step 2 above; raise the
 * requested signal in-process so the caller observes the same end-
 * state as a successful arm + instant fire.
 *
 * authority: docs/runlogs/2026-05-21-hurd-xorg-probe.md is the
 * receipt that pins both the slot shape and the load-bearing
 * primitive correction (probes F, F2, G).  v0.9.8 placeholder was
 * the ENOSYS body; v0.9.9 v1 (hurd/87a5ed5) shipped the watcher
 * with the wrong ownership and re-entry models; this commit (v2)
 * is the post-falsification rewrite.
 *
 * load-bearing falsification log: proc_setowner is NOT the right
 * primitive (Deprecated at /usr/include/x86_64-gnu/hurd/process.defs
 * :127).  the right primitive is MACH_NOTIFY_DEAD_NAME via
 * mach_port_request_notification at mach_port.defs:247 + notify.defs
 * :106.  v1's "release parent_task after request_notification" was
 * also falsified: the kernel needs the send right's ipc_entry to
 * stay populated for the notification record to survive (see
 * mach_port.defs:228-251).
 *
 * exec divergence: Mach receive rights are NOT inherited across
 * exec.  the watcher pthread also disappears at exec.  the death
 * link therefore breaks silently on the post-exec image; the caller
 * is expected to re-arm immediately after exec if it needs the link
 * in the exec'd binary.  this differs from Linux's PR_SET_PDEATHSIG
 * which survives exec.  the spawn_xorg() call site arms before
 * execve, which gives a small race window where Xorg starts and the
 * link is gone; on Hurd the kernel-level safety net (gnumach reboots
 * if pid1 dies) covers this, so the death link is purely defence-in-
 * depth.
 *
 * TBD-1: sync=0 in the request_notification call.  the spec defaults
 * to sync=0 ("notify only on real death, do not fire immediately if
 * the target is already a dead name when we ask").  sync=1 would
 * fire the notification immediately if parent_task is already dead
 * at request time; we get the same behaviour from the ESRCH short-
 * circuit above, so sync=0 is the lighter path.
 *
 * TBD-2: NO_SENDERS fail-safe registration is intentionally not
 * wired in this slice (deferred to v0.9.10).
 *
 * TBD-3: signal delivery from the watcher pthread.  v2 used
 * kill(getpid(), sig) on the theory that POSIX would deliver to
 * some unblocked thread.  on Hurd's multi-threaded signal delivery
 * VM-verify observed the signal landing in the watcher pthread's
 * own context, leaving the main thread parked in pause() /
 * mach_msg() forever.  v2.1 captures pthread_self() at arm time
 * into ctx->main_thread and the watcher calls
 * pthread_kill(ctx->main_thread, sig) instead, so the armer thread
 * is guaranteed to receive the signal.
 *
 * return values:
 *   0          : success, OR idempotent second arm with same signal.
 *   -1/EINVAL  : signal out of range.
 *   -1/ENOMEM  : malloc or pthread_create resource failure.
 *   -1/EALREADY: second arm with DIFFERENT signal; first arm stays
 *                live, no new watcher spun.
 *   -1/ESRCH   : parent already dead (after retry loop); fired on
 *                any of {ESRCH wire, EIO wire, KERN_INVALID_NAME}.
 *                the in-process pthread_kill(pthread_self(), signal)
 *                has already fired before this return.
 *   -1/EIO     : unknown kern_return_t escaped the local table. */

/* re-entrancy bookkeeping.  one process-global slot under a mutex.
 * v0.9.9 v2 contract: second arm with same signal is idempotent
 * (returns 0 with no side effects); second arm with different signal
 * fails fast with EALREADY.  there is never more than one watcher
 * pthread live in a process.
 *
 * parent_task_name is recorded so a future skeptic reading g_arm can
 * answer "which send right does the live watcher own?" without
 * chasing the heap ctx (which is owned exclusively by the watcher
 * pthread and freed on its exit). */
static struct {
    pthread_t       tid;               /* detached watcher; not joinable */
    mach_port_t     notify_port;       /* receive right held by watcher */
    mach_port_t     parent_task_name;  /* send right held by watcher */
    int             signal;            /* signal the watcher will raise */
    int             active;            /* 1 once tid+notify_port are valid */
} g_arm = { 0, MACH_PORT_NULL, MACH_PORT_NULL, 0, 0 };
static pthread_mutex_t g_arm_lock = PTHREAD_MUTEX_INITIALIZER;

/* heap struct handed to the detached watcher.  freed by the watcher
 * before it enters the blocking mach_msg.  three fields:
 * notify_port (the receive right the kernel will deliver into),
 * parent_task_name (the name we requested the notification against;
 * the watcher verifies the incoming not_port matches), and signal. */
struct hurd_pdeath_watcher_ctx {
    mach_port_t notify_port;
    mach_port_t parent_task_name;
    int         signal;
    pthread_t   main_thread;  /* the thread that called arm_parent_death;
                                 we deliver the signal to it specifically
                                 so a pause() / mach_msg() in that thread
                                 actually wakes (kill(getpid(),sig) on Hurd
                                 can pick the watcher's own thread). */
};

static void *
hurd_pdeath_watcher(void *arg)
{
    /* the heap ctx stays alive for the watcher's lifetime; we hold
     * the ONLY references to parent_task_name (send right) and
     * notify_port (receive right) in the process from the moment the
     * armer hands them to us.  re-entry is banned at the armer, so
     * nothing else will touch either right.  on every exit path we
     * free both rights and the ctx. */
    struct hurd_pdeath_watcher_ctx *ctx = arg;

    /* mach_msg buffer sized for mach_dead_name_notification_t (header
     * + trailer + not_port name).  the kernel-emitted dead-name
     * message is small; 256 bytes is the conventional comfortable
     * upper bound used elsewhere in this file. */
    union {
        mach_msg_header_t              hdr;
        mach_dead_name_notification_t  dn;
        char                           pad[256];
    } buf;

    for (;;) {
        /* zero before each receive: the kernel writes only the
         * header it is sending us, and the message-id check below
         * would dereference uninitialised storage if we left old
         * bytes in place across an unrelated msg.  belt and braces. */
        memset(&buf, 0, sizeof buf);

        mach_msg_return_t mr =
            mach_msg(&buf.hdr,
                     MACH_RCV_MSG,
                     0,
                     sizeof buf,
                     ctx->notify_port,
                     MACH_MSG_TIMEOUT_NONE,
                     MACH_PORT_NULL);

        if (mr != MACH_MSG_SUCCESS) {
            /* any failed receive is terminal.  re-entry is banned at
             * the armer so the previous-watcher teardown that v1
             * relied on via MACH_RCV_PORT_DIED never happens; if we
             * see a failure here something unrelated went wrong.
             * log, clean up both rights, free ctx, exit. */
            int fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
            if (fd >= 0) {
                char m[96];
                int n = snprintf(m, sizeof m,
                                 "pid1: pdeath watcher mach_msg failed mr=0x%x\n",
                                 (unsigned)mr);
                if (n > 0) { ssize_t w = write(fd, m, (size_t)n); (void)w; }
                (void)close(fd);
            }
            (void)mach_port_deallocate(mach_task_self(),
                                       ctx->parent_task_name);
            (void)mach_port_mod_refs(mach_task_self(), ctx->notify_port,
                                     MACH_PORT_RIGHT_RECEIVE, -1);
            free(ctx);
            pthread_exit(NULL);
        }

        if (buf.hdr.msgh_id != MACH_NOTIFY_DEAD_NAME) {
            /* unknown msgid on this port; log once and loop.  the
             * port is single-purpose (registered only for dead-name)
             * so seeing anything else means something else minted a
             * send right to it, which is a caller bug, not ours. */
            int fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
            if (fd >= 0) {
                char m[96];
                int n = snprintf(m, sizeof m,
                                 "pid1: pdeath watcher unexpected msgid=%d\n",
                                 (int)buf.hdr.msgh_id);
                if (n > 0) { ssize_t w = write(fd, m, (size_t)n); (void)w; }
                (void)close(fd);
            }
            continue;
        }

        /* match the not_port name against what we armed against.
         * mismatch is a kernel bug; log and loop rather than send a
         * spurious signal to ourselves. */
        if (buf.dn.not_port != ctx->parent_task_name) {
            int fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
            if (fd >= 0) {
                char m[128];
                int n = snprintf(m, sizeof m,
                                 "pid1: pdeath watcher port mismatch "
                                 "got=0x%x want=0x%x\n",
                                 (unsigned)buf.dn.not_port,
                                 (unsigned)ctx->parent_task_name);
                if (n > 0) { ssize_t w = write(fd, m, (size_t)n); (void)w; }
                (void)close(fd);
            }
            continue;
        }

        /* parent died.  raise the requested signal on the thread
         * that armed the link.  on multi-threaded Hurd, kill(getpid(),
         * sig) can deliver to any thread including this watcher;
         * pthread_kill targets the specific thread that armed the
         * link so a pause()/mach_msg() in that thread actually wakes.
         * v0.9.9 v2 used kill(getpid(),sig) and VM-verify caught the
         * signal landing in the watcher pthread's context, leaving
         * the main thread parked in pause() forever. */
        (void)pthread_kill(ctx->main_thread, ctx->signal);
        (void)mach_port_deallocate(mach_task_self(),
                                   ctx->parent_task_name);
        (void)mach_port_mod_refs(mach_task_self(), ctx->notify_port,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        free(ctx);
        pthread_exit(NULL);
    }
}

/* tiny errno table for the kern_return_t values this RPC path can
 * surface.  kept local to this function so the broader port_hurd.c
 * is not perturbed; if a future slot needs the same mapping we hoist
 * to a shared helper.
 *
 * the parent-gone trio (ESRCH wire, EIO wire, KERN_INVALID_NAME) all
 * map to ESRCH so a caller that hits the fall-through path on a
 * parent-gone kr still sees the documented contract errno, not EIO
 * via default.  see hurd_pdeath_kr_is_parent_gone for the encoding
 * ground-truth (err_hurd, not err_kern; see docs/runlogs/
 * 2026-05-21-v099-vm-verify.md). */
static int
hurd_pdeath_errno_from_kr(kern_return_t kr)
{
    switch (kr) {
    case KERN_SUCCESS:            return 0;
    case (kern_return_t)ESRCH:    return ESRCH;
    case (kern_return_t)EIO:      return ESRCH;
    case KERN_INVALID_NAME:       return ESRCH;
    case KERN_INVALID_RIGHT:      return EPERM;
    case KERN_INVALID_ARGUMENT:   return EINVAL;
    case KERN_RESOURCE_SHORTAGE:  return ENOMEM;
    case MIG_BAD_ID:              return ENOSYS;
    default:                      return EIO;
    }
}

/* test whether a kern_return_t indicates "the parent task is no
 * longer reachable".  gnumach 1.8+git20260224 + Hurd's proc server
 * on Debian GNU/Hurd 0.9 return errno values as kern_return_t,
 * encoded as err_hurd|unix_errno (high bits 0x40000000).  Hurd's
 * <errno.h> defines the POSIX errno macros to exactly those wrapped
 * values, so a direct compare `kr == (kern_return_t)ESRCH` matches
 * the wire bits the proc server actually emits.
 *
 * empirical from the v0.9.9 third-iteration VM-verify on this
 * kernel/libc:
 *   proc_pid2task(bogus pid)  -> 0x40000003 = ESRCH
 *   proc_pid2task(stale pid)  -> 0x40000005 = EIO
 * both are "parent task lookup failed" from this RPC; either
 * outcome means we should treat the parent as gone, raise the
 * caller's signal, and return -1/ESRCH.
 *
 * KERN_INVALID_NAME stays in the recognised set as a defence for
 * textbook-Mach kernels that surface the bare Mach spec code rather
 * than the err_hurd-wrapped errno; on Debian Hurd 0.9 / gnumach 1.8
 * it is never observed in practice.
 *
 * supersedes the err_kern / err_get_code decode from hurd/6e50576
 * (and the KERN_FAILURE broadening at hurd/2d4eccb): both assumed
 * the wrong subsystem (err_kern, high-byte 0x40, low-bits = KERN_*).
 * the actual subsystem on this kernel is err_hurd (also high-byte
 * 0x40 by accident, distinct sub_system field) and the low bits are
 * unix errno values, not KERN_* codes. */
static inline int
hurd_pdeath_kr_is_parent_gone(kern_return_t kr)
{
    return kr == (kern_return_t)ESRCH
        || kr == (kern_return_t)EIO
        || kr == KERN_INVALID_NAME;
}

static int
hurd_arm_parent_death(int sig)
{
    /* signal range guard (defence-in-depth; the elisp binding also
     * range-checks, but this body is reachable from the C tests/
     * helper which goes straight to the slot). */
    if (sig < 1 || sig >= NSIG) {
        errno = EINVAL;
        return -1;
    }

    /* step 1: ppid snapshot.  getppid is async-signal-safe and never
     * fails on POSIX; the value is the parent at this instant which
     * is what we want for the dead-name watch.  if the parent dies
     * between this line and proc_pid2task below, the retry-loop /
     * ESRCH short-circuit covers it. */
    pid_t ppid = getppid();

    /* step 2: parent's task port via the proc server.
     *
     * getproc() returns a CACHED send right; we MUST NOT deallocate
     * it (libc owns the cache).  proc_pid2task returns a FRESH send
     * right we own; on the SUCCESS path this right transfers to the
     * watcher in step 6, on every ERROR path we deallocate it.
     *
     * KERN_INVALID_NAME retry loop: on a freshly forked caller the
     * proc server may not yet have registered our own pid (and thus
     * not have our parent's pid in its hash either).  this is a
     * narrow race observed in the v1 test harness; production
     * spawn_xorg arms from a child whose parent is pid1, registered
     * since boot, so the retry loop is a no-op there but defends the
     * test path (and any future non-pid1-parented spawn path that
     * arms within milliseconds of fork). */
    process_t proc = getproc();
    if (proc == MACH_PORT_NULL) {
        errno = EAGAIN;
        return -1;
    }
    task_t parent_task = MACH_PORT_NULL;
    kern_return_t kr = KERN_SUCCESS;
    for (int attempt = 0; attempt < 10; attempt++) {
        kr = proc_pid2task(proc, ppid, &parent_task);
        /* retry on the broadened parent-gone code set so a transient
         * proc-server hiccup gets the same 2-3 attempts before we
         * short-circuit to ESRCH.  the set covers both the textbook
         * KERN_INVALID_NAME and the err_hurd-encoded ESRCH/EIO that
         * gnumach 1.8 actually returns from proc_pid2task on Debian
         * Hurd 0.9 (see hurd_pdeath_kr_is_parent_gone for the wire-
         * value ground truth).  any other non-success kr is terminal
         * (no retry). */
        if (kr == KERN_SUCCESS) break;
        if (!hurd_pdeath_kr_is_parent_gone(kr)) break;
        /* 100ms back-off; 10 attempts = 1s wall budget total. */
        struct timespec ts = { 0, 100 * 1000 * 1000 };
        (void)nanosleep(&ts, NULL);
    }
    if (kr != KERN_SUCCESS) {
        if (hurd_pdeath_kr_is_parent_gone(kr)) {
            /* ESRCH short-circuit: parent really is gone (or proc
             * server permanently lost the pid; either way the death-
             * link semantics are "parent is no longer reachable").
             * raise the requested signal on THIS thread (we are the
             * caller that armed) so the caller sees the same end-
             * state as a successful arm + instant fire.  pthread_self
             * is correct here because we are the armer thread; using
             * kill(getpid(),sig) on Hurd can deliver to any thread,
             * same hazard as the watcher path.  then return -1/ESRCH
             * per the spec.
             *
             * v0.9.9 empirical (third-iteration VM-verify on Debian
             * GNU/Hurd 0.9 / gnumach 1.8+git20260224): proc_pid2task
             * returns errno values wrapped in the err_hurd subsystem
             * (0x40000000 high bits + unix errno low bits), NOT the
             * err_kern subsystem that hurd/6e50576 assumed.  observed
             * values:
             *   0x40000003 = err_hurd|3 = ESRCH
             *   0x40000005 = err_hurd|5 = EIO
             * Hurd's <errno.h> defines the POSIX errno macros to those
             * wrapped values exactly, so we compare kr against ESRCH/
             * EIO directly (see hurd_pdeath_kr_is_parent_gone).  the
             * earlier err_kern + err_get_code() decode never matched
             * because the bare low-order codes after that decode were
             * 3 and 5, which in Mach's spec table are KERN_NO_SPACE
             * and KERN_FAILURE, not the textbook proc_pid2task return.
             * one ESRCH errno for every arm keeps the caller contract
             * stable regardless of which wire encoding the kernel
             * surfaces. */
            (void)pthread_kill(pthread_self(), sig);
            errno = ESRCH;
            return -1;
        }
        errno = hurd_pdeath_errno_from_kr(kr);
        return -1;
    }

    /* step 3: allocate the notify receive right. */
    mach_port_t notify_port = MACH_PORT_NULL;
    kr = mach_port_allocate(mach_task_self(),
                            MACH_PORT_RIGHT_RECEIVE,
                            &notify_port);
    if (kr != KERN_SUCCESS) {
        (void)mach_port_deallocate(mach_task_self(), parent_task);
        errno = hurd_pdeath_errno_from_kr(kr);
        return -1;
    }

    /* step 4: request the dead-name notification.
     *
     * arg-by-arg recap (spec section B.4):
     *   self          : our task name, kernel reads it directly.
     *   parent_task   : SEND right we hold; kernel reads the name out
     *                   and binds the notification record to the
     *                   ipc_entry in OUR ipc_space (mach_port.defs:
     *                   228-251).  this is why parent_task MUST stay
     *                   alive past this call (the watcher will hold
     *                   it for its lifetime); v1's eager deallocate
     *                   freed the entry and silently consumed the
     *                   notification record.
     *   MACH_NOTIFY_DEAD_NAME : the msgid the kernel will set on the
     *                   delivered notification (notify.defs:106).
     *   sync = 0      : do NOT fire immediately if already dead; we
     *                   handle that case via the ESRCH short-circuit.
     *   notify_port   : OUR receive-right name; kernel mints a send-
     *                   once from it to use as the destination.  we
     *                   keep the receive right (the watcher will own
     *                   it).
     *   MAKE_SEND_ONCE: tells the kernel to mint a send-once from our
     *                   receive right.  DO NOT pass MOVE_SEND_ONCE;
     *                   we are not transferring an existing one.
     *   &prev         : kernel transfers the previous notify port
     *                   (the port that USED to be registered for this
     *                   dead-name slot, typically MACH_PORT_NULL on
     *                   a fresh request) into our name space as a
     *                   send right we own.  caller (us) is responsible
     *                   for deallocating it on every exit path.
     *
     * on failure: deallocate parent_task and notify_port, return -1.
     * we do NOT deallocate parent_task on the success path; ownership
     * transfers to the watcher in step 6. */
    mach_port_t prev = MACH_PORT_NULL;
    kr = mach_port_request_notification(mach_task_self(),
                                        parent_task,
                                        MACH_NOTIFY_DEAD_NAME,
                                        0,
                                        notify_port,
                                        MACH_MSG_TYPE_MAKE_SEND_ONCE,
                                        &prev);
    if (kr != KERN_SUCCESS) {
        (void)mach_port_deallocate(mach_task_self(), parent_task);
        (void)mach_port_mod_refs(mach_task_self(), notify_port,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        /* if the kernel handed us a prev even on failure (does not
         * happen on gnumach today but the contract permits it),
         * release it so we do not leak. */
        if (MACH_PORT_VALID(prev)) {
            (void)mach_port_deallocate(mach_task_self(), prev);
        }
        errno = hurd_pdeath_errno_from_kr(kr);
        return -1;
    }

    /* step 5: RE-ENTRY CHECK under the lock.  if a watcher is already
     * live in this process, we do NOT spin a second one (that was the
     * v1 thread-leak).  same-signal: idempotent return 0.  different-
     * signal: return -1/EALREADY and leave the existing arm alone.
     * either way we clean up the resources WE allocated in steps 2-4
     * because the existing watcher already owns its own pair. */
    pthread_mutex_lock(&g_arm_lock);
    if (g_arm.active) {
        int prev_sig = g_arm.signal;
        pthread_mutex_unlock(&g_arm_lock);
        (void)mach_port_deallocate(mach_task_self(), parent_task);
        if (MACH_PORT_VALID(prev)) {
            (void)mach_port_deallocate(mach_task_self(), prev);
        }
        (void)mach_port_mod_refs(mach_task_self(), notify_port,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        if (prev_sig == sig) {
            return 0; /* idempotent same-signal arm */
        }
        errno = EALREADY;
        return -1;
    }

    /* step 6: heap-allocate the watcher context.  the watcher owns
     * both rights for its lifetime and frees ctx on exit. */
    struct hurd_pdeath_watcher_ctx *ctx = malloc(sizeof *ctx);
    if (ctx == NULL) {
        pthread_mutex_unlock(&g_arm_lock);
        (void)mach_port_deallocate(mach_task_self(), parent_task);
        if (MACH_PORT_VALID(prev)) {
            (void)mach_port_deallocate(mach_task_self(), prev);
        }
        (void)mach_port_mod_refs(mach_task_self(), notify_port,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        errno = ENOMEM;
        return -1;
    }
    ctx->notify_port      = notify_port;
    ctx->parent_task_name = parent_task; /* ownership transfers here */
    ctx->signal           = sig;
    /* capture the armer thread id BEFORE the watcher is spawned so the
     * watcher can pthread_kill() this specific thread on dead-name fire
     * rather than kill(getpid(),sig), which on Hurd can land in the
     * watcher's own context.  pthread_self() here returns the armer's
     * tid because hurd_arm_parent_death runs in the caller's thread. */
    ctx->main_thread      = pthread_self();

    /* step 7: spin the detached watcher.  detached so we never need
     * to pthread_join; the watcher cleans up on its own pthread_exit. */
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t tid;
    int prc = pthread_create(&tid, &attr, hurd_pdeath_watcher, ctx);
    pthread_attr_destroy(&attr);
    if (prc != 0) {
        pthread_mutex_unlock(&g_arm_lock);
        free(ctx);
        (void)mach_port_deallocate(mach_task_self(), parent_task);
        if (MACH_PORT_VALID(prev)) {
            (void)mach_port_deallocate(mach_task_self(), prev);
        }
        (void)mach_port_mod_refs(mach_task_self(), notify_port,
                                 MACH_PORT_RIGHT_RECEIVE, -1);
        errno = prc; /* pthread_create returns errno directly */
        return -1;
    }

    /* step 8: commit g_arm.  prev belongs to us on every path; if the
     * kernel handed us a non-null prev, release it now.  doing it
     * under the lock keeps every g_arm-related action grouped, and
     * the dealloc itself is lock-agnostic. */
    g_arm.tid              = tid;
    g_arm.notify_port      = notify_port;
    g_arm.parent_task_name = parent_task;
    g_arm.signal           = sig;
    g_arm.active           = 1;
    if (MACH_PORT_VALID(prev)) {
        (void)mach_port_deallocate(mach_task_self(), prev);
    }
    pthread_mutex_unlock(&g_arm_lock);
    return 0;
}

#ifdef PID1_TEST_HELPER
/* test-only entry: drive the proc_pid2task call against an arbitrary
 * pid (not just getppid()) and exercise the parent-gone branches of
 * hurd_arm_parent_death without trying to win a fork race.  the body
 * mirrors steps 1-2 of the real slot exactly up to the ESRCH short-
 * circuit; on success it returns 0 WITHOUT spinning a watcher (that
 * would leak the receive-right plumbing for the synthetic case), on
 * the parent-gone branches it raises sig on the calling thread and
 * returns -1/ESRCH; on every other Mach code it returns -1 with the
 * same hurd_pdeath_errno_from_kr mapping.  this is the only mechanism
 * the probe harness has to reach the err_hurd-encoded parent-gone arm
 * of the guard deterministically: gnumach 1.8 + Hurd proc returns
 * 0x40000003 (= ESRCH) for a bogus pid and 0x40000005 (= EIO) for a
 * stale pid, and a real arm path would otherwise need a fork-and-die
 * race to surface either.  symbol is gated by PID1_TEST_HELPER so it
 * never compiles into the production module or the standalone pid1
 * binary.
 *
 * v0.9.9 third-iteration errno-leak fix: the prior attempts assumed
 * the err_kern subsystem and decoded with err_get_code(), which never
 * matched because the actual subsystem is err_hurd and the low-order
 * bits are unix errno values, not Mach spec codes.  this iteration
 * compares kr against the wire values (ESRCH, EIO) directly, mirroring
 * Hurd's <errno.h>.  the production function and this helper share
 * the same is_parent_gone and errno-from-kr helpers so behaviour
 * matches by construction. */
int
__test_hurd_arm_parent_death_for_pid(int pid, int sig)
{
    if (sig < 1 || sig >= NSIG) {
        errno = EINVAL;
        return -1;
    }
    process_t proc = getproc();
    if (proc == MACH_PORT_NULL) {
        errno = EAGAIN;
        return -1;
    }
    task_t parent_task = MACH_PORT_NULL;
    kern_return_t kr = proc_pid2task(proc, pid, &parent_task);
    if (hurd_pdeath_kr_is_parent_gone(kr)) {
        /* parent-gone short-circuit, mirrors production.  pthread_kill
         * may not touch errno, but we set ESRCH explicitly AFTER the
         * call so any errno set by glibc inside proc_pid2task (the
         * v2.1 probe observed the raw kr leaking to errno here on
         * gnumach 1.8) is overwritten with the documented value. */
        (void)pthread_kill(pthread_self(), sig);
        errno = ESRCH;
        return -1;
    }
    if (kr != KERN_SUCCESS) {
        errno = hurd_pdeath_errno_from_kr(kr);
        return -1;
    }
    /* success path: we deliberately do not arm a watcher here; the
     * helper exists to exercise the guard arm only.  release the
     * fresh send right we own. */
    (void)mach_port_deallocate(mach_task_self(), parent_task);
    return 0;
}
#endif /* PID1_TEST_HELPER */

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
    .disk_size_bytes       = hurd_disk_size_bytes,
    .arm_parent_death      = hurd_arm_parent_death,
    .remount_root_rw       = hurd_remount_root_rw,
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
