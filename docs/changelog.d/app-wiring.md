- macOS menu, stage 3: `HelperClient` speaks the helper unix socket
  (`status_read`, arm `user_connect`, disarm `user_disconnect` / `quit` /
  `sign_out`) with typed not-installed, version-mismatch, and unauthorized
  errors. The socket is a protocol; tests use a socketpair and a temp-dir
  socket. `ConnectionModel` shows connected only when the kernel read-back
  is `connected`, the helper sees a utun, and the AI lock is armed. The menu
  polls every 2s while open, backs off to 32s when closed, and refreshes on
  wake and network change. Quit does not disarm. Disconnect disarms;
  Restore network asks, then disarms with `user_disconnect`. Diagnostics
  export is a redacted zip of read-backs and logs. The menu explains when
  the helper is not installed.
