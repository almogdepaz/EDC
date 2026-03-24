# EDC — Your Every Day Carry Skills

Claude Code plugin for deep codebase understanding and context-aware code review.

## Commands

| Command | What it does |
|---------|-------------|
| `/edc:build-context` | Builds deep architectural context. Auto-detects: full build on new repos, incremental update on existing ones. |
| `/edc:review <pr>` | Context-aware differential review. Ensures context is fresh before reviewing. |
| `/edc:split-context` | Splits full analysis into navigable per-module files. |
| `/edc:update-context` | Incrementally updates context based on branch changes. |

## How it works

**Build context** analyzes every function in your codebase with the [Trail of Bits audit methodology](https://github.com/trailofbits/skills) — line-by-line, block-by-block, with First Principles, 5 Whys, and 5 Hows. Produces:

- `context.md` — brief architecture map (actors, flows, invariants, trust boundaries)
- `.context/{module}.md` — deep per-module analysis
- `.context/issues.md` — actionable list of all problems found
- `.context/full-context.md` — complete monolithic analysis
- `.context/.meta.json` — metadata for incremental updates

**Review** uses the context files to catch things a blind diff review would miss: invariant violations, cross-module breakage, regression of known issues.

## Install

```bash
claude plugins install edc@wolfpack-plugins
```

## Skills

Built on two generalized skills from Trail of Bits:

- **deep-context-building** — ultra-granular code analysis (generalized from `audit-context-building`)
- **differential-review** — structured code review with blast radius, adversarial modeling, and reporting (generalized from `differential-review`)

Both generalized from Solidity/smart-contract focus to work with any language and any codebase.
