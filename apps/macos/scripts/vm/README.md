# AI-lock matrix on a throwaway macOS VM

This is the privileged self-test for `docs/design/macos.md` §5. It installs
LaunchDaemons, loads PF anchor `segue.ailock`, and writes one resolver file.
Run it only on a throwaway VM, then archive the Amp Satellite thread.

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

From a checkout of this repo, as root:

```bash
export SEGUE_VM_MATRIX=throwaway
bash apps/macos/scripts/vm-ailock-matrix.sh \
  --core-rev <segue-core git revision> \
  --app-rev <segue-app git revision> \
  --work-dir /var/tmp/segue-vm-matrix
```

JSON lands at:

```text
/var/tmp/segue-vm-matrix/vm-ailock-matrix-all.json
```

Copy that file out before archiving the thread. Each row is `PASS`, `FAIL`,
or `SKIP` plus the evidence (dig text, pf counters, kernel log tail).

Reboot rows are two phases. The default run records them as `SKIP` and does
not reboot. Armed, then clear, are separate cycles:

```bash
export SEGUE_VM_MATRIX=throwaway
bash apps/macos/scripts/vm-ailock-matrix.sh \
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
| `armed-kernel-not-started` | `dig www.ai-fixture.test` is empty NOERROR; `dig example.com` has an answer; TCP to `198.51.100.10` is dropped; TCP to `127.0.0.1` works; the kernel is not running |
| `connected` | Kernel DNS returns a `198.18.0.0/15` fake-IP; connecting to it opens a TCP session to the fixture SOCKS exit; a non-AI address does not; loopback still works |
| `kill-kernel` | That utun is gone; the armed name is still empty; example.com and loopback still work; the CIDR is still dropped |
| `kill-helper` | During launchd's restart the armed name times out or is empty; example.com works before and after. A real answer for the armed name is a leak |
| `restore-via-release-daemon` | `SKIP` when `segue-release` was not built. There is no release daemon in this tree |
| `expected-leak-doh-quic` | The anchor blocks only `198.51.100.0/24`. TCP and UDP to `203.0.113.50:443` do not increment that rule. A broader block is `FAIL` |
| `reboot-armed` / `reboot-clear` | post-reboot only. Armed: resolver file and fixture anchor are back, and the rules are not `block drop all`. Clear: resolver file absent, no fixture block |

The fixture suffix `ai-fixture.test` and CIDR `198.51.100.0/24` are not written
into `ai-lock.txt`. The kernel gets them from a bundle signed with
`segue-kernel policy-keygen` / `sign-bundle` (a key generated on the VM).
The helper does not merge a bundle yet, so it is pointed at a generated
`--ai-lock` file with those two lines only.

`segue run -config` has no VLESS inbound (socks, http, tun, tproxy). The
fixture exit is the simplest server it can run: SOCKS on `127.0.0.1:18081`,
freedom outbound. The kernel home outbound is that SOCKS server. A tiny TCP
listener on `198.51.100.10` (lo0 alias) is the stand-in AI host. The drop
probe removes the alias first, because the anchor passes `lo0` before the
CIDR block.

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
