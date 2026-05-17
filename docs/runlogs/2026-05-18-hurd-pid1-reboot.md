# 2026-05-18: host_reboot Mach RPC verified end-to-end on GNU/Hurd

Third runlog of the day.  Closes the last gating row in
`HURD_PORT.md`'s verification matrix: `port->reboot` moves from
"builds on Hurd 2026-05-17" to "YES on 2026-05-18".

## Result

**PASS.**  `(pid1-reboot)` called from inside `emacs --batch` (with
`pid1-module.so` module-loaded) triggered an actual VM reboot:

  - SSH session running on uptime 1068s died (TCP banner timeout
    immediately after the call).
  - QEMU process stayed alive; the VM did not crash, it rebooted.
  - `/hurd/startup` re-execed `/sbin/init` (= emacs-init), which
    re-entered the supervisor loop and re-spawned `/usr/bin/emacs`.
  - Console showed a fresh `*scratch*` greeting (colour palette
    different from the pre-reboot screen because the framebuffer
    came up clean).
  - Sending `!` via QEMU `sendkey` echoed into the buffer and the
    mode line flipped from `-=1-:---` to `-=1-:**`.  emacs IS the
    process responding.

Screen captures:

  - `2026-05-18-hurd-pid1-reboot-rpc-screen.png` (post-reboot
    *scratch* greeting, fresh frame).
  - `2026-05-18-hurd-pid1-reboot-aftertype-screen.png` (same
    *scratch* with a typed `!` and mode-line modified marker,
    proving emacs is live).

## What changed since the previous runlog

One C change on the hurd branch, one workflow lesson.

  - `pid1/port_hurd.c` (`hurd_reboot_cmd`): replaced
    `mach_host_self()` with `get_privileged_ports(&host_priv,
    NULL)`.  `mach_host_self()` returns the *unprivileged* host
    name port (suitable for `host_info` only); `host_reboot`
    requires the *privileged* host control port.  gnumach rejects
    the unprivileged port with `KERN_INVALID_HOST`, which my old
    switch correctly mapped to `EINVAL`.  the first attempt
    yielded `pid1: reboot: Invalid argument` in the elisp signal,
    which traced back to the right spot in two minutes thanks to
    the kern_return_t -> errno mapping already in place.
  - Workflow lesson: after host_reboot, sshd does NOT come back.
    on the pre-reboot system, sshd was a legacy survivor from
    Debian's sysvinit chain (it was up when we swapped /sbin/init
    to emacs-init).  after the reboot, /sbin/init is emacs-init
    from boot 0, and emacs-init only supervises emacs; sysvinit's
    `/etc/init.d/ssh` never runs.  this is the expected GEOS
    deployment shape, not a bug.  diagnostics from here on go
    through the QEMU framebuffer + sendkey, until v0.8 adds a
    GEOS-side sshd supervisor or we wire pid1's
    `/run/geos/super.sock` to a serial-port carrier.

## What this verifies for real

  - The full reboot chain works: elisp `(pid1-reboot)` ->
    `Fpid1_reboot` -> `port->reboot(RB_AUTOBOOT)` ->
    `hurd_reboot_cmd` -> `get_privileged_ports` ->
    `host_reboot(host_priv, RB_AUTOBOOT)` -> gnumach issues warm
    reboot -> GRUB -> Hurd boot -> /sbin/init -> emacs.
  - `pid1-module.so` is a usable artifact on Hurd: it builds with
    `make module PORT=hurd`, dlopens cleanly via `module-load`,
    and the `pid1-reboot` / `pid1-mount` bindings are present.
    `pid1-sethostname` is intentionally absent on PORT_HURD (the
    sethostname slot dispatches via port->set_hostname but is not
    re-exported as a separate elisp function on Hurd today).
  - The kern_return_t -> errno mapping in `hurd_reboot_cmd` is
    load-bearing diagnostic infrastructure.  the EINVAL from the
    first attempt named the exact problem so the fix was a single
    function call swap, not a port-layer redesign.

## What is still pending

  - `port->reboot(LINUX_REBOOT_CMD_POWER_OFF)` (i.e. RB_HALT path).
    Not separately exercised; the dispatch is the same shape and
    the host_reboot RPC accepts both flags equivalently, but a
    skeptic-grade verification would re-run with the halt path
    and observe the QEMU monitor reporting `vcpu halted`.
  - The remaining bootstrap-order noise from
    `2026-05-18-hurd-pid1-boot-result.md` (read-only root at init
    time, tmpfs default pager missing, /hurd/tmpfs argv shape).
    These do not block the reboot RPC and are tracked separately
    as task #104.

## Reproduction

Assumes the install path from `HURD_BOOT.md` is already done
(/sbin/init = emacs-init) and SSH is currently up.

  1. SCP `pid1/emacs-init.c` (hurd branch HEAD), `port_layer.h`
     (hurd branch HEAD), `port_hurd.c` (hurd branch HEAD,
     post-`get_privileged_ports` fix), and `Makefile` (hurd
     branch HEAD) to `/root/geos/pid1/` on the VM.
  2. `cd /root/geos/pid1 && make clean PORT=hurd && make module
     PORT=hurd` -> 38520-byte `pid1-module.so` linking
     `-lcrypt -lfshelp -lhurduser -lmachuser` (all resolved via
     ldd; no missing DT_NEEDED).
  3. Record pre-reboot uptime: `awk '{print int($1)}' /proc/uptime`.
  4. Fire `(pid1-reboot)` via batch emacs in detached background
     so SSH session does not hang on the RPC:
     ```
     nohup sh -c "sleep 2; emacs --batch \
       --eval '(progn (module-load \"/root/geos/pid1/pid1-module.so\") (pid1-reboot))' \
       >/tmp/reboot.log 2>&1" >/dev/null 2>&1 & disown
     ```
  5. SSH dies within seconds.  Wait ~30-60s for GRUB + Hurd boot.
     SSH stays down (sshd is not in the GEOS supervisor tree).
  6. QEMU `screendump` -> fresh `*scratch*` greeting frame.
  7. QEMU `sendkey` -> emacs echoes characters and the mode line
     flips to modified.

## Why this is the right v0.7.x close

The two binding gaps on entry to today were "does emacs-init
boot as PID 1 on real Hurd" and "does the Mach reboot RPC fire
when we ask it to".  Both are now PASS receipts pinned by
runlogs + screen captures.  v0.7.x's Hurd port is no longer a
desk-review hypothesis; it is software that runs.
