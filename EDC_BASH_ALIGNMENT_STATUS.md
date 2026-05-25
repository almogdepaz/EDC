# edc bash alignment status

## goal
make cli and pi use one resolved bash >=4 for all edc orchestrator entrypoints and nested script calls.

## evidence
- wolfpack pi review failed because top-level pi used `/opt/homebrew/bin/bash`, but nested bare `bash` resolved to `/bin/bash` under `bash -lc`.
- `/bin/bash` on macos is bash 3.2 and trips edc version gates.

## plan
1. add regression coverage for nested bad PATH.
2. add shared `EDC_BASH` resolution/export.
3. replace internal bare edc script invocations with `$EDC_BASH`.
4. export `EDC_BASH` from pi backend and align PATH.
5. run narrow + relevant hardening tests.

## status
- started: 2026-05-25
- current: implementation verified

## red result
- `bash tests/hardening/t19-bash-alignment.sh`
- failed before implementation because `edc-review.sh` auto-mode re-entered via ambient `bash`, which resolved to the fake PATH bash.

## green narrow result
- `bash tests/hardening/t19-bash-alignment.sh`: 2 passed
- `bash tests/hardening/t7-cli-entrypoint.sh`: passed
- `bash tests/hardening/t18-pi-backend.sh`: 6 passed
- `bash tests/hardening/t14-resolve-prompt-decoupled.sh`: 26 passed after making the test actually hermetic from repo-local `.edc/skills`

## broader verification
- `bun test`: no bun-native tests found (exit 1); project test script is `bun run test`
- `bun run test`: first run failed at t14 because repo-local `.edc/skills` leaked into a nominally hermetic test; test fixed to cd into temp workdir
- `bun run test`: passed after implementation and test stabilization
