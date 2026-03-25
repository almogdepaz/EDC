#!/usr/bin/env python3
"""Parse ground-truth.md and output pipe-delimited CVE entries."""
import re
import sys

def parse(path):
    with open(path) as f:
        text = f.read()

    entries = []
    for block in re.split(r'(?=^### CVE-)', text, flags=re.MULTILINE):
        m_cve = re.match(r'### (CVE-[\d-]+)', block)
        if not m_cve:
            continue
        cve = m_cve.group(1)

        def field(name):
            m = re.search(rf'\*\*{name}:\*\*\s*`?([^`\n]+)`?', block)
            return m.group(1).strip() if m else ""

        fix = field("fix_commit")
        if not fix or fix.startswith("("):
            continue

        entries.append("|".join([
            cve, fix, field("affected_file"),
            field("category"), field("severity"), field("bug_pattern")
        ]))

    return entries

if __name__ == "__main__":
    for line in parse(sys.argv[1]):
        print(line)
