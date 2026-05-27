# BUILD_VALUE_PLAN

## Goal

Decide whether `edc build` earns its cost as a prerequisite for `edc review`.

Exit with exactly one of:

- **(a) keep mandatory** — measured lift justifies build cost
- **(b) make optional/conditional** — lift only in specific shapes (weak review model, large repo, multi-module diff, etc.)
- **(c) drop** — no measurable lift over no-build

Every claim in the final report must be backed by re-scorable artifacts under `benchmark/regression/results/`.

---

## Status legend

- `todo` — not started
- `wip` — in progress
- `done` — finished, artifacts committed
- `blocked` — waiting on prior phase / external input

---

## Phase 0 — Trust the scorer first (BLOCKING)

**Status:** done

**Why this is first:** the judge undercounts real findings. Concrete case: `benchmark/regression/results/d0451ef052/v2/build-sonnet-review-sonnet/curl/review-results.tsv` records `0.333` recall, but transcript inspection shows the review wrote exact findings (including CVE IDs and affected files) for ~9/9 CVEs. Anthropic safety refusals plus brittle JSON extraction silently mark exact findings as `missed`. No build/no-build conclusion is valid until this is fixed.

### 0.1 Audit current scorer failure modes — `done`

Implemented: `benchmark/audit.py` + `benchmark/transcript_utils.py`. First sweep over `benchmark/regression/results/**` produced `benchmark/judge-audit.md`:

- 129 rows audited across 27 TSVs.
- 58 `ok`, 55 `actual-miss`, 1 `keyword-prefilter`, 15 `unknown`.
- 16 suspect rows where the recorded verdict is `missed`/error but the reconstructed transcript contains the CVE id AND an affected file. These are the high-likelihood undercounts.
- All 6 `d0451ef052` sonnet/sonnet `missed` rows show up as suspect, matching the manual transcript audit from the prior debugging session.

- Re-score every run under `benchmark/regression/results/**` using the existing `score.py`.
- For each row, cross-check the recorded verdict against the transcript-written `issues.md` (or `~/.claude/projects/.../*.jsonl` when `issues.md` is missing).
- Classify each mismatch as one of:
  - `refusal` — judge `claude -p` refused / returned safety boilerplate
  - `parse` — judge returned a verdict but the regex failed to extract it
  - `keyword-prefilter` — `kw_score < KEYWORD_THRESHOLD` killed the row before the judge ran, despite a real finding being present
  - `actual-miss` — review really did not find the CVE
- Output: `benchmark/judge-audit.md` with per-CVE mismatch table and counts per failure class.

### 0.2 Fail loudly on judge errors — `done`

No retries. No silent fallback. If the judge fails, the row is marked failed and surfaced so a human can re-judge it interactively after the run.

- Detect refusal patterns ("I can't help with that", "I cannot assist", policy/safety language) and emit verdict `judge_error` with a reason field.
- Require the judge to QUOTE from `issues.md`; verdicts without a quote become `judge_error`.
- Distinguish `judge_error` from `missed` in the TSV `verdict` column. Currently they collapse into `missed` via the keyword-only fallback — drop that fallback.
- `judge_error` rows are excluded from recall aggregates (not counted as misses, not counted as hits). The aggregate report must show `n_scored / n_total` and the count of `judge_error` rows.
- Print a post-run summary listing every `judge_error` row with: cve, run path, issues.md path, transcript path. This is the worklist for the interactive re-judge step.

### 0.2b Interactive re-judge tool — `done`

Implemented: `benchmark/rejudge.py`. Walks rows where `found == judge_error` or `build_verdict == judge_error`, locates the analysis text via `transcript_utils`, prompts for verdict, writes back in place with `manual=1` audit trail and a `.bak.<ts>` of the original TSV.

- `benchmark/rejudge.py <results.tsv>` walks every `judge_error` row.
- For each row: print the CVE info + issues.md content, optionally open in `$PAGER`, prompt for verdict (`exact / partial / missed / skip`).
- Writes the corrected verdict back to the TSV with a `manual=1` flag.
- This is the escape hatch for Anthropic refusals: when automated judging fails, a human resolves it once, in batch, after the run.

### 0.2c Validation against the known-bad case — `done`

Implemented: `benchmark/rescore.py`. Re-runs the hardened scorer against an existing TSV using a focused `issues.md` reconstruction (replays Write/Edit tool calls in timestamp order, ignoring chatter), and writes a new `<input>.rescored.tsv` with both `original_found` and the new verdict.

