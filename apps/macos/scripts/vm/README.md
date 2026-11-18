# AI-lock matrix on a throwaway macOS VM

This is the privileged self-test for `docs/design/macos.md` §5. It installs
LaunchDaemons, loads PF anchor `segue.ailock`, and writes one resolver file.
Run it only on a throwaway volume. An Amp Satellite is one command and no
reboots (the volume is deleted, not restarted). Reboot cycles run only on a
persistent VM such as Tart.

The script never reboots and never calls `shutdown`. `--dry-run` prints every
privileged command and does not run it. A real run refuses unless
`SEGUE_VM_MATRIX=throwaway` and `sysctl kern.hv_vmm_present` is `1`, and it
must be root.

## What the VM needs

- A throwaway macOS volume (Tart or UTM). Not the Mac mini CI runner.
- Outbound DNS, so `dig example.com` can get a real answer.
- A default route, so the fixture CIDR probe leaves the machine and hits PF.
  The probe address is TEST-NET `198.51.100.10`, not a host you own.
- Rust and Swift on `PATH`. If `/Volumes/dev/ci/cargo` exists, the script uses
  that cargo home and target dir.
- The VM may reload `/etc/pf.conf` (the helper writes the anchor line but does
  not reload the live ruleset; boot does, and the same-boot rows do it too).
  The image's `pf.conf` must not block the orchestrator's SSH.

## Commands

### Satellite: one command, no reboots

From a checkout of this repo, as root:

```bash
export SEGUE_VM_MATRIX=throwaway
bash apps/macos/scripts/vm-ailock-matrix.sh \
  --host-kind satellite \
  --core-rev <segue-core git revision> \
  --app-rev <segue-app git revision> \
  --work-dir /var/tmp/segue-vm-matrix
```

`reboot-armed` and `reboot-clear` are `SKIP` with reason "Satellite is
destroyed on reboot; run reboot rows on a Tart VM". Do not reboot the
Satellite. JSON lands at:

```text
/var/tmp/segue-vm-matrix/vm-ailock-matrix-all.json
```

The script prints `SUMMARY fails=<number of FAIL rows>` and then the whole
JSON between `BEGIN-MATRIX-JSON` and `END-MATRIX-JSON`. Copy that block out
before archiving the thread. Each row is `PASS`, `FAIL`, or `SKIP` plus the
evidence (dig text, pf counters, kernel log tail).

A failing arm step does not end the run and never SKIPs a later row. The
`armed-kernel-not-running` row records the failure with its step dump, and
every remaining non-reboot row still runs best-effort: each retries its own
preconditions (the socket arm is idempotent, launchd restarts the helper)
and records `PASS`/`FAIL` on its own evidence. A row whose precondition the
failed arm step removed records `FAIL` with `blocked_by=<arm step>` in the
JSON, so one Satellite run surfaces every bug at once. `SKIP` is reserved
for host-kind reasons (reboot rows on a Satellite) and a missing binary.
Each row has a time budget (`ROW_BUDGET`, default 120 s; kill-helper
legitimately needs ~85 s of waits and digs): a row still running past it is
killed with its children and recorded `FAIL`, so a hang cannot eat the run.
The cleanup at the end is unconditional — it is the EXIT trap.

`--simulate-arm-fail <step>` (dry-run only; a real run refuses it) plans
what a run does when the arm dies at that step: every row still planned,
blocked rows marked `blocked_by=<step>`, nothing SKIPped for the arm.

`--exit-via loopback|alias` (default `loopback`) picks where the kernel's
AI exit dials the fixture relay — `127.0.0.1:17443` directly, or the
`192.0.2.10` alias forwarder for comparison with older cores. Both work
with `--dry-run`, which shows the difference in the plan.

### Persistent VM: reboot cycles

`--host-kind vm` (the default) is a Tart or UTM volume that survives a
reboot. The default phase does not reboot. Armed, then clear, are separate
cycles:

```bash
export SEGUE_VM_MATRIX=throwaway
bash apps/macos/scripts/vm-ailock-matrix.sh \
  --host-kind vm \
  --phase pre-reboot --expect armed \
  --core-rev <segue-core git revision> \
  --app-rev <segue-app git revision> \
  --work-dir /var/tmp/segue-vm-matrix
```

The script leaves the helper installed, prints `REBOOT_REQUEST`, and exits.
Reboot the VM (the orchestrator does this; the script will not). After boot,
before relying on the GUI:

```bash
export SEGUE_VM_MATRIX=throwaway
bash apps/macos/scripts/vm-ailock-matrix.sh \
  --host-kind vm \
  --phase post-reboot --expect armed \
  --work-dir /var/tmp/segue-vm-matrix
```

JSON: `/var/tmp/segue-vm-matrix/vm-ailock-matrix-post-reboot-armed.json`.

