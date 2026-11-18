- `apps/macos`: new `SegueAILayer` library target (pure, no side effects) —
  the stage-2 groundwork for the helper's AI lock outside the process
  (design `docs/design/macos.md` §2).
- `AILockList` parses the kernel's built-in destination list
  (`segue-kernel/data/ai-lock.txt`: `suffix <domain>` / `cidr <prefix>`,
  `#` comments, IPv4 and IPv6) and merges a signed bundle's extra
  `ai_domains` / `ai_cidrs` with validation and dedupe; bad lines are typed
  errors with line numbers (host bits set in a prefix are rejected, not
  masked). The tests load a byte-identical copy of the kernel file from
  `Tests/SegueAILayerTests/Fixtures/ai-lock.txt`, refreshed from
  segue-core, never hand-edited.
- `PFAnchorRenderer` renders anchor `segue.ailock` exactly as designed:
  `pass quick on lo0`, `pass quick on <utun>` when a tunnel exists, then one
  `block drop out quick <family> to <cidr> label "segue-ai-<n>"` per armed
  CIDR with unique labels and nothing else (no `user`, no block-all; an
  empty CIDR list passes everything). `PFConfHook` inserts or verifies only
  the `anchor "segue.ailock"` declaration line in a pf.conf — idempotent,
  the rest preserved byte-for-byte, never `load anchor … from` — and
  reports a duplicated hook, a foreign `segue.*` anchor, or a boot-load
  directive as a typed error.
- `ResolverFiles` renders `/etc/resolver/<suffix>` files (`nameserver
  127.0.0.1` plus the helper's `port`) keyed by filename; suffixes are
  validated as plain DNS names since they become filenames. `DNSSnapshot`
  is the pure capture/restore-diff model: per-service server lists (empty
  is a meaningful restore target), a restore plan that says which services
  to rewrite, which already match, which captures lost their service, and
  which services are new and untouched.
- `GuardResponder` answers raw DNS query packets with a hand-written codec:
  armed names (case-insensitive suffix match on the name and subdomains)
  get NOERROR with zero answers for every qtype, anything else is REFUSED,
  nothing is ever recursed, and malformed packets (short, non-query,
  multi-question, compression pointer in the question name) are dropped
  with nil. EDNS additional records are ignored, not echoed.
- 61 XCTest cases pin all of the above, including golden anchor text for
  0/1/many CIDRs with and without a utun (v4+v6), pf.conf hook idempotence
  and preserve-rest, resolver file goldens, and hand-built DNS packets
  (A, AAAA, MX, uppercase, non-armed, truncated).
