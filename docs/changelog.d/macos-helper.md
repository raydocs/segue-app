- macOS helper, stage 0: shared wire types in `SegueHelperProtocol`, and
  `segue-core-helper` (`SegueHelperCore`). Versioned JSON lines on a unix
  socket; a peer must be in the allowed-uid list and satisfy the code-signing
  requirement. Arm and disarm are persisted mode 0600 and do not start the
  kernel or touch PF or DNS; replies say `ai_layer: not_implemented`. The
  kernel supervisor restarts crashes (10 per 600s, then `kernel_failed`) and
  escalates stop from SIGTERM to SIGKILL after 5s. LaunchDaemon plist and a
  dry-run install script. No privileged install.
