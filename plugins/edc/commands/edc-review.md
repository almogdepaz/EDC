---
name: edc:edc-review
description: Internal — invokes the review skill for a single module (used by the orchestrator, not called directly by users)
argument-hint: "--task-file <path>"
allowed-tools:
  - Skill
  - Read
  - Write
  - Grep
  - Glob
  - Bash
---

# Differential Review (per-module)

**Arguments:** $ARGUMENTS

Invoke the `edc-review-impl` skill and follow its instructions exactly. Pass through the arguments above.
