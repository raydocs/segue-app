- VM matrix: a failing arm step no longer SKIPs every later row. The
  `armed-kernel-not-running` row keeps its step dump, and each remaining
  non-reboot row still runs best-effort — retrying its own preconditions
  (idempotent socket arm, launchd helper restart) and recording PASS/FAIL
  on its own evidence, with `blocked_by=<arm step>` in the JSON when the
  precondition never came true. SKIP is now only for a missing binary or
  host-kind reasons (reboot rows on a Satellite), so one Satellite run
  surfaces every bug at once. `SUMMARY fails=` counts those FAIL rows.
- VM matrix: each row runs under a time budget (`ROW_BUDGET`, 120 s
  default). A row still running past it is killed with its children and
  recorded FAIL, so a hung probe cannot eat the run; cleanup stays
  unconditional on the EXIT trap.
- VM matrix: `--simulate-arm-fail <step>` plans a run whose arm dies at
  that step — dry-run only, a real run refuses it (exit 2) — showing every
  row still planned with its `blocked_by` marking.
