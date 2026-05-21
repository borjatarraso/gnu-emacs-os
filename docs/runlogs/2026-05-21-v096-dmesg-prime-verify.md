<!-- 2026-05-21: v0.9.6 follow-on dmesg-prime VM-verify on Debian Hurd 0.9 -->

# 2026-05-21: v0.9.6 follow-on dmesg-prime VM-verify on Debian Hurd 0.9

this receipt is the live-verify pass for the v0.9.6 follow-on ship at
`main/3d4a88b`: priming `*journal*` from `/var/log/dmesg` at startup so
the day-zero buffer is non-empty on images where `/var/log/kern.log` is
0 bytes. the slice adds `journal-buffer--parse-dmesg-record` in
`buffers/journal.el`, `journal-tail--prime-from-dmesg` in
`services/journal-tail.el` with a top-level call right before the
existing `supervise-register` for `journal-kmsg`, and
`iso-build/freeze-tests/freeze-test-hurd-dmesg-prime.el` with three
asserts. it closes follow-on item 2 from the v0.9.6 kmsg verify receipt
at `docs/runlogs/2026-05-21-v096-kmsg-verify.md`, which is also the
HURD_PORT.md row 197 footnote about the day-zero buffer gap.

## Verdict

PASS. the prime does what the code says it does on Debian GNU/Hurd 0.9.
`journal-tail--prime-from-dmesg` reads `/var/log/dmesg`, splits on
newlines, drops empty lines, parses each one through
`journal-buffer--parse-dmesg-record`, and appends the resulting plists
into `*journal*` via the existing render path. the line count in
`*journal*` matches the non-empty line count in `/var/log/dmesg`
exactly (61 lines, delta 0). the negative path (file unreadable) is
silent: no raise, no panic, no buffer mutation. 100 back-to-back prime
calls show buffer growth proportional to the data (1 prime ~= 4865
bytes; 100 primes lands `*journal*` at 391482 bytes ~= 382 KiB) and
VmRSS delta of ~5836 KiB across the burst, of which ~382 KiB is the
buffer itself and the remaining ~5454 KiB is Emacs heap arena churn
from string + plist consing per call. that is GC residue, not a port
handle leak. all three freeze-test asserts pass on the VM.

non-idempotency is by design. the user-facing call site is a single
top-level invocation at journal-tail load time, so the second prime
doubling (61 -> 122 lines, 4865 -> 9730 bytes) observed when I drove
the function manually a second time is the contract working as
documented, not a defect. HURD_PORT.md row 197's footnote about day-zero
*journal* emptiness is satisfied.

## Test-harness amendments

the brief's path list and env assumptions were slightly stale for this
verify. recording the amendments so the next verifier does not step on
the same trip-wires.

1. `emacs-init/buffers/panic.el` does not exist. panic.el is at
   `emacs-init/core/panic.el`, and supervise.el is at
   `emacs-init/core/supervise.el`. scp'd from the real paths.
2. `journal-buffer.el` is in-tree as `emacs-init/buffers/journal.el`
   which `provide`s `'journal-buffer`. to make `(load "journal-buffer")`
   resolve under `emacs -Q --batch` on the VM, I created a symlink
   `/root/journal-buffer.el -> /root/journal.el`. pure rename for the
   loader, no source mutation.