Repeat with `--expect clear` on both phases. Add `--skip-build` on the second
pre-reboot when `/var/tmp/segue-vm-matrix` already has that revision built.
post-reboot does not build.

A dry plan, safe on a machine that is not a VM:

```bash
SEGUE_VM_MATRIX=throwaway bash apps/macos/scripts/vm-ailock-matrix.sh --dry-run
```

## How long

First real run: about 20–40 minutes (clone, `cargo build --release` of
`segue-kernel`, `segue-cli` and `segue-relay`, `swift build -c release`, then the rows).
A later run that only rebuilds is shorter. The rows themselves are a few
minutes; several `dig` calls use a 2 second timeout on purpose.
pre-reboot is most of that if it builds. post-reboot is under a minute,
plus the reboot the orchestrator performs. Armed and clear are two reboots.

## What it actually checks

| Row | Pass |
| --- | --- |
| `connected` | Arm started the kernel (through the helper) and `GET /v1/status` is `state: connected`: the resolver file is `nameserver 127.0.0.1` port `15353`; `dig @127.0.0.1 -p 15353` and the system resolver (`dscacheutil` / `getaddrinfo`, not bare `dig`) both return a `198.18.0.0/15` fake-IP; connecting to it increments `segue_relay_connects_home`; a non-AI address increments neither `connects_home` nor `connects_overseas`; loopback still works. The metrics read is the HTTP/1.0 body the relay writes on accept — it does not read a request, and sending one is reset |
| `kill-kernel` | SIGTERM the kernel (SIGKILL only if that pid is still alive). The killed pid is gone. During the gap the system resolver returns no real address (nothing, or a fake-IP) and the fixture CIDR is not reachable on the physical NIC. A clean SIGTERM is exit 0 (`SIGTERM, stopped` in the kernel log) and the supervisor does **not** restart it: the utun stays gone, the resolver file is the guard port, `getaddrinfo` returns nothing, `dig @127.0.0.1 -p 5354` is empty NOERROR, example.com is a real address, and the CIDR is a PF drop because the tunnel is down. A crash restart (any other exit) is the other pass: a **new** pid, posture `connected`, fake-IP again, and the CIDR route is a utun rather than a PF drop |
| `armed-kernel-not-running` | Sends `kernel_pause` (dev verb, accepted only when the helper was started with `--requirement` or `--paths-root` — the matrix plist passes `--requirement`). That stops the kernel the way disarm does, but does **not** release the layer. Then: no `segue-kernel` process; the resolver file is the guard port; `getaddrinfo` of the armed name returns nothing (never a real address) and `dig @127.0.0.1 -p 5354` is empty NOERROR; example.com is a real address; the tunnel is down so TCP to `198.51.100.10` is a PF drop; TCP to `127.0.0.1` works. The row pauses the kernel itself. It does not depend on `kill-kernel` leaving it down, and it does not disarm |
| `kill-helper` | SIGKILL the helper; launchd brings it back and it starts the kernel again. During the gap the armed name does not resolve to a real address, and example.com still does. After the new kernel is `connected`, the system resolver and `dig @127.0.0.1 -p 15353` are a fake-IP. example.com is not required once the tunnel is up (split-default routes capture port 53, and the lab domestic resolver is TEST-NET) |
| `restore-via-release-daemon` | With the helper in `SIGSTOP`, `segue-release-ctl restore` returns `outcome=restored` and `anchor_loaded=false`, removes resolver files whose first line is `# managed by segue.ailock`, puts DNS back, and clears intent. `partial` is FAIL. `SKIP` if `segue-release` or `segue-release-ctl` was not built |
| `expected-leak-doh-quic` | The anchor still blocks only `198.51.100.0/24`. TCP connect to `203.0.113.10:443` succeeds and UDP round-trips. That address is a second lo0 alias, not in the fixture CIDR — the expected leak to an unlisted IP. Do not "fix" this leak. A broader block is `FAIL` |
| `reboot-armed` / `reboot-clear` | On `--host-kind satellite`, `SKIP` (a Satellite is destroyed on reboot). On a persistent VM, post-reboot only. Armed: resolver file and fixture anchor are back, and the rules are not `block drop all`. Clear: resolver file absent, no fixture block |

The fixture suffix `ailock-fixture.example.com` and CIDR `198.51.100.0/24` are not written
into `ai-lock.txt`. `.test` is a reserved TLD: the Satellite VPC resolver answers it
itself, so an empty NOERROR there is not the guard. `example.com` is a real zone and
this label is NXDOMAIN upstream; empty NOERROR from `127.0.0.1` is the guard.

