# Common Issue Patterns

Quick reference for detecting common issues in code changes.

---

## Security Regressions

**Pattern:** Previously removed code is re-added

**Detection:**
```bash
git log -S "pattern" --all --grep="security\|fix\|CVE"
```

**Red flags:**
- Commit message contains "security", "fix", "CVE", "vulnerability"
- Code removed <6 months ago
- No explanation in current PR for re-addition

---

## Double State Mutation

**Pattern:** Same state operation twice for same logical event

**Detection:** Look for two state updates in related functions for same action

**Example:**
```
// requestExit() decrements balance
// processExit() also decrements balance
// User balance decremented twice for one exit
```

**Impact:** State corruption, resource loss

---

## Missing Validation

**Pattern:** Removed validation check without replacement

**Detection:**
```bash
git diff <range> | grep "^-" | grep -E "require|assert|validate|check|guard|throw|reject"
```

**Questions to ask:**
- Was validation moved elsewhere?
- Is it redundant (defensive programming)?
- Does removal expose a bug?

---

## Integer Overflow/Underflow

**Pattern:** Arithmetic without bounds checking

**Detection:** Look for unchecked arithmetic on user-controlled values, especially:
- Subtraction that could underflow
- Multiplication that could overflow
- Division by potentially-zero values
- Type narrowing casts (`u64 as u32`, `Number()` coercion)

---

## Re-entrant / Recursive Invocation

**Pattern:** External call or callback before state update completes

**Detection:** Look for patterns where:
- State is read → external call made → state is written (the read value may be stale)
- Event handler triggers code that re-enters the same handler
- Callback/webhook invokes the caller before the original call completes

**Mitigation patterns:** Mutex/lock flags, update-before-call ordering, re-entrancy guards

---

## Access Control Bypass

**Pattern:** Removed or relaxed permission checks

**Detection:**
```bash
git diff <range> | grep "^-" | grep -E "auth|admin|owner|permission|role|middleware|guard"
```

**Questions:**
- Who can now call this function?
- What's the new trust model?
- Was check moved to caller?

---

## Race Conditions / TOCTOU

**Pattern:** Check-then-act with a gap between check and action

**Detection:** Look for:
- File existence check followed by file operation
- Database read followed by conditional write
- Lock check followed by lock acquisition
- Session validation followed by session use

**Example:**
```
// Check if name is available
if (!sessions.includes(name)) {
  // GAP: another request could claim the name here
  createSession(name);  // May create duplicate
}
```

---

## Command / Query Injection

**Pattern:** User input reaches shell commands, SQL queries, or template evaluation

**Detection:**
```bash
git diff <range> | grep "^+" | grep -E "exec\(|spawn\(|system\(|eval\(|query\(|raw\("
```

**Questions:**
- Is input validated/escaped before reaching the sink?
- Is `execFile` (array args) used instead of `exec` (shell string)?
- Are parameterized queries used instead of string interpolation?

---

## Path Traversal

**Pattern:** User-controlled input used in filesystem paths

**Detection:**
```bash
git diff <range> | grep "^+" | grep -E "readFile|writeFile|join\(|resolve\(|open\("
```

**Questions:**
- Is the path component validated (no `..`, no absolute paths)?
- Is the resolved path checked against an allowed directory?
- Are symlinks resolved before the containment check?

---

## Unchecked Return Values / Error Swallowing

**Pattern:** External call without checking success, or catch block that silently continues

**Detection:**
```bash
git diff <range> | grep "^+" | grep -E "catch\s*\{|catch\s*\(\)|\.catch\(\(\) =>"
```

**Questions:**
- Does the caller assume success?
- Does the error handler mask a real failure?
- Should the error propagate instead of being swallowed?

---

## Denial of Service

**Pattern:** Unbounded operations, external failures blocking critical paths

**Detection:**
- Arrays/collections that grow without limit
- Loops over user-controlled data
- Critical function depends on external call success
- Synchronous operations blocking event loop
- No timeout on network/subprocess calls

---

## Secret Leakage

**Pattern:** Credentials or sensitive data in logs, error messages, or responses

**Detection:**
```bash
git diff <range> | grep "^+" | grep -E "log\(|console\.|error\(|JSON\.stringify" | grep -i "secret\|token\|key\|password\|credential"
```

**Questions:**
- Does the error message include request body or headers?
- Does the log include auth tokens or API keys?
- Does the response include internal state?

---

## Quick Detection Commands

**Find removed validation:**
```bash
git diff <range> | grep "^-" | grep -E "require|assert|validate|check|guard|throw"
```

**Find new external calls:**
```bash
git diff <range> | grep "^+" | grep -E "fetch\(|exec\(|spawn\(|\.call\(|request\("
```

**Find changed auth patterns:**
```bash
git diff <range> | grep -E "auth|admin|permission|middleware|guard|role"
```

**Find new file operations:**
```bash
git diff <range> | grep "^+" | grep -E "readFile|writeFile|unlink|mkdir|open\("
```

---

**For detailed analysis workflow, see [methodology.md](methodology.md)**
**For building exploit scenarios, see [adversarial.md](adversarial.md)**
