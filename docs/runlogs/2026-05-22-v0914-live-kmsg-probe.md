# 2026-05-22: v0.9.14 slice 2, live kmsg flow on Hurd end-to-end

this slice closes the open follow-on #1 from
`docs/runlogs/2026-05-22-v0913-journal-kmsg-verify.md`: v0.9.13 left
journal-kmsg alive on Debian GNU/Hurd 0.9 with `tail -F` attached to
an empty `/var/log/kern.log`, but never provoked a real append to
prove the wire from syslog file through to `*journal*`.  receipt-only
slice, no code shipped.  drives the v0.9.6 pipeline (tail -F ->
journal-tail--filter-syslog -> journal-buffer--parse-syslog-record ->
*journal*) end-to-end against a synthetic kern.log line.

## Result

PASS on the load-bearing claim.  a real syslog-shape kern.* line
written to `/var/log/kern.log` inside the Hurd guest is picked up by
the supervised tail, parsed through `journal-buffer--parse-syslog-record`
with the expected field shape (:source syslog, :sev "info", :msg with
the unique probe token), and lands as a single record in `*journal*`.
the v0.9.6 syslog parser defaulting holds: the parser sees no explicit
severity in the kern.log line and falls back to "info".

what is not verified: the user-process `logger -p kern.info` path.  on
this image inetutils-syslogd demotes user-process LOG_KERN to LOG_USER
per syslog spec, so the probe pivoted to a direct `printf >>` against
kern.log.  that is the exact tail-input the supervisor sees in
production from gnumach via /dev/klog -> syslogd anyway, so the wire is
covered; the demotion detail is logged as a follow-on for any future
slice that wants user-side kern.log writes.

## What this slice ships

nothing.  verification-only.

## Build matrix

Linux dev host: not run, no code changed.
Hurd VM: not rebuilt, ran against the live qemu from
`/tmp/geos-hurd-vm-v0913-reverify-qemu.pid` (pid 3434078, qcow2
`/tmp/geos-hurd-vm-v0913-reverify-1779459141.qcow2`).

## Probe run

unique token for this probe: `geos-v0914-kmsg-probe-1779473530`.

trigger pivot: original intent was `logger -p kern.info "$TOKEN"`
from inside the guest, but inetutils-syslogd on Debian GNU/Hurd 0.9
demotes user-process LOG_KERN messages to LOG_USER (the line lands in
/var/log/syslog and /var/log/messages as facility=user instead of in
/var/log/kern.log).  this is a syslogd-side behavior per spec, not a
Hurd-specific bug.  probe pivoted to a direct `printf "<syslog-shape
kern.* line>" >> /var/log/kern.log` from inside the guest, which is
exactly the byte sequence the supervised tail would have seen had the
line arrived via /dev/klog.

verbatim line landed in /var/log/kern.log (single line in the file,
confirmed via `od -c`):

```
May 22 19:12:12 geos-hurd kernel: geos-v0914-kmsg-probe-1779473530
```

verbatim `*journal*` content after the supervisor picked up the line:

```
19:12:12 syslog info  kernel: geos-v0914-kmsg-probe-1779473530
```

buffer-size 63, count-lines 1, single record.

parsed record fields from
`(journal-buffer--parse-syslog-record raw)` run against the on-disk
line:

```
:source syslog
:time   (27152 40060)
:sev    "info"
:msg    "kernel: geos-v0914-kmsg-probe-1779473530"
:raw    "May 22 19:12:12 geos-hurd kernel: geos-v0914-kmsg-probe-1779473530"
```

v0.9.6 defaulting confirmed: `:source = syslog`, `:sev = "info"`.
kern.log is implicitly kern.*, the parser has no explicit severity in
the line, and the default kicks in.

bonus end-to-end confirmation of the respawn-and-rebackfill path:
emacs respawned exactly once between probe-fire and probe-inspect
(pid 618 -> 1326, tail pid 623 -> 1371).  `journal-kmsg` came back
`:status running` automatically, consistent with the task #171 closure
landed at main/997314f and hurd/daa0a64.  the `--lines=+1` on the
supervised `tail -F` meant the new tail re-read kern.log from offset 0,
so the synthetic line was still captured cleanly into the post-respawn
`*journal*`.  no probe data lost across the respawn.

retained artifacts on the host (not sanitized in this receipt because
they are tmp paths on the dev host, kept for follow-on debugging):

- post-probe qcow2 snapshot
  `/tmp/geos-hurd-vm-v0913-reverify-1779459141.qcow2`, still attached
  to the running qemu
- QEMU pid 3434078, pidfile
  `/tmp/geos-hurd-vm-v0913-reverify-qemu.pid`
- serial console transcript
  `/tmp/geos-hurd-vm-v0913-reverify-serial.log`
- SSH forward `127.0.0.1:2266 -> guest 22`

## Open follow-ons (do NOT block this slice's commit)

1. inetutils-syslogd kern facility demotion.  on this image,
   `logger -p kern.info` from a user process lands in syslog and
   messages as facility=user, not in kern.log as facility=kern.
   syslogd is behaving per spec (kern facility is reserved for the
   kernel side, getting it from a user process is non-standard).  if
   a future slice wants user-side kern.log writes, drop a
   `kern.* /var/log/kern.log` line into
   `/etc/inetutils-syslog.conf` and SIGHUP syslogd, or pivot to
   `printf >> /var/log/kern.log` as this probe did.  not load-bearing
   for the v0.9.6 pipeline.  next-step hint: a one-line syslog.conf
   override would make user-space kern logging Just Work without
   changing any elisp.

2. /var/log/kern.log on a fresh boot only carries this probe's line
   and nothing else, because gnumach boot printfs land in
   /var/log/dmesg (read direct from the gnumach printbuf by
   `dmesg(8)`) rather than through /dev/klog -> syslogd -> kern.log.
   v0.9.7's `journal-tail--prime-from-dmesg` backfills the day-zero
   boot transcript at load time.  a future slice could wire a
   periodic dmesg re-sync if a runtime kernel event arrives via the
   dmesg printbuf rather than through the syslog path.  not
   load-bearing.  next-step hint: idle timer running `dmesg | diff`
   against the last priming, append delta into `*journal*`.

## Files touched on the main branch

none.  verification-only slice.

## Files touched on the hurd branch

none.
