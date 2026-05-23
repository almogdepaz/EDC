# Benchmark forward plan — Codex, detection, token efficiency

## Goal

Improve EDC review detection quality and token efficiency on real PR/code-review workloads, using Codex as the main reviewer. The previous Haiku/Sonnet CVE matrix is useful background, but it is not the main target anymore.

Target question:

> does EDC context improve accepted findings per token/cost on real PRs, especially larger protocol/system PRs?

Secondary question:

> when context helps, can we make it cheaper by changing what the reviewer reads?

## Current position

We have:

- hardened CVE scorer (`judge_error`, transcript-backed rescoring, interactive rejudge)
- `--no-context-refresh` review mode: skip build/update/recovery, but use existing context if available
- `--ignore-context` review mode: pure baseline, force no EDC context usage
- Cursor PR benchmark wrapper
- spawn logging / token/cost telemetry
- partial evidence: build helps recall on curl+sonnet, but not cost
- no decision-grade Codex data yet

So next work should be:

1. measure Codex on real PRs
2. optimize context usage based on telemetry
3. keep CVE benchmark as regression guard, not primary objective

---

## Phase 1 — establish Codex baseline

Run the same review comparison with Codex.

### Modes

1. `ignore-context`
   - no build/update
   - no EDC docs
   - pure baseline

2. `no-context-refresh`
   - do not build/update
   - use existing context if present
   - measures review-only benefit/cost of already-built context

3. normal `context`
   - auto build/update if stale/missing
   - real current user behavior

4. optional `force-build-context`
   - include first-build cost explicitly

### Needed runner change

Generalize the current Cursor-only runner into a backend-agnostic runner:

```bash
benchmark/pr-review/run-pr-benchmark.sh \
  --agent codex \
  --repo ~/Dev/chia-blockchain \
  --target HEAD \
  --base main
```

Supported agents:

```text
codex | cursor | claude
```

Keep the Cursor script as a wrapper or deprecate it later.

### Metrics to collect

Primary:

- accepted findings per 100k tokens
- severity-weighted score per 100k tokens
- false-positive rate

Secondary:

- total cost, if backend reports cost
- wall time
- input tokens
- output tokens
- cache read/write tokens
- number of spawned review processes
- file reads / searches, if transcripts expose tool calls

---

## Phase 2 — use real PR benchmark suite

User-provided target: Chia network protocol PRs.

Create a small suite file:

```text
benchmark/pr-review/suites/chia-network-protocol.tsv
```

Suggested columns:

```tsv
name	repo	target	base	notes
protocol-pr-1	~/Dev/chia-blockchain	HEAD	main	...
protocol-pr-2	~/Dev/chia-blockchain	<branch>	main	...
```

For each PR, run:

- `ignore-context`
- `no-context-refresh`
- `context`

Then manually adjudicate findings.

Minimum useful pilot:

- 3 PRs
- same repo
- same agent/model
- same base rules

`n=1` per PR is acceptable initially because PR diversity matters more than stochastic repeats.

Output layout:

```text
benchmark/pr-review/results/<suite>/<run-id>/
```

---

## Phase 3 — define real PR scoring

Do not use CVE recall for real PRs. Real PRs need manual adjudication.

### Manual finding statuses

```text
accepted
false-positive
duplicate
unclear
```

### Severity weights

```text
critical = 8
high     = 5
medium   = 3
low      = 1
```

Suggested score:

```text
severity_weighted_score = sum(accepted severity weights) - false_positive_count
```

Duplicates and unclear findings score 0.

### Efficiency metrics

```text
quality_per_100k_tokens = 100000 * severity_weighted_score / total_tokens
accepted_per_100k_tokens = 100000 * accepted_findings / total_tokens
false_positive_rate = false_positives / total_findings
```

Primary ranking metric:

```text
quality_per_100k_tokens
```

Secondary guardrail:

```text
false_positive_rate
```

Do not reward noisy output. If context increases raw findings but doubles false positives, it loses.

---

## Phase 4 — optimize context usage

Likely token inefficiency sources:

- context index too large
- module docs too verbose
- review task always says read index + issues + module doc
- reviewer reads docs, then still searches same files anyway
- stale context warnings / boilerplate consume tokens
- module docs are prose-heavy, not retrieval-shaped

Optimization ideas to test after Codex baseline exists:

### 1. Context budget modes

Add review flags:

```bash
--context-budget minimal|standard|deep
```

Modes:

#### `minimal`

- manifest/routing only
- small module summary only
- no full index unless needed

#### `standard`

- current behavior, but tightened

#### `deep`

- current + known issues + invariants

For Codex token efficiency, `minimal` may win.

### 2. Structured module docs

Current module docs are probably too prose-heavy. Shape them like:

```md
## purpose
## files
## invariants
## trust boundaries
## review traps
## call graph
## known risky areas
```

