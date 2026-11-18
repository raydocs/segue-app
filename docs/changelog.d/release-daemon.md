- macOS `segue-release` daemon, design §3's escape hatch: a second root
  LaunchDaemon on `/var/run/segue-release.sock` that restores the network
  without the helper. One idempotent verb, `restore` — flush the
  `segue.ailock` anchor, remove only `/etc/resolver` files carrying Segue's
  `# managed by segue.ailock` marker (foreign files survive), put the DNS
  snapshot's servers back, clear the persisted arm intent, and answer with a
  read-back (`restored` only when the anchor is empty, the files are gone,
  DNS is `system`, and no step failed). Same peer check as the helper
  (allowed uid plus the code-signing requirement); no IPC to the helper, so
  a stuck helper cannot delay it. The helper's resolver files now carry the
  marker line. `install-helper.sh --dry-run` prints the release daemon's
  install steps too (still dry-run only), and
  `Resources/com.segue.release.plist` is its launchd template.
- SegueKit `ReleaseClient` speaks the release socket
  (`ReleaseProtocol.swift`, version 1, same envelope discipline as the
  helper). Restore network still asks the helper first, but a helper that
  cannot answer within 3 s — or whose socket is dead, or that was
  uninstalled leaving the machine locked — is bypassed via the release
  daemon, and the kernel is disconnected either way. Plain Disconnect never
  uses the fallback. Tests cover the armed-machine restore, idempotency,
  foreign resolver files, peer rejection, protocol errors, and the app
  fallback on a stuck helper.
