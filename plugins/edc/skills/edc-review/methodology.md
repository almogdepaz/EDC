# Security Review Methodology

Use this workflow to find security-relevant issues in a diff. Keep the scope adversarial: trust boundaries, attacker-controlled input, removed protections, sensitive state, and security regressions.

## Pre-analysis: context

If `edc-context/index.md` exists:
1. Read it for `Route by path/task`, critical invariants, trust boundaries, and cross-module coupling / blast-radius notes.
2. Use `edc-context/manifest.json` or orchestrator task files for authoritative path routing; do not improvise routing from prose.
3. Load affected `edc-context/modules/{module}.md` files.
4. Load `edc-context/reports/issues.md` to see whether changed files touch known risks.

If generated context is missing, build a lightweight baseline from changed files, adjacent security-sensitive code, and git history. Do not invent architecture.

Capture only security-relevant baseline facts:
- trust boundaries and privilege levels
- validation/escaping/authorization patterns
- sensitive state transitions
- external calls and subprocess/file/network boundaries
- invariants whose violation could create security impact

## Phase 0: security triage

Extract the diff and commits:
```bash
git diff <base>...<head> --stat
git diff <base>...<head> --name-only
git log <base>..<head> --oneline
```

Risk score files by security exposure:

| Risk | Triggers |
|---|---|
| HIGH | auth/authz, crypto/secrets, validation/escaping removal, external calls, subprocesses, memory safety, sensitive state mutation |
| MEDIUM | public API shape, parser changes, config/state changes, new data flow across trust boundary |
| LOW | changes with no plausible security impact after inspection |

Skip generic style, maintainability, or delivery findings. If a bug is not security-relevant, leave it for `edc-audit` or `edc-delivery-review`.

## Phase 0.5: C/C++ memory-safety fast path

For changed C/C++ files, scan before deep analysis:

```bash
grep -n "memcpy\|memmove\|memset\|strcpy\|strcat\|sprintf\|snprintf" <file>
grep -n "malloc\|realloc\|calloc\|alloc" <file>
grep -n "free\|curl_free\|Curl_safefree\|safefree" <file>
grep -n "atoi\|atol\|htons\|ntohs\|ntohl\|htonl\|strtol\|strtoul" <file>
grep -n "parse\|decode\|visit\|walk\|recurse" <file>
```

For recursive C/C++ parsers or tree/packet walkers, trace whether attacker-controlled nesting can drive unbounded recursion. Verify a depth counter, input-size bound, or iterative limit exists before dismissing stack-overflow risk.

For each candidate, verify whether attacker/peer-controlled data reaches the size, pointer, lifetime, or recursion-depth decision without a guard. Report only verified memory-safety risk.

If one issue is found, run a variant sweep for that pattern class across the changed file before continuing.

## Phase 1: changed-code security analysis

When Octocode is already installed and useful, prefer it for targeted reachability, blast-radius, dependency-source, and permitted history research. Remote history remains allowed only when the assigned workflow already permits it. Do not install or configure Octocode, widen assigned scope, treat unavailable semantic support as evidence of absence, or fail when Octocode is unavailable or unnecessary; existing Read, Grep, Glob, and Bash workflows remain valid fallbacks.

For each security-relevant diff region:

1. Read surrounding current code and, when needed, the baseline version.
2. Identify the before/after security property:
   ```text
   BEFORE: protection / trust boundary / validation / state invariant
   AFTER: changed behavior
   SECURITY QUESTION: can an attacker or lower-privilege actor reach this?
   ```
3. Git-blame removed protections:
   ```bash
   git log -S "removed_code" --all --oneline
   git log -S "added_code" --all -p
   ```
4. Escalate removed/reintroduced code from `security`, `CVE`, `fix`, auth, validation, sandboxing, crypto, or memory-safety commits.
5. Trace attacker-controlled inputs to sinks: auth decisions, filesystem paths, shell/SQL/template execution, network calls, deserialization, sensitive state writes, memory operations.
6. For candidate findings, prove or disprove reachability. If reachability is uncertain, state the limit instead of fabricating an exploit.

## Phase 2: security test confidence

Only assess tests as security confidence evidence. Do not perform generic test-quality review.

Flag as risk multipliers:
- modified auth/validation/security behavior with unchanged tests
- missing regression test for a security fix or removed protection
- tests that cover only happy path for attacker-controlled input
- tests that mock away the trust boundary being reviewed

## Phase 3: security blast radius

Calculate blast radius for HIGH/MEDIUM security changes:
- direct callers / routes / commands
- public entrypoints reaching the changed code
- coupled modules from `edc-context/index.md`
- documented invariants or trust boundaries in module docs

Use broad grep/reference checks only to answer reachability or impact questions.

## Phase 4: deep context check

For each candidate finding:
- which trust boundary is crossed?
- what privilege does the attacker/misuser need?
- what validation/auth/escaping used to exist?
- what sensitive state can change or leak?
- does this violate EDC documented invariants or known issues?

If a candidate survives this check, proceed to adversarial analysis.

## Phase 5: adversarial analysis

Use `adversarial.md` for HIGH findings and any MEDIUM finding where exploitability is not obvious. Each confirmed finding needs a concrete attack path or explicit statement that reachability is unproven.

## Phase 6: report

Use `reporting.md`. If no issue survives verification, write `No security findings` with scope, techniques used, and limitations.