Then review instructions can say:

> read only purpose, invariants, review traps, and changed-file sections first.

Avoid brittle parsing of prose where possible. Prefer structured sidecars if we need deterministic extraction.

### 3. Review-specific context artifact

Build a smaller review-focused artifact:

```text
edc-context/review-index.json
```

Possible fields:

```json
{
  "modules": [
    {
      "name": "...",
      "prefixes": ["..."],
      "topInvariants": ["..."],
      "riskTags": ["..."],
      "knownIssueRefs": ["..."],
      "readFirst": ["..."]
    }
  ]
}
```

Review prompt uses this small artifact instead of full docs by default.

This is probably the biggest token-efficiency win.

### 4. Avoid reading repo index when routing already knows module

Current task effectively says:

1. read index
2. read issues
3. read module doc

But the orchestrator already routed files. More efficient default:

- read module doc first
- read index only if module doc says cross-module dependency, target has unmapped files, or reviewer is confused
- read issues only if changed files match known issue paths

This reduces fixed context tax.

### 5. Log actual reads/searches

Need to know where tokens go.

For Claude, transcripts expose tool calls. For Codex/Cursor, confirm stream captures tool calls. If not, require each report to include:

```md
## Evidence Read
- files read:
- context docs read:
- searches run:
```

This is not perfect, but useful.

---

## Phase 5 — keep CVE benchmark as regression guard

The CVE benchmark is still useful, but not as the main optimization target.

Use it to ensure PR-review optimizations do not destroy security detection.

Candidate guard set:

### curl hard CVEs

- `CVE-2023-38545`
- `CVE-2019-3822`

### redis hard CVEs

- `CVE-2022-31144`
- `CVE-2023-22458`
- `CVE-2023-28856`
- `CVE-2023-41053`

Track:

- recall
- total tokens
- judge errors
- wall time

Do not over-optimize for CVE recall at the expense of real PR review efficiency.

---

## Concrete next implementation steps

### Step 1 — generic PR benchmark runner

Add:

```text
benchmark/pr-review/run-pr-benchmark.sh
```

Supports:

```bash
--agent codex|cursor|claude
--mode both|ignore-context|no-refresh|context
--force-build-context
--repo <path>
--target <target>
--base <ref>
```

Expected behavior:

- sets `EDC_AGENT_CLI=<agent>`
- runs selected cells
- preserves transcripts
- writes `summary.tsv`
- copies final `review-*.md` artifacts
- writes `manual-findings.tsv` template

### Step 2 — suite runner

Add:

```text
benchmark/pr-review/run-suite.sh
benchmark/pr-review/suites/example.tsv
```

Runs multiple PRs and writes aggregate summary.

### Step 3 — adjudication aggregator

Add:

```text
benchmark/pr-review/summarize-findings.py
```

Reads:

- `summary.tsv`
- `manual-findings.tsv`

Outputs:

- accepted findings
- false positives
- duplicates
- unclear
- severity-weighted score
- quality per 100k tokens
- accepted findings per 100k tokens
- false-positive rate

### Step 4 — Chia pilot

For each selected Chia network protocol PR:

```bash
benchmark/pr-review/run-pr-benchmark.sh \
  --agent codex \
  --repo ~/Dev/chia-blockchain \
  --target <branch-or-pr> \
  --base main \
  --mode both
```

Then fill `manual-findings.tsv`.

### Step 5 — inspect telemetry

Questions to answer:

- does context reduce file reads/searches?
- does context increase input tokens?
- does context increase accepted findings?
- are extra findings real or noisy?
- does no-refresh perform same as full context review?
- does context help specifically on cross-module protocol invariants?

---

## Decision thresholds

Keep / default to context only if, on the Chia PR suite:

```text
context quality_per_100k_tokens >= ignore-context by 20%
```

and:

```text
false_positive_rate does not increase by >10 percentage points
```

and either:

```text
accepted high/critical findings increase
```

or:

```text
wall time decreases materially
```

Otherwise:

- default to `--no-context-refresh` or `--ignore-context`
- make build opt-in or triggered only for large/risky PRs

---

## Likely product direction

Hypothesis:

```text
default review:
  --no-context-refresh
  use context if present
  do not auto-build/update

large/risky review:
  auto-update if context exists and stale
  build only on explicit user request or repo-size threshold

benchmark/security mode:
  force context
```

Rationale:

- build is expensive
- surprise background build/update annoys users
- context may help quality but must prove token efficiency
- no-refresh gives upside from existing context without surprise spend

---

## Immediate recommended task

Implement generic Codex-capable PR benchmark runner + summarizer.

Then run 2–3 Chia network protocol PRs with:

```bash
--agent codex --mode both
```

After manual adjudication, decide from real data rather than vibes.
