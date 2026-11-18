# matrix run 12: prove egress, and a PF drop while the kernel is down

Run 12 passed armed, kill-helper, expected-leak and restore. Two rows failed
for harness reasons, not because the flow left via the physical NIC.

- `connected`: DNS, the fake-IP and `ai_connect=ok` were real, and the relay
  had `carriers_accepted 1` / `tickets_ok 1`. `connects_home` and
  `connects_overseas` stayed 0 because `ssrf_blocked` was 1. The kernel
  dials the fake-IP flow by name. segue-relay resolves that name itself
  (`segue_relay_connects_home` increments only after the home SOCKS dial;
  `connects_overseas` is a direct connect). `/etc/resolver` sends the
  fixture suffix to the kernel, which answers with a `198.18.0.0/15`
  fake-IP, and the SSRF guard blocks that range. `dev_allow_cidrs` is only
  `198.51.100.10/32`. The fixture server's `dns.hosts` is never consulted:
  the relay resolves to an IP before the SOCKS CONNECT. `GET /v1/status`
  has no per-flow counter. `/etc/hosts` is still wrong: run 11 showed it
  makes the client's own resolver return the alias. The relay process
  alone now gets `www.ailock-fixture.example.com` → `198.51.100.10` from
  `relay_hosts.dylib` (`DYLD_INSERT_LIBRARIES`; `nohup` would strip it, so
  a shell sets it and execs). The fixture TCP server records the peer. The
  row passes only when `connects_home` moves and that peer is the home
  SOCKS path (127.0.0.1, or the fixture address if the source is the lo0
  alias). A non-AI flow must not be accepted there. A utun/en0 peer would
  be a bypass; this run was not one.
- `kill-kernel`: clean SIGTERM stayed down (`SIGTERM, stopped`, no new
  pid). The TCP timeout was not a PF drop by itself: `198.51.100.10` is
  TEST-NET, so a packet the anchor does not drop also times out via the
  default route. The counter went backwards (`evaluations 79 → 0`, then
  `24 → 0`) because after the exit the helper's tunnel poll calls
  `kernelChanged` every 250ms for 20s, and each `pfctl -f` zeroes the
  counters. An unchanged anchor body is no longer reloaded. The row
  records kill / exit / utun / probe timestamps and requires the counter
  to move only while `segue-kernel` is not running.
