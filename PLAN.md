# EDC Plugin — Implementation Plan

## Vision

EDC (Engineering Deep Context) is a Claude Code plugin that builds persistent, structured codebase context and uses it for high-signal PR reviews. The core insight: reviews are better when the reviewer deeply understands the codebase architecture, invariants, and coupling — not just the diff.

## Current State (v0.2.0)

- [x] Marketplace created (`almogdepaz/wolfpack-plugins`, private)
- [x] Plugin `edc` installed and enabled
- [x] `/edc:build-context` command — full codebase analysis, outputs `context.md` + `.context/*.md`
- [x] `/edc:review` command — context-aware PR review with confidence scoring
- [ ] Neither command has been tested on a real codebase yet

## Output Structure

```
repo/
├── context.md              # brief architecture intro (~50-100 lines)
│   ├── system overview
│   ├── module map (table with links to .context/*.md)
│   ├── actor model
│   ├── key flows
│   ├── global invariants
│   ├── trust boundaries
│   └── cross-module coupling
│
└── .context/               # per-module deep analysis
    ├── server.md           # full micro-analysis for src/server/
    ├── cli.md              # full micro-analysis for src/cli/
    ├── public.md           # PWA frontend analysis
    └── ...
```

## Phase 1 — Validate & Refine `/build-context` (current)

**Goal**: Run on wolfpack, evaluate output quality, iterate on prompt.

- [ ] 1.1 Run `/edc:build-context` on wolfpack repo
- [ ] 1.2 Evaluate output:
  - Is `context.md` actually brief? (target: 50-100 lines)
  - Does the module map correctly identify all modules?
  - Are `.context/*.md` files appropriately scoped (not too big, not too granular)?
  - Is the micro-analysis useful or bloated?
- [ ] 1.3 Tune prompt based on evaluation:
  - Adjust granularity (function-level analysis may be overkill for some codebases)
  - Calibrate what "non-trivial function" means
  - Define sensible module boundaries (directory-based? logical grouping?)
- [ ] 1.4 Add `.context/` to `.gitignore` template or not (user decides per-repo)
- [ ] 1.5 Re-run after tuning, compare output quality

## Phase 2 — Incremental Updates

**Goal**: Don't regenerate everything on every run.

- [ ] 2.1 Detect which files changed since last `/build-context` run (git diff against a stored commit SHA)
- [ ] 2.2 Only regenerate `.context/*.md` for modules with changed files
- [ ] 2.3 Re-synthesize `context.md` if module map or global invariants changed
- [ ] 2.4 Store metadata (last build commit, module→files mapping) in `.context/.meta.json`
- [ ] 2.5 Add `--force` flag to regenerate everything regardless

## Phase 3 — Validate & Refine `/review`

**Goal**: Run on a real PR, evaluate review quality.

- [ ] 3.1 Create a test PR on wolfpack
- [ ] 3.2 Run `/edc:review` against it
- [ ] 3.3 Evaluate:
  - Does it correctly load only relevant `.context/*.md` files?
  - Are the findings high-signal or noisy?
  - Does the confidence scoring effectively filter false positives?
  - Is the cross-module impact agent useful?
- [ ] 3.4 Tune agent prompts based on evaluation
- [ ] 3.5 Consider adding CLAUDE.md compliance agent (from code-review plugin)

## Phase 4 — Context Splitting Improvements

**Goal**: Right-size the context files for agent consumption.

- [ ] 4.1 Define max file size target for `.context/*.md` (e.g., 500 lines)
- [ ] 4.2 If a module is too large, split into sub-modules (e.g., `.context/server/routes.md`, `.context/server/websocket.md`)
- [ ] 4.3 Add a "relevance score" to function analyses so agents can skip low-relevance entries
- [ ] 4.4 Consider a `.context/index.json` that maps file paths → relevant context files (faster lookup for /review)

## Phase 5 — Custom Analysis Profiles

**Goal**: Different analysis depth for different use cases.

- [ ] 5.1 `--profile security` — emphasize trust boundaries, input validation, auth flows
- [ ] 5.2 `--profile architecture` — emphasize module coupling, data flows, public interfaces
- [ ] 5.3 `--profile onboarding` — emphasize high-level understanding, skip micro-analysis
- [ ] 5.4 Profiles stored in `.context/.profiles/` or as frontmatter in context.md

## Phase 6 — Additional Commands

- [ ] 6.1 `/edc:status` — show what context exists, when it was last built, which modules are stale
- [ ] 6.2 `/edc:update` — incremental update (alias for `build-context` with change detection)
- [ ] 6.3 `/edc:query <question>` — ask a question about the codebase using context files as grounding
- [ ] 6.4 `/edc:diff` — show what changed in the codebase since context was last built

## Phase 7 — Plugin Infrastructure

- [ ] 7.1 Add a skill (auto-injected) that loads relevant `.context/*.md` when editing files in the repo
- [ ] 7.2 Add hooks that warn if context is stale (files changed since last build)
- [ ] 7.3 Add README.md to the marketplace repo
- [ ] 7.4 Consider open-sourcing the marketplace repo

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Context file format | Markdown | Human-readable, works with git diff, agents parse it natively |
| Module detection | Directory-based (auto) | Simple, predictable, matches most project structures |
| Analysis methodology | Trail of Bits audit-context | Proven, thorough, will customize over time |
| Confidence threshold | 80 (from code-review plugin) | Aggressive filtering reduces noise; can lower if needed |
| Context storage | Committed to repo | Shared across team, versioned, survives branch switches |
| Context location | `.context/` directory | Stays out of the way, easy to gitignore if wanted |

## Open Questions

- Should context.md include a version/timestamp to detect staleness?
- How to handle monorepos with multiple services?
- Should `/review` update context.md if it discovers the context is wrong?
- What's the right granularity — every function, or only exported/public ones?
- Should we support context for non-code files (config, infra, CI)?
