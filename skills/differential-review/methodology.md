# Differential Review Methodology

Detailed phase-by-phase workflow for code review.

## Pre-Analysis: Baseline Context Building

**FIRST ACTION — Check for existing context, then build baseline if needed:**

If `.context/context.md` exists in the repository:
1. Read `context.md` for architecture overview, module map, actors, invariants, trust boundaries, coupling
2. This IS your baseline — skip the full context build
3. Map changed files to modules using the Module Map table
4. Load `.context/{module}.md` for affected modules
5. Load `.context/issues.md` to check if changes touch known issues

If `.context/` does NOT exist but `deep-context-building` skill is available:

```bash
# Checkout baseline commit
git checkout <baseline_commit>

# Invoke deep-context-building skill on baseline codebase
deep-context-building --scope [entire project or main source directory]
```

**Capture from baseline analysis:**
- System-wide invariants (what must ALWAYS be true across all code)
- Trust boundaries and privilege levels (who can do what)
- Validation patterns (what gets checked where - defense-in-depth)
- Complete call graphs for critical functions (who calls what)
- State flow diagrams (how state changes)
- External dependencies and trust assumptions

**Why this matters:**
- Understand what the code was SUPPOSED to do before changes
- Identify implicit assumptions in baseline
- Detect when changes violate baseline invariants
- Know which patterns are system-wide vs local
- Catch when changes break defense-in-depth

**Store baseline context for reference during differential analysis.**

After baseline analysis, checkout back to head commit to analyze changes.

---

## Phase 0: Intake & Triage

**Extract changes:**
```bash
# For commit range
git diff <base>..<head> --stat
git log <base>..<head> --oneline

# For PR
gh pr view <number> --json files,additions,deletions

# Get all changed files
git diff <base>..<head> --name-only
```

**Assess codebase size:**
```bash
find . -type f \( -name "*.ts" -o -name "*.rs" -o -name "*.go" -o -name "*.py" -o -name "*.sol" -o -name "*.js" \) | wc -l
```

**Classify complexity:**
- **SMALL**: <20 files → Deep analysis (read all deps)
- **MEDIUM**: 20-200 files → Focused analysis (1-hop deps)
- **LARGE**: 200+ files → Surgical (critical paths only)

**Risk score each file:**
- **HIGH**: Auth, crypto, external calls, state mutation, validation removal
- **MEDIUM**: Business logic, state changes, new public APIs
- **LOW**: Comments, tests, UI, logging

**Context-aware triage (if `.context/` exists):**
- Check `.context/issues.md` — does this PR touch files with known issues?
- Check module coupling in `context.md` — does this change have cascade risk?
- Elevate risk for changes touching fragility clusters documented in `.context/{module}.md`

---

## Phase 1: Changed Code Analysis

For each changed file:

1. **Read both versions** (baseline and changed)

2. **Analyze each diff region:**
   ```
   BEFORE: [exact code]
   AFTER: [exact code]
   CHANGE: [behavioral impact]
   RISK: [implications]
   ```

3. **Git blame removed code:**
   ```bash
   # When was it added? Why?
   git log -S "removed_code" --all --oneline
   git blame <baseline> -- <file> | grep "pattern"
   ```

   **Red flags:**
   - Removed code from "fix", "security", "CVE" commits → CRITICAL
   - Recently added (<1 month) then removed → HIGH

4. **Check for regressions (re-added code):**
   ```bash
   git log -S "added_code" --all -p
   ```

   Pattern: Code added → removed for security → re-added now = REGRESSION

5. **Micro-adversarial analysis** for each change:
   - What problem did removed code prevent?
   - What new surface does new code expose?
   - Can modified logic be bypassed?
   - Are checks weaker? Edge cases covered?

6. **Generate concrete scenarios:**
   ```
   SCENARIO: [what goes wrong]
   PRECONDITIONS: [required state]
   STEPS:
     1. [specific action]
     2. [expected outcome]
     3. [actual outcome]
   WHY IT WORKS: [reference code change]
   IMPACT: [severity + scope]
   ```

7. **Invariant compliance (if `.context/` exists):**
   - Read `.context/{module}.md` for the affected module
   - Does the change violate any documented invariant?
   - Does it break an implicit contract with another module?
   - Does the coupling map flag cascade risk?

---

## Phase 2: Test Coverage Analysis

**Identify coverage gaps:**
```bash
# Production code changes (exclude tests)
git diff <range> --name-only | grep -v "test"

# Test changes
git diff <range> --name-only | grep "test"

# For each changed function, search for tests
grep -r "test.*functionName" test/ tests/
```

**Risk elevation rules:**
- NEW function + NO tests → Elevate risk MEDIUM→HIGH
- MODIFIED validation + UNCHANGED tests → HIGH RISK
- Complex logic (>20 lines) + NO tests → HIGH RISK

---

## Phase 3: Blast Radius Analysis

**Calculate impact:**
```bash
# Count callers for each modified function
grep -r "functionName(" . --include="*.ts" --include="*.rs" --include="*.py" | wc -l
```

**Classify blast radius:**
- 1-5 calls: LOW
- 6-20 calls: MEDIUM
- 21-50 calls: HIGH
- 50+ calls: CRITICAL

**Context-aware blast radius (if `.context/` exists):**
- Cross-module coupling section in `context.md` maps cascade paths
- `.context/{module}.md` documents which modules depend on the changed module
- Use these instead of grep when available — they capture non-obvious coupling

**Priority matrix:**

| Change Risk | Blast Radius | Priority | Analysis Depth |
|-------------|--------------|----------|----------------|
| HIGH | CRITICAL | P0 | Deep + all deps |
| HIGH | HIGH/MEDIUM | P1 | Deep |
| HIGH | LOW | P2 | Standard |
| MEDIUM | CRITICAL/HIGH | P1 | Standard + callers |

---

## Phase 4: Deep Context Analysis

**If `.context/` exists**, this is already done — the context files contain the deep analysis. Focus on:
1. Does the change violate documented invariants?
2. Does the change break documented implicit contracts?
3. Does the change touch a documented fragility cluster?
4. Does the change conflict with documented design decisions?

**If `.context/` does NOT exist**, build context for HIGH RISK changes:

Use the `deep-context-building` skill or manually analyze:

1. **Map complete function flow:**
   - Entry conditions (preconditions, guards, middleware)
   - State reads (which variables accessed)
   - State writes (which variables modified)
   - External calls (to APIs, subprocesses, services)
   - Return values and side effects

2. **Trace internal calls:**
   - List all functions called
   - Recursively map their flows
   - Build complete call graph

3. **Trace external calls:**
   - Identify trust boundaries crossed
   - List assumptions about external behavior
   - Check for re-entrant or recursive invocation risks

4. **Identify invariants:**
   - What must ALWAYS be true?
   - What must NEVER happen?
   - Are invariants maintained after changes?

5. **Five Whys root cause:**
   - WHY was this code changed?
   - WHY did the original code exist?
   - WHY might this break?
   - WHY is this approach chosen?
   - WHY could this fail in production?

**Cross-cutting pattern detection:**
```bash
# Find repeated validation patterns
grep -r "validate\|check\|assert\|guard" . --include="*.ts" --include="*.rs"

# Check if any removed in diff
git diff <range> | grep "^-.*validate\|^-.*check\|^-.*assert"
```

**Flag if removal breaks defense-in-depth.**

---

**Next steps:**
- For HIGH RISK changes, proceed to [adversarial.md](adversarial.md)
- For report generation, see [reporting.md](reporting.md)
