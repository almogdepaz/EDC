# pi background review recovery status

## goal
background review status/logs survive context recovery that wipes `edc-context/`, so `/edc` → review status never loses an active run just because context cleanup happened.

## status
- [x] reproduced root cause from live process state: run metadata under `edc-context/runs/` gets deleted by clean-slate recovery
- [x] added regression test for pi background review status surviving `edc-context` cleanup
- [x] move current background review status to `.git/edc/status`
- [x] move current background review log to `.git/edc/review.log`
- [x] verify narrow regression test after `.git/edc/review.log`
- [x] run full test suite after `.git/edc/review.log` (`bun run test`)
- [x] stopped orphaned old background review subprocesses from the pre-fix run

## notes
- generated context cleanup remains `rm -rf edc-context AGENTS.md`; active process status must not live there.
- only current background review status/log are retained; next run overwrites `.git/edc/status` and `.git/edc/review.log`.