**Result for `d0451ef052/v2/build-sonnet-review-sonnet/curl`** (`benchmark/regression/results/d0451ef052/v2/build-sonnet-review-sonnet/curl/review-results.rescored.tsv`):

| Phase | Recall |
| ----- | ------ |
| Original scorer | `3/9 = 0.333` |
| Hardened rescore | `7 exact / 2 judge_error / 0 missed` — 7/7 scored = `1.000` |
| After `rejudge.py` resolves the 2 judge_error rows | `9/9 = 1.000` |

The 2 `judge_error` rows were Anthropic API usage-policy refusals (the prompt contained NTLM and SOCKS buffer-overflow descriptions that tripped server-side safety). The hardened scorer correctly surfaced both as `judge_error` instead of silently coercing them to `missed`. `rejudge.py` resolved both to `exact` based on transcript inspection, matching the manual audit from the prior debugging session.

Validation exceeds the exit criterion (`≥ 0.89`).

Along the way, two scorer bugs were fixed:
- `transcript_utils.extract_review_text_from_transcript(mode="issues_only")` replays Write/Edit calls in order to reconstruct just the file the review wrote. The prior "full" mode mixed chatter with content and buried findings past the judge's 8000-char truncation window.
- `score.py` REFUSAL_PATTERNS now match Anthropic's server-side `"API Error: Claude Code is unable to respond … violate our Usage Policy"` envelope, which arrives via stdout with rc=1.

### 0.3 Transcript-backed audit mode — `done`

Folded into `benchmark/audit.py` (the audit step already cross-references transcripts when `issues.md` is missing). The audit report flags any row where the recorded verdict disagrees with transcript evidence.

- Add `score.py --audit` that, for each CVE row, also inspects:
  - the canonical `edc-context/reports/issues.md` artifact (already supported)
  - the corresponding `~/.claude/projects/<encoded-path>/*.jsonl` transcript
- Flag rows where the judge says `missed` but the transcript wrote:
  - the CVE ID, OR
  - an affected file from ground truth, AND a related bug-pattern keyword
- This becomes the canonical "is the scorer lying" check, run after every benchmark batch.

### Phase 0 exit criterion

- [x] Scorer no longer silently turns judge failures into misses.
- [x] `judge_error` is a first-class verdict, surfaced and excluded from aggregates.
- [x] `rejudge.py` exists and works on a real failed batch.
- [x] Re-scored `d0451ef052/v2/build-sonnet-review-sonnet/curl` matches manual transcript audit: `9/9 = 1.000` vs the original `3/9 = 0.333`.

---

## Phase 1 — Fill the missing matrix cell: no-build baseline

**Status:** done (curl pilot, n=1)

**Why:** current artifacts have `v1` (per-CVE build + review) and `v2` (repo-wide build + review). There is **no** controlled "review with zero pre-built context" run on the same commit, same corpus, same scoring. Without that cell, the build-value question cannot be answered.

### 1.1 Define the matrix — `done` (pilot scope)

Per user direction: curl only, n=1, reuse existing builds where possible. Locked commit for new runs = `token_model_optimization` HEAD (`2cf4ca56eb`). Existing v2 cells are from different EDC commits (`9727d87e4f`, `d0451ef052`, `7788697171`) — cross-commit comparison is noisy but accepted as pilot constraint.

Matrix actually executed:

| Review model ↓ / Build ↓ | none (v0) | haiku-built (v2) | sonnet-built (v2) |
| ------------------------ | --------- | ---------------- | ----------------- |
| haiku review             | **new run** | reused `9727` (n=2 attempts, old scorer) | reused `7788` (rescored) |
| sonnet review            | **new run** | reused `d045` (rescored) | reused `d045` (rescored) |

### 1.2 Implement `v0` mode in the regression harness — `done`

`benchmark/regression/run-regression.sh` now accepts `--mode v0`. Behavior:

- `--mode` validation accepts `v0` alongside `v1`/`v2`/`v2-per-cve`.
- The drive loop's per-attempt build phase is replaced with a single `status=skipped` row in `build-metrics.tsv` (all metrics 0) so downstream aggregation sees a consistent shape.
- `review_one_cve` gets a dedicated v0 branch: creates an empty `edc-context/reports/` dir and uses a no-preamble prompt: `"No pre-built architectural context is available. Analyze the source files directly. …"`.
- Scoring already gated on `MODE == v2` for `--build-issues`, so v0 naturally produces single-phase rows.

