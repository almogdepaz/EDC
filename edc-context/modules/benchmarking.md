# Module: benchmarking

**Path:** `benchmark/` (excluding `benchmark/curl/` and `benchmark/redis/` which are .edcignored)
**Purpose:** CVE-recall benchmark harness for EDC security analysis quality — runs, scores, and autonomously improves the `edc-review` skill against known vulnerabilities.

---

## Architecture Overview

The benchmark module has three layers:

1. **Single-shot runner** (`run.sh`) — baseline one-off evaluation of the full CVE set
2. **Autoresearch loop** (`autoresearch.sh`) — Karpathy-style autonomous prompt tuning loop
3. **GEPA optimizer** (`gepa/`) — reflection-based gradient-free prompt evolution (alternative to autoresearch)

All three layers share: `parse_gt.py` (ground-truth parser), `score.py` (two-phase CVE scorer), and the repo-configuration convention (`repo.conf` + `ground-truth.md` + optional `cve-lists.conf`).

---

## Repo Configuration Convention

Each target repo lives in a subdirectory under `benchmark/<repo-name>/`. Three files drive everything:

| File | Purpose |
|------|---------|
| `repo.conf` | `key=value` pairs; `repo_url` is required — the git remote to clone |
| `ground-truth.md` | Markdown file listing CVEs as `### CVE-XXXX-XXXXX` blocks with structured fields |
| `cve-lists.conf` (optional) | bash arrays `FAST_CVES=()` and `REGRESSION_CVES=()` splitting the CVE set |

### ground-truth.md format

Each block under `### CVE-XXXX-XXXXX` declares bold fields:

```
**fix_commit:** <sha>
**affected_file:** <comma-separated paths>
**category:** <heap-buffer-overflow | use-after-free | ...>
**severity:** <critical | high | medium | low>
**bug_pattern:** <short human-readable description>
**description:** <longer description used by LLM judge>
```

`parse_gt.py` parses these blocks via regex and emits pipe-delimited rows: `cve|fix_commit|affected_files|category|severity|bug_pattern|description`.

If `cve-lists.conf` is absent, autoresearch auto-splits the full CVE list (first half = fast, second half = regression).

---

## Benchmark Loop (run.sh)

`run.sh` is the simple entry point:

1. Discovers repos by scanning for `benchmark/<name>/ground-truth.md` + `repo.conf`
2. For each CVE: clones (or reuses) the target repo, checks out `fix_commit~1` (the vulnerable version), builds a prompt asking `claude -p` to run `edc-module-context-impl` on the affected files and write findings to `.context/issues.md`
3. Calls `score.py` on the resulting `issues.md` to compute verdict and append to `results.tsv`

**Output:** `benchmark/results.tsv` — TSV with columns: `timestamp`, `cve`, `category`, `severity`, `verdict`, `confidence`, `duration`, `notes`.

Key env vars:
- `EDC_BENCH_WORKDIR` — working directory for clones (default `/private/tmp/edc-bench`)
- `EDC_BENCH_MODEL` — model passed to `claude --model` (default: unset = claude default)

---

## Scoring Methodology (score.py)

Two-phase scoring pipeline:

### Phase 1 — Keyword pre-filter

Computes a score 0–1 from:
- File mention: +0.15 if any affected filename appears in `issues.md`
- Category keywords: up to +0.25 based on fraction of category-specific keywords matched (per `CATEGORY_KEYWORDS` dict covering heap-buffer-overflow, use-after-free, credential-leak, protocol-injection, etc.)
- Bug-pattern keywords: up to +0.35 based on fraction of extracted bug-pattern words matched (stop-words removed)

If keyword score < `KEYWORD_THRESHOLD` (0.30) → immediate `missed` verdict without invoking LLM.

### Phase 2 — LLM-as-judge

For candidates passing the keyword threshold, calls `claude -p` with a structured prompt presenting the known CVE (category, affected files, bug pattern, description) and the `issues.md` content. The judge returns a JSON verdict:

```json
{"verdict": "exact"|"partial"|"missed", "confidence": 0.0-1.0, "explanation": "..."}
```

