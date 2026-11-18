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
`segue-kernel` and `segue-cli`, `swift build -c release`, then the rows).
A later run that only rebuilds is shorter. The rows themselves are a few
minutes; several `dig` calls use a 2 second timeout on purpose.
pre-reboot is most of that if it builds. post-reboot is under a minute,
plus the reboot the orchestrator performs. Armed and clear are two reboots.

## What it actually checks

| Row | Pass |
| --- | --- |
| `connected` | Arm started the kernel (through the helper): kernel DNS (`dig @127.0.0.1 -p 15353`) returns a `198.18.0.0/15` fake-IP; connecting to it opens a TCP session to the fixture SOCKS exit; a non-AI address does not; loopback still works. System DNS stays on the guard — port 15353 is not a system-resolver port |
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
the helper and kernel log tails, `ls -l /var/run/segue*`, `lsof` on the guard
port, and the first 60 lines of `scutil --dns`.

`segue run -config` has no VLESS inbound (socks, http, tun, tproxy). The
fixture exit is the simplest server it can run: SOCKS on `127.0.0.1:18081`,
freedom outbound. The kernel home outbound is that SOCKS server. A tiny TCP
listener on `198.51.100.10` (lo0 alias) is the stand-in AI host. The drop
probe removes the alias first, because the anchor passes `lo0` before the
CIDR block. The expected-leak row adds a second alias, `203.0.113.10/32`,
with a local TCP listener and a UDP echo on port 443, so that probe does
not leave the machine.

The helper does not publish a utun, and its supervisor argv passes `--config`,
which `segue-kernel` rejects. The connected row starts
`segue-kernel run --state-dir … --log … kernel.json` itself and queries the
kernel's DNS port. System DNS stays on the guard.

## Archive the thread right after

Copy the JSON out, then archive the Amp Satellite thread. Do not leave the
VM sitting, and do not start another thread on the same volume until you have
read the cleanup. Exit runs cleanup (bootout, flush `segue.ailock`, delete
`/etc/resolver/ai-fixture.test`, restore DNS and `pf.conf`). A successful
pre-reboot does not clean up, on purpose, so the reboot can see the intent.
`SIGKILL` skips the trap and can leave the anchor and the resolver file in
place. Archiving the thread is what stops that volume from being reused with
a live AI lock.
