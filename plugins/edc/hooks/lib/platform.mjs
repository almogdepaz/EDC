// Detects the host agent runtime from a hook input payload.
// Cursor payloads carry one of `conversation_id`, `cursor_version`, or
// `workspace_roots`; Claude Code payloads do not.
export function detectPlatform(input) {
  if (
    input &&
    ("conversation_id" in input ||
      "cursor_version" in input ||
      "workspace_roots" in input)
  ) {
    return "cursor";
  }
  return "claude-code";
}
