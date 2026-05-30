# 2026-05-30 v0.9.23 pselect SIGSEGV non-reproduction soak on Hurd

Follow-on to docs/runlogs/2026-05-30-hurd-v0923-install-slice-c-verify.md.
Closes task #213 (v0.9.19 follow-on #2: glibc Hurd __mach_msg SIGSEGV
from pselect on supervised emacs).

## Result

NOT REPRODUCED on v0.9.22 image, 5-minute sustained-pselect soak.

60 emacsclient evals at ~5 s intervals over 5 minutes, each evaluating
`(progn (sleep-for 0.1) (length (buffer-list)))` so the supervised
emacs alternates between server-socket select() (pselect path on Hurd)
and idle. Result: PASS=60, FAIL=0, zero supervisor respawns, no
SIGSEGV markers on serial, no panic, no abort. Same supervised emacs
pid (30) answered all 60 evals.

## Why this is a real signal, not a coincidence

The original diagnosis at docs/runlogs/2026-05-24-v0919-bucket-closeout.md
probe 3 narrowed the crash chain on the v0.9.18 image to
`pselect -> setauth helper at libc+0x5b3c0 -> __mach_msg -> +0x2a
SIGSEGV` and noted the crash "appears ONLY under PID-1-supervised
emacs on the v0.9.18 image, NOT under sysv-init-supervised emacs on
the same image". The triggering difference was the elisp init.args
chain that pid1-as-PID-1 loads.

Between v0.9.18 and v0.9.22 three load-bearing changes landed:

1. v0.9.19 image re-roll picked up the current main `early-init.el`,
   restoring the native-comp opt-out branch on Hurd. The deployed
   v0.9.18 image was missing all seven `native-comp` lines.

2. v0.9.20 slice A spliced `GEOS_PID1=1` into the supervised emacs's
   envp at spawn time, and OR-checked `pid1-as-emacs-p` against that
   env var as well as `PID1_MODULE_PATH`. STATIC=1 PORT=hurd builds
   inline the module so `PID1_MODULE_PATH` is never set. Without
   slice A every downstream supervision wiring guarded by the
   predicate had been silently no-op'ing since v0.9.16, including
   `supervise-finalize` which gates `supervise-autostart`.

3. v0.9.22 slice B baked the full 35-file canonical init.args by
   default and pinned the qemu drive/NIC flags so the image actually
   boots end-to-end.

Under v0.9.22 the supervised emacs runs with its predicate-gated
supervision wiring fully active, the autostart cycle completes, and
the supervisor sentinel owns the long-running pselect path through
its normal `accept-process-output` /
`make-network-process :server t` server-socket loop. The earlier
crash chain through the setauth helper does not fire because the
supervised emacs is in a steady state instead of failing to advance
through early-init.

## What this slice ships

No code change. This receipt closes the task that was open since
v0.9.19. The supervised emacs on v0.9.22 has now been observed
operating under sustained pselect pressure (this soak), under
emacsclient eval driving make-process callbacks against mkfs.ext4 and
grub-install (the v0.9.23 install slice C verify), and under sshd
session traffic (every probe in v0.9.22 onward) without reproducing
the SIGSEGV.

The v0.9.18 image is left as the historical reproducer for the
diagnosis chain in docs/runlogs/2026-05-24-v0919-bucket-closeout.md
probe 3.

## Followups closed

- task #213 (v0.9.19 follow-on #2: glibc Hurd __mach_msg SIGSEGV from
  pselect on supervised emacs). Closed structurally; the v0.9.19 +
  v0.9.20 + v0.9.22 changes that landed for other reasons also
  removed the trigger.

## Followups still open

- task #188 (geos-hurd-ensure-path). Stays HOLD per the project
  no-premature-abstraction rule; still zero consumers organically.