Smoke-tested: `bash benchmark/regression/run-regression.sh --mode v0 --commit HEAD --repo curl` enters the review phase with the v0 prompt and correctly writes the `status=skipped` build row. Killed before any paid `claude -p` ran.

### 1.3 Run the matrix — `done` (pilot)

New runs:
- `v0/haiku/curl` @ 2cf4ca56eb, n=1, all 9 CVEs scored cleanly (no judge_error). recall = `0.667`.
- `v0/sonnet/curl` @ 2cf4ca56eb, n=1, all 9 CVEs scored, 2 judge_error resolved via rejudge. recall = `0.778`.

Rescores:
- `7788697171/v2/build-sonnet-review-haiku/curl`: 8/9 rescored (1 had no transcript). new recall = `0.556`.
- `d0451ef052/v2/build-haiku-review-sonnet/curl`: 9/9, 3 judge_error resolved. new recall = `1.000`.
- `d0451ef052/v2/build-sonnet-review-sonnet/curl`: 9/9, 2 judge_error resolved. new recall = `1.000`.

Observed issues:
- v0/sonnet review duration without context spikes hard: cve-23838545 ran 23min, cve-19-3822 ran 34min, cve-18-0500 needed `EDC_REG_REVIEW_TIMEOUT=3600` to finish (default 600s killed it mid-stream the first time).
- Harness watchdog kills the entire process group on timeout; if the outer wrapper is interrupted, claude orphans need manual cleanup.

### Phase 1 exit criterion

Pilot-scope criterion (per user direction): curl + redis matrices at n=1 with no-build baseline rows produced and scored under hardened scorer.

- [x] v0/haiku/curl n=1
- [x] v0/sonnet/curl n=1
- [x] v0/haiku/redis n=1
- [x] v0/sonnet/redis n=1
- [x] v2 curl cells rescored under hardened scorer
- [ ] v2 redis cells rescorable — NO (transcripts gone, scored under old scorer; recall numbers are floors only)
- [x] All judge_error rows resolved (rejudge.py)
- [x] Comparison reports written: `benchmark/build-value-report.md` (curl), `benchmark/build-value-report-redis.md` (redis)

Full-scope criterion (`n≥3` + clean v2/sonnet/redis at HEAD) deferred until decision warrants the spend.

---

## Phase 2 — Apples-to-apples comparison

**Status:** done (pilot, curl + redis)

Deliverables: `benchmark/build-value-report.md` (curl), `benchmark/build-value-report-redis.md` (redis). Each contains per-cell recall, costs, $/exact, and per-CVE flip tables.

Headline findings (n=1, cross-commit and old-scorer caveats apply):

| review model | repo  | v0 recall | best comparable v2 | v0 total $ | v2 total $ |
| ------------ | ----- | --------- | ------------------ | ---------- | ---------- |
| haiku        | curl  | 0.667     | 0.611 (rescored)   | 1.74       | 5.44       |
| haiku        | redis | 0.625     | 0.458 (old scorer) | 2.19       | 8.18       |
| sonnet       | curl  | 0.778     | 1.000 (rescored)   | 8.23       | 16.60      |
| sonnet       | redis | 0.833     | 0.250 (old scorer) | 17.08      | 11.74      |

Reads:
- **haiku review: build NOT worth it on either repo.** Two independent data points.
- **sonnet review on curl: build helps** (+0.222 recall at +$8.37/run).
- **sonnet review on redis: too contaminated to judge.** v2 cells all under old scorer with no transcripts to rescore; a fresh v2/sonnet/redis run at HEAD is needed.
- **2 CVE classes don't yield to v0:** curl scattered-helper bugs (CVE-2023-38545, CVE-2019-3822) miss entirely; redis multi-step bugs (CVE-2022-31144, CVE-2023-22458, CVE-2023-28856, CVE-2023-41053) get partial credit (sonnet finds the right file/CVE but describes a parallel bug). Different failure modes.
- Anthropic API usage-policy refusals are routine (~20% of judge calls + reviews); `rejudge.py` is a hard requirement.

### 2.1 Per-cell aggregates — `todo`

For each `(build, review, repo)` cell compute:

