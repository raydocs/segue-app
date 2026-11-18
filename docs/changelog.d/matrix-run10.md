# matrix run 10 harness

Run 10's product chain was fine (arm, posture connected, fake-IP, restore,
expected-leak). Four FAIL rows were harness checks that did not match how
macOS and the helper actually behave.

- System-resolver checks no longer use bare `dig name`. That reads
  `/etc/resolv.conf` and ignores `/etc/resolver`, so on a Satellite the
  armed name was answered by `10.0.0.98`. Rows now use `dscacheutil` and
  `getaddrinfo` (`probes.py resolve`), and flush the resolver cache first.
  `dig @127.0.0.1 -p <port>` stays the direct guard/kernel check. Connected
  requires a `198.18.0.0/15` fake-IP. Kernel down requires no answer, never
  a real address.
- `armed-kernel-not-running` sends `kernel_pause` before it looks. That
  dev verb (helper started with `--requirement` or `--paths-root`; the
  matrix plist passes `--requirement`) stops the kernel without disarming,
  so the anchor and the guard resolver stay. Production refuses it.
  Disarm is not used: it releases the layer. A clean external SIGTERM also
  leaves the kernel down — the supervisor does not restart exit 0 — but
  the row no longer depends on the previous row for that.
- `kill-kernel` SIGTERMs, then scores the gap (no real address, fixture
  CIDR not reachable on the physical NIC). A clean stop must stay down
  (guard, empty resolution, PF drop — the tunnel is down). A crash restart
  must come back as a new pid, posture connected, fake-IP, with the CIDR
  routed into the utun. Run 10 was the clean-stop path (`SIGTERM, stopped`;
  `gone=no` means the utun was not still present).
- Relay metrics are read from the HTTP/1.0 body `segue-relay` writes on
  accept. It does not read a request; sending one first is
  `ConnectionResetError` and the counter looks missing, which is why
  `ai_home_delta` was missing while `ai_connect` was ok.
- The fixture-CIDR expectation follows the tunnel. PF drop only when the
  tunnel is down (and a counter reset from an anchor reload is retried).
  When the tunnel is up the route has to be a utun; the flow is the kernel
  AI tier, not a drop.
