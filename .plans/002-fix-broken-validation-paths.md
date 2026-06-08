# fix broken validation paths

## goal
Make the validation paths from `.plans/001-current-implementation-validation.md` non-footgunny:

1. `edc --model gpt-5.5 ... --agent pi` routes to the intended Pi model/backend.
2. direct `edc-review.sh --model <slug> ...` is accepted for compatibility.
3. pi non-interactive hang is either fixed in this repo or explicitly classified as upstream pi behavior with a minimal repro.

## assumptions
- `gpt-5.5` should normalize to `openai-codex/gpt-5.5` for Pi only.
- Existing non-Pi model behavior must remain verbatim.
- Direct raw orchestrator compatibility can be implemented by exporting `EDC_BUILD_MODEL` / `EDC_REVIEW_MODEL`; raw script still uses `EDC_AGENT_CLI` for backend selection.

## status
- [x] plan written
- [x] red tests added
- [x] implementation done
- [x] pi hang classified/fixed — classified as direct Pi upstream/provider lifecycle hang; EDC pi backend hang guard remains covered by `t18.10`
- [x] narrow tests green
- [x] full suite green
