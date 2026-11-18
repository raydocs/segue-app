- macOS helper, tunnel DNS: armed names are held with `/etc/resolver/<suffix>`
  files (`nameserver 127.0.0.1` and `port`), not per-service DNS.
  `networksetup -setdnsservers` cannot carry a port, so pointing services at
  the kernel's `127.0.0.1:15353` listener never read back and the layer could
  finish armed on system DNS with the resolver files removed. Tunnel up now
  writes the kernel's listen port (from `dns.listen`, published only while
  the control API reports a connected carrier). Tunnel down, a dead kernel,
  or an unknown address rewrites the same files to the helper's guard port
  by atomic replace, so a suffix is never without a file. A failed write is
  `ai_layer=degraded` and is retried; status is never `system` while armed.
  `dns_mode` is `kernel` or `guard`. A leftover per-service snapshot is still
  restored, only after the resolver files are in place. The VM matrix arm
  row requires the kernel port when the helper has a utun and the guard port
  otherwise, and the connected row requires a `198.18.0.0/15` fake-IP from
  both the system resolver and `dig @127.0.0.1 -p <kernel port>`.
