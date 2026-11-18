- macOS VM matrix: `apps/macos/scripts/vm-ailock-matrix.sh` is the throwaway-VM
  self-test for the AI-lock rows in `docs/design/macos.md` §5. It refuses
  unless `SEGUE_VM_MATRIX=throwaway`, and a real run also requires
  `kern.hv_vmm_present=1` and root. `--dry-run` prints every privileged
  command and does not run it. The script never reboots.
- The fixture suffix `ai-fixture.test` and TEST-NET CIDR `198.51.100.0/24`
  are added with `segue-kernel sign-bundle`, not by editing `ai-lock.txt`.
  The helper is pointed at a generated list because it does not merge a
  bundle yet. The fixture exit is a loopback SOCKS `segue run -config`
  (no VLESS inbound in the engine parser). Reboot rows are `--phase
  pre-reboot` / `post-reboot`. `segue-release` is `SKIP` when the binary
  is absent. Results go to one JSON file. `apps/macos/scripts/vm/README.md`
  is the Amp Satellite runbook, including archiving the thread right after.
