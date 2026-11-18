# kernel output capture + matrix exit-via

Matrix run 9 lost the cause of `last_exit=tun_setup_failed` — the helper's
launcher sent the kernel child's stdout and stderr to `/dev/null.

- `KernelSupervisor` + `FoundationProcessLauncher` now append the child's
  stdout/stderr to `kernel.stdout` / `kernel.stderr` in the kernel log dir
  (the `--log` file's directory), mode 0600, rotated to `.1` at 1 MiB per
  launch, so one stream costs at most ~2 MiB. A path that cannot be opened
  falls back to `/dev/null`; a lost capture never blocks the kernel.
- While the kernel state is `kernel_failed`, `status_read` also carries
  `kernel.last_stderr`: the last 2 KiB of the captured stderr, redacted.
  `DiagnosticsRedactor` moved from `SegueKit` to `SegueHelperProtocol`
  (a typealias keeps app-side callers unchanged) so the helper scrubs with
  the same rules as the diagnostics export.
- The VM matrix dumps the `kernel.stderr` tail on FAIL rows and parses
  `kernel_last_stderr` out of `status_read`. New `--exit-via loopback|alias`
  (default `loopback`) puts the kernel's AI exit at the relay on
  `127.0.0.1:17443` directly — no NIC alias, no forwarder; `alias` keeps
  the `192.0.2.10` forwarder for comparison with older cores that cannot
  dial loopback from the carrier.
