# Cursor Adapter Status

Cursor uses the shared terminal wrapper plus the `.cursor/commands/` prompt adapters in this repo.

The v2 context layout is supported by the prompt surface and session-start rule, but explicit `--context-mode advisory|inject` install flows are not implemented yet. Both modes fail loudly with:

```text
edc: cursor/<mode> not yet implemented
```
