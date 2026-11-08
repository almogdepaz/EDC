#!/usr/bin/env python3
"""Ground-truth parser for the clean benchmark (plan 041).

Reads `### <id>` blocks with `- **field:** value` lines, the format of
`benchmark/curl/ground-truth.md`. Handles CVE entries (`CVE-...`) and planted
entries (`PLANT-<project>-NN`). Unlike `parse_gt.py` (CVE-only, pipe output,
kept unchanged for the legacy runners) this returns dicts.
"""

import re
from pathlib import Path

ENTRY_RE = re.compile(r"^###\s+(\S+)\s*$")
FIELD_RE = re.compile(r"^-\s+\*\*([A-Za-z_]+):\*\*\s*(.*)$")


def _clean(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == "`" and value[-1] == "`":
        value = value[1:-1].strip()
    return value


def entry_kind(entry_id: str) -> str:
    if entry_id.startswith("CVE-"):
        return "cve"
    if entry_id.startswith("PLANT-"):
        return "planted"
    raise ValueError(f"unknown entry id kind: {entry_id}")


def parse_entries(path) -> list[dict]:
    entries: list[dict] = []
    current = None
    last_field = None
    for raw in Path(path).read_text().splitlines():
        m = ENTRY_RE.match(raw)
        if m:
            entry_id = m.group(1)
            try:
                kind = entry_kind(entry_id)
            except ValueError:
                current = None
                continue
            current = {"id": entry_id, "kind": kind}
            entries.append(current)
            last_field = None
            continue
        if current is None:
            continue
        if raw.startswith("#") or raw.strip() == "---":
            current, last_field = None, None
            continue
        m = FIELD_RE.match(raw)
        if m:
            last_field = m.group(1)
            current[last_field] = _clean(m.group(2))
        elif last_field and raw.strip() and raw[:1].isspace():
            current[last_field] = (current[last_field] + " " + raw.strip()).strip()
        elif not raw.strip():
            last_field = None
    for entry in entries:
        entry["affected_files"] = [p.strip() for p in entry.get("affected_file", "").split(",") if p.strip()]
    return entries


def find_entry(path, entry_id: str) -> dict:
    for entry in parse_entries(path):
        if entry["id"] == entry_id:
            return entry
    raise KeyError(f"{entry_id} not found in {path}")


def read_repo_url(project_dir) -> str:
    for line in (Path(project_dir) / "repo.conf").read_text().splitlines():
        line = line.strip()
        if line.startswith("repo_url="):
            return line.split("=", 1)[1].strip()
    raise KeyError(f"repo_url missing in {project_dir}/repo.conf")
