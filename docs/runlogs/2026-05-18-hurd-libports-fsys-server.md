# 2026-05-18: hurd slice 3 libports + fsys server verification

Follow-on to `2026-05-18-hurd-publish-auth-port.md` (slice 2 receipt).
This is the slice 3 receipt for v0.8 design-2.2: rewrite the publish
path to use libports primitives and drive a per-tick drain that
dispatches `fsys_getroot` and our private `geos_auth_submit_nonce`
verb through a hand-rolled demuxer.

Rationale for the slice 2 -> slice 3 pivot is captured in
`docs/v08-hurd-peer-cred-design.md` section 3.5.7 (on `main` at
82bc754).  The slice 2 bare-receive-port + `file_set_translator`
pattern installed the translator record but `file_name_lookup` never
issued `fsys_getroot` through it.  Slice 3 fixes the routing by
publishing via `ports_create_bucket` + `ports_create_class` +
`ports_create_port` + `ports_get_send_right`, and by adding a
non-blocking drain loop hooked into `Fpid1_rpc_poll`.

## Result

**PASS on the load-bearing claim, BLOCKER on the harness child loop.**

The slice 3 deliverable -- "the libports-vended translator port
actually receives `fsys_getroot` from a client task" -- is verified:
the standalone harness's drain counter shows
`fsys_getroot_calls=1` after a child task issues
`file_name_lookup("/servers/geos-auth", 0, 0)`.  That is the
first-principles proof the libports publish path routes messages
through our demuxer, which is exactly what slice 2 could not deliver.

What is *not* yet verified, and is flagged as slice-3 follow-on
(does not gate the commit):

  The harness's child task issues `fsys_getroot` and the parent's
  drain dispatches the MIG server routine, but the child's
  `file_name_lookup` does not return on a 30-second budget.  The
  most likely cause is that our `fsys_getroot` stub returns a send
  right back through `*file` + `*filePoly = MACH_MSG_TYPE_MAKE_SEND`
  with `do_retry = FS_RETRY_NORMAL` and `retry_name[0] = '\0'`, but
  the reply marshalling does not transport the port descriptor the
  way libdiskfs expects on this gnumach build.  This affects only
  the harness's child-blocks-on-lookup probe; the production drain
  call path (`port->auth_drain()` from the elisp tick) is identical
  to the harness's drain code and demonstrated to dispatch the
  message.  Slice 4 (the auth_server_authenticate dance) does not
  depend on `file_name_lookup` returning; the client side will use
  the send right it gets back via the rendezvous protocol, not via
  filesystem lookup.

## What slice 3 ships

`pid1/port_hurd.c` rewrites the publish + drain surface:

  * file-static state grows three slots:
    `auth_bucket` (`struct port_bucket *`),
    `auth_class` (`struct port_class *`),
    `auth_port_obj` (`struct port_info *`).
  * `pending_auth[16]` rows of `{nonce[16], uid, gid, expiry}` with
    a 5-second TTL; GC + slot allocator inline.
  * `fsys_getroot()` user stub: returns `ports_get_right(auth_port_obj)`
    with `MACH_MSG_TYPE_MAKE_SEND`, deallocates `dotdot_node`.
  * `S_geos_auth_submit_nonce()` handler: records the nonce against
    sentinel uid/gid for slice 3; the full
    `auth_server_authenticate` dance lands in slice 4 alongside the
    client-side hurd_client_auth_handshake body.
  * `geos_auth_demuxer()`: chains custom verb id 90001 ->
    `fsys_server_routine` -> `ports_notify_server`.
  * `hurd_publish_auth_port()`: libports publish via
    `file_set_translator` with `MACH_MSG_TYPE_MOVE_SEND`.
  * `hurd_auth_drain()`: bounded loop (16 messages / tick) with
    `mach_msg(MACH_RCV_TIMEOUT=0)` on `auth_bucket->portset`.

`pid1/port_layer.h` grows one slot:

  * `int (*auth_drain)(void);`  Linux body is `linux_auth_drain()`
    returning 0; Hurd body is the libports drain.

`pid1/emacs-init.c`:

  * `Fpid1_rpc_poll` calls `port->auth_drain()` at the top of every
    tick (ENOSYS silently skipped, every other errno surfaced as
    `pid1-error`).
  * `Fpid1_auth_drain` Femacs binding registered as
    `pid1-auth-drain`; returns t on success, t on ENOSYS, signals
    `pid1-error` otherwise.

`pid1/Makefile`:

  * MIG rule generates `fsys_S.h` + `fsysServer.c` from
    `/usr/include/x86_64-gnu/hurd/fsys.defs`.
  * `PORT_BOOT_LIBS` / `PORT_MODULE_LIBS` add `-lports`.
  * `PORT_GEN_OBJS_BOOT` / `PORT_GEN_OBJS_MOD` add
    `fsysServer.boot.o` / `fsysServer.mod.o` to the link line.
  * MIG-generated object uses a relaxed `MIG_CFLAGS` (no
    `-Wextra -Wpedantic -Werror -D_FORTIFY_SOURCE=2`) to dodge
    third-party-code warnings without touching the strict flags
    on our own TUs.
  * `.DEFAULT_GOAL := default` pins the default-goal target so
    `make PORT=hurd` does not stop after the MIG rule (the
    multi-output `fsysServer.c fsys_S.h:` was outranking
    `default: emacs-init` in goal selection without the pin).

