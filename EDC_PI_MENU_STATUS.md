# edc pi menu status

## goal
replace multiple pi slash commands with a single interactive `/edc` menu.

## assumptions
- pi interactive users use `/edc`; non-interactive users use the `edc` cli.
- first review action runs current branch (`HEAD`) against `main`.
- old pi commands are intentionally removed.

## status
- current: implementation verified

## implemented
- `/edc` is the only registered pi command.
- `/edc` uses `ctx.ui.select` for menu actions.
- review action launches background review with `HEAD --base main`.
- status/build/update/audit/doctor actions reuse existing deterministic script paths.
- non-interactive `/edc` prints CLI guidance instead of executing.
- pi install docs now advertise only `/edc`.

## verification
- `node --check agents/pi/index.mjs`
- `bash -n tests/hardening/t10-pi-extension.sh agents/pi/install.sh`
- `bash tests/hardening/t10-pi-extension.sh`
- `bash tests/hardening/t7-cli-entrypoint.sh`
- `bash tests/hardening/t18-pi-backend.sh`
- `bash tests/hardening/t5-portability-install.sh`
- `bun run test`
