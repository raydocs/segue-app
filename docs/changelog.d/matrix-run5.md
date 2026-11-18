## matrix-run5

Run 5 armed with an empty AI list: the helper had already started, so
`--ai-lock` was read once before `ai-lock.fixture.txt` existed, a missing
file became an empty list with no error, the anchor had no CIDR block, the
guard REFUSED the fixture suffix, and `/etc/resolver` was never created.

- The list is reread on every arm. A missing file or a parse error sets
  `status_read` `ai_list_error` (the open errno, or the line that failed)
  and does not install an empty anchor over a list that previously parsed.
- Resolver writes create the directory at mode 0755 and replace the file
  with a temp file in that directory. A failed write reports `errno N` in
  `last_error`.
- `--paths-root` puts `pf.conf` and the resolver directory under `<root>/etc`,
  matching `/etc/pf.conf` and `/etc/resolver`. `--pfctl` records the anchor
  without root.
- Production helper and release plists set `StandardOutPath` and
  `StandardErrorPath` under `/var/log`. The VM matrix plists already point
  those keys at the log directory the harness passes.
- `testMatrixFixtureArmsTunnelThenGuard` runs `segue-core-helper` against
  the matrix fixture, a fake kernel, and a recording pfctl.
