## matrix-run3

Run 3's arm row failed with "helper did not arm" while the helper, the guard,
and the kernel were all up. The row did not say which wait died.

- `arm_helper` names the failing step (`socket_present`, `socket_arm`,
  `resolver_present`, `pf_reload`, `anchor_refill`, `anchor_has_fixture`,
  `guard_answers`, `helper_kernel_up`, and the after-reload repeats) and
  dumps status_read, the parsed kernel fields, the socket-arm reply,
  `control.json`, the intent file, resolver files, `pfctl -a segue.ailock -s rules`,
  and the guard dig into the row. `--dry-run` lists those steps and the
  same evidence commands.
- The matrix helper is started with `--requirement` for
  `identifier "com.apple.python3" and anchor apple`. Without it the probe
  was peer-denied, so `helper_kernel_up` never saw the utun. Production
  plists still omit `--requirement`.
- The helper retries `POST /v1/connect` until the control API reports a
  connected carrier with a utun, re-reading `control.json` each pass. One
  call at start lost the race with the token file, and a kernel restart
  (new port, new token) was not connected again. A restart during the poll
  extends the deadline instead of being dropped.
- The helper polls the intent file, so an arm written after bootstrap does
  not need `launchctl kickstart`. `pfctl -f /etc/pf.conf` still flushes
  anchor contents; the harness sends `arm` again on the socket to refill
  them. `start()` leaves the live kernel alone, so the kickstart — which
  SIGTERMed the kernel and minted a new control port — is gone. A clear
  intent is still not applied from the file; release stays on the disarm
  path.
- `testFakeKernelArmConnectsAcrossRestart` runs `segue-core-helper` with
  `--paths-root` against a fake kernel that delays `control.json`, stays
  disconnected until `POST /v1/connect`, and binds a new port when killed.
