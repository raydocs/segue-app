- VM matrix: the fixture exit is `segue-relay` on `127.0.0.1`, with a
  synthetic Ed25519 ticket generated under the work dir (not committed).
  The kernel's AI route is that relay, so `GET /v1/status` can reach
  `state: connected` and the helper moves resolver files onto the kernel
  DNS port. A carrier forwarder on `192.0.2.10` covers `IP_BOUND_IF`
  (the physical NIC cannot dial loopback). The connected row counts
  `segue_relay_connects_home` instead of a SOCKS session delta. Every
  FAIL row includes the kernel status JSON.
