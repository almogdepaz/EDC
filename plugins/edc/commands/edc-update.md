---
name: edc:edc-update
description: Incrementally updates .context/ files based on branch changes
argument-hint: "[--base <ref>]"
allowed-tools:
  - Skill
  - Read
  - Write
  - Grep
  - Glob
  - Bash(git *)
---

# Update Context

**Arguments:** $ARGUMENTS

Invoke the `edc-update-impl` skill and follow its instructions exactly. Pass through the arguments above.
