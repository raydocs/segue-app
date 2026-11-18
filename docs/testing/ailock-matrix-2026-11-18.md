# AI-lock matrix on a real Mac — first all-green run (2026-11-18)

Synthetic test, not production evidence. Environment: Amp macOS Satellite (macOS 27, arm64 VM, mac.medium),
`apps/macos/scripts/vm-ailock-matrix.sh --host-kind satellite`, fixture exit = `segue-relay` on 127.0.0.1 with
run-time synthetic Ed25519 tickets, fixture AI suffix `ailock-fixture.example.com`, fixture AI CIDR 198.51.100.0/24
(TEST-NET), unlisted leak target 203.0.113.10 (TEST-NET). Revisions: segue-app `62be614`, segue-core `38c54f1`.
Run 13 of the series (runs 1–12 found and fixed the bugs listed below). Cost of the run: $0.16.

| Row | Result | Key evidence |
| --- | --- | --- |
| armed, kernel not running | PASS | guard answers empty NOERROR; system resolver returns nothing for the armed name, real answers for example.com |
| connected | PASS | armed name → fake-IP 198.18.89.127 (system resolver and kernel DNS); AI flow peer = relay (home delta 1); non-AI flow never touches the relay |
| kill kernel | PASS | killed pid dead in 281 ms, utun gone in the gap, PF drop counter 0→2→4 for the AI CIDR while the kernel is down |
| kill helper | PASS | armed name never resolves to a real address during the restart; fake-IP again after |
| expected leak (DoH/QUIC to an unlisted IP) | PASS | TCP + UDP to 203.0.113.10 succeed; anchor blocks only the fixture CIDR (documented leak, do not "fix") |
| restore via segue-release (helper paused) | PASS | outcome=restored, anchor empty, resolver files removed, intent and snapshot cleared |
| reboot armed / reboot clear | SKIP | Satellites are destroyed on reboot; needs a persistent VM (Tart) or a real Mac |

Bugs the series found (all fixed, see git history of apps/macos and segue-core PRs #67, #70):
helper bound its socket after reconcile; probe peer-denied + single `/v1/connect` race; tunnel-up DNS could not carry a
port and fell back to system DNS (fail-OPEN); AI list read once at startup (empty list); `/etc/resolver` missing;
helper did not supervise the kernel; loopback exits pinned to the physical NIC; exit-route EEXIST exited the kernel
silently; kernel stdout/stderr not captured; anchor reloaded every 250 ms after a kernel exit (zeroed PF counters);
plus several harness bugs (swapped wait args, `dig` ignoring /etc/resolver, /etc/hosts polluting the client resolver).

Still open: reboot rows; Safe Mode, sleep/wake and a notarized signature are manual checks before a beta.
