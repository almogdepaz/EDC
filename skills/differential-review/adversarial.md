# Adversarial Analysis (Phase 5)

Structured methodology for finding issues through attacker/misuse modeling.

**When to use:** After completing deep context analysis (Phase 4), apply this to all HIGH RISK changes.

---

## 1. Define Specific Attacker Model

**WHO is the attacker?**
- Unauthenticated external user
- Authenticated regular user
- Malicious administrator/operator
- Compromised internal component or dependency
- Automated system (bot, crawler, scheduler)

**WHAT access/privileges do they have?**
- Public API access only
- Authenticated user role
- Specific permissions/tokens
- Network-level access (same machine, same network, internet)
- Filesystem access

**WHERE do they interact with the system?**
- HTTP endpoints
- WebSocket connections
- CLI commands
- Configuration files
- Environment variables
- Message queues / event streams

---

## 2. Identify Concrete Attack Vectors

```
ENTRY POINT: [Exact function/endpoint attacker can access]

ATTACK SEQUENCE:
1. [Specific API call/action with parameters]
2. [How this reaches the vulnerable code]
3. [What happens in the vulnerable code]
4. [Impact achieved]

PROOF OF ACCESSIBILITY:
- Show the function is public/reachable
- Demonstrate attacker has required permissions
- Prove attack path exists through actual interfaces
```

---

## 3. Rate Realistic Exploitability

**EASY:** Exploitable via public interfaces with no special privileges
- Single request/action
- Common user access level
- No complex conditions required

**MEDIUM:** Requires specific conditions or elevated privileges
- Multiple steps or timing requirements
- Elevated but obtainable privileges
- Specific system state needed

**HARD:** Requires privileged access or rare conditions
- Admin/operator privileges needed
- Rare edge case conditions
- Significant resources required

---

## 4. Build Complete Exploit Scenario

```
ATTACKER STARTING POSITION:
[What the attacker has at the beginning]

STEP-BY-STEP EXPLOITATION:
Step 1: [Concrete action through accessible interface]
  - Command/Request: [Exact call]
  - Parameters: [Specific values]
  - Expected result: [What happens]

Step 2: [Next action]
  - Command/Request: [Exact call]
  - Why this works: [Reference to code change]
  - System state change: [What changed]

Step 3: [Final impact]
  - Result: [Concrete harm achieved]
  - Evidence: [How to verify impact]

CONCRETE IMPACT:
[Specific, measurable impact - not "could cause issues"]
- Data exposed or corrupted
- Privileges escalated
- Service disrupted
- Resources consumed
```

---

## 5. Cross-Reference with Baseline Context

From baseline analysis (see [methodology.md](methodology.md#pre-analysis-baseline-context-building)), check:
- Does this violate a system-wide invariant?
- Does this break a trust boundary?
- Does this bypass a validation pattern?
- Is this a regression of a previous fix?

If `.context/` exists:
- Does the change violate invariants documented in `.context/{module}.md`?
- Does the coupling map in `context.md` flag modules affected by this change?
- Is this issue already documented in `.context/issues.md`?

---

## Vulnerability Report Template

Generate this for each finding:

```markdown
## [SEVERITY] Title

**Attacker Model:**
- WHO: [Specific attacker type]
- ACCESS: [Exact privileges]
- INTERFACE: [Specific entry point]

**Attack Vector:**
[Step-by-step exploit through accessible interfaces]

**Exploitability:** EASY/MEDIUM/HARD
**Justification:** [Why this rating]

**Concrete Impact:**
[Specific, measurable harm - not theoretical]

**Root Cause:**
[Reference specific code change at file:L123]

**Blast Radius:** [N callers affected]
**Baseline Violation:** [Which invariant/pattern broken]
```

---

## Example: Complete Adversarial Analysis

**Change:** Removed authorization check from an API endpoint

### 1. Attacker Model
- **WHO:** Unauthenticated external user
- **ACCESS:** Can reach public API endpoints
- **INTERFACE:** `POST /api/admin/config` (was restricted, now open)

### 2. Attack Vector
**ENTRY POINT:** `POST /api/admin/config { "setting": "value" }`

**ATTACK SEQUENCE:**
1. Send POST request with arbitrary config values
2. No authorization check (removed in this PR)
3. Config written to disk / applied to running system
4. System behavior changed by unauthorized user

**PROOF:** Endpoint is reachable without authentication after this change

### 3. Exploitability
**RATING:** EASY
- Single HTTP request
- No authentication required
- No special state needed

### 4. Exploit Scenario
**ATTACKER POSITION:** Has network access to the server

**EXPLOITATION:**
```
Step 1: POST /api/admin/config { "debug": true, "logLevel": "verbose" }
  - Passes through (no auth check)
  - Config saved to settings.json

Step 2: System now logs sensitive data
  - Debug mode exposes internal state
  - Verbose logging includes credentials

Step 3: Attacker reads exposed data via other endpoints or logs
  - Credentials harvested
  - Further escalation possible
```

**IMPACT:**
- Configuration tampered by unauthorized user
- Sensitive data exposure via debug mode
- Potential credential theft leading to full system compromise

### 5. Baseline Violation
- Violates invariant: "All /api/admin/* endpoints require admin authentication"
- Breaks trust boundary: Admin endpoints were behind auth middleware
- Regression: Auth check added in commit abc123 "Secure admin endpoints"

---

**Next:** Document all findings in final report (see [reporting.md](reporting.md))
