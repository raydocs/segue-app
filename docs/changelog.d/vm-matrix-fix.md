- VM matrix restore row sends `segue-release-ctl restore` (SegueKit
  `ReleaseClient`) on `/var/run/segue-release.sock` while the helper is
  stopped, and checks the read-back: anchor rules empty, marked resolver
  files gone, DNS matches the pre-arm snapshot, intent cleared. The
  throwaway daemon is started with an `identifier` requirement matching
  the ad-hoc signed ctl; production plists still omit `--requirement`.
- Expected DoH/QUIC leak is a second lo0 alias `203.0.113.10` (not in the
  fixture CIDR) with a local TCP listener and UDP echo. TCP must connect
  and UDP must round-trip. The fixture CIDR stays blocked. Do not "fix"
  this leak.
- `SUMMARY fails=` is the number of `FAIL` rows, not a boolean. The JSON
  document is printed between `BEGIN-MATRIX-JSON` and `END-MATRIX-JSON`.
- `--host-kind satellite` skips reboot rows ("Satellite is destroyed on
  reboot; run reboot rows on a Tart VM"). Reboot cycles stay on
  `--host-kind vm`.
