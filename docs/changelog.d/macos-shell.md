- macOS shell, stage A: `apps/macos` Swift package (`SegueKit` plus a
  `Segue` menu-bar executable). Models match the kernel loopback control JSON
  (status, policy, utun, errors). `KernelControlClient` talks only to
  127.0.0.1 with the bearer token from the caller's token file, and does not
  follow redirects or use a proxy. Helper IPC is versioned Codable envelopes
  (arm, disarm, status read-back) with no socket yet. The menu's connect and
  disconnect buttons show the read-back, not the click. Diagnostics export
  writes redacted JSON (home paths, bearer tokens, utun peer addresses).
  CI runs `swift build` and `swift test` on macos-15.
