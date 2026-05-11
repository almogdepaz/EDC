# Decouple EDC CLI from Claude Plugin

## Goal

Two independent installation paths, each fully functional alone:

1. **CLI path** (`bash install.sh --agent claude`): installs `~/.edc/scripts/`
   + `~/.edc/skills/`. `edc build|update|review|audit` works without
   any claude plugin installed. Slash commands (`/edc:edc-build` etc.)
   do NOT work — that's the plugin's job.

2. **Plugin path** (`claude plugin install edc@edc`): installs slash
   commands + hooks under `~/.claude/plugins/`. Slash commands work in
   interactive claude. **Plugin still requires `~/.edc/scripts/` on disk**
   (orchestrators are heavy shell logic; not duplicated). Plugin install
   docs/messaging will tell user to run `bash install.sh --agent claude`
   first or alongside.

## Current Broken Behavior (root cause)

- `resolve_prompt()` claude branch emits `/edc:edc-build` slash commands.
- `claude -p` returns "Unknown command" (exit 0, no error) when plugin
  not installed, which `stream_filter` swallows silently.
- `install.sh` claude branch dumps files into `~/.claude/plugins/edc/` —
  claude's loader never reads from there (it only reads
  `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` registered
  via `claude plugin install`).

## Files Changed

### `plugins/edc/scripts/edc-resolve-prompt.sh`
- Add `find_claude_skill()` mirroring `find_cursor_skill` / `find_codex_skill`.
  Search order: `.edc/skills`, `~/.edc/skills`,
  `~/.claude/plugins/marketplaces/edc/plugins/edc/skills` (so plugin install
  alone with cli also installed satisfies it).
- Replace claude `build`/`update`/`audit`/`review` cases to use the same
  pattern as cursor/codex: find skill file, prepend optional arg-string
  prefix, cat the skill content.
- For `review` (ALL agents): embed full skill content. Read task file
  contents, then cat SKILL.md + methodology.md + adversarial.md +
  reporting.md + patterns.md inline with clear separators. Wraps with
  a strict prefix: "Follow the instructions below EXACTLY. Do not
  improvise. Do not substitute your own methodology."
- Refactor: extract a single `_emit_skill_prompt <agent> <skill> [args...]`
  helper so the build/update/audit branches across claude/cursor/codex
  collapse to one implementation. Same for review.

### `install.sh`
Claude branch (`install_claude_runtime`):
- DELETE the `cp -R "$LOCAL_PLUGIN_ROOT" "$target"` block. Dead writes.
- DELETE the entire `else` branch downloading individual files into
  `~/.claude/plugins/edc/`. Dead writes.
- KEEP `install_terminal_cli`.
- ADD: install SKILL.md trees to `~/.edc/skills/<name>/` (mirror cursor's
  layout). Use the existing `SKILLS=()` array.
- UPDATE messaging: explain that this installs the CLI only. For slash
  commands inside interactive claude, separately run:
  `claude plugin marketplace add ... && claude plugin install edc@edc`.

Cursor/codex branches: unchanged (already use SKILL.md on disk pattern).

### `README.md`
- Line 170: remove "Claude build requires the EDC Claude plugin/commands
  to already be installed" — no longer true after this change.
- Add a short "Two install paths" section explaining CLI vs plugin.

### Tests
- Add hardening test: `tests/hardening/cli-without-plugin.sh` — verify
  `resolve_prompt` for claude returns SKILL.md content (not slash commands)
  and never emits `/edc:edc-`.
- Existing hardening tests don't reference `/edc:edc-` literals (verified
  via grep), so no breakage expected.

## Out of Scope (explicit)

- Changing cursor/codex behavior. They already work.
- Making the claude plugin standalone (independent of `~/.edc/scripts`).
  User accepted this dependency in Q1.
- Fixing `stream_filter` to surface "Unknown command" results. Separate
  bug, separate fix. (Should still do it eventually — the silent failure
  bit hard.)
- Auto-installing the claude plugin from `install.sh`. Plugin install is
  the user's choice; we just give clear instructions.

## Decision Log

- Q1 (resolved): plugin depends on cli being installed. Acceptable.
- Q2 (resolved): all agents same prompt-resolution pattern.
- Q3 (resolved): embed full skill content for review across all agents.
  Token cost accepted in exchange for zero wiggle room.

## Token Cost Estimate

`edc-review-impl/` files combined: roughly 30–50 KB markdown. This gets
embedded once per per-module review subprocess. Typical review = 5–15
modules. Net per-review token increase: ~30–60k input tokens beyond
today's baseline. Not free, but well within model context budgets and
worth the determinism per user requirement.

## Status

- [x] approval to start (pending — awaiting explicit go)
- [x] Q1, Q2, Q3 decided
- [ ] resolve_prompt.sh edits + helper extraction
- [ ] install.sh edits (claude branch decoupling, ~/.edc/skills install)
- [ ] README.md edits
- [ ] hardening test: verify resolve_prompt(claude, build) emits skill
      content and never `/edc:edc-`
- [ ] hardening test: verify resolve_prompt(*, review) embeds all five
      review files
- [ ] manual verification: rm -rf .context && edc review --agent claude
      --base main in wolfpack with plugin DISABLED in claude settings
- [ ] manual verification: plugin alone (no ~/.edc/scripts) prints clear
      SCRIPT_MISSING error from slash command wrapper
