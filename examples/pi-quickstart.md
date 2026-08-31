# EDC Pi Quickstart

This quickstart shows the shortest path from a fresh Pi install to a context-aware review.

## 1. Install

```bash
pi install npm:@sgtbeatdown/edc
```

Restart Pi or run `/reload` in existing sessions so Pi loads the new extension.

## 2. Open a repository

```bash
cd path/to/your/git-repo
pi
```

In a plain repository with no EDC context yet, startup should be quiet:

- no EDC prompt is injected
- workflows use the installed package or managed `~/.edc` runtime
- repo-local `.edc/` is ignored and never created; remove old caches manually
- EDC skills are still available globally

## 3. Build context

Run:

```text
/edc
```

Choose **build context**. EDC will generate repository context such as:

- `edc-context/index.md`
- `edc-context/manifest.json`
- `edc-context/modules/*.md`
- `AGENTS.md` or `EDC_AGENTS.md`

## 4. Review changes

Run `/edc` again and choose:

1. **changes vs default branch**
2. a review lens:
   - **combined** — security + delivery/architecture + quality
   - **security** — adversarial/security review
   - **delivery** — spec/goal and architecture-fit review
   - **quality** — maintainability and simplification review

EDC runs the selected workflow in the background and stores operational status under `.git/edc/`.

## 5. Check status

Run `/edc` → **job status**.

Typical outputs include status, scope, base branch, log path, report path, and structured failure hints when something goes wrong.

## Useful links

- Pi package: <https://pi.dev/packages/@sgtbeatdown/edc>
- npm package: <https://www.npmjs.com/package/@sgtbeatdown/edc>
- Agent summary: [`../llms.txt`](../llms.txt)