- mean recall (`exact=1`, `partial=0.5`, `missed=0`)
- mean review cost USD
- mean review duration s
- mean review total tokens
- mean build cost USD (`0` for `v0`)
- total cost per CVE USD
- cost per exact finding USD
- per-CVE verdict diff vs the `v0` baseline (which specific CVEs flipped, which direction)

### 2.2 Build-value report — `todo`

Write `benchmark/build-value-report.md` containing:

- one summary table per repo
- per-CVE flip table (`v0` → `built`) so the conclusion is not just a mean
- explicit answer to: "does build raise recall?", "does build lower total cost per exact finding?", "are wins concentrated in any CVE class / model / repo?"
- raw numbers cited with path to source TSV

### Phase 2 exit criterion

`build-value-report.md` exists, every claim has a TSV citation, and the answer to the three questions above is unambiguous.

---

## Phase 3 — Decision + action

**Status:** blocked on one more cell + variance bound

Pilot data (curl + redis, both at HEAD) is consistent for haiku review: build is not worth it. For sonnet review, curl says yes-build, redis cannot say (old-scorer v2 cells are unrescorable).

Before drawing the keep/conditional/drop conclusion:
- variance bound: rerun v0/haiku/curl and v0/sonnet/curl @ n=3 (cost ~$30) to confirm the haiku finding is not noise
- one new cell: v2/haiku-build/sonnet-review/redis @ HEAD, n=1 (~$25-30) to close the sonnet/redis question

If both confirm the pilot direction:
- **drop-build for haiku reviews** (clear win)
- **conditional-build for sonnet reviews** (curl yes, redis tbd — likely gated by codebase shape / scattered-helper bug class)

### 3.1 Apply the decision rules — `todo`

- **Keep mandatory** if: build raises mean recall by `≥ 0.15` OR reduces total cost per exact finding by `≥ 20%`.
- **Make conditional** if: lift exists only for one of {weak review model, large repo, multi-module diff}. Define the gating predicate.
- **Drop** if: `v0` matches or beats built within `5%` recall at lower-or-equal total cost.

### 3.2 Implement the decision — `todo`

If **drop** or **conditional**:

- Modify `plugins/edc/scripts/edc-review.sh` to skip `recover_context_if_needed` under the appropriate gate (env var or manifest policy).
- Update `edc-context/index.md` and `AGENTS.md` to reflect the new contract.
- Keep `edc build` working as-is for `edc audit` (separate workflow, separate value question).

If **keep mandatory**: document the measured lift in `edc-context/index.md` so it can be challenged later, and add a "build value last verified at commit `<sha>`" stamp.

### Phase 3 exit criterion

Decision is implemented in code/docs and matches what `build-value-report.md` says.

---

## Phase 4 — Regression-proof the answer

**Status:** blocked on Phase 3

- Lock the corpus + commit + models used in Phase 1 as a `build-value snapshot`.
- Add `benchmark/build-value/run.sh` that reproduces Phases 1+2 in one command (drives `run-regression.sh` for every matrix cell, then generates the report).
- Add to the hardening suite: any change to `plugins/edc/prompt-bundles/edc-build-impl/**` or `plugins/edc/skills/edc-review/**` must re-run this and not regress the decision criteria.

### Phase 4 exit criterion

One command reproduces the answer; the snapshot is referenced from `edc-context/modules/benchmarking.md`.

---

## Out of scope

- New ground truth or new repos (curl + redis are enough)
- Autoresearch / GEPA prompt evolution (orthogonal — tunes the review prompt, not the build/no-build question)
- Rewriting the harness from scratch
- Judge-model selection beyond "swap to a less-refusal-prone variant if Phase 0.2 cannot eliminate refusals"

---

## Open questions

- Which commit to lock for Phase 1? Tentative: HEAD of `token_model_optimization` once Phase 0 lands.
- Is `n=3` enough? `benchmark/redis/baseline-metrics-haiku-fast.json` shows per-run scores `0.8 / 0.8 / 0.6`; variance ~0.1 is on the edge. May need `n=5` on hard CVEs.
- Judge model choice: keep `sonnet` (current `EDC_JUDGE_MODEL` default) or try `opus`? If `opus` also refuses, the scorer fix is purely prompt + parsing, not model.
- Should `v0` review get a longer max-turns budget to compensate for no pre-built context? Risk: confounds the comparison. Default: same budget.

---

## Tracking

Update each phase's `Status:` field as work progresses. Do not start a downstream phase before the upstream phase's exit criterion is met. Plan changes go in this file, not in chat.
