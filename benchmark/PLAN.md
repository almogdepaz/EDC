# Autoresearch Benchmark — Implementation Plan

## Architecture

```
ONE-TIME SETUP:
  1. clone repo (shared, cached)
  2. for each CVE:
     a. checkout fix_commit~1, copy affected files to cache
     b. run edc:edc-context → .context/full-context.md (FROZEN, never rebuilt)

EACH ITERATION:
  1. agent edits edc-review skill files
  2. hash skill files → skip if already tried
  3. commit the change
  4. for each CVE:
     a. copy cached source + pre-built context to working dir
     b. run edc:edc-review (full-file mode, NOT diff mode)
     c. → .context/issues.md
  5. score issues.md against ground truth
  6. if improved → keep commit, update baseline
     else → discard commit, restore skill files
```

### Why two skills, not one

- **edc-context** = architectural map. data flows, state machines, invariants, cross-module coupling. explicitly says "do NOT identify vulnerabilities." built once per CVE, frozen.
- **edc-review** = vulnerability finder. uses pre-built context to find bugs. has methodology.md (how to analyze), patterns.md (what to look for), adversarial.md (attacker modeling). THIS is what the agent iterates on.

The current benchmark calls edc-context and asks it to find vulns — contradicting the skill's own instructions ("do NOT identify vulnerabilities"). That's why baseline = 0.000.

### Review mode: full-file, not diff

edc-review is designed for diffs/PRs. The benchmark uses it differently:
- prompt says: "here's the context, here's the source, find all security vulnerabilities"
- no diff, no baseline commit, no blast radius
- the skill's methodology/patterns/adversarial content still applies — it teaches what to look for
- the agent will naturally evolve skill files toward what works for full-file review

### Files the agent tunes

```
plugins/edc/skills/edc-review/
  SKILL.md         — main skill definition
  methodology.md   — phase-by-phase review workflow
  patterns.md      — common issue patterns to detect
  adversarial.md   — attacker modeling methodology
```

Frozen (not tuned):
- `plugins/edc/skills/edc-context/SKILL.md`
- `plugins/edc/skills/edc-review/reporting.md`

---

## Directory structure

```
benchmark/
  autoresearch.sh       — main script (setup + loop)
  score.py              — two-phase scorer (keyword + LLM judge)
  parse_gt.py           — ground truth parser (pipe-delimited output)
  .gitignore            — exclude cache/, logs, temp files
  curl/
    ground-truth.md     — 11 CVE entries (KEEP AS-IS)
    repo.conf           — repo_url=https://github.com/curl/curl.git
  cache/                — auto-generated, gitignored
    curl/
      repo/             — shared git clone
      CVE-xxx/
        *.c, *.h        — cached source files at fix_commit~1
        .context/
          full-context.md — pre-built context (frozen)
```

---

## Scoring

- **metric:** recall (did it find the CVE?)
- **classification:** exact / partial / missed (per CVE)
- **scorer:** two-phase — keyword pre-filter then sonnet LLM judge
- **score formula:** `(exact*1.0 + partial*0.5) / total`
- **cost tracking:** log API calls per iteration

---

## File-by-file implementation spec

### 1. `benchmark/autoresearch.sh` — COMPLETE REWRITE

#### Constants

```bash
SKILL_FILES=(
    "plugins/edc/skills/edc-review/SKILL.md"
    "plugins/edc/skills/edc-review/methodology.md"
    "plugins/edc/skills/edc-review/patterns.md"
    "plugins/edc/skills/edc-review/adversarial.md"
)

FAST_CVES=(
    "CVE-2023-38545"   # heap-buffer-overflow / state machine
    "CVE-2020-8285"    # stack-overflow / recursion
    "CVE-2019-3822"    # stack-buffer-overflow / integer underflow
    "CVE-2021-22945"   # use-after-free / double-free
    "CVE-2018-0500"    # heap-overflow / wrong malloc size
)

ALL_CVES=( all 11 from ground-truth.md )

MODEL="sonnet"
CONTEXT_MODEL="sonnet"       # for building context (one-time)
REVIEW_MODEL="sonnet"        # for running reviews (each iteration)
JUDGE_MODEL="sonnet"         # for LLM scoring
```

#### Functions

**`ensure_repo(repo_name)`**
- reads `benchmark/{repo}/repo.conf` for `repo_url`
- clones to `cache/{repo}/repo/` if not exists
- validates with `git rev-parse HEAD`