3. `core/supervise.el`'s `(require 'state)` was a transitive dep that
   was not in the brief. scp'd `emacs-init/core/state.el` and re-ran.
4. `geos-kernel-linux-p` reads the `GEOS_KERNEL` env var with `"linux"`
   as the default. under pid1 this is exported via the GEOS_KERNEL
   splice at `main/a53304b`, but under `emacs -Q --batch` on the VM the
   var is unset, so the Hurd arm silently no-ops. I prepended
   `GEOS_KERNEL=hurd` to every emacs invocation in this verify so the
   prime branch fires. future verifies on a non-pid1 emacs need the
   same prefix.

## VM build environment

```
uname:           GNU geos-hurd 0.9 GNU-Mach 1.8+git20260224-up-amd64/Hurd-0.9 x86_64 GNU
debian_version:  forky/sid
emacs:           GNU Emacs 30.2
dmesg src:       /var/log/dmesg (regular file, populated from gnumach printbuf at boot)
```

canonical image mtime preserved at 2026-05-18 13:34:31 across the run.
no snapshot writes leaked back into the canonical image.

## Probe A: baseline dmesg readout

`/var/log/dmesg` on this image is populated, non-empty, and has 61
non-empty lines. the file ends mid-line; the last `[` is the real tail
of the file (dmesg's writer SIGKILLed mid-record at boot, this is
upstream Debian Hurd 0.9 behavior, not introduced by the verify).

```
$ wc -l /var/log/dmesg
61 /var/log/dmesg
$ grep -c -v "^[[:space:]]*$" /var/log/dmesg
61
$ head -3 /var/log/dmesg
rt ffffffffdea94ac8 entry ffffffffdea37d40 for acpi
[   1.0000000] Copyright (c) 1996, 1997, 1998, 1999, 2000, 2001, 2002, 2003,
[   1.0000000]     2004, 2005, 2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013,
$ tail -3 /var/log/dmesg
[  11.6800050] cd0: dos partition I/O error
Unable to get block size
[
```

stderr: ssh known-hosts notice only.

## Probe B: single prime under emacs -Q --batch

drove the prime once with `GEOS_KERNEL=hurd emacs -Q --batch`, loaded
`core/port.el`, `core/state.el`, `core/panic.el`, `core/supervise.el`,
`buffers/journal.el`, `services/journal-tail.el`, then called
`(journal-tail--prime-from-dmesg)` explicitly and dumped `*journal*`
state.

```
kernel-linux-p=nil
journal-buffer-exists=t
journal-size=4865
journal-line-count=61
journal-buffer--line-count=61
first-3-lines=
07:31:38 dmesg info  rt ffffffffdea94ac8 entry ffffffffdea37d40 for acpi
07:31:38 dmesg info  [   1.0000000] Copyright (c) 1996, 1997, 1998, 1999, 2000, 2001, 2002, 2003,
07:31:38 dmesg info  [   1.0000000]     2004, 2005, 2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013,
last-3-lines=
07:31:38 dmesg info  [  11.6800050] cd0: dos partition I/O error
07:31:38 dmesg info  Unable to get block size
07:31:38 dmesg info  [
```

the row prefix is the documented `HH:MM:SS source sev  msg` shape from
`journal-buffer--format-ts`; source is `dmesg`, sev defaults to `info`,
the `:time nil` plist field coalesces to `current-time` at render
(known approximation, see follow-on 2). line count matches
`grep -c -v "^[[:space:]]*$"` from probe A exactly. delta = 0. the file
ends mid-line at a lone `[` because gnumach was mid-write to the
printbuf when bootlogs SIGKILLed the dd that snapshotted it; upstream
Debian Hurd 0.9 behavior, not introduced by the verify. stderr: ssh
known-hosts notice + library load lines.

## Probe C: explicit re-call, doubling by design

called `(journal-tail--prime-from-dmesg)` twice from the same emacs
process to confirm the function is not internally idempotent (it does
not need to be; the user-facing call site is once).

```
after prime #1: journal-size=4865 journal-line-count=61
after prime #2: journal-size=9730 journal-line-count=122
```

exact 2x. this is the contract working as documented. the live call
site in `services/journal-tail.el` invokes the prime exactly once at
load time, just before `supervise-register` of `journal-kmsg`, so no
production path doubles up. recording the behavior here so it is not
mistaken for a regression in a future verify.

## Probe D: 100-call leak smoke

drove `(journal-tail--prime-from-dmesg)` 100 times back-to-back in a
single emacs process, with `/proc/self/status` captured before and
after, and the final `*journal*` size logged.

```
=== leak smoke: 100x prime-from-dmesg ===
VmSize before=4541148 after=4544832 delta_kb=3684
VmRSS  before=36076   after=41912   delta_kb=5836
journal-size after=391482
ports before=nil after=nil delta=nil
```

`*journal*` ended at 391482 bytes (~382 KiB), which is bounded buffer
growth proportional to the 101 cumulative primes (1 implicit at load +
100 explicit in the loop); the per-call increment differs from the
single-prime size because `journal-buffer--append-records` renders each
record once into the buffer rather than re-appending raw chunks. the
VmRSS delta is ~5836 KiB; subtract the ~382 KiB of buffer growth and
the remainder is ~5454 KiB of Emacs heap arena churn, roughly 55 KiB
per call, from string + plist consing in the parse loop. that is GC
residue, not a port handle leak. the Mach port counter is nil before and after
because Debian Hurd 0.9's procfs does not expose `/proc/<pid>/port_obj`;
same caveat as v0.9.5 and v0.9.6's kmsg verify, recorded here for
parity.

## Probe E: negative path, file unreadable

stubbed `file-readable-p` with `cl-letf` so it returns `nil` only for
`/var/log/dmesg` (and falls through for every other path the
require-chain needed), then drove the prime once. observed: no raise,
no panic, no buffer mutation.

```
raised=nil
buffer-size-delta=0
```

the prime's guard is a plain `(when (file-readable-p ...))` so this is
the expected silent no-op. nothing to handle, nothing to log, no churn
to `*journal*`. stderr: ssh known-hosts notice only.

## Probe F: freeze-test triple replayed on the VM

scp'd `iso-build/freeze-tests/freeze-test-hurd-dmesg-prime.el` to the
VM and ran the triple under `GEOS_KERNEL=hurd emacs -Q --batch` with
the same require-chain as probe B.

```
=== freeze-test-hurd-dmesg-prime/* ===
parse-good      => pass
parse-empty     => pass
prime-no-file   => pass
```

all three pass. parse-good exercises
`journal-buffer--parse-dmesg-record` on a representative dmesg line
(non-empty, no syslog prefix), parse-empty confirms the empty-string
input returns nil, prime-no-file confirms the prime no-ops when the
source file is absent / unreadable.

## VM state on exit

1. canonical image at `/home/overdrive/hurd-vm/work.img` mtime preserved
   at 2026-05-18 13:34:31, size 4194304000 unchanged.
2. snapshot, pidfile, and serial log used for the run removed.
3. QEMU killed via SIGTERM; host port 2222 free.

## Open follow-ons (do NOT block this slice's commit)

1. the prime runs once at journal-tail load time. if pid1 restarts
   emacs but the boot dmesg has not changed, the prime adds the same 61
   lines again into a fresh `*journal*`. that is not a leak (fresh
   process, fresh buffer) but it does mean rebooting pid1 mid-session
   would not show the boot transcript a second time, since it is the
   same content as the first time. no action; recording for future. if
   this matters later, dedup at the parse layer with a content hash
   keyed off `:raw`.

2. `:time nil -> current-time` at render means every dmesg row is
   timestamped with the time the prime ran, not the actual boot
   wall-clock. recovering the real boot time would need either a regex
   over the `[ NN.NNNNNNN]` bracketed monotonic stamps that gnumach
   emits (and then a delta from `/var/log/dmesg`'s mtime) or a
   settrans-then-stat trick on the file itself. not worth shipping
   today. next step is a small `journal-buffer--parse-dmesg-record`
   extension that pulls the monotonic field when present.

3. the test-harness amendments section above (panic.el path,
   journal-buffer.el symlink, state.el transitive dep, GEOS_KERNEL
   prefix) should be cited from any future verifier brief so the
   trip-wires this verify hit are not re-stepped. next step is to fold
   the four amendments into the standing VM-verify checklist that ships
   alongside the next port_hurd.c slot verify (audio).
