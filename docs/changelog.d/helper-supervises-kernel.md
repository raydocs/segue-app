## helper-supervises-kernel

The macOS helper now actually runs `segue-kernel` (stage 1 wiring; found by
the matrix bee: `KernelSupervisor.start` was never called and its argv passed
`--config`, which the kernel CLI rejects).

- `KernelSupervisor` argv matches the real CLI (`run --state-dir DIR --log
  PATH <kernel.json>`), polls `/v1/status` through the kernel's control token
  file for the utun and the carrier, and publishes the kernel DNS listen
  address (from kernel.json) only while the control API reports `connected`.
  The child's pid goes to `<stateDir>/kernel.pid`; a start that finds a live
  kernel named there (an orphan from a SIGKILLed helper) takes it over before
  spawning, so a fresh child cannot lose the ports to a leftover process.
- `arm` (user_connect): persist intent, install the narrow guard, start the
  kernel, then converge to "tunnel up" — kernel DNS for every service once
  the carrier is connected and the kernel's listen address is a valid system
  resolver (an IP or `ip:53`), the guard at every other moment. The converge
  runs on a background poll (`POST /v1/connect`, then `GET /v1/status`), so
  the arm reply is not held for the connect.
- `disarm` (user_disconnect / quit / sign_out): release the layer first (DNS
  restored and read back before the anchor flushes), then stop the kernel
  (SIGTERM, 5 s grace, SIGKILL).
- Kernel crash: restart inside the budget; while the kernel is down or coming
  back the layer is in guard mode and is never released. Budget exhaustion
  reports `kernel_failed` and keeps the layer. Helper restart with armed
  intent re-arms the narrow layer and starts (or takes over) the kernel again.
- `status_read` reports the kernel pid, state, last exit code, and the utun
  name from the kernel's control API.
- New `KernelControlClient` (`LiveKernelControlClient`) speaks the loopback
  control API: token file read, Bearer auth, `Host: localhost`, no `Origin`.
  `HelperPaths` grows `--kernel-log` and `--control-token`.
- VM matrix: the kernel is started by the helper via arm (status_read wait
  replaces the script's `nohup`); `connected` runs on the already-running
  kernel, `kill-kernel` drops to the renamed `armed-kernel-not-running` row,
  and `kill-helper` waits for the takeover. `--kernel-by-script` keeps the
  script-exec path for debugging. `kernel.json` gains a `control` section.