- `exact` = same root cause found, even in different words
- `partial` = related issue in the same area, not the specific root cause
- `missed` = not found

If the judge fails, falls back to keyword-only verdict (`exact` if kw_score ≥ 0.4, else `missed`).

**Score weighting** (used by autoresearch): `exact=1.0`, `partial=0.5`, `missed/error=0.0`.

**Judge model:** controlled by `EDC_JUDGE_MODEL` env var (default: `sonnet`).

---

## Autoresearch Pipeline (autoresearch.sh)

Autonomous loop that evolves the security review skill files to maximize CVE recall.

### Skill files under mutation

```
plugins/edc/skills/edc-review/SKILL.md
plugins/edc/skills/edc-review/methodology.md
plugins/edc/skills/edc-review/patterns.md
plugins/edc/skills/edc-review/adversarial.md
```

### Loop structure

```
startup:
  discover_repos → load_cve_lists → cache_cve_sources → build_context_for_cve (one-time)
  compute or load: baseline (fast CVEs) + regression_floor (regression CVEs)

each iteration:
  1. apply_change() — LLM agent edits skill files; emits HEURISTIC: <description>
  2. compute SHA256 of skill file contents → skip if already tried (tried-hashes.tsv dedup)
  3. git commit the change (flat commit on current branch)
  4. run_benchmark("iter-N-fast", FAST_CVES) in parallel
  5. if fast_score > baseline:
       run_benchmark("iter-N-regression", REGRESSION_CVES)
       if reg_score >= regression_floor: KEEP → update baseline
       else: discard → git checkout HEAD~1 + soft reset
     else: discard
  6. log hash + score + delta + heuristic to tried-hashes.tsv and autoresearch-log.tsv
```

### Source caching

Before the loop, autoresearch clones each target repo once to `$WORK_DIR/repos/<repo>/`, then for every CVE:
- Checks out `fix_commit~1` in a temporary worktree
- Copies the affected source files to `$WORK_DIR/cve-cache/<repo>/<CVE>/`
- Builds architectural context via `edc-module-context-impl` skill (output to `.context/full-context.md`)

This pre-built context is injected into each review run, so the reviewer reads architecture docs before hunting bugs.

### Parallel benchmark execution

`run_benchmark` spawns one background `run_cve` process per CVE, each with its own temp `EDC_RESULTS_FILE` and `EDC_METRICS_FILE`. Results are merged after all pids complete. Each `claude -p` invocation has a 600s watchdog (SIGTERM → 5s → SIGKILL).

### State files (scope-aware)

With a single active repo, state files live under `benchmark/<repo>/`; with multiple repos they live under `benchmark/`:

| File | Contents |
|------|---------|
| `baseline-score.txt` | current fast-CVE baseline score (float) |
| `regression-floor.txt` | minimum acceptable regression score |
| `tried-hashes.tsv` | SHA256 → score + delta + heuristic for all attempted skill states |
| `autoresearch-log.tsv` | per-iteration timestamped record |
| `autoresearch-output.log` | verbose log of current/last run |

### Stop/control

- `--stop` → touches `.autoresearch.stop` sentinel, sends SIGTERM to running PID
- `--status` → prints state summary (running/stopped, CVE counts, baseline, recent history)
- `--baseline` → forces baseline recomputation
- `-n N` → limit to N iterations
- `SHOULD_STOP` trap on SIGTERM/SIGINT for graceful shutdown

---

## Regression Harness (regression/)

`regression/run-regression.sh` is a separate, more rigorous harness comparing EDC plugin versions across commits. It supports three modes:

| Mode | Build phase | Review phase |
|------|-------------|--------------|
| `v1` | none (per-CVE inline) | edc-context per CVE, then edc-review |
| `v2` | one edc-build for whole repo, shared context | edc-review reads shared `.context/` |
| `v2-per-cve` | edc-context per CVE (module-scoped) | edc-review reads per-CVE module doc |

Workflow: takes `--commit <sha> --repo <name> --attempts N`, creates a git worktree of the EDC plugin at that exact commit, clones the target repo, runs `N` build+review attempts, scores each CVE, writes build-metrics, review-metrics, and review-results TSVs to `benchmark/regression/results/<sha>/<mode>/<model>/<repo>/`.