**`cache_sources(repo_name)`**
- for each CVE in ground-truth.md:
  - skip if `cache/{repo}/{cve_id}/` already has source files
  - create git worktree at `fix_commit~1`
  - copy affected_file(s) to `cache/{repo}/{cve_id}/`
  - remove worktree
- uses shared worktree across CVEs (checkout between them) to avoid repeated worktree creation

**`build_context(repo_name)`**
- for each CVE:
  - skip if `cache/{repo}/{cve_id}/.context/full-context.md` already exists and is non-empty
  - copy cached source to temp working dir
  - run claude with edc:edc-context skill:
    ```
    prompt: "Run the edc:edc-context skill on these files: {file_list}
    Write the complete analysis to .context/full-context.md"
    ```
  - tools: `Read Glob Grep Write Skill`
  - model: `$CONTEXT_MODEL`
  - max-turns: 30 (context building is thorough)
  - watchdog: 15min (context building is slow)
  - copy `.context/full-context.md` back to cache
  - CRITICAL: no vulnerability finding in this step. edc-context does pure context building.

**`run_cve(cve_id)`**
- copy cached source + `.context/full-context.md` to working dir
- build prompt:
  ```
  You have pre-built architectural context in .context/full-context.md
  Read it first, then perform a full security review of these source files: {file_list}

  Use the edc:edc-review skill methodology. This is a FULL-FILE review, not a diff review.
  Ignore any diff/PR-specific instructions — analyze the entire file for vulnerabilities.

  Write .context/issues.md listing ALL security issues found, with:
  - issue title
  - severity (critical/high/medium/low)
  - category (buffer overflow, use-after-free, logic error, etc.)
  - affected file:line
  - description of the bug
  - evidence (the specific code pattern)
  ```
- run claude:
  - tools: `Read Glob Grep Write Skill`
  - model: `$REVIEW_MODEL`
  - max-turns: 20
  - watchdog: 5min (context is pre-built, review should be faster)
- fallback: if no issues.md, copy claude-output.txt to issues.md
- call score.py on issues.md

**`run_benchmark(label, cve_list[])`**
- create results TSV with header
- launch all CVEs in parallel (background processes)
- each CVE writes to a temp file via `EDC_RESULTS_FILE`
- wait for all, merge results into `results-{label}.tsv`
- compute score, write to `.score-{label}.tmp`

**`calc_score(results_file)`**
- python one-liner: `(exact + partial*0.5) / total`

**`compute_hash()`**
- concatenate all SKILL_FILES contents, sha256sum

**`hash_tried(hash)`**
- check if hash exists in tried-hashes.tsv

**`log_hash(hash, score, delta, heuristic)`**
- append to tried-hashes.tsv

**`apply_change(iteration)`**
- build prompt with:
  - current baseline score
  - last 15 experiment results (score, delta, heuristic)
  - last CVE breakdown (which CVEs hit/missed — from most recent results-*.tsv)
  - list of already-tried hashes
- prompt tells agent to:
  - read the edc-review skill files
  - make ONE focused change to improve vulnerability detection
  - output `HEURISTIC: <description>`
- agent tools: `Read(plugins/edc/skills/edc-review/*) Edit(plugins/edc/skills/edc-review/*)`
- model: sonnet
- max-turns: 15

**`discard()`**
- restore skill files: `git checkout HEAD~1 -- "${SKILL_FILES[@]}"`
- soft reset: `git reset --soft HEAD~1`
- NEVER `git reset --hard`

**`main()`**
- parse args: `--baseline`, `-n`, `--status`, `--stop`
- run `ensure_repo`, `cache_sources`, `build_context` (one-time setup)
- compute or load baseline
- loop:
  1. `apply_change(iteration)` → get heuristic
  2. check for changes (`git diff --quiet`)
  3. hash dedup
  4. commit
  5. `run_benchmark("iter-N-fast", FAST_CVES)`
  6. if fast > baseline → `run_benchmark("iter-N-full", ALL_CVES)`
  7. if full > baseline → keep, update baseline
  8. else → `discard()`
  9. log everything

#### CLI