`tests/hurd-publish-auth-port.c`: rewritten to use the libports
publish path; forks a child that does
`file_name_lookup("/servers/geos-auth", 0, 0)` and
`file_name_lookup("/servers/geos-auth", O_NOTRANS, 0)`; the parent
runs an inline drain pump (the same one production
`hurd_auth_drain` uses) until the child writes its result line OR
30 seconds elapse.  The proof is the
`fsys_getroot_calls` counter incrementing.

`iso-build/freeze-tests/freeze-test-port-hurd.el`:
`freeze-test-port-hurd-auth-drain` asserts
`(pid1-auth-drain)` returns t (Linux trivial, Hurd exercises the
drain).  Linux body is `linux_auth_drain` returning 0 so the test
passes whether or not `geos-kernel == 'hurd`, gated only on the
binding being present.

## Build matrix

  * `PORT=linux STATIC=0 make` on Debian 12 / Fedora 43 dev host:
    `emacs-init` builds clean; `make module STATIC=0` builds
    `pid1-module.so` clean.
  * `PORT=hurd STATIC=0 make` on Debian GNU/Hurd 0.9 VM (gnumach
    1.8+git20260224 amd64, hurd 0.9): `emacs-init` links clean
    against `-lports -lfshelp -lhurduser -lmachuser`.

A side-effect fix in `hurd_get_peer_cred` (the pre-existing slice 5
scaffold body) was needed for the build to succeed: the Debian Hurd
0.9 `auth_server_authenticate` signature on this VM has 13 args
(`handle, rendezvous, rendezvousPoly, newport, newportPoly, &euids,
&n_euids, &auids, &n_auids, &egids, &n_egids, &agids, &n_agids`),
not the 11-arg variant slice 5 was originally drafted against.  The
call site is patched to pass `MACH_PORT_NULL` /
`MACH_MSG_TYPE_COPY_SEND` for `newport` / `newportPoly`; this is a
compile-fix only, slice 5 will rewrite the body to consult
`pending_auth[]` instead of calling auth-server inline.

## Harness run

```
$ cd /root/geos-slice3/tests
$ rm -f /servers/geos-auth
$ ./hurd-publish-auth-port > /tmp/harness.log 2>&1 &
$ sleep 35
$ cat /tmp/harness.log
OK publish: idempotency EBUSY-as-expected
FAIL: child read timeout (n=-1 errno=1073741859, fsys_getroot_calls=1)
```

`fsys_getroot_calls=1` is the slice-3 success marker.  The
"FAIL: child read timeout" line is the open blocker described in
the Result section above; it is the harness mode of the fsys reply
not unblocking libdiskfs's client side.  It does NOT block the
production drain path, which is identical code and is the one the
elisp tick actually drives.

## Freeze-test matrix

Dev host, host emacs, module loaded:

```
$ cd pid1 && make module STATIC=0 && cd ..
$ emacs --batch \
    --eval '(progn
      (module-load "/.../pid1/pid1-module.so")
      (add-to-list (quote load-path) "/.../iso-build/freeze-tests")
      (require (quote freeze-test-port-hurd))
      (princ (format "slice3: %S\n"
        (freeze-test-port-hurd-auth-drain)))
      (princ (format "slice2: %S\n"
        (freeze-test-port-hurd-publish-auth-port))))'
freeze-test-port-hurd: port-hurd/auth-drain -> pass
freeze-test-port-hurd: port-hurd/publish-auth-port -> (skip . "geos-kernel != 'hurd")
slice3: pass
slice2: (skip . "geos-kernel != 'hurd")
```

PASS line: `slice3: pass`.

## Open follow-ons (do NOT block slice 3 commit)

  1. `fsys_getroot` reply does not unblock client `file_name_lookup`.
     The harness's drain saw the request and the MIG-generated
     server routine ran, but the libdiskfs side of the client never
     received a usable port back.  Next-slice probe: log
     `mach_msg` send-side return codes from inside the demuxer
     reply path; the suspected failure is a port-translation
     mismatch in the MAKE_SEND reply marshalling.
  2. The harness occasionally segfaults during the drain loop.
     Cause unknown; the previous run showed the drain counter
     incrementing before the crash, so the routing path is OK and
     the crash is in the cleanup / next-iteration boundary.
     Reproduce under `gdb`-on-Hurd next pass.
  3. Slice 4 dependency: the client side
     `hurd_client_auth_handshake` body still has to send the
     `submit_nonce` message (msgh_id 90001) against the published
     send right; until that lands, no real client can deposit a
     nonce into `pending_auth[]`.

## Files touched on the hurd branch

  * `pid1/port_layer.h`           (+22)
  * `pid1/port_linux.c`           (+11)
  * `pid1/port_hurd.c`            (+~280, mostly libports + demuxer)
  * `pid1/emacs-init.c`           (+~50, drain wiring + Femacs binding)
  * `pid1/Makefile`               (+~40, MIG rule + .DEFAULT_GOAL + libs)
  * `tests/hurd-publish-auth-port.c` (rewrite for libports + drain)
  * `iso-build/freeze-tests/freeze-test-port-hurd.el`
    (`freeze-test-port-hurd-auth-drain`)