`regression/compare.py` compares pre vs post regression runs: checks recall non-regression, build/review cost within headroom (default 1.10×), and module coverage.

---

## GEPA Optimizer (gepa/)

Alternative to autoresearch: uses the GEPA (Gradient-free Evolution with Prompt Adaptation) library for reflective optimization.

### Components

| File | Role |
|------|------|
| `run.py` | Driver: configures GEPA, splits CVEs into trainset/valset, calls `gepa.optimize()` |
| `adapter.py` | `GEPAAdapter` subclass — bridges GEPA to the EDC benchmark harness via `bench.sh` |
| `bench.sh` | Single-shot benchmark wrapper that sources `autoresearch.sh` helpers |
| `reflect.py` | `ClaudeCliReflectionLM` — wraps `claude -p` as GEPA's reflection LM |
| `template.py` | Splits `SKILL.md` into frozen/mutable segments; reassembles after mutation |

### What GEPA evolves

Four components in `edc-review`:
- `methodology_part1`: `SKILL.md` "Core Principles" through "Quality Checklist"
- `methodology_part2`: `SKILL.md` "Example Usage" through "Supporting Documentation"
- `methodology_md`: all of `methodology.md`
- `patterns_md`: all of `patterns.md`

Frozen: SKILL.md frontmatter, invocation modes, Integration block, footer; `adversarial.md`, `reporting.md`.

### Candidate evaluation

Each candidate writes the mutated skill files, calls `bench.sh` to run `autoresearch.sh`'s `run_benchmark` helper (which spawns parallel `claude -p` review processes), scores results, and restores original files. Early-abort: if first `probe_n` (default 2) CVEs score below `threshold * baseline_sum`, scores remaining CVEs as missed to save cost.

### Reflection anti-overfit guard

`make_reflective_dataset` deliberately redacts: CVE id, category, affected files, judge explanation, ground-truth bug pattern. Reflection LM only sees the model's output (issues.md) + binary verdict + cost/tokens. This prevents the reflection LM from encoding per-CVE answers into the methodology.

---

## compute_baseline.py

Aggregates metrics across N autoresearch/benchmark runs:
- Input: `run_label:results.tsv:metrics.tsv` tuples
- Computes per-run score (exact=1.0, partial=0.5, missed=0) and cross-run statistics: mean, std, p50, p95 for score, duration, token counts, cache hit/create, cost, turns
- Output: JSON to `--out` file

---

## Results Files

The `benchmark/` root contains historical TSV snapshots from past autoresearch runs:

| File | Description |
|------|-------------|
| `results.tsv` | Latest single-shot run results |
| `results-baseline.tsv` | Initial baseline (all fast CVEs) |
| `results-baseline-regression.tsv` | Initial regression floor measurement |
| `results-iter-N-fast.tsv` | Fast benchmark for iteration N |
| `results-iter-N-regression.tsv` | Regression benchmark for iteration N (only when fast improved) |
| `results-iter-N-full.tsv` | Full CVE set for iteration N |
| `baseline-score.txt` | Current baseline scalar (`1.000` as of latest keep) |
| `regression-floor.txt` | Current regression floor scalar (`0.833`) |
| `tried-hashes.tsv` | All attempted skill hashes with score/delta/heuristic |
| `autoresearch-log.tsv` | Human-readable per-iteration experiment log |

---

## Key Design Decisions

**Two-phase scoring** avoids calling the expensive LLM judge on clear misses (keyword score < 0.3), reducing cost by skipping ~40–60% of evaluations in practice.

**Hash-based deduplication** ensures the autoresearch loop never retests an identical skill state, even across restarts. The SHA256 covers all four skill files concatenated.

**Regression gate** prevents score improvements on fast CVEs from shipping if they regress the held-out regression CVEs below the floor. Current floor: 0.833.

**Parallel CVE evaluation** (all CVEs in a benchmark run execute simultaneously) is safe because each CVE gets its own `WORK_DIR` subdirectory and results temp file.

**Source caching + pre-built context** separates the expensive context-building step (run once, cached) from the iterative review step (run every iteration), dramatically reducing per-iteration cost.
