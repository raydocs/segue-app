# Matrix run 2: segue-core follow-ups

Satellite run of app `12072f7` / core `72d8126`. These two rows need a
segue-core change. The app repo cannot fix them.

## connected: AI flow never reaches the fixture SOCKS

The matrix kernel config is a signed bundle whose `ai_route` is the outbound
tag `home`, a SOCKS client of `127.0.0.1:18081` (the fixture `segue run`
inbound), with `"tun": {"ipv6": false}`. DNS did the right thing: fake-IP
`198.19.221.198`, and `ai_connect=ok`. `ai_socks_delta` stayed 0.

`TunSession::prepare` installs a socket protector that pins **every** dial
fd to the physical NIC with `IP_BOUND_IF` (`crates/segue-kernel/src/tun_setup.rs`,
`InterfaceBind`). `KernelDialer::dial` then hands the `home` tag to the
engine dialer (`session/mod.rs`), which connects through that protector.
A socket bound to `en0` cannot connect to `127.0.0.1`, so the home SOCKS
handshake never starts. The utun stack still completes the client handshake,
which is why connect looks fine.

Core change: do not call `protect` for a dial whose next hop is loopback
(or any address that routes via `lo`). `protect` currently runs before
connect and does not see the destination, so the dialer has to skip it
when the outbound's server address is loopback. A non-loopback home exit
is unaffected.

## kill-kernel: utun4 still listed after segue-kernel

The helper does not open a utun. `KernelSupervisor.start` is not called
from `HelperSession` (stage 0), and its argv (`run --config`) is not what
the matrix uses. The only control fd is the one `open_utun` holds in
`LiveTun`, `FD_CLOEXEC`, borrowed by the packet runtime
(`TunFdClosePolicy::Borrowed` in `main.rs`). `Drop` / `tun.shutdown` deletes
the split routes and closes that fd. Nothing else in this repo dups it.

The matrix used to `SIGKILL` 300ms after `SIGTERM`, which skips
`tun.shutdown`. XNU should still destroy the utun when the last fd closes.
Run 2 showed `utun4` still in `ifconfig -l` two seconds later. The matrix
now waits up to 5s for the SIGTERM handler (`wait_for_stop`) to exit, and
records whether the pid is actually dead, before SIGKILL.

If a **confirmed-dead** pid still leaves the utun, core should issue
`SIOCIFDESTROY` in `LiveTun::shutdown` after the close, so a graceful stop
does not depend on the control-socket teardown. That ioctl cannot run
after SIGKILL; a utun that survives process death is an XNU leak of the
control fd and needs a core-side owner check (`lsof` on the utun) rather
than another process holding it from the helper.
