#!/usr/bin/env python3
"""stream-json (stdin) -> text (stdout) for clean-bin/agent (plan 041).

Prints the final result text, or the assistant text if no result event
arrived. An is_error result is also copied to stderr so callers' logs show it.
"""
import json
import sys


def main() -> int:
    result, is_error, assistant = None, False, []
    for line in sys.stdin:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "result":
            result, is_error = str(event.get("result") or ""), bool(event.get("is_error"))
        elif event.get("type") == "assistant":
            for block in (event.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == "text":
                    assistant.append(block.get("text", ""))
    text = result if result is not None else "\n".join(assistant)
    if text:
        print(text)
    if is_error and text:
        print(text, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
