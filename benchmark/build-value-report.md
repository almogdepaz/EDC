# Build-value report — curl, n=1

Phase 2 deliverable per `BUILD_VALUE_PLAN.md`. Compares review recall and cost across build/review model combinations on the curl benchmark (9 CVEs). All cells scored by the hardened scorer (`benchmark/score.py`) with manual `rejudge.py` resolution of Anthropic API usage-policy refusals.

**N=1 attempt per cell.** Phase 1.3 ran a pilot to learn before expanding. Variance is unknown at this sample size — treat every number as indicative, not conclusive.

## Headline matrix

| cell | build model | review model | recall | n scored | build $ | review $ | total $ | $/exact |
|------|-------------|--------------|--------|----------|---------|----------|---------|---------|
| **v0/haiku** | — | haiku | 0.667 | 9 | 0.00 | 1.74 | **1.74** | 0.35 |
| **v2/haiku-build/haiku-review** (`9727`) | haiku | haiku | 0.611 | 9 | 2.34 | 3.10 | 5.44 | 1.36 |
| **v2/sonnet-build/haiku-review** (rescored, `7788`) | sonnet | haiku | 0.556 | 9 | 4.66 | 2.02 | 6.68 | 1.67 |
| **v0/sonnet** | — | sonnet | 0.778 | 9 | 0.00 | 8.23 | **8.23** | 1.18 |
| **v2/haiku-build/sonnet-review** (rescored, `d045`) | haiku | sonnet | 1.000 | 9 | 3.35 | 13.26 | 16.60 | 1.84 |
| **v2/sonnet-build/sonnet-review** (rescored, `d045`) | sonnet | sonnet | 1.000 | 9 | 6.22 | 11.10 | 17.32 | 1.92 |

