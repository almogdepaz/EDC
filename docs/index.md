# EDC: Context-Aware Code Review for Pi and AI Coding Agents

EDC is a local-first Pi package and agent toolkit for repository architecture maps, agent context, and context-aware code review.

It helps AI coding agents understand a repository before reviewing or changing code. EDC builds a generated `edc-context/` tree with module ownership, path routing, invariants, assumptions, and trust boundaries, then routes reviews through that context.

## Install

```bash
pi install npm:@sgtbeatdown/edc
```

Then start Pi inside a git repository and run:

```text
/edc
```

## Core workflows

- **build context** — generate `edc-context/`, module docs, routing metadata, and agent orientation.
- **review full repo** — run context-aware review across the current tracked repository.
- **review changes** — review a diff against the detected default branch or a custom base.
- **security lens** — adversarial/security review through `edc-review`.
- **delivery lens** — goal/spec and architecture-fit review through `edc-delivery-review`.
- **quality lens** — maintainability and simplification review through `edc-audit`.

## Why agents use it

AI coding agents often start with only the prompt and recently-read files. EDC gives them a persistent local map of the codebase: where modules live, which paths belong to which owner, what invariants matter, and which trust boundaries are relevant.

That makes reviews less generic. Instead of treating a diff as isolated text, EDC routes files to their module context and asks the right review lens to inspect the change.

## Package links

- Pi package: <https://pi.dev/packages/@sgtbeatdown/edc>
- npm package: <https://www.npmjs.com/package/@sgtbeatdown/edc>
- GitHub repository: <https://github.com/almogdepaz/edc>
- Agent summary: [`../llms.txt`](../llms.txt)
- Pi quickstart: [`../examples/pi-quickstart.md`](../examples/pi-quickstart.md)

## Quiet startup behavior

Installing EDC does not mean every Pi session gets injected with EDC context. In repositories without `edc-context/manifest.json`, startup is quiet and no EDC context prompt is sent. Workflows execute only the installed package or managed `~/.edc` runtime; repo-local `.edc/` is ignored and never created. Run `/edc` explicitly when you want EDC to build or use context.
