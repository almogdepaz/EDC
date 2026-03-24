# Report Generation (Phase 6)

Comprehensive markdown report structure and formatting guidelines.

---

## Report Structure

Generate markdown report with these mandatory sections:

### 0. Context Inputs & Compliance

- Context freshness status (`.context/.meta.json` vs reviewed commit)
- Context files consulted list
- Invariants checked list (with pass/fail or violated/unchanged)
- Search scope note (confirm context-first, targeted search)

**Template:**
```markdown
## Context Inputs & Compliance

**Context Freshness:**
- Reviewed commit: `<sha>`
- `.context/.meta.json lastCommit`: `<sha>`
- Status: MATCH / REBUILT DURING REVIEW

**Context Files Consulted:**
- `.context/context.md`
- `.context/issues.md`
- `.context/<module-a>.md`
- `.context/<module-b>.md`

**Invariants Checked:**
| Invariant | Source | Result |
|-----------|--------|--------|
| Nonce must increase monotonically | `.context/service.md` | PASS |
| Auth required for admin endpoints | `.context/api.md` | VIOLATED |

**Search Discipline:**
- Broad search before context load: NO
- Search scope: changed files + direct dependencies
```

---

### 1. Executive Summary

- Severity distribution table
- Risk assessment (CRITICAL/HIGH/MEDIUM/LOW)
- Final recommendation (APPROVE/REJECT/CONDITIONAL)
- Key metrics (test gaps, blast radius, red flags)

**Template:**
```markdown
# Executive Summary

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | X |
| 🟠 HIGH | Y |
| 🟡 MEDIUM | Z |
| 🟢 LOW | W |

**Overall Risk:** CRITICAL/HIGH/MEDIUM/LOW
**Recommendation:** APPROVE/REJECT/CONDITIONAL

**Key Metrics:**
- Files analyzed: X/Y (Z%)
- Test coverage gaps: N functions
- High blast radius changes: M functions
- Security regressions detected: P
```

---

### 2. What Changed

- Commit timeline with visual
- File summary table
- Lines changed stats

**Template:**
```markdown
## What Changed

**Commit Range:** `base..head`
**Commits:** X
**Timeline:** YYYY-MM-DD to YYYY-MM-DD

| File | +Lines | -Lines | Risk | Blast Radius |
|------|--------|--------|------|--------------|
| file1.sol | +50 | -20 | HIGH | CRITICAL |
| file2.sol | +10 | -5 | MEDIUM | LOW |

**Total:** +N, -M lines across K files
```

---

### 3. Critical Findings

For each HIGH/CRITICAL issue:

```markdown
### [SEVERITY] Title

**File**: path/to/file.ext:lineNumber
**Commit**: hash
**Blast Radius**: N callers (HIGH/MEDIUM/LOW)
**Test Coverage**: YES/NO/PARTIAL

**Description**: [clear explanation]

**Historical Context**:
- Git blame: Added in commit X (date)
- Message: "[original commit message]"
- [Why this code existed]

**Attack Scenario**:
[Concrete exploitation steps from adversarial.md]

**Proof of Concept**:
```code demonstrating issue```

**Recommendation**:
[Specific fix with code]
```

**Example:**
```markdown
### 🔴 CRITICAL: Authorization Bypass in Admin Config

**File**: routes.ts:245
**Commit**: abc123def
**Blast Radius**: 12 callers (MEDIUM)
**Test Coverage**: NO

**Description**:
Removed auth middleware check allows any user to modify server configuration.

**Historical Context**:
- Git blame: Added 2024-06-15 (commit def456)
- Message: "Add auth check per security review #45"
- Code existed to prevent unauthorized config changes

**Attack Scenario**:
1. Unauthenticated user sends POST /api/admin/config
2. No authorization check (removed in this PR)
3. Server config overwritten with attacker-controlled values
4. Service compromised

**Recommendation**:
```typescript
// Restore auth middleware for admin routes
if (!isAdmin(req)) {
  return res.status(403).json({ error: "forbidden" });
}
```
```

---

### 4. Test Coverage Analysis

- Coverage statistics
- Untested changes list
- Risk assessment

**Template:**
```markdown
## Test Coverage Analysis

**Coverage:** X% of changed code

**Untested Changes:**
| Function | Risk | Impact |
|----------|------|--------|
| functionA() | HIGH | No validation tests |
| functionB() | MEDIUM | Logic untested |

**Risk Assessment:**
N HIGH-risk functions without tests → Recommend blocking merge
```

---

### 5. Blast Radius Analysis

