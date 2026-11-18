- macOS helper stage 2: arm and disarm install and release the narrow AI
  layer instead of answering `ai_layer: not_implemented`. `SystemCommands`
  is the only side-effect seam (pfctl `-a segue.ailock -f -` / `-F all` /
  `-s Anchors`, `/etc/pf.conf`, `/etc/resolver/<suffix>`, networksetup DNS,
  and the loopback guard listener). `LiveSystemCommands` is the process and
  file implementation; tests use an in-memory recording fake and never call
  it.
- `AILayerController` arms fail-closed: pf.conf hook, then the anchor (utun
  pass only while the kernel snapshot has one), then either point service
  DNS at the kernel address or — tunnel down — write resolver files and
  start the guard before restoring the DNS snapshot. Disarm reads DNS back
  before it flushes the anchor. A thrown step leaves the layer at least as
  closed as it started. Startup with armed intent re-arms the anchor and
  the resolver files and does not release them; a clear intent installs
  nothing. Kernel death while armed switches to the guard and keeps the
  anchor. Status reports `anchor_loaded`, `resolver_files`,
  `guard_listening`, and `dns_mode` (`tunnel` / `guard` / `system`).
- The production supervisor still does not poll the kernel control API, so
  its snapshots leave the utun and kernel DNS address unset and the live
  helper takes the tunnel-down branch until a later stage publishes them.
