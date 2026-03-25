# EDC — Improvement Plan

## Current State (v1.1.0)

### Commands
- `/edc:edc-build` — orchestrator (full build or incremental update)
- `/edc:edc-split` — splits full-context.md into per-module files
- `/edc:edc-update` — incremental update from branch changes
- `/edc:edc-audit` — bloat/duplication/overengineering detection
- `/edc:edc-review` — context-aware differential review

### Skills
- `edc:edc-context` — generalized from Trail of Bits audit-context-building
- `edc:edc-review` — generalized from Trail of Bits differential-review

### Agents
- Claude Code, Cursor, Codex, Gemini CLI

### Repo Structure
- Plugin lives at `plugins/edc/` (restructured from `agents/claude/plugins/edc/`)
- Cursor commands reference shared skills via `plugins/edc/skills/`
- Marketplace entry at `.claude-plugin/marketplace.json`

### Validated
- Compared against TOB on wolfpack (TypeScript), Veil (Rust/ZK), clanker-wallet (TS+Python)
- EDC is a strict superset of TOB findings (14/14 TOB + 6 additional on clanker-wallet)
- Full pipeline: edc-build → edc-split → edc-audit → edc-review

### Recent Fixes
- Skill references disambiguated to `edc:edc-context` with explicit NOT `audit-context-building` guards (prevents collision when both plugins installed)
- Cursor commands renamed to `edc-run-*` for clarity

---

## Planned Improvements (from research)

### 1. Fault Injection Thinking
**Add to:** edc-review methodology.md, Phase 1 step 5

Systematic "what if" failure prompts for each changed function:
- What if this external dependency fails/hangs/returns garbage?
- What if this input is malicious/malformed/empty/huge?
- What if two concurrent callers hit this simultaneously?
- What if the filesystem is full/readonly/slow?
- What if the network drops mid-operation?
- What if this runs on a different platform/timezone/locale?

**Status:** [ ] not started

### 2. ATAM Trade-Off Analysis
**Add to:** edc-context SKILL.md, Phase 3 new section 5

For each major design decision: what does it optimize, what does it sacrifice, where does the trade-off become painful, what triggers revisiting it.

**Status:** [ ] not started

### 3. Unenforced Invariant Detection
**Add to:** edc-context SKILL.md, Phase 2 section 5.1

Find invariants CLAIMED in comments/docstrings/names but NOT enforced by code. "Comment says thread-safe but no locking."

**Status:** [ ] not started

### 4. Cognitive Complexity Flagging
**Add to:** edc-audit.md, new Step 9

Beyond LOC: nesting depth >3, >5 control flow branches, multiple responsibilities, boolean params, long param lists, god objects.

**Status:** [ ] not started

### 5. Security Checklist as Structured Prompts
**Add to:** edc-review patterns.md, new section

Mandatory pass/fail checklist: no hardcoded secrets, input validation, return value checks, auth on endpoints, no injection paths, no sensitive data in logs, path validation, constant-time crypto, timeouts, rate limiting.

**Status:** [ ] not started

### 6. Manual Taint Tracing
**Add to:** edc-context SKILL.md, Phase 2 section 5.2

Trace untrusted input source → transformations → sink. Note where sanitization happens or doesn't.

**Status:** [ ] not started

### 7. TRAIL Threat Modeling
**Add to:** edc-review adversarial.md, new section

Structured threat boundary tracing: identify trust assumptions, ask "what if wrong?", trace cascading impact of violated assumptions.

**Status:** [ ] not started

## Priority

**Phase 0** (prerequisite): Benchmark framework — without measurement, skill improvements are vibes
**Phase 1** (easy, high impact): 1, 5, 4
**Phase 2** (moderate effort): 3, 6, 2
**Phase 3** (needs design): 7

---

## Benchmark Framework (autoresearch-inspired)

### Concept

Modify → measure → keep/discard → repeat. Same loop as karpathy/autoresearch but for code analysis quality instead of val_bpb.