- High-impact functions table
- Dependency graph
- Impact quantification

**Template:**
```markdown
## Blast Radius Analysis

**High-Impact Changes:**
| Function | Callers | Risk | Priority |
|----------|---------|------|----------|
| transfer() | 89 | HIGH | P0 |
| validate() | 45 | MEDIUM | P1 |
```

---

### 6. Historical Context

- Security-related removals
- Regression risks
- Commit message red flags

**Template:**
```markdown
## Historical Context

**Security-Related Removals:**
- Line 45: `require` removed (added 2024-03 for CVE-2024-1234)
- Line 78: Validation removed (added 2023-12 "security hardening")

**Regression Risks:**
- Code pattern removed in commit X, re-added in commit Y
```

---

### 7. Recommendations

- Immediate actions (blocking)
- Before production (tracking)
- Technical debt (future)

**Template:**
```markdown
## Recommendations

### Immediate (Blocking)
- [ ] Fix CRITICAL issue in TokenVault.sol:156
- [ ] Add tests for withdraw() function

### Before Production
- [ ] Security audit of auth changes
- [ ] Load test blast radius functions

### Technical Debt
- [ ] Refactor validation pattern consistency
```

---

### 8. Analysis Methodology

- Strategy used (DEEP/FOCUSED/SURGICAL)
- Context-first compliance summary
- Files analyzed
- Coverage estimate
- Techniques applied
- Limitations
- Confidence level

**Template:**
```markdown
## Analysis Methodology

**Strategy:** FOCUSED (80 files, medium codebase)

**Analysis Scope:**
- Files reviewed: 45/80 (56%)
- HIGH RISK: 100% coverage
- MEDIUM RISK: 60% coverage
- LOW RISK: Excluded

**Context-First Compliance:**
- `.context` freshness validated before triage
- Context files loaded before broad search
- Invariants mapped from module context files

**Techniques:**
- Git blame on all removals
- Blast radius calculation
- Test coverage analysis
- Adversarial modeling for HIGH RISK

**Limitations:**
- Did not analyze external dependencies
- Limited to 1-hop caller analysis

**Confidence:** HIGH for analyzed scope, MEDIUM overall
```

---

### 9. Appendices

- Commit reference table
- Key definitions
- Contact info

---

## Formatting Guidelines

**Tables:** Use markdown tables for structured data

**Code blocks:** Always include syntax highlighting
```typescript
// TypeScript code
```
```rust
// Rust code
```
```python
# Python code
```

**Status indicators:**
- ✅ Complete
- ⚠️ Warning
- ❌ Failed/Blocked

**Severity:**
- 🔴 CRITICAL
- 🟠 HIGH
- 🟡 MEDIUM
- 🟢 LOW

**Before/After comparisons:**
```markdown
**BEFORE:**
```code
old code
```

**AFTER:**
```code
new code
```
```

**Line number references:** Always include
- Format: `file.ts:L123`
- Link to commit: `file.ts:L123 (commit abc123)`

---

## File Naming and Location

**Priority order for output:**
1. Current working directory (if project repo)
2. User's Desktop
3. `~/.claude/skills/edc-review/output/`

**Filename format:**
```
<PROJECT>_DIFFERENTIAL_REVIEW_<DATE>.md

Example: PROJECT_DIFFERENTIAL_REVIEW_2026-03-23.md
```

---

## User Notification Template

After generating report:

```markdown
Report generated successfully!

📄 File: [filename]
📁 Location: [path]
📏 Size: XX KB
⏱️ Review Time: ~X hours

Summary:
- X findings (Y critical, Z high)
- Final recommendation: APPROVE/REJECT/CONDITIONAL
- Confidence: HIGH/MEDIUM/LOW

Next steps:
- Review findings in detail
- Address CRITICAL/HIGH issues before merge
- Consider chaining with issue-writer for stakeholder report
```

---

## Integration with issue-writer

After generating differential review, transform into audit report:

```bash
issue-writer --input DIFFERENTIAL_REVIEW_REPORT.md --format audit-report
```

This creates polished documentation for non-technical stakeholders.

---

## Error Handling

If file write fails:
1. Try Desktop location
2. Try temp directory
3. As last resort, output full report to chat
4. Notify user to save manually

**Always prioritize persistent artifact generation over ephemeral chat output.**

---

## Report Quality Gate

A report is incomplete unless all of the following are present:

- `Context Inputs & Compliance` section
- Explicit `Context Files Consulted` list
- Explicit `Invariants Checked` table/list
- At least one context citation for each HIGH/MEDIUM finding

If missing, revise the report before delivery.
