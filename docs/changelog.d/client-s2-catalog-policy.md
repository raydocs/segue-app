- `segue-client`: account and device types. Access tokens stay in memory;
  refresh tokens go only to the credential store. `401` ends the session.
  `403 PLAN_EXPIRED` and `403 QUOTA_EXHAUSTED` are an account hold: tokens stay,
  and the hold does not disarm the AI lock.
- Catalog admission. A signed schema-1 document is checked with Ed25519, capped,
  and kept only when its revision is newer than the stored floor. The same
  revision and digest is idempotent; any other digest at that revision is
  refused. Node names follow the kernel exit grammar, relays are literal
  `ip:port`, and outbound servers are literal public IPs (documentation ranges
  allowed). An absent egress group is left absent so the kernel pins AI to that
  exit alone. Admitted nodes are the `prepare` input.
- Policy and ticket lifecycle. The client checks the policy envelope (size,
  key id, signature, version floor, expiry against the last server `Date`) and
  forwards the original bytes. It does not read the rule table. A fast device
  clock cannot expire a bundle the server still considers valid. Tickets are
  `SGT1.` bearers: stored as secrets, kept out of status and errors, refreshed
  before `not_after`, and an older ticket cannot replace a newer one. Expiry
  of a stored ticket is a scheduled UI state, not a connect failure.
- The cache is a state-store port. The crate does not open files. Bindings
  write ticket bytes mode `0600`.
- Conformance vectors: `crates/segue-client/vectors/catalog/` and
  `vectors/policy/`. Signing seeds are labels, not committed private keys.
