- Helper listens before it reconciles an armed intent, so a slow or failed
  `pfctl` no longer hides the socket. `--paths-root`, `--guard-port`, and
  `--requirement` run it without root. A pfctl failure still starts the DNS
  guard. `anchor_loaded` is "the anchor has rules": `pfctl -s Anchors` keeps
  listing `segue.ailock` after `-F all` because the pf.conf hook names it,
  which made every real restore `partial`.
- VM matrix fixture suffix is `ailock-fixture.example.com` (not `.test`, which
  the Satellite resolver answers itself). Armed checks require empty NOERROR
  from `127.0.0.1` and `dig @127.0.0.1 -p <guard>`. FAIL rows capture launchctl,
  helper/kernel logs, `/var/run/segue*`, the guard listener, and `scutil --dns`.
  Restore PASSes only on `outcome=restored` and `anchor_loaded=false`.
  Kernel SIGTERM is given time to drop the utun before SIGKILL.