System-resolver checks do not use bare `dig name`. That reads `/etc/resolv.conf`
(on a Satellite, `10.0.0.98`) and ignores macOS `/etc/resolver` scoped files, so
an armed name looks like an upstream SOA even while the guard is holding it.
The rows call `dscacheutil -q host -a name` and `probes.py resolve`
(`socket.getaddrinfo`), which honour `/etc/resolver`. `dig @127.0.0.1 -p <port>`
stays the direct check of the guard or the kernel DNS. The cache is flushed
first (`dscacheutil -flushcache`, `killall -HUP mDNSResponder`) so a fake-IP
from the tunnel is not scored after the kernel is gone. Connected means
getaddrinfo returns a `198.18.0.0/15` address. Kernel down means it returns
nothing (the guard's empty NOERROR, or a dead listener) — never a real address.

`kernel_pause` is a dev-only helper verb (`{"version":1,"kind":"kernel_pause"}`).
The helper accepts it only when started with `--requirement` or `--paths-root`.
It is `KernelSupervisor.stop` (SIGTERM, then SIGKILL if needed) followed by
the same converge disarm does **not** get: the intent stays armed, the anchor
stays loaded, and the resolver file is pointed back at the guard port. Disarm
is the wrong tool for `armed-kernel-not-running` because it releases the layer.
Production launchd passes neither flag, so the verb is `unauthorized` there.
An external SIGTERM is not a pause: the kernel exits 0, the supervisor's
`stopRequested` flag is clear, and a clean exit is not restarted (a crash
still is). Run 10's `gone=no` on the kill-kernel row is that variable's
"utun still present? no", and the kernel log is one `SIGTERM, stopped`.

The fixture-CIDR probe follows the tunnel. Tunnel down: the anchor's
`block drop` must move its counter, the connect must fail, and the route
must not be `utun` or `lo0`. A counter that goes backwards is the helper
reloading the anchor; the probe retries. Tunnel up: traffic to the CIDR
enters the utun (kernel AI tier, then the relay), so a PF drop is **not**
expected — the route interface has to be a utun. The gap sample fails only
a connect that succeeds on a physical NIC.
The kernel gets the suffix and CIDR from a bundle signed with
`segue-kernel policy-keygen` / `sign-bundle` (a key generated on the VM).
The helper does not merge a bundle yet, so it is pointed at a generated
`--ai-lock` file with those two lines only.

A FAIL row also records `launchctl print` for the helper and the release daemon,
the helper, kernel and kernel-output log tails (`kernel.log`,
`kernel.stdout`, `kernel.stderr` — the helper captures the kernel child's
stdout/stderr there, mode 0600, rotated at 1 MiB; while the kernel state
is `kernel_failed`, `status_read` also carries the last 2 KiB of stderr,
redacted, as `kernel_last_stderr`), the relay log and metrics, the full
kernel `GET /v1/status` JSON, `ls -l /var/run/segue*`, `lsof` on the guard
port, and the first 60 lines of `scutil --dns`.

The fixture exit is `segue-relay` on `127.0.0.1:17443`, with a synthetic
Ed25519 ticket generated under the work dir at run time (not committed).
The kernel's AI route is that relay (`exit_class: ai`). The relay dials a
confirmed AI target through a loopback Home line — `segue run` SOCKS on
`127.0.0.1:18081` with a freedom outbound — never as a direct overseas
connect. `--exit-via` picks where the kernel's exit dials that relay:

- `loopback` (the default): `127.0.0.1:17443` directly. No alias on the
  physical NIC and no forwarder. Needs a core whose carrier can dial lo0.
- `alias`: `192.0.2.10:17443`, an alias on the physical NIC, with a
  forwarder to the relay — the older world, where carrier sockets bound
  to the NIC (`IP_BOUND_IF`) could not dial loopback. Kept for
  comparison.

A tiny TCP listener on `198.51.100.10` (lo0 alias) is the
stand-in AI host; `/etc/hosts` points the relay's resolver at it (`dig`
does not read hosts). The drop probe removes the alias first, because the
anchor passes `lo0` before the CIDR block. The expected-leak row adds a
second alias, `203.0.113.10/32`, with a local TCP listener and a UDP echo
on port 443, so that probe does not leave the machine.

The helper starts `segue-kernel` and polls `GET /v1/status`. It keeps
resolver files on the guard port until `state` is `connected`, then points
them at the kernel DNS port. `--kernel-by-script` is the debug fallback
that execs the kernel itself.

## Archive the thread right after

Copy the JSON out, then archive the Amp Satellite thread. Do not leave the
VM sitting, and do not start another thread on the same volume until you have
read the cleanup. Exit runs cleanup (bootout, flush `segue.ailock`, delete
`/etc/resolver/ai-fixture.test`, restore DNS and `pf.conf`). A successful
pre-reboot does not clean up, on purpose, so the reboot can see the intent.
`SIGKILL` skips the trap and can leave the anchor and the resolver file in
place. Archiving the thread is what stops that volume from being reused with
a live AI lock.
