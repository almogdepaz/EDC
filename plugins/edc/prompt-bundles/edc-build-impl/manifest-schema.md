# `manifest.json` Schema Reference (v2)

`/edc-context/manifest.json` is the authoritative machine-readable routing and policy contract for an EDC-built repo. It replaces the v1 `edc-context/.meta.json` and is the only document runtime adapters consult to map repo paths to module docs and to decide enforcement behavior.

This document is the canonical schema spec. `edc build`, `edc update`, and `edc doctor` MUST honor it. Runtime adapters (Claude hooks, Pi extensions, Cursor/Codex/Gemini wrappers) MUST treat it as the single source of truth.

---

## Top-Level Fields

| Field | Type | Required | Owner | Description |
|---|---|---|---|---|
| `schemaVersion` | integer | yes | LLM | Manifest schema version. Currently `2`. |
| `edcVersion` | string (semver) | yes | LLM | EDC release that produced the manifest, e.g. `"2.0.0"`. |
| `generatedAt` | string (ISO-8601 UTC) | yes | post-step | Timestamp filled deterministically after the build LLM step. |
| `sourceCommit` | string (full git SHA) | yes | post-step | `git rev-parse HEAD` at build time, filled deterministically after the LLM step. |
| `repoContextFile` | string (path) | yes | LLM | Path to the operational context index, normally `edc-context/index.md`. |
| `reports` | object | yes | LLM | Map of report name → path under `edc-context/reports/`. |
| `build` | object | yes | LLM | Provenance and intermediate artifact paths under `edc-context/build/`. |
| `policy` | object | yes | LLM | Enforcement and gating configuration (see [Policy](#policy)). |
| `modules` | array | yes | LLM | Ordered list of real human context module routing entries (see [Modules](#modules)). |
| `contextless` | object | optional | LLM | Structured coverage entries for paths intentionally absent from generated human docs (see [Contextless coverage](#contextless-coverage)). |
| `unmapped` | object | yes | LLM | Legacy migration globs for repo paths intentionally not owned by any module. Prefer `contextless.entries`. |
| `coverage` | object | yes | post-step | Deterministic counts emitted after path classification (see [Coverage](#coverage)). |

### Field Ownership

The build pipeline has two phases. The LLM authors the structural and semantic content. A deterministic post-step fills computed/derivative values so they cannot drift.

- **LLM-authored fields:** `schemaVersion`, `edcVersion`, `repoContextFile`, `reports`, `build`, `policy`, `modules[]`, `contextless.entries[]`, legacy `unmapped.allowedGlobs`.
- **Post-step deterministic fill:** `generatedAt`, `sourceCommit`, `coverage.contextMappedFileCount`, `coverage.contextlessFileCount`, `coverage.uncoveredFileCount`, `coverage.ambiguousPathCount`, `coverage.ignoredFileCount`, `coverage.ignoreSource`, `coverage.ignoreGlobs`, and deprecated aliases `coverage.mappedFileCount` / `coverage.unmappedFileCount`.

The LLM SHOULD emit the post-step fields as placeholders (e.g. empty string, `0`); the post-step overwrites them. `edc doctor` flags any manifest where the LLM-authored placeholder leaked into the final file.

---

## `reports`

Map of canonical report name to file path. Standard keys:

| Key | Path |
|---|---|
| `issues` | `edc-context/reports/issues.md` |
| `complexity` | `edc-context/reports/complexity.md` |

Adapters MAY add extra report keys (e.g. `security`, `performance`); unknown keys MUST be preserved by `edc update`.

## `build`

| Key | Path |
|---|---|
| `buildInfoFile` | `edc-context/build/build.json` |

Build provenance only. Runtime adapters MUST NOT auto-load it.

---

## `policy`

| Field | Type | Required | Description |
|---|---|---|---|
| `defaultMode` | enum: `"advisory"` \| `"inject"` | yes | Repo-default runtime mode. `advisory` means EDC only ships docs and instructions; `inject` means the harness auto-loads the matching module doc when it can. Flip with `edc mode advisory\|inject`. |
| `guardedTools` | string[] | optional | Tools that, in inject installs, are gated on the matching module doc being loaded. Conventional values: `read`, `edit`, `write`. |
| `discoveryGatedOnIndex` | string[] | optional | Tools gated only on `edc-context/index.md` having been loaded. Conventional values: `grep`, `glob`, `find`, `ls`. |
| `bootstrapAlwaysReadable` | string[] (globs) | optional | Paths always readable regardless of which module docs have been loaded. Defaults to `edc-context/**`, `AGENTS.md`, `EDC_AGENTS.md`, `.edc/**`, `LICENSE*`, `package.json`, `Cargo.toml`, `*.lock`, `.gitignore`, `.editorconfig`. |
| `unmatchedPathPolicy` | enum: `"warn-allow"` \| `"allow"` \| `"fail"` | yes | Behavior for code paths that match no module. Default authoring SHOULD use `"warn-allow"`: unmatched paths are warned and allowed so the manifest stays an honest contract instead of blocking new code. `"allow"` suppresses warnings; `"fail"` makes review task generation reject unmatched paths. |

---

## `modules[]`

Each entry routes a slice of the repo to a deep module doc.

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Stable module identifier. Lowercase, kebab-case. Used as the registry key for the loaded-set in inject mode. |
| `doc` | string (path) | yes | Path to the module doc, normally `edc-context/modules/<name>.md`. |
| `summary` | string | yes | One-sentence module description. |
| `priority` | integer | yes | Tie-breaker for ambiguous matches. Higher wins. Default convention: `100`. |
| `match` | object | yes | Path-matching predicates (see below). |

### `match`

| Field | Type | Required | Description |
|---|---|---|---|
| `exactFiles` | string[] (repo-relative paths) | optional | Literal file paths owned by this module. Highest-precedence routing tier. |
| `prefixes` | string[] (repo-relative path prefixes) | optional | Directory prefixes. Longest-prefix wins within this tier. |
| `globs` | string[] (repo-relative globs) | optional | Glob patterns using the EDC dialect: `*` matches within one path segment, `**` may cross `/`, `?` matches one non-`/` character, and character classes are supported. Any match counts; precedence among globs is broken only by `priority`. |

At least one of `exactFiles`, `prefixes`, `globs` MUST be non-empty.

---

## Path classification algorithm

`classify-cli.mjs` is the deterministic batch classifier used by manifest, doctor, review, and JS adapters. It reads repo-relative paths on stdin and emits `<path>\t<state>` for each path. Given a repo-relative path `P`, it returns exactly one state: `ignored`, `context-module:<module>`, `contextless:<entryId>:<reviewPolicy>`, `uncovered`, or `ambiguous`.

First apply resolved ignore rules. Ignored paths return `ignored`. Otherwise, resolve the owning module by walking three precedence tiers in order and stopping at the first tier that produces a winner:

1. **Tier 1 — `match.exactFiles`:** if any module lists `P` literally in its `exactFiles`, that module wins.
2. **Tier 2 — `match.prefixes` (longest-prefix wins):** of all modules whose `prefixes` contain a string that is a prefix of `P`, the module with the **longest matching prefix** wins. Length is measured in characters of the prefix string after normalizing trailing slashes.
3. **Tier 3 — `match.globs`:** any module whose `globs` match `P`. In EDC globs, `*` does not cross `/`; use `**` when a match should span nested directories.

Across all tiers, ties are broken by higher `priority` (numeric, larger wins). If two or more modules match `P` at the **same effective tier with equal `priority`**, the path is **ambiguous**:

- The post-step increments `coverage.ambiguousPathCount`.
- `edc doctor` reports the path and the conflicting modules.
- Runtime adapters MUST treat the path as if no module owned it (fall through to `unmatchedPathPolicy`).

Notes:

- A literal `exactFiles` hit always beats any prefix/glob match — even a longer prefix or a higher-priority glob.
- Within Tier 2, a longer prefix beats a shorter one regardless of `priority`. `priority` only resolves ties between equal-length prefixes.
- Within Tier 3, all matching globs are at the same tier; only `priority` orders them.
- Paths matching no module tier are checked against `contextless.entries[].globs` and then legacy `unmapped.allowedGlobs` (as generated `contextless:legacy-unmapped:account-only`).
- A path matching both a context module and a contextless entry, or multiple distinct contextless entries, is `ambiguous`.
- A path matching neither a context module nor contextless coverage is `uncovered`; `edc doctor` fails uncovered tracked paths.

---

## Contextless coverage

`contextless.entries` accounts for paths that are tracked and covered but should not receive generated human module docs.

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | kebab-case string | yes | Stable accounting identifier; not a module name. |
| `globs` | string[] | yes | Repo-relative globs covered by this entry. |
| `reason` | string | yes | Short rationale for why durable human context is not useful here. |
| `reviewPolicy` | enum | yes | One of `account-only`, `promotion-check`, or `no-context-review`. |

Review policies:

- `account-only`: include in accounting/final metadata; no spawned review task.
- `promotion-check`: group into one bounded no-context task that only asks whether update should promote durable context.
- `no-context-review`: create direct no-context review tasks without module docs.

---

## `unmapped`

| Field | Type | Required | Description |
|---|---|---|---|
| `allowedGlobs` | string[] | yes | Legacy compatibility globs. They are treated as generated `contextless:legacy-unmapped:account-only` entries for one release; new manifests should prefer `contextless.entries`. |

---

## `coverage`

Filled by the post-step. All counts cover the set of repo files included in `git ls-files` after applying ignore rules.

| Field | Type | Description |
|---|---|---|
| `contextMappedFileCount` | integer | Files routed to exactly one real context module. |
| `contextlessFileCount` | integer | Files covered by `contextless.entries` or legacy `unmapped.allowedGlobs`. |
| `uncoveredFileCount` | integer | Files matching neither a module nor contextless coverage. Doctor fails these. |
| `ambiguousPathCount` | integer | Files with ambiguous module/contextless classification. |
| `ignoredFileCount` | integer | Files excluded by resolved ignore rules. |
| `ignoreSource` | string | `flags`, `file`, or `none`. |
| `ignoreGlobs` | string[] | Effective ignore globs used for counters. |
| `mappedFileCount` | integer | Deprecated alias for `contextMappedFileCount` for one release. |
| `unmappedFileCount` | integer | Deprecated alias for `contextlessFileCount + uncoveredFileCount` for one release. |

---

## Validation Rules

`edc doctor` fails when any of the following hold:

1. `schemaVersion` is missing or not equal to `2`.
2. `edcVersion`, `repoContextFile`, `reports.issues`, `reports.complexity`, `build.buildInfoFile`, `policy.defaultMode`, `policy.unmatchedPathPolicy`, or `unmapped.allowedGlobs` is missing.
3. `policy.defaultMode` is not one of `"advisory"`, `"inject"`.
4. `policy.unmatchedPathPolicy` is not one of `"warn-allow"`, `"allow"`, or `"fail"`.
5. `modules` is empty.
6. Two modules share the same `name`.
7. A module's `doc` path does not exist on disk.
8. A module declares an empty `match` (no `exactFiles`, `prefixes`, or `globs`).
9. The same path appears in `exactFiles` of two different modules (always-ambiguous; cannot be resolved by `priority`).
10. `contextless.entries[]` has an invalid id, empty globs/reason, or reviewPolicy outside `account-only`, `promotion-check`, `no-context-review`.
11. `coverage.ambiguousPathCount > 0`.
12. `coverage.uncoveredFileCount > 0`.
13. `generatedAt` is not a valid ISO-8601 UTC timestamp.
14. `sourceCommit` is empty or not a 40-char hex SHA.
15. The post-step left `generatedAt`, `sourceCommit`, or any `coverage.*` field at the LLM placeholder value.

---

## Full Annotated Example

```json
{
  // schema and edc release this manifest was produced against
  "schemaVersion": 2,
  "edcVersion": "2.0.0",

  // post-step fills these deterministically; LLM emits placeholders
  "generatedAt": "2026-04-30T12:34:56Z",
  "sourceCommit": "18b6a1b6803c4fbb3b1d6fa05b4d2c0c5f3e9a11",

  // operational context index agents load first
  "repoContextFile": "edc-context/index.md",

  // canonical reports under edc-context/reports/
  "reports": {
    "issues": "edc-context/reports/issues.md",
    "complexity": "edc-context/reports/complexity.md"
  },

  // build provenance; not auto-loaded
  "build": {
    "buildInfoFile": "edc-context/build/build.json"
  },

  // enforcement and gating policy
  "policy": {
    // build-time default; "advisory" or "inject" only
    "defaultMode": "advisory",

    // tools gated on the matching module doc being loaded (inject only)
    "guardedTools": ["read", "edit", "write"],

    // tools gated only on edc-context/index.md being loaded
    "discoveryGatedOnIndex": ["grep", "glob", "find", "ls"],

    // always-readable bootstrap paths (no gate)
    "bootstrapAlwaysReadable": [
      "edc-context/**",
      "AGENTS.md",
      "EDC_AGENTS.md",
      ".edc/**",
      "LICENSE*",
      "package.json",
      "Cargo.toml",
      "*.lock",
      ".gitignore",
      ".editorconfig"
    ],

    // unmatched paths are warned and allowed; edc doctor flags the gap
    "unmatchedPathPolicy": "warn-allow"
  },

  // module routing entries
  "modules": [
    {
      "name": "consensus",
      "doc": "edc-context/modules/consensus.md",
      "summary": "Chain state, block validation, fork choice, difficulty math.",
      "priority": 100,
      "match": {
        "exactFiles": [
          "chia/consensus/blockchain.py",
          "chia/consensus/block_creation.py"
        ],
        "prefixes": ["chia/consensus/"],
        "globs": ["chia/consensus/**"]
      }
    },
    {
      "name": "consensus-tests",
      "doc": "edc-context/modules/consensus-tests.md",
      "summary": "Consensus-layer test suite.",
      // higher priority wins ties at the same tier
      "priority": 110,
      "match": {
        "prefixes": ["chia/consensus/tests/"],
        "globs": ["chia/consensus/tests/**"]
      }
    }
  ],

  // machine-only coverage for paths intentionally absent from human docs
  "contextless": {
    "entries": [
      {
        "id": "supporting-docs",
        "globs": ["README.md", "docs/**"],
        "reason": "public/supporting docs; no durable agent-only ownership contract",
        "reviewPolicy": "account-only"
      },
      {
        "id": "generated-assets",
        "globs": ["assets/**"],
        "reason": "generated assets without durable source-edit guidance",
        "reviewPolicy": "promotion-check"
      }
    ]
  },

  // legacy migration compatibility; prefer contextless.entries
  "unmapped": {
    "allowedGlobs": ["benchmarks/**"]
  },

  // post-step deterministic fill; counts cover git ls-files after ignore rules
  "coverage": {
    "contextMappedFileCount": 0,
    "contextlessFileCount": 0,
    "uncoveredFileCount": 0,
    "ambiguousPathCount": 0,
    "ignoredFileCount": 0,
    "ignoreSource": "none",
    "ignoreGlobs": [],
    "mappedFileCount": 0,
    "unmappedFileCount": 0
  }
}
```

In this example, `chia/consensus/tests/test_blockchain.py` resolves as follows:
- Tier 1 (`exactFiles`): no hit.
- Tier 2 (`prefixes`): both `consensus` (`chia/consensus/`) and `consensus-tests` (`chia/consensus/tests/`) match. Longest-prefix wins → `consensus-tests`. `priority` is not consulted because the prefixes differ in length.

A file like `chia/consensus/blockchain.py` resolves at Tier 1 directly to `consensus`, even though `consensus-tests` has higher `priority` — exactFiles always beats prefixes.

---

## Agent entrypoint template

`edc build` emits a short EDC startup-orientation file at the repo root. The default path is `AGENTS.md`; when a repo already owns `AGENTS.md`, the build prompt may set `EDC_AGENTS_TARGET: EDC_AGENTS.md` so EDC preserves existing instructions and tells the user how to replace, append, or reference the generated file. The generated EDC entrypoint MUST contain the following sections in order:

1. **Startup orientation header.** A short title and one-paragraph statement of what this file is and why the agent should read it first. Example:
   ```md
   # Agent Instructions

   This repo ships deep architectural context generated by EDC. Read this file at session start before touching code.
   ```

2. **Link to `edc-context/index.md` operational index.** A pointer to the routing-first index, with a single sentence about what it contains:
   ```md
   ## Overview

   See [`edc-context/index.md`](edc-context/index.md) for the routing index, critical invariants, and coupling/blast-radius guidance.
   ```

3. **Link to `edc-context/manifest.json` routing contract.** A pointer to the manifest as the authoritative routing and policy contract:
   ```md
   ## Routing Contract

   See [`edc-context/manifest.json`](edc-context/manifest.json) for the authoritative path→module routing contract, enforcement policy, and report locations. Runtime adapters consult this file directly; do not duplicate or paraphrase its rules.
   ```

4. **Statement of the runtime mode.** A line reflecting `policy.defaultMode` from `edc-context/manifest.json`:
   ```md
   ## Runtime Mode

   Runtime mode: **inject**. The harness auto-loads the matching module doc from `edc-context/modules/<name>.md` before guarded operations.
   ```
   For `advisory`:
   ```md
   Runtime mode: **advisory**. EDC ships docs only; loading is best-effort. Read `edc-context/index.md` first, then the relevant `edc-context/modules/<name>.md`.
   ```

`edc build` MUST emit all four sections to the configured EDC agent entrypoint. Flip the runtime mode at any time with `edc mode advisory|inject`; rebuilds preserve the existing value.