```
./benchmark/autoresearch.sh                  # run until stopped
./benchmark/autoresearch.sh -n 5             # run 5 iterations
./benchmark/autoresearch.sh --status         # show progress
./benchmark/autoresearch.sh --stop           # graceful stop
./benchmark/autoresearch.sh --baseline       # recompute baseline
./benchmark/autoresearch.sh --context        # rebuild context only
```

---

### 2. `benchmark/score.py` — COMPLETE REWRITE

Same concept, cleaner implementation.

**`keyword_score(issues_text, bug_pattern, category, affected_files) → (score, notes)`**
- check affected file mentioned (0.15)
- check category keywords (0.25 max)
- check bug pattern keywords (0.35 max)
- threshold: 0.3 to pass to LLM judge

**`llm_judge(issues_text, cve_id, bug_pattern, category, description, affected_files) → (verdict, confidence, explanation)`**
- truncate issues to 8000 chars
- prompt: "did the analysis find this specific vulnerability?"
- verdict: exact / partial / missed
- parse JSON response, handle errors

**`score_cve(issues_text, cve_id, ...) → (verdict, confidence, notes)`**
- phase 1: keyword pre-filter
- phase 2: LLM judge (if keywords pass threshold)
- fallback: keyword-only if judge errors

**`append_result(cve_id, category, severity, verdict, confidence, duration, notes)`**
- write TSV row to results file

**CLI:**
```
python3 score.py --issues path --cve CVE-XXX --bug-pattern "..." --category "..." ...
python3 score.py --summary
```

---

### 3. `benchmark/parse_gt.py` — KEEP AS-IS

42 lines, works fine, outputs pipe-delimited CVE entries. no changes needed.

---

### 4. `benchmark/curl/repo.conf` — NEW

```
repo_url=https://github.com/curl/curl.git
```

---

### 5. `benchmark/.gitignore` — NEW

```
cache/
.score-*.tmp
.result-*
.autoresearch.pid
.autoresearch.stop
autoresearch-output.log
```

---

## Execution order

### Step 0: Prove the pipeline (manual, no loop)

#### 0a: Cache sources
- clone curl, cache source files for all 11 CVEs
- verify: each CVE dir has .c/.h files, non-empty

#### 0b: Build context for 1 CVE
- run edc-context on CVE-2023-38545 (the flagship)
- verify: `.context/full-context.md` exists, is substantial (>1KB)
- record time

#### 0c: Single review
- run edc-review on CVE-2023-38545 with pre-built context
- verify: issues.md written, SOCKS5 heap overflow found
- record time

#### 0d: Score
- run score.py on issues.md
- verify: exact or partial classification
- verify: LLM judge output is valid JSON

#### 0e: Build context for all 11 CVEs
- run in parallel (or serial if resource-constrained)
- verify: all have full-context.md

#### 0f: Parallel 5-CVE baseline
- all 5 fast CVEs, parallel, pre-built context
- verify: all complete, baseline > 0

**GATE: Do NOT proceed to step 1 until 0f passes with baseline > 0.**

### Step 1: Minimal loop (3 iterations)
- agent edits review skill files
- commit → benchmark → score → keep/discard
- watchdog: 5min per CVE review
- max turns: 15 for agent, 20 for review

### Step 2: Full loop with two-phase scoring
- fast (5 CVEs) → if improved → full (11 CVEs)
- hash dedup active
- agent history (last 15 experiments)

---

## Models

| Role | Model | Why |
|------|-------|-----|
| Context building | sonnet | one-time, needs to be good but not opus-expensive |
| Security review | sonnet | iterated many times, needs speed |
| Agent (skill editor) | sonnet | fast iteration |
| LLM judge (scorer) | sonnet | accuracy matters for scoring |

---

## Watchdogs

| Step | Timeout | Rationale |
|------|---------|-----------|
| Context building | 15min | line-by-line analysis of 500-3000 line files |
| Security review | 5min | context pre-built, just finding bugs |
| Agent edit | 3min | reading + editing skill files |
| LLM judge | 60s | single classification call |

---

## Status

- [ ] 0a: Cache sources for all 11 CVEs
- [ ] 0b: Build context for CVE-2023-38545
- [ ] 0c: Single review with pre-built context
- [ ] 0d: Score pipeline
- [ ] 0e: Build context for all 11 CVEs
- [ ] 0f: Parallel 5-CVE baseline (GATE: baseline > 0)
- [ ] 1: Minimal loop (3 iterations)
- [ ] 2: Full loop with two-phase scoring
