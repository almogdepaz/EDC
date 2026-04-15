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

## Planned Improvements

> **Scope note:** benchmark tunes `edc-review` only. Context is built once via `edc-context` and frozen.
> Ideas marked **[DEFERRED]** target `edc-context` or `edc-audit` — skip for benchmark, revisit later.

### edc-review experiments (benchmark targets)

#### 1. Fault Injection Thinking
**Add to:** edc-review methodology.md

Systematic "what if" prompts per function: external dep fails, input is malicious/empty/huge, two concurrent callers, filesystem full, network drops mid-op.

**Status:** [ ] not started

#### 5. Security Checklist as Structured Prompts
**Add to:** edc-review patterns.md

Mandatory pass/fail checklist for C: bounds on every memcpy/strcpy, return value checked on every alloc, no signed integer used as size/index, every free'd pointer NULLed, every realloc return checked.

**Status:** [ ] not started

#### 7. TRAIL Threat Modeling
**Add to:** edc-review adversarial.md

Structured threat boundary tracing: identify trust assumptions per entrypoint, ask "what if wrong?", trace cascading impact of violated assumptions.

**Status:** [ ] not started

#### 8. Sharp-Edges C Checklist (inspired by TOB `sharp-edges`)
**Add to:** edc-review patterns.md

Enumerate dangerous C APIs and require per-call-site audit:
- `memcpy`/`memmove`: is `n` bounded by dest size on ALL paths?
- `strcpy`/`strcat`/`sprintf`: banned — flag unconditionally
- `realloc`: is return value checked before freeing old pointer?
- `malloc(a * b)`: is overflow in `a * b` possible?
- `int`/`short` used as length/index fed by peer-controlled data: negativity check present?

**Status:** [ ] not started

#### 9. Subagent for Complex Functions (inspired by TOB `audit-context-building`)
**Add to:** edc-review SKILL.md / methodology.md

For functions >100 LOC or containing: state machines, multi-entry switch/case, recursive patterns, or protocol parsing — spawn a dedicated sub-analysis pass with a focused prompt on that function alone before continuing. Prevents timeout on complex targets (e.g. SOCKS5 state machine in CVE-2023-38545).

**Status:** [ ] not started

#### 10. Variant Analysis Pass (inspired by TOB `variant-analysis`)
**Add to:** edc-review methodology.md

After finding any vulnerability: grep the codebase for the same pattern. One unchecked `memcpy` → search for all `memcpy` calls with peer-controlled `n`. One unsigned underflow → find all arithmetic feeding `malloc`/`memcpy`. Document whether variants are present or explicitly ruled out.

**Status:** [ ] not started

#### 11. Dimensional Analysis — Integer Type Tracking (inspired by TOB `dimensional-analysis`)
**Add to:** edc-review patterns.md

For every size/length/count variable: track its declared type, its source (peer-controlled vs local), and every arithmetic operation applied before it reaches `malloc`/`memcpy`/array index. Flag: signed used where unsigned expected, narrowing casts, subtraction that could underflow, multiplication that could overflow.

**Status:** [ ] not started

#### 12. Explicit Trust Boundary + Taint Trace per Entrypoint
**Add to:** edc-review methodology.md

For each function that receives network/peer/user input: explicitly label it as a taint source. Trace every tainted value to every sink (alloc size, copy length, array index, branch condition). Document where sanitization occurs or is absent.

**Status:** [ ] not started

---

### Deferred (edc-context / edc-audit — not relevant while context is frozen)

#### 2. ATAM Trade-Off Analysis [DEFERRED]
**Add to:** edc-context SKILL.md — skip for benchmark

#### 3. Unenforced Invariant Detection [DEFERRED]
**Add to:** edc-context SKILL.md — skip for benchmark

#### 4. Cognitive Complexity Flagging [DEFERRED]
**Add to:** edc-audit.md — skip for benchmark

#### 6. Manual Taint Tracing [DEFERRED]
**Add to:** edc-context SKILL.md — skip for benchmark (taint trace now in #12 for review phase)

---

## Experiment Priority

**Next batch (highest signal for C CVEs):**
- 8 — sharp-edges C checklist (direct hit on buffer overflow class)
- 11 — integer type tracking (signedness/underflow CVEs)
- 9 — subagent for complex functions (fixes CVE-2023-38545 timeout)

**Second batch:**
- 10 — variant analysis (multiplier effect once any CVE found)
- 12 — taint trace per entrypoint (protocol parsing CVEs)
- 5 — security checklist (broad coverage)

**Third batch:**
- 1 — fault injection thinking
- 7 — TRAIL threat modeling

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
