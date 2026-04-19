# Differential Review Methodology

Detailed phase-by-phase workflow for code review.

## Pre-Analysis: Baseline Context Building

**FIRST ACTION — Check for existing context, then build baseline if needed:**

If `.context/context.md` exists in the repository:
1. Read `.context/context.md` for architecture overview, module map, actors, invariants, trust boundaries, coupling
2. This IS your baseline — skip the full context build
3. Map changed files to modules using the Module Map table
4. Load `.context/{module}.md` for affected modules
5. Load `.context/issues.md` to check if changes touch known issues

If `.context/` does NOT exist but the `edc:edc-context` skill is available (NOT `audit-context-building` — that is a different plugin):

```bash
# Checkout baseline commit
git checkout <baseline_commit>

# Invoke edc:edc-context skill on baseline codebase
edc-context --scope [entire project or main source directory]
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
- Check module coupling in `.context/context.md` — does this change have cascade risk?
- Elevate risk for changes touching fragility clusters documented in `.context/{module}.md`

---

## Phase 0.5: C Memory Safety Fast-Path (run BEFORE deep analysis)

**CRITICAL: Create the output issues file FIRST, before any scanning.** Write an empty report skeleton to `issues.md` (or `.context/issues.md` if that directory exists) immediately. Then append each finding as you discover it. This guarantees a file exists even if analysis is cut short by time limits.

```bash
# Create output file immediately
mkdir -p .context 2>/dev/null || true
OUTPUT_FILE=".context/issues.md"
cat > "$OUTPUT_FILE" << 'EOF'
# Security Review Findings
<!-- findings appended below as discovered -->
EOF
```

For C/C++ codebases, run these targeted grep scans immediately. Flag any match as a candidate finding — do NOT wait for deep context. Each scan takes seconds and catches the majority of critical memory safety bugs. **Append each finding to the output file right away — do not buffer findings in memory.**

**Scan 1 — Fixed destination + peer-controlled write size (heap/stack buffer overflow):**
```bash
grep -n "memcpy\|memmove\|memset\|strcpy\|strncpy\|sprintf\|snprintf" <file>
```
For every hit: is the *destination* a fixed-size stack array (`char buf[N]`) or a heap allocation of known size? Is the *length* argument (third arg to memcpy, format-string expansion to sprintf) bounded to that size on ALL paths, including when the peer sends a maximum-size value? If not → REPORT as buffer overflow. **Append to output file immediately.**

**Scan 2 — Recursive functions without per-call-site depth guard (stack overflow):**
```bash
grep -n "recurse\|keyword_filter\|glob\|match\|parse" <file>  # adjust to function names
```
For each recursive function: enumerate EVERY call site inside the function body (there may be multiple — one for `*`, one for `[`, one for `(`, etc.). Check that EACH call site has its own depth check immediately before the recursive call, not just a single check at function entry. A single entry-point guard is bypassed if any branch recurses without re-entering through it. If any call site lacks a per-site guard → REPORT as unbounded recursion / stack overflow. **Append to output file immediately.**

**Scan 3 — Use-after-free and double-free:**
```bash
grep -n "free\|curl_free\|Curl_safefree\|safefree" <file>
```
For each `free(p)`: scan the next 30 lines for any read/write through `p` (dereference, pass to function, arithmetic). Also check: is `p` NULLed after free? If not, does any later `if (p)` guard pass on the dangling value? Check cleanup/error-handler paths for double-free: if two paths both call `free(p)` for the same pointer → REPORT. **Append to output file immediately.**

**Scan 4 — Peer-controlled allocation size (integer overflow into malloc):**
```bash
grep -n "malloc\|realloc\|calloc\|alloc" <file>
```
For each allocation: is the size argument computed from peer-supplied data (e.g., `Content-Length`, protocol field, user input)? Is there an overflow/underflow check on the arithmetic BEFORE the allocation? `malloc(a + b)` where both are attacker-controlled wraps to a small value → tiny allocation → overflow on write → REPORT. **Append to output file immediately.**

**Scan 5 — Signed-to-unsigned conversion used as size (signedness confusion):**
```bash
grep -n "atoi\|atol\|htons\|ntohs\|ntohl\|htonl\|strtol\|strtoul" <file>
```
For each variable assigned from these functions: (1) is the variable declared `int` or `short` (signed)? (2) is it used as a size/length argument to `malloc`/`memcpy`/array subscript without an `if (n <= 0)` guard immediately before that use? A negative `int` passed as `malloc(n)` silently widens to a huge `size_t` → REPORT as signedness confusion. Pattern to confirm: `int n = ntohs(hdr->len); malloc(n)` with no negativity check between assignment and use. **Append to output file immediately.**

**After all 5 scans complete:** Finalize the output file. Even if no findings were produced by the grep scans, write a "No issues found" summary to the output file so the file exists and is non-empty. The output file MUST exist after Phase 0.5 regardless of findings.

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
- Cross-module coupling section in `.context/context.md` maps cascade paths
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

Use the `edc:edc-context` skill (NOT `audit-context-building`) or manually analyze:

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
