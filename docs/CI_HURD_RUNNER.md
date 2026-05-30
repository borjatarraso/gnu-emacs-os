# Self-hosted runner for the Hurd boot smoke gate

## why

The Hurd boot smoke at `.github/workflows/hurd-smoke.yml` boots a
canonical Debian GNU/Hurd 0.9 qcow2 under qemu and gates on serial
markers.  github-hosted ubuntu runners do not expose `/dev/kvm` (their
nested-virt story is "we are already nested"), so an unaccelerated tcg
boot of the Hurd image takes 3 to 5 minutes per cycle, which blows past
any sane CI budget.

This is the v0.8 follow-up promised in `docs/HURD_PORT.md` (the "CI
shape" section).  The workflow file is drafted; the gate flips live the
day a runner labelled `hurd-kvm` registers with the repo.

Until that happens, the job's `if:` clause keeps it from queueing on
forks that have no runner provisioned.  The repo owner's own pushes
exercise the gate the moment a runner is up; outside maintainers flip
the repository variable `HURD_RUNNER_REGISTERED=true` after the first
registration.

## hardware shape

Anything that boots Linux with KVM works.  In practice:

  - x86_64 host with Intel VT-x (vmx flag) or AMD-V (svm flag).  check
    with `egrep -c '(vmx|svm)' /proc/cpuinfo`; any non-zero is fine.
  - qemu-system-x86_64 17 or newer.  `qemu-system-x86_64 --version`
    should report 17+ on Debian trixie / Ubuntu 24.10 / Fedora 41.
  - 4 GiB free RAM for the Hurd guest (workflow allocates 2048 MiB; the
    libguestfs appliance during image-reroll wants another 512 MiB).
  - 20 GiB free disk for image overlays.  the pristine canonical image
    is 4 GiB; each per-run overlay grows to roughly 200 MiB; artifact
    retention is 14 days and the workflow uploads serial log plus
    guest-state text only (small).
  - host packages: `qemu-system-x86 qemu-utils libguestfs-tools
    openssh-client`.  guix hosts can substitute the corresponding
    package names.

## runner registration

GitHub generates a one-shot registration token at
`https://github.com/<owner>/<repo>/settings/actions/runners/new`.
Treat it like a secret.  The token expires after roughly an hour, so
register promptly.

```
mkdir -p /var/lib/geos-ci/actions-runner && cd /var/lib/geos-ci/actions-runner
curl -L -o runner.tar.gz \
  https://github.com/actions/runner/releases/download/v2.319.1/actions-runner-linux-x64-2.319.1.tar.gz
tar xzf runner.tar.gz
./config.sh \
  --url https://github.com/<owner>/<repo> \
  --token <TOKEN> \
  --labels hurd-kvm \
  --name "$(hostname)-hurd" \
  --unattended
sudo ./svc.sh install
sudo systemctl enable --now actions.runner.<owner>-<repo>.$(hostname)-hurd.service
```

The systemd unit name comes out long; `systemctl list-units 'actions*'`
shows it after `svc.sh install`.  Rename via `--name` above if a
shorter handle would help.

After registration, flip the ungate by setting the repository variable
`HURD_RUNNER_REGISTERED` to the literal string `true` under
`Settings > Secrets and variables > Actions > Variables`.  Repo owners
do not need this; the workflow's `if:` clause accepts either
condition.

## secrets and env

The workflow expects three runner-side inputs:

  - `secrets.HURD_RUNNER_KEY`: PEM-encoded SSH private key that opens
    a root session on the booted Hurd guest.  the matching public key
    is baked into the rerolled image (the `SSH_PUBKEY` input to
    `iso-build/hurd-image-reroll.sh`).  generate once with
    `ssh-keygen -t ed25519 -N '' -f hurd_runner_key`, store the
    private half as the secret, install the public half on the runner
    at `~/.ssh/hurd_runner_key.pub`.
  - variable `HURD_PRISTINE_IMG`: absolute path on the runner to the
    pristine canonical Debian GNU/Hurd 0.9 image.  default
    `/var/lib/geos-ci/pristine/debian-hurd-amd64-20260314.pre-pid1.img`
    matches my own runner layout; override per runner if needed.
  - variable `HURD_PID1_BIN`: absolute path to a `STATIC=1`
    `emacs-init` binary built for `PORT=hurd`.  optional.  if absent,
    the workflow runs `make -C pid1 PORT=hurd STATIC=1` on the runner
    and stages the result.  the runner needs the cross toolchain for
    that path; until it does, prebake the binary off the runner and
    point `HURD_PID1_BIN` at it.

The runner user needs read access to the pristine image and write
access to `/tmp` (where the workflow stages overlays and serial logs).
The simplest layout is:

```
sudo install -d -o <runner-uid> -g <runner-uid> \
  /var/lib/geos-ci /var/lib/geos-ci/pristine /var/lib/geos-ci/staging
sudo cp /path/to/canonical-hurd.img \
  /var/lib/geos-ci/pristine/debian-hurd-amd64-20260314.pre-pid1.img
```

The runner also needs membership in `kvm` (so `/dev/kvm` is openable
by the runner uid):

```
sudo usermod -aG kvm <runner-uid>
sudo systemctl restart actions.runner.*
```

Verify with `sudo -u <runner-uid> test -w /dev/kvm && echo ok`.

## security note

A self-hosted runner that accepts pull-request builds from untrusted
forks is a remote-code-execution vector by design.  Two ways to keep
that contained:

  - workflow-level: this draft only fires on `push` to `main` and
    `hurd` and on `pull_request` to `main`.  the github recommendation
    is to also gate fork PRs behind a maintainer's `pull_request_target`
    approval step, or to drop the `pull_request` trigger entirely and
    smoke-only-on-push.  i lean toward the second for any runner that
    holds long-lived secrets.
  - runner-level: run the runner inside an ephemeral VM that resets to
    a snapshot after every job.  `actions-runner-controller` on
    kubernetes is the upstream story; for a single-host setup a libvirt
    `virsh snapshot-revert` between jobs works.  the runner registers
    as ephemeral with `--ephemeral` on `config.sh`, github
    de-registers it after each job, the next job starts a fresh VM
    that re-registers from the same token-rotating script.

Either is acceptable.  For my own runner i use the workflow-level gate
and accept that fork PRs do not get hurd smoke; the gate only fires on
push to main/hurd and on PRs to main from branches inside the repo.

## teardown

Stop the runner service, deregister, remove the install dir.  A fresh
token from the github UI is required for `config.sh remove`.

```
sudo systemctl stop  actions.runner.<owner>-<repo>.$(hostname)-hurd.service
sudo systemctl disable actions.runner.<owner>-<repo>.$(hostname)-hurd.service
cd /var/lib/geos-ci/actions-runner
sudo ./svc.sh uninstall
./config.sh remove --token <TOKEN>
cd /
sudo rm -rf /var/lib/geos-ci/actions-runner
```

If the runner host is going away for good, also clear the repository
variable `HURD_RUNNER_REGISTERED` so the workflow's `if:` clause keeps
PRs from stalling.  Repo-owner pushes will continue to attempt the
gate; that is intentional, because the owner is the one who would
re-provision a runner.

## troubleshooting

`smoke TIMEOUT after 300s, success markers never matched`: the
workflow's `boot smoke gate` step polled the serial log for 300
seconds and never saw both `hurd-essentials: eth0 static OK` and
`geos: emacs userland up`.  download the build artifact
(`hurd-smoke-<run-id>`), open `serial-<run-id>.log`, scan from the
top.  the earlier `hurd-image-reroll.sh` step would have caught any
GRUB / gnumach / pid1 wedge already, so a timeout at this stage almost
always means an elisp-level regression in `services/hurd-essentials.el`
or `core/boot-marker.el`.

`pid1 PORT=hurd STATIC=1 build failed`: the runner is on the build
path and the cross toolchain is missing or incomplete.  the long way
is to install `gcc-x86-64-linux-gnu hurd-dev` (the latter is in
`debian-ports` and may need `dpkg --add-architecture`).  the short way
is to build pid1 on a real Debian Hurd box, scp the binary to the
runner, set `HURD_PID1_BIN` to its path, and re-run.

`/dev/kvm not writable by runner uid`: the runner user is not in the
`kvm` group, or `systemd` started the runner before the group was
applied.  `id <runner-uid>` should list `kvm`; if not, fix and
`systemctl restart` the runner.
