# GNU/Emacs Operating System (GEOS)

Maintainer: Borja Tarraso <borja.tarraso@member.fsf.org>

I have been using Emacs since 2006. Most of what I do on a computer
already happens inside it: code, mail, IRC, news, git, shell, PDFs,
the calendar, the file manager. The pattern of my day is "switch to
Emacs, do the thing, switch back to whatever the OS makes me put up
with for the bits Emacs cannot reach". This project is me getting
tired of that last clause.

So I built an operating system where Emacs is the userland and Emacs
is PID 1. Short name is GEOS, full name is GNU/Emacs Operating
System; the rest of this document uses GEOS.

## the thesis

Emacs is not an editor that runs on an OS. Emacs IS the OS.

The kernel (Linux today, the Hurd if I live long enough) provides
hardware abstraction. Everything above the kernel is Elisp. Process
supervision, the shell, the window manager, the network UI, the
package manager UI, the journal, the disk inspector, all of it lives
in buffers, written in the same language, evaluable at runtime,
introspectable with `C-h f`.

The first userspace process the kernel starts is a tiny C program
that mounts the pseudo-filesystems, reaps zombies, sets the hostname,
and then `execve`s Emacs. The same C source compiles a second time as
an Emacs dynamic module, loaded by `early-init.el`, so the supervision
code lives inside the Emacs process itself. There is no Shepherd. There
is no systemd. There is no `/etc/init.d`. The supervisor is Elisp and
the supervisor is the thing being supervised. If that sentence makes
you uncomfortable, good, it should.

## why

Because every OS I have used pretends my workflow ends at the prompt.
GNOME wants me in nautilus. KDE wants me in konsole. macOS wants me
in Finder. I do not want to be in any of those. I want to be in a
buffer. I want `M-x` to be the universal verb of my computer.

Because the Unix philosophy was right about composition and wrong
about boundaries. The shell pipeline is a Lisp expression with worse
syntax and no debugger. Once you accept that, the question stops being
"how do I integrate Emacs better with my system" and starts being "why
is there anything outside of Emacs at all".

Because Stallman sketched something like this years ago, in a footnote,
and I wanted to see if it was actually possible. Turns out it almost is.

## the hard rule about the shell

There is no shell other than eshell. `/bin/sh` exists, but it is a 50
line C stub that turns `sh -c "<cmd>"` into a call to `emacsclient`
that runs `<cmd>` inside an eshell. No bash. No dash. No busybox.

This breaks things. Some Guix package post-install scripts depend on
heredocs or `$(())` or other POSIX shell features eshell does not have
the same mouth shape for. When that happens I document the package in
`guix-system/exceptions.scm` and route around it. The list is short and
keeps shrinking.

I think this is the right call. The shell is not a programming language
I want on my system any more. Eshell is. It has lambdas and hash tables
and a debugger and structured data, and it is the same thing I get when
I `M-x shell` everywhere else.

## the failure mode I accept

Emacs is single threaded.

A stuck regex in any code path stalls the OS. A slow TRAMP connection
stalls the OS. A runaway `while t` stalls the OS. The panic buffer
catches errors raised through `condition-case`, and the supervisor
restarts services that die, but neither of those mechanisms saves you
from a tight loop in C-level code or a network call with no timeout.

This is a known design constraint, not a bug. I am not going to fight
it by introducing threads or async runtimes or any of the patterns that
would turn this project into something other than what it is. If I
wanted concurrency I would not have started with Emacs.

What I do instead: every long-running operation goes through
`make-process` with a sentinel. Every regex on user input has a length
cap. Every network call has an explicit timeout. The `*panic*` buffer
gets the most aggressive test suite in the repo (`/freeze-test`), and
every release blocks on it surviving deliberate abuse including a
literal `(kill-emacs)` call.

I lose maybe one session a week to a freeze I have to recover from in
QEMU. I am fine with that ratio. You may not be. That is a real reason
to not use this OS.

## what is in GEOS today (v0.2)

  - PID 1 is a C binary that becomes Emacs and then loads itself back
    in as an Emacs module so the reaper, the mount helper, the
    hostname call, the reboot syscall, and the signal handlers live
    inside the Emacs process.
  - The panic buffer catches every uncaught Elisp error and refuses to
    let Emacs exit.
  - eshell is the only shell. `/bin/sh` is the stub. `uname -a` reads
    `GEOS lambda <release> ... GNU/Emacs (Linux)`.
  - EXWM with the modesetting Xorg driver. Real keyboard and mouse in
    QEMU. X11 windows are buffers.
  - `M-x geos-poweroff` and `M-x geos-reboot` go through `reboot(2)`
    via the pid1 module. There is no `/sbin/poweroff` to call; the
    supervisor IS Emacs and the answer to "shut down" lives in elisp.
  - System concepts have buffers: `*processes*`, `*network*`,
    `*journal*`, `*services*`, `*disks*`, `*packages*`. Each has a
    major mode, sensible keybindings, and a refresh timer.
  - The whole thing builds reproducibly from a pinned Guix channel.
    The ISO is 1.57 GB. The qcow2 boots in about eleven seconds on
    KVM.

## what is not in GEOS yet

The Hurd variant. Real hardware. Multi-user. Audio. Bluetooth.
Anything Wayland.

These are real, they are tracked, and I will get to them. GEOS v0.1
proved that Emacs as PID 1, no Shepherd, no shell, actually holds
together under a normal day of work. v0.2 added the things you cannot
live without on a daily driver (input, poweroff, hostname). v0.3 is
where networking, audio, and persistence land.

## relationship to GNU

Guix System is the base. Linux-libre is the kernel. The userland tools
that I do call out from Elisp (`ip`, `ps`, `df` for parsing, never for
display) come from GNU coreutils and iproute2 in the Guix profile.

I am not affiliated with the FSF or with the Guix project. I am a user
of both. If anyone there wants to fold pieces of this work upstream I
would be happy to talk. If they want to tell me the whole approach is
heretical I will listen and then keep building.

## who this is for

People who already live in Emacs and want to stop pretending the rest
of the system is a separate concern. People who think a reproducible
desktop is worth more than a polished one. People who can read a
backtrace and are not scared off by the words "kernel panic in QEMU".

If that is not you, this is not your OS. That is fine. Use what makes
you happy. I am using this.

## the name

It is GNU/Emacs Operating System, GEOS for short. The slash in
GNU/Emacs is mandatory. I am not making the joke you think I am
making. I am making a different joke that happens to land in the
same place.
