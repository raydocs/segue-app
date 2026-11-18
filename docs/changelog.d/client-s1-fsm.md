- `segue-client`: new proprietary crate with no OS calls and no sockets.
  Shells bind five ports (HTTP, credentials, data plane, protector, clock).
  `prepare()` turns an admitted catalog, policy key refs, and ticket paths
  into one kernel config: loopback listeners, exits, segue routes, signed
  policy paths, DNS and UDP, and no inline `rules` or `default`. An absent
  egress group is left absent, so the kernel keeps that exit as its own group.
- Connect state machine with the nine phases (Off, Preparing, Arming,
  Connecting, Verifying, Connected, ProtectedOffline, Disarming, Failed).
  Only an explicit disconnect, sign-out, or quit disarms the AI lock. A lost
  arm or disarm reply is retried and is not a release. A crash returns to Off
  and keeps the recorded intent, including an arm that was already persisted.
- Default failure mode is an AI-only hold. The reconnect ladder is 2/5/10/20/30
  seconds with a 30 minute budget. When that budget runs out, ordinary traffic
  is released and AI stays blocked. Strict mode is a setting and keeps ordinary
  traffic held. Conformance vectors are
  `crates/segue-client/vectors/fsm/transitions.json` and
  `crates/segue-client/vectors/intent/scenarios.json`.