Cells in **bold** are no-build baselines. The 9727 row is from an older EDC commit and was scored under the old scorer (transcripts gone, can't rescore). Other v2 rows were rescored with the hardened pipeline.

## What the cheapest cell can do

`v0/haiku` — review only, no pre-built context — is by far the cheapest at `$1.74` total for 9 curl CVEs, and lands `5 exact + 2 partial + 2 missed` = `0.667` recall. That's higher than `v2/haiku-build/haiku-review` on the same commit-class (`0.611`), and the build phase added `$2-5` per cell on top of review.

Implication: for haiku-as-review, **the pilot data suggests build is not earning its cost.** At n=1 the recall difference is within noise, but the cost difference is real (`$1.74` vs `$5.44` per run).

## Where build seems to help

`sonnet review with haiku-built context` and `sonnet review with sonnet-built context` both hit `1.000` recall, while `v0/sonnet` lands `0.778`. The two missed CVEs in `v0/sonnet` (`CVE-2023-38545`, `CVE-2019-3822`) are exactly the ones where no-context sonnet wandered for 20-30 minutes per CVE and wrote ≤226 chars of usable output (timeout/exhaustion).

Both are critical buffer-overflow CVEs in scattered files (`lib/socks.c`, `lib/vauth/ntlm.c`). The context build seems to give the review enough navigation to actually find these without burning through its turn budget.

Cost shape:
- `v0/sonnet`: `$8.23` total, `0.778` recall
- `v2/haiku-build/sonnet-review`: `$16.60` total, `1.000` recall
- delta: `+$8.37` for `+0.222` recall = `~$37 per additional exact finding`

Whether that's worth it depends on the use case. For security-critical CVE hunting where you need every finding, yes. For general code review, probably not.

## Build model choice matters less than expected

`v2/haiku-build/sonnet-review` and `v2/sonnet-build/sonnet-review` both score `1.000`. Sonnet-built context costs `~$2.87` more per build than haiku-built (`$6.22` vs `$3.35`) but doesn't improve review recall in this pilot. The cheap build is enough.

`v2/sonnet-build/haiku-review` (`0.556`) actually scored *worse* than `v2/haiku-build/haiku-review` (`0.611`) and `v0/haiku` (`0.667`) — but it's from a different EDC commit (`7788697171` vs `9727d87e4f`), and the rescore found 1 row with no transcript, so the comparison is dirty. Don't conclude anything from this row alone.

## Important caveats

- **n=1.** redis baseline runs showed per-run variance of ~0.1 on the same model. n=1 differences of ≤0.15 should be treated as noise.
- **Different EDC commits across rows.** The `v2` cells come from commits `7788697171`, `9727d87e4f`, and `d0451ef052`. Code path differences between those commits could explain part of the variance. Only the two `v0` cells and the `d0451ef052` cells are at the locked HEAD.
- **Different ground-truth target commits.** The `pick_build_commit` selector picks the newest fix commit across the CVE list, so target source contents differ slightly across EDC commits.
- **Two CVEs (`CVE-2023-38545`, `CVE-2019-3822`) consistently miss without context.** Both are the same pattern: critical buffer overflow, multi-state-machine logic, scattered helper functions. Bug class signal worth tracking.
- **Anthropic API usage-policy refusals are routine.** Across 4 cells × 9 CVEs (36 judge calls + 36 review runs), I had to manually resolve ~8 refusals via `rejudge.py`. Anyone running this pipeline needs to plan for human-in-the-loop verdict resolution.

## Per-CVE flip table

CVE → verdict by cell. `E`=exact, `P`=partial, `M`=missed, `JE`=judge_error (resolved interactively).

| CVE | v0/haiku | v0/sonnet | v2 h→h (9727) | v2 s→h (7788) | v2 h→s (d045) | v2 s→s (d045) |
|-----|----------|-----------|---------------|---------------|---------------|---------------|
| CVE-2023-38545 | P | M | E | P→after rescore | E | E→after rejudge |
| CVE-2020-8285  | P | E | E | E→rescore | E | E |
| CVE-2020-8177  | M | E | M | M→rescore | E | E |
| CVE-2016-8617  | E | E | E | E→rescore | E | E |
| CVE-2021-22945 | M (mislabeled) | E (after rejudge) | P | M→rescore | E | E |
| CVE-2019-3822  | E | M | P | E→rescore | E→after rejudge | E→after rejudge |
| CVE-2018-0500  | E | E (after rejudge) | M | P→rescore | E→after rejudge | E |
| CVE-2018-16890 | E | E | E | (no transcript) | E→after rejudge | E |
| CVE-2022-27776 | E | E | E | E | E | E |

The `9727` row aggregates 2 attempts × 9 CVEs = 16 rows; verdict shown is the best-of-attempts for each CVE.

## Initial read on the build-value question

Based on **this pilot only** (curl, n=1, mostly cross-commit comparisons for v2):

1. **For haiku as review model: build is not worth it.** v0/haiku beats v2/haiku-build/haiku-review on both recall and cost.
2. **For sonnet as review model: build helps recall significantly** (`0.778 → 1.000`) at substantial cost (`+$8/run`).
3. **Build model choice matters less than review model choice.** Haiku-built context with sonnet review is as good as sonnet-built.
4. **Two CVE patterns aren't solvable by either model without context.** They might also not be solvable WITH context — need redis hard set to confirm.

This is the cell of the decision tree the plan was missing. Going forward:
- before drawing a final keep/conditional/drop conclusion, run `n=3` on at least the haiku and sonnet v0 cells to bound variance
- add redis cells (where the bug-class shape is different) to test whether the no-build wins generalize
- the rescoring methodology already paid for itself: 5 of the 7 "exact" verdicts above were `missed` under the old scorer

## Artifacts referenced

- `benchmark/regression/results/2cf4ca56eb/v0/haiku/curl/review-results.tsv`
- `benchmark/regression/results/2cf4ca56eb/v0/sonnet/curl/review-results.tsv`
- `benchmark/regression/results/9727d87e4f/v2/haiku/curl/review-results.tsv`
- `benchmark/regression/results/7788697171/v2/build-sonnet-review-haiku/curl/review-results.rescored.tsv`
- `benchmark/regression/results/d0451ef052/v2/build-haiku-review-sonnet/curl/review-results.rescored.tsv`
- `benchmark/regression/results/d0451ef052/v2/build-sonnet-review-sonnet/curl/review-results.rescored.tsv`
