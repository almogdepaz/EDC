# review fix status

source review: `review-HEAD.md` (run `20260526T233547Z-review-47376`)

## issue checks

- [x] agent-wrappers: background review start race — still current before fix; new `t10` immediate duplicate-start regression failed red, now passes.
- [x] agent-wrappers: absolute `.edc/scripts` bash timeout — still current before fix; new `t10` absolute-path timeout coverage now passes.
- [x] agent-wrappers: stale `status=running` recovery — still current before fix; new `t10` dead-PID recovery coverage now passes.
- [x] hardening-tests: `EDC_PI_SUBPROCESS=1` env hermeticity — still current before fix; red observed at `CMDS_FAIL:`, now passes with `EDC_PI_SUBPROCESS=1`.
- [x] hardening-tests: bash >=4 interpreter selection — still current before fix; macOS-like PATH made `t15`, `t18`, `t19` fail at the Bash >=4 gate, now passes.
- [x] runtime-cli: pi `agent_end` error handling — stale; current HEAD has `classify_agent_end` and `t18` coverage for assistant error.
- [x] runtime-cli: allowed+unexpected unmapped accounting — stale; current HEAD adds `allowed-unmapped` report/manifest coverage and `t15` mixed-case assertions.
- [x] runtime-cli: `EDC_PI_MODEL` top-level gate — still current before fix; new `t7` EDC_PI_MODEL-only case failed red, now passes.

## implementation

- `agents/pi/index.mjs`: synchronous running-status reservation, dead/stale running-state recovery, absolute project `.edc/scripts` timeout matching.
- `plugins/edc/scripts/edc`: top-level model gate accepts `EDC_PI_MODEL` when `--agent pi` is selected.
- `tests/hardening`: regression coverage for duplicate starts, stale PID recovery, absolute timeout matching, env hermeticity, Bash >=4 resolution, and EDC_PI_MODEL-only pi CLI dispatch.

## verification

- `/opt/homebrew/bin/bash -n ... && node --check agents/pi/index.mjs` passed.
- `PATH=/opt/homebrew/bin:$PATH env -u EDC_PI_SUBPROCESS bun run test` passed all hardening tests.