### Metric

**Recall**: how many known-real issues does a run find?
**Precision**: how many findings are false positives?
**Score**: `recall * 0.7 + (1 - false_positive_rate) * 0.3` (recall-weighted — missing real issues is worse than noise)

### Components

#### 1. Training Set (user provides)
Repos with known ground-truth issues. For each repo:
- `benchmark/{repo}/` — the codebase (or git URL + commit SHA)
- `benchmark/{repo}/ground-truth.md` — list of real issues with:
  - issue description
  - affected file:line
  - severity (critical/high/medium/low)
  - category (invariant violation, missing validation, race condition, dead code, etc.)

#### 2. Runner (`benchmark/run.sh`)
```
for each repo in benchmark/*/
  run /edc:edc-build on repo
  collect .context/issues.md + .context/complexity.md
  run scorer against ground-truth.md
done
```

#### 3. Scorer (`benchmark/score.py`)
Compares EDC output against ground truth:
- for each ground-truth issue: did EDC find it? (fuzzy match on file + description)
- for each EDC finding: is it in ground truth? (if not, likely false positive — but could be a new real finding, flag for human review)
- outputs: recall, precision, F1, per-category breakdown

#### 4. Experiment Loop
```
1. git checkout -b experiment/<name>
2. modify a skill file (e.g., add fault injection prompts)
3. run benchmark/run.sh
4. compare score against baseline
5. if improved → keep (merge to main)
6. if same or worse → discard (delete branch)
7. log result to benchmark/results.tsv
8. repeat
```

#### 5. Results Log (`benchmark/results.tsv`)
```
commit  recall  precision  f1  status  description
abc1234 0.82    0.91       0.86  keep    baseline
def5678 0.85    0.89       0.87  keep    added fault injection prompts
ghi9012 0.80    0.93       0.86  discard removed 5-whys (hurt recall)
```

### Ground Truth Sources

**Primary (public, language-agnostic):**
- **curl** (C, ~150k LOC) — 100+ CVEs, each with vulnerable version, fix commit, and detailed writeup at https://curl.se/docs/security.html. Best-documented CVE history in OSS. Primary benchmark repo.
- **Go x/crypto or hyper** (Go/Rust) — add after curl loop works, for language coverage
- **redis** (C) — clean codebase, ~15 well-documented CVEs

**Secondary (private, from prior work):**
- clanker-wallet (20 ground-truth issues from our best run)
- wolfpack (TOB's 14 observations as ground truth)
- Veil (cross-referenced EDC + TOB findings as ground truth)

### Execution Order

1. **Build ground truth for curl** — pull CVE list, map to vulnerable commit SHAs, write `benchmark/curl/ground-truth.md`
2. **Build scorer** — `benchmark/score.py`, compare EDC output vs ground truth (fuzzy match on file + description)
3. **Get baseline score** — run edc-build on curl at vulnerable commits, score output
4. **Autoresearch loop** — modify ONE skill variable per experiment, run scorer, keep/discard based on score delta
5. **Expand** — add Go/Rust repos for language coverage, re-run loop

### What Gets Experimented On

Each experiment modifies ONE thing in the skills:
- add/remove a prompt section
- rephrase an instruction
- change quality thresholds
- add/remove a pattern in patterns.md
- change the analysis ordering
- add a new phase or checklist item

The metric tells us if the change helped, hurt, or was neutral.

### Cold Start

curl is the cold start repo. No private data needed, no auth, fully public ground truth.
Once the loop works on curl, expand to Go/Rust repos and private repos (wolfpack, Veil, clanker-wallet).

### Status

- [ ] Step 1: Build curl ground truth (`benchmark/curl/ground-truth.md`)
- [ ] Step 2: Build scorer (`benchmark/score.py`)
- [ ] Step 3: Baseline score on curl
- [ ] Step 4: First autoresearch experiment
- [ ] Step 5: Add Go/Rust benchmark repos
