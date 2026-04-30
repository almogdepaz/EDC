# `manifest.json` Schema Reference (v2)

`/.context/manifest.json` is the authoritative machine-readable routing and policy contract for an EDC-built repo. It replaces the v1 `.context/.meta.json` and is the only document runtime adapters consult to map repo paths to module docs and to decide enforcement behavior.

This document is the canonical schema spec. `edc build`, `edc update`, and `edc doctor` MUST honor it. Runtime adapters (Claude hooks, Pi extensions, Cursor/Codex/Gemini wrappers) MUST treat it as the single source of truth.

---

## Top-Level Fields

| Field | Type | Required | Owner | Description |
|---|---|---|---|---|
| `schemaVersion` | integer | yes | LLM | Manifest schema version. Currently `2`. |
| `edcVersion` | string (semver) | yes | LLM | EDC release that produced the manifest, e.g. `"2.0.0"`. |
| `generatedAt` | string (ISO-8601 UTC) | yes | post-step | Timestamp filled deterministically after the build LLM step. |
| `sourceCommit` | string (full git SHA) | yes | post-step | `git rev-parse HEAD` at build time, filled deterministically after the LLM step. |
| `repoContextFile` | string (path) | yes | LLM | Path to the startup overview, normally `.context/index.md`. |
| `reports` | object | yes | LLM | Map of report name → path under `.context/reports/`. |
| `build` | object | yes | LLM | Provenance and intermediate artifact paths under `.context/build/`. |
| `policy` | object | yes | LLM | Enforcement and gating configuration (see [Policy](#policy)). |
| `modules` | array | yes | LLM | Ordered list of module routing entries (see [Modules](#modules)). |
| `unmapped` | object | yes | LLM | Globs of repo paths that are intentionally not owned by any module. |
| `coverage` | object | yes | post-step | Deterministic counts emitted after routing analysis (see [Coverage](#coverage)). |

### Field Ownership

The build pipeline has two phases. The LLM authors the structural and semantic content. A deterministic post-step fills computed/derivative values so they cannot drift.

- **LLM-authored fields:** `schemaVersion`, `edcVersion`, `repoContextFile`, `reports`, `build`, `policy`, `modules[]`, `unmapped.allowedGlobs`.
- **Post-step deterministic fill:** `generatedAt`, `sourceCommit`, `coverage.mappedFileCount`, `coverage.unmappedFileCount`, `coverage.ambiguousPathCount`.

The LLM SHOULD emit the post-step fields as placeholders (e.g. empty string, `0`); the post-step overwrites them. `edc doctor` flags any manifest where the LLM-authored placeholder leaked into the final file.

---

## `reports`

Map of canonical report name to file path. Standard keys:

| Key | Path |
|---|---|
| `issues` | `.context/reports/issues.md` |
| `complexity` | `.context/reports/complexity.md` |

Adapters MAY add extra report keys (e.g. `security`, `performance`); unknown keys MUST be preserved by `edc update`.

## `build`

| Key | Path |
|---|---|
| `fullContextFile` | `.context/build/full-context.md` |
| `buildInfoFile` | `.context/build/build.json` |

These are intermediate artifacts. Runtime adapters MUST NOT auto-load them.

---

## `policy`

| Field | Type | Required | Description |
|---|---|---|---|
| `defaultMode` | enum: `"advisory"` \| `"inject"` | yes | Repo-default runtime mode. `advisory` means EDC only ships docs and instructions; `inject` means the harness auto-loads the matching module doc when it can. The two valid values are `advisory` and `inject`. (The `strict` mode is set at install time and is not encoded in `policy.defaultMode`.) |
| `guardedTools` | string[] | optional | Tools that, in inject/strict installs, are gated on the matching module doc being loaded. Conventional values: `read`, `edit`, `write`. |
| `discoveryGatedOnIndex` | string[] | optional | Tools gated only on `.context/index.md` having been loaded. Conventional values: `grep`, `glob`, `find`, `ls`. |
| `bootstrapAlwaysReadable` | string[] (globs) | optional | Paths always readable regardless of which module docs have been loaded. Defaults to `.context/**`, `AGENTS.md`, `.edc/**`, `LICENSE*`, `package.json`, `Cargo.toml`, `*.lock`, `.gitignore`, `.editorconfig`. |
| `unmatchedPathPolicy` | enum: `"warn-allow"` | yes | Behavior for code paths that match no module. v2 only defines `"warn-allow"`: edits/writes against unmatched paths are warned and allowed; `edc doctor` flags the gap. This keeps the manifest an honest contract instead of a precondition for adding new code. |

`defaultMode` lists `advisory` and `inject` because those are the values a build can sensibly default to without harness-specific install state. `strict` is a runtime install choice (selected via `edc install --context-mode strict`) and is recorded in installed runtime artifacts, not in the manifest's default.

---

## `modules[]`

Each entry routes a slice of the repo to a deep module doc.

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Stable module identifier. Lowercase, kebab-case. Used as the registry key for the loaded-set in inject/strict modes. |
| `doc` | string (path) | yes | Path to the module doc, normally `.context/modules/<name>.md`. |
| `summary` | string | yes | One-sentence module description. |
| `priority` | integer | yes | Tie-breaker for ambiguous matches. Higher wins. Default convention: `100`. |
| `match` | object | yes | Path-matching predicates (see below). |

### `match`

| Field | Type | Required | Description |
|---|---|---|---|
| `exactFiles` | string[] (repo-relative paths) | optional | Literal file paths owned by this module. Highest-precedence routing tier. |
| `prefixes` | string[] (repo-relative path prefixes) | optional | Directory prefixes. Longest-prefix wins within this tier. |
| `globs` | string[] (repo-relative globs) | optional | Glob patterns. Any match counts; precedence among globs is broken only by `priority`. |

At least one of `exactFiles`, `prefixes`, `globs` MUST be non-empty.

---

## Path → Module Routing Algorithm

Given a repo-relative path `P`, resolve the owning module by walking three precedence tiers in order and stopping at the first tier that produces a winner:

1. **Tier 1 — `match.exactFiles`:** if any module lists `P` literally in its `exactFiles`, that module wins.
2. **Tier 2 — `match.prefixes` (longest-prefix wins):** of all modules whose `prefixes` contain a string that is a prefix of `P`, the module with the **longest matching prefix** wins. Length is measured in characters of the prefix string after normalizing trailing slashes.
3. **Tier 3 — `match.globs`:** any module whose `globs` match `P`.

Across all tiers, ties are broken by higher `priority` (numeric, larger wins). If two or more modules match `P` at the **same effective tier with equal `priority`**, the path is **ambiguous**:

- The post-step increments `coverage.ambiguousPathCount`.
- `edc doctor` reports the path and the conflicting modules.
- Runtime adapters MUST treat the path as if no module owned it (fall through to `unmatchedPathPolicy`).

Notes:

- A literal `exactFiles` hit always beats any prefix/glob match — even a longer prefix or a higher-priority glob.
- Within Tier 2, a longer prefix beats a shorter one regardless of `priority`. `priority` only resolves ties between equal-length prefixes.
- Within Tier 3, all matching globs are at the same tier; only `priority` orders them.
- Paths matching no tier are unmapped. They are checked against `unmapped.allowedGlobs`. Unmapped paths NOT in `allowedGlobs` are counted in `coverage.unmappedFileCount` and flagged by `edc doctor`.

---

## `unmapped`

| Field | Type | Required | Description |
|---|---|---|---|
| `allowedGlobs` | string[] | yes | Globs of repo paths that are intentionally not owned by any module (e.g. `README.md`, `docs/**`, `benchmarks/**`). Paths matched by these globs do not count as missing coverage. |

---

## `coverage`

Filled by the post-step. All counts cover the set of repo files included in `git ls-files` after applying ignore rules.

| Field | Type | Description |
|---|---|---|
| `mappedFileCount` | integer | Files routed to exactly one module. |
| `unmappedFileCount` | integer | Files matching no module and not covered by `unmapped.allowedGlobs`. |
| `ambiguousPathCount` | integer | Files where two or more modules tied at the same tier with equal `priority`. |

---

## Validation Rules

`edc doctor` fails when any of the following hold:

1. `schemaVersion` is missing or not equal to `2`.
2. `edcVersion`, `repoContextFile`, `reports.issues`, `reports.complexity`, `build.fullContextFile`, `build.buildInfoFile`, `policy.defaultMode`, `policy.unmatchedPathPolicy`, or `unmapped.allowedGlobs` is missing.
3. `policy.defaultMode` is not one of `"advisory"`, `"inject"`.
4. `policy.unmatchedPathPolicy` is not `"warn-allow"`.
5. `modules` is empty.
6. Two modules share the same `name`.
7. A module's `doc` path does not exist on disk.
8. A module declares an empty `match` (no `exactFiles`, `prefixes`, or `globs`).
9. The same path appears in `exactFiles` of two different modules (always-ambiguous; cannot be resolved by `priority`).
10. `coverage.ambiguousPathCount > 0`.
11. `coverage.unmappedFileCount > 0` for paths not covered by `unmapped.allowedGlobs`.
12. `generatedAt` is not a valid ISO-8601 UTC timestamp.
13. `sourceCommit` is empty or not a 40-char hex SHA.
14. The post-step left `generatedAt`, `sourceCommit`, or any `coverage.*` field at the LLM placeholder value.

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

  // startup overview agents load first
  "repoContextFile": ".context/index.md",

  // canonical reports under .context/reports/
  "reports": {
    "issues": ".context/reports/issues.md",
    "complexity": ".context/reports/complexity.md"
  },

  // intermediate provenance artifacts; not auto-loaded
  "build": {
    "fullContextFile": ".context/build/full-context.md",
    "buildInfoFile": ".context/build/build.json"
  },

  // enforcement and gating policy
  "policy": {
    // build-time default; "advisory" or "inject" only
    "defaultMode": "inject",

    // tools gated on the matching module doc being loaded (inject/strict)
    "guardedTools": ["read", "edit", "write"],

    // tools gated only on .context/index.md being loaded
    "discoveryGatedOnIndex": ["grep", "glob", "find", "ls"],

    // always-readable bootstrap paths (no gate)
    "bootstrapAlwaysReadable": [
      ".context/**",
      "AGENTS.md",
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
      "doc": ".context/modules/consensus.md",
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
      "doc": ".context/modules/consensus-tests.md",
      "summary": "Consensus-layer test suite.",
      // higher priority wins ties at the same tier
      "priority": 110,
      "match": {
        "prefixes": ["chia/consensus/tests/"],
        "globs": ["chia/consensus/tests/**"]
      }
    }
  ],

  // paths intentionally outside any module
  "unmapped": {
    "allowedGlobs": [
      "README.md",
      "docs/**",
      "benchmarks/**"
    ]
  },

  // post-step deterministic fill; counts cover git ls-files after ignore rules
  "coverage": {
    "mappedFileCount": 0,
    "unmappedFileCount": 0,
    "ambiguousPathCount": 0
  }
}
```

In this example, `chia/consensus/tests/test_blockchain.py` resolves as follows:
- Tier 1 (`exactFiles`): no hit.
- Tier 2 (`prefixes`): both `consensus` (`chia/consensus/`) and `consensus-tests` (`chia/consensus/tests/`) match. Longest-prefix wins → `consensus-tests`. `priority` is not consulted because the prefixes differ in length.

A file like `chia/consensus/blockchain.py` resolves at Tier 1 directly to `consensus`, even though `consensus-tests` has higher `priority` — exactFiles always beats prefixes.

---

## `AGENTS.md` Template

`edc build` emits `AGENTS.md` at the repo root as the universal startup-orientation file for any agent harness that honors repo instruction files. It MUST contain the following sections in order:

1. **Startup orientation header.** A short title and one-paragraph statement of what this file is and why the agent should read it first. Example:
   ```md
   # Agent Instructions

   This repo ships deep architectural context generated by EDC. Read this file at session start before touching code.
   ```

2. **Link to `.context/index.md` overview.** A pointer to the startup overview, with a single sentence about what it contains:
   ```md
   ## Overview

   See [`.context/index.md`](.context/index.md) for the architecture overview, actor map, key flows, global invariants, and module table.
   ```

3. **Link to `.context/manifest.json` routing contract.** A pointer to the manifest as the authoritative routing and policy contract:
   ```md
   ## Routing Contract

   See [`.context/manifest.json`](.context/manifest.json) for the authoritative path→module routing contract, enforcement policy, and report locations. Runtime adapters consult this file directly; do not duplicate or paraphrase its rules.
   ```

4. **Statement of the installed runtime mode.** A line declaring which mode (`advisory`, `inject`, or `strict`) is installed for this repo. If no runtime is installed yet, say so:
   ```md
   ## Runtime Mode

   Installed runtime mode: **inject**. The harness auto-loads the matching module doc from `.context/modules/<name>.md` before guarded operations.
   ```
   For `strict`:
   ```md
   Installed runtime mode: **strict**. Code-touching tools are gated on the matching `.context/modules/<name>.md` having been Read in this session. Discovery tools are gated on `.context/index.md`.
   ```
   For `advisory` or no install:
   ```md
   Installed runtime mode: **advisory**. EDC ships docs only; loading is best-effort. Read `.context/index.md` first, then the relevant `.context/modules/<name>.md`.
   ```

`edc build` MUST emit all four sections. `edc install --context-mode <mode>` MUST rewrite the runtime-mode section in place to match the installed mode.
