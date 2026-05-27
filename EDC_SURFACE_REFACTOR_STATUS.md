# EDC Surface Refactor Follow-up Status

## Goal

Close the review findings from `EDC_SURFACE_REFACTOR_SUMMARY.md` before treating the surface refactor as ready.

## Tasks

- [x] reproduce stale `t1-tool-lockdown.sh` failure and inspect history
- [x] fix `t1-tool-lockdown.sh` for current `edc-lib.sh` spawn shape
- [x] fix README/plugin README layout drift (`skills/` vs `prompt-bundles/`)
- [x] update stale generated `edc-context/` module docs for new public surface
- [x] update stale benchmark prompts using old skill names
- [x] run relevant hardening tests
- [x] run full-build smoke on an available target repo (`hybrid_donkey_tracker`) in a temp clone
- [ ] run full-build smoke on polybot if repo is available locally — blocked: no local `polybot` directory found under `/Users/home` or `/Users/home/Dev`

## Evidence

- `bash tests/hardening/t1-tool-lockdown.sh` currently exits 1 before useful assertions because it greps old inline `claude -p` formatting.
- `git log` shows prior t1 refactors; current `edc-lib.sh` now uses array-based `cmd=(claude -p ...)` and two allowed-tools contracts.
- `/Users/home/Dev/polybot` was not present at first check; follow-up `find /Users/home -maxdepth 4 -type d -iname '*polybot*'` found no matches.
- `bash tests/hardening/t1-tool-lockdown.sh` now passes after updating the test for array-based claude spawn and both allowed-tool contracts.
- `rg` found no remaining old public/internal skill names in README/plugin docs, benchmark prompts, tests, or plugin source outside generated context.
- Full hardening suite passed via `for t in $(find tests/hardening -maxdepth 1 -type f -name 't*.sh' | sort); do bash "$t"; done`.
- While running full suite, `t2-stream-filter.sh` and `t7-cli-entrypoint.sh` exposed stale expectations from the newer array-based spawn/model guard; both were fixed and verified.
- `plugins/edc/scripts/edc` now validates `--agent` before the non-interactive model guard, so missing-agent errors are not masked by model configuration errors.
- Hybrid Donkey Tracker smoke: temp clone at `/var/folders/5q/bkddpjlx3tz5l_s3k5bgk4m80000gn/T/tmp.6wxvupiSXF/hybrid_donkey_tracker`, `installOrchestratorScript` installed `.edc/scripts` and `.edc/skills`, then `EDC_CODEX_HOME=$HOME/.codex plugins/edc/scripts/edc --model gpt-5.5 build --agent codex <temp> --force` exited 0. Output included `Build OK. Layout validated by edc-doctor.` and a follow-up `bash .edc/scripts/edc-doctor.sh` also printed `edc-doctor: ok`.
- Claude attempt against the same target class was blocked by local auth: `401 Invalid authentication credentials`; codex smoke was used instead.
- Real `/Users/home/Dev/hybrid_donkey_tracker` remained clean (`git status --short --branch` showed only `## main...origin/main`).
