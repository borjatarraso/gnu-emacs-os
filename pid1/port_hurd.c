/* SPDX-License-Identifier: GPL-3.0-or-later
 * Author: Borja Tarraso <borja.tarraso@member.fsf.org>
 */
/* port_hurd.c, the Hurd backend for port_layer.h.
 *
 * step 4 of the hurd port work order (docs/v04-item11-hurd-spike.md
 * lines 161-163): "port_hurd.c mount + reboot, enough to boot".  the
 * networking surfaces (bring_up_lo / set_address / set_route_default)
 * are stubbed to ENOSYS here and get their real pfinet RPC bodies in
 * step 5.  the suspend surface stays ENOSYS forever on this port:
 * Hurd has no /sys/power/state equivalent and the elisp layer is
 * supposed to render that as "not on this kernel".
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
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
        /* file_name_lookup sets errno via __hurd_fail on failure;
         * the MACH_PORT_NULL path means lookup itself bailed.  errno
         * is already correct for us to return. */
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
        /* file_set_translator returns an error_t which Hurd's libc
         * has already mapped to a POSIX errno value (error_t is
         * compatible with errno on Hurd, see <hurd/hurd_types.h>).
         * assign directly; do NOT pass a raw kern_return_t up. */
        errno = rc;
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

/* bring_up_lo: pfinet RPC, step 5.  for step 4 we return ENOSYS so
 * the supervisor's network init logs cleanly and the boot proceeds
 * without networking.  this is acceptable for the console-only
 * profile we are aiming at; the elisp side already prints a panic
 * entry when the call fails and otherwise carries on. */
static int
hurd_bring_up_lo(void)
{
    errno = ENOSYS;
    return -1;
}

/* set_address: pfinet RPC, step 5.  see bring_up_lo. */
static int
hurd_set_address(const char *ifname, uint32_t addr_be, int prefix)
{
    (void)ifname; (void)addr_be; (void)prefix;
    errno = ENOSYS;
    return -1;
}

/* set_route_default: pfinet RPC, step 5.  see bring_up_lo. */
static int
hurd_set_route_default(uint32_t gw_be, const char *ifname)
{
    (void)gw_be; (void)ifname;
    errno = ENOSYS;
    return -1;
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
 * linux header defines (they are not Hurd-portable include-wise) and
 * fall back to RB_AUTOBOOT for anything else.  if pid1 ever grows a
 * third reboot mode, this dispatch needs a real lookup table.
 *
 * the LINUX_REBOOT_CMD_* values are part of the kernel ABI; their
 * numeric values are documented and stable across linux history:
 *   RESTART   = 0x01234567
 *   HALT      = 0xCDEF0123
 *   POWER_OFF = 0x4321FEDC
 *
 * if a caller hands us a value we do not recognise, we still try
 * RB_AUTOBOOT.  a wedged kernel is worse than a wrong reboot type. */
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
    if (cmd == (int)0xCDEF0123 || cmd == (int)0x4321FEDC) {
        /* HALT or POWER_OFF.  Mach has RB_HALT; some Hurd headers
         * also expose RB_POWERDOWN but it is not universal, and
         * mach's idea of "power off" on a hosted VM ends up halting
         * the kernel and letting the VM monitor stop the cpu.  RB_HALT
         * is the portable choice. */
        flag = RB_HALT;
    } else {
        flag = RB_AUTOBOOT;
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
