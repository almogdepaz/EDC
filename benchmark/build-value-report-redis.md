# Build-value report — redis, n=1

Phase 1 follow-up per `BUILD_VALUE_PLAN.md`: extend the curl pilot to redis. Same harness, same scorer, same pilot constraints (n=1, mixed-commit caveats).

**Important:** all existing v2 redis cells were scored under the OLD scorer (before hardened `score.py`) AND their transcripts are no longer on disk. They cannot be rescored. Their recall numbers are floors only.

## Headline matrix

| cell | build model | review model | recall | n scored | build $ | review $ | total $ | $/exact |
|------|-------------|--------------|--------|----------|---------|----------|---------|---------|
| **v0/haiku** | — | haiku | **0.625** | 12 | 0.00 | 2.19 | **2.19** | 0.31 |
| v2/haiku-build/haiku-review (`9727`, old scorer) | haiku | haiku | 0.458 | 12 | 3.97 | 4.21 | 8.18 | 1.64 |
| v2/haiku-build/haiku-review (`df82`, old scorer) | haiku | haiku | 0.125 | 12 | 0.07 | 2.50 | 2.57 | 2.57 |
| **v0/sonnet** | — | sonnet | **0.833** | 12 | 0.00 | 17.08 | **17.08** | 2.14 |
| v2/haiku-build/sonnet-review (`9727`, old scorer) | haiku | sonnet | 0.250 | 12 | 7.40 | 4.34 | 11.74 | 3.91 |

Cells in **bold** are the new n=1 v0 baselines at locked HEAD (`ba4ad4cbd7`). Other cells are reference data with severe scorer/commit caveats.

## What this confirms about curl-pilot findings

1. **v0 beats v2 for haiku review.** On redis: v0/haiku = `0.625` vs the best v2/haiku = `0.458` (which is itself probably undercounted). Cost: `$2.19` vs `$8.18`. Consistent with curl pilot.
2. **Build helps less than expected even for sonnet review on redis.** v0/sonnet = `0.833` while v2/haiku-build/sonnet-review (`9727`) only scored `0.250` — but again, old scorer. Even granting a generous 2x undercount, v0 sonnet still wins.
3. **Anthropic API refusals are heavier on redis content.** ~17% of judge calls + ~25% of review runs hit policy refusals (vs ~22% combined on curl). `rejudge.py` resolved all of them as exact.

## What's different on redis vs curl

- **Sonnet without context actually performs.** On curl, v0/sonnet missed 2/9 CVEs (the multi-state-machine ones). On redis, v0/sonnet hit `0.833` recall with no misses — just 4 partials where sonnet correctly identified the file/CVE but described a parallel bug in the same function. That's not a context problem; that's an analysis-depth problem.
- **The 4 partials all happen on harder CVEs.** `CVE-2022-31144` (XAUTOCLAIM count off-by-one vs zmalloc), `CVE-2023-22458` (zsetLength narrowing vs ZRANDMEMBER count), `CVE-2023-28856` (HINCRBYFLOAT NaN vs listpack lpSafeToAdd), `CVE-2023-41053` (sortROGetKeys numkeys vs BY/GET enumeration). All four match the pattern from `benchmark/BLOGPOST.md`: multiple plausible bugs in the same area, model picked a different one.

## Per-CVE flip table (redis, scored at HEAD `ba4ad4cbd7`)

| CVE | v0/haiku | v0/sonnet |
|-----|----------|-----------|
| CVE-2021-29477 | E | E |
| CVE-2021-32626 | M (timed out) | E |
| CVE-2022-31144 | E→after rejudge (API refusal) | P |
| CVE-2024-31449 | M (judge correctly rejected) | E→after rejudge |
| CVE-2024-31228 | E | E |
| CVE-2021-29478 | E | E |
| CVE-2022-35951 | E | E→after rejudge |
| CVE-2023-22458 | M (keyword-filter, no signal) | P |
| CVE-2023-28856 | E | P |
| CVE-2023-41053 | M (keyword-filter) | P |
| CVE-2023-45145 | P | E |
| CVE-2024-31227 | E | E |

The 4 sonnet partials are CVEs where haiku either got `exact` (28856) or completely missed (22458, 41053). Mixed outcomes don't suggest a simple "sonnet is better" story.

## Cross-pilot summary (curl + redis combined)

| review model | repo | v0 recall | best v2 recall (rescored) | v0 total $ | v2 total $ |
|--------------|------|-----------|---------------------------|-----------|-----------|
| haiku | curl | 0.667 | 0.611 (9727, old scorer) | 1.74 | 5.44 |
| haiku | redis | 0.625 | 0.458 (9727, old scorer) | 2.19 | 8.18 |
| sonnet | curl | 0.778 | 1.000 (d045, rescored) | 8.23 | 16.60 |
| sonnet | redis | 0.833 | 0.250 (9727, old scorer; suspect) | 17.08 | 11.74 |

The one cell where v2 clearly beats v0 is `curl + sonnet review`. The redis comparison for sonnet is contaminated by old-scorer issues — needs a fresh v2 run at HEAD to resolve.

## Operational findings (redis specific)

- v0/sonnet/redis took 92 minutes for 12 CVEs. cve-2023-41053 ran 13 min, cve-2023-28856 ran 11 min. all completed without orphan-claude issues this time.
- Total v0/sonnet/redis cost: $17.08 (vs my $25 estimate — sonnet was cheaper than expected, presumably because redis CVEs are more file-local than curl's scattered NTLM/SOCKS).
- Judge model (opus) cost on top: ~$0.10-0.20 per call × 12 = ~$2 added per cell.

## Initial read (curl + redis combined)

Strengthens the curl-pilot conclusion in 3 of 4 cells:

1. **haiku review: build is NOT worth it on either repo.** v0/haiku consistently beats v2/haiku at one-third the cost. Two independent data points.
2. **sonnet review on curl: build DOES help** (`0.778 → 1.000`). One data point.
3. **sonnet review on redis: too contaminated to judge.** Need a fresh v2/sonnet redis run at HEAD before drawing a conclusion. Until then, the `0.833 v0` vs `0.250 v2 (old scorer)` gap is unscoreable.

The 2 CVEs that consistently miss in curl (`CVE-2023-38545`, `CVE-2019-3822`) don't have direct redis analogues — the redis multi-step CVEs (`28856`, `41053`, `22458`) ARE found by sonnet, just at partial confidence. That's a different failure mode than curl: not a "needs context to find" gap, but a "needs more analysis depth to identify the right one of multiple candidates" gap.

## Recommended next step (NOT executing without your go-ahead)

To close the redis question cleanly, run **one** new cell: `v2/haiku-build/sonnet-review/redis` at HEAD, n=1. Estimated cost: ~$8-12 build + ~$15-20 review = ~$25-30. That tells us whether build helps sonnet review on redis or not.

If yes (and similar lift to curl): conditional-build for sonnet is the answer.
If no: drop-build is the answer for everything except curl-style scattered-helper bugs.

## Artifacts referenced

- `benchmark/regression/results/ba4ad4cbd7/v0/haiku/redis/review-results.tsv`
- `benchmark/regression/results/ba4ad4cbd7/v0/sonnet/redis/review-results.tsv`
- `benchmark/regression/results/9727d87e4f/v2/{haiku,sonnet}/redis/review-results.tsv` (old scorer, unrescorable)
- `benchmark/regression/results/df829314b3/v2/haiku/redis/review-results.tsv` (old scorer, unrescorable)
