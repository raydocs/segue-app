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
| `connected` | Arm started the kernel (through the helper) and `GET /v1/status` is `state: connected`: the resolver file is `nameserver 127.0.0.1` port `15353`; kernel DNS returns a `198.18.0.0/15` fake-IP; connecting to it increments `segue_relay_connects_home`; a non-AI address increments neither `connects_home` nor `connects_overseas`; loopback still works |
| `kill-kernel` | After SIGTERM (SIGKILL only if it is still alive): a clean shutdown is not restarted, so the utun is gone, the pid is dead, and the helper has converged the layer to the guard; the armed name is still empty NOERROR from `127.0.0.1`; example.com and loopback still work; the CIDR is still dropped |
| `armed-kernel-not-running` | Runs after `kill-kernel`, with the kernel down: no `segue-kernel` process; system `dig www.ailock-fixture.example.com` is empty NOERROR from `127.0.0.1`, and `dig @127.0.0.1 -p 5354` is empty NOERROR; `dig example.com` has an answer; TCP to `198.51.100.10` is dropped; TCP to `127.0.0.1` works |
| `kill-helper` | During launchd's restart the armed name times out or is empty NOERROR from `127.0.0.1`; an upstream NXDOMAIN is a leak. example.com works before and after. After restart the armed name is empty NOERROR from the guard again, and the helper has taken the kernel back over (the orphan's pid file named it) and restarted it |
| `restore-via-release-daemon` | With the helper in `SIGSTOP`, `segue-release-ctl restore` returns `outcome=restored` and `anchor_loaded=false`, removes resolver files whose first line is `# managed by segue.ailock`, puts DNS back, and clears intent. `partial` is FAIL. `SKIP` if `segue-release` or `segue-release-ctl` was not built |
| `expected-leak-doh-quic` | The anchor still blocks only `198.51.100.0/24`. TCP connect to `203.0.113.10:443` succeeds and UDP round-trips. That address is a second lo0 alias, not in the fixture CIDR — the expected leak to an unlisted IP. Do not "fix" this leak. A broader block is `FAIL` |
| `reboot-armed` / `reboot-clear` | On `--host-kind satellite`, `SKIP` (a Satellite is destroyed on reboot). On a persistent VM, post-reboot only. Armed: resolver file and fixture anchor are back, and the rules are not `block drop all`. Clear: resolver file absent, no fixture block |

The fixture suffix `ailock-fixture.example.com` and CIDR `198.51.100.0/24` are not written
into `ai-lock.txt`. `.test` is a reserved TLD: the Satellite VPC resolver answers it
itself, so an empty NOERROR there is not the guard. `example.com` is a real zone and
this label is NXDOMAIN upstream; empty NOERROR from `127.0.0.1` is the guard.
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
