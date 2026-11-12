"""Strict, offline conversion and file receipts for the pinned B-only pilot."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re

EDC_REVISION = "d634519851b9bba41ae7a7b66b90a95681c0ab36"
REVIEWBENCH_REVISION = "f223ce33558a6d211fd222b1f7ff2fd7b44403d4"


class AdapterError(ValueError):
    """Invalid or ambiguous input; never an empty successful review."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("xb") as stream:
        stream.write(encoded(value))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def safe_relative(value):
    if not isinstance(value, str) or not value or "\\" in value or any(ord(c) < 32 for c in value):
        raise AdapterError("unsafe relative path")
    parts = value.split("/")
    if PurePosixPath(value).is_absolute() or any(p in ("", ".", "..") for p in parts):
        raise AdapterError("unsafe relative path: " + value)
    return value


def regular_files(root):
    """Hash every retained artifact, rejecting links instead of following them."""
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise AdapterError("artifact symlink: " + str(path))
        if path.is_file():
            if path.stat().st_nlink != 1:
                raise AdapterError("artifact hard link: " + str(path))
            relative = path.relative_to(root).as_posix()
            if relative != "receipt.json":
                result[relative] = digest(path.read_bytes())
        elif not path.is_dir():
            raise AdapterError("non-regular artifact: " + str(path))
    return result


def begin_job(root, identity):
    """An existing incomplete job is ambiguous, even after its owner exits."""
    root = Path(root)
    try:
        root.mkdir(parents=False)
    except FileExistsError:
        try:
            if root.is_symlink() or (root / "receipt.json").is_symlink():
                raise AdapterError("linked receipt")
            receipt = json.loads((root / "receipt.json").read_text())
            if receipt["identity"] != identity:
                raise AdapterError("input identity changed; refusing to repeat review")
            if receipt["state"] != "succeeded":
                raise AdapterError("in-flight/failed job requires parent reconciliation; no automatic retry")
            artifacts = regular_files(root)
            if not artifacts or artifacts != receipt["artifacts"]:
                raise AdapterError("corrupt or partial artifacts")
            return True
        except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
            raise AdapterError("invalid receipt; no automatic retry") from error
    atomic_json(root / "receipt.json", {"state": "running", "identity": identity, "pid": os.getpid()})
    return False


def complete_job(root, identity):
    artifacts = regular_files(root)
    if not artifacts:
        raise AdapterError("cannot complete empty artifact set")
    atomic_json(root / "receipt.json", {"state": "succeeded", "identity": identity, "artifacts": artifacts})


def validate_result(result, head, base=None):
    if not isinstance(result, dict) or result.get("kind") != "review-all" or result.get("schemaVersion") != 1:
        raise AdapterError("missing/unsupported combined structured result")
    for field in ("startedHead", "finishedHead", "candidateCommit"):
        if result.get(field) != head:
            raise AdapterError("structured result head mismatch: " + field)
    if base is not None and (result.get("base") != base or result.get("scope") != "differential"
                             or result.get("candidateKind") != "committed"
                             or result.get("dirtyTrackedIncluded") is not False
                             or result.get("untrackedIncluded") is not False):
        raise AdapterError("structured result does not match the immutable base/head candidate")
    phases = result.get("phases", [])
    if not isinstance(phases, list) or not all(isinstance(p, dict) for p in phases) or [p.get("phase") for p in phases] != ["security", "delivery", "quality"]:
        raise AdapterError("missing or duplicate review phases")
    for phase in [result] + phases:
        if phase.get("status") != "success" or phase.get("exitCode") != 0 or phase.get("childExitCode", 0) != 0:
            raise AdapterError("failed phase or incomplete coverage: " + str(phase.get("phase")))


def sections(text, level, title=None):
    """Return heading/body pairs, ending at the next same-or-higher heading."""
    lines = text.splitlines()
    result = []
    for index, line in enumerate(lines):
        match = re.fullmatch(r"(#{1,6}) (.+)", line)
        if not match or len(match[1]) != level or (title is not None and match[2] != title):
            continue
        end = index + 1
        while end < len(lines):
            following = re.match(r"^(#{1,6}) ", lines[end])
            if following and len(following[1]) <= level:
                break
            end += 1
        result.append((match[2], "\n".join(lines[index + 1:end]).strip()))
    return result


def location(value, bounds):
    value = value.strip()
    if value.startswith("`") and value.endswith("`"):
        value = value[1:-1]
    match = re.fullmatch(r"([^`:]+):L?([0-9]+)(?:-L?([0-9]+))?", value)
    if not match:
        raise AdapterError("unsupported or ambiguous head evidence: " + value)
    file = safe_relative(match[1])
    start, end = int(match[2]), int(match[3] or match[2])
    if file not in bounds or not 1 <= start <= end <= bounds[file]:
        raise AdapterError("evidence is not within an existing regular head file: " + value)
    return file, start, end


def finding(title, body, field, bounds, producer):
    evidence = re.findall(r"^- " + re.escape(field) + r": (.+)$", body, re.M)
    if len(evidence) != 1:
        raise AdapterError("finding needs one explicit " + field + ": " + title)
    file, start, end = location(evidence[0], bounds)
    if len([line for line in body.splitlines() if line.strip()]) < 2:
        raise AdapterError("finding has no explanation: " + title)
    return dict(file=file, start_line=start, end_line=end, message=title + "\n" + body, producer=producer)


ZERO_QUALITY = "No actionable code-quality findings in the inspected scope."
QUALITY_SECTIONS = {
    "Dead Exports / Public Surface", "Wrapper Functions", "Over-Abstracted Modules", "Duplication",
    "Oversized Files / Functions", "Deep Call Chains", "Test Mirroring / Test Value",
    "Correctness and Error-Handling Risks", "Interface / Type / Contract Risks", "Simplicity Opportunities",
}


def convert_reports(reports, bounds, producer):
    """Only final products, never worker findings as a substitute for synthesis.

    This intentionally accepts a small documented Markdown subset. Unsupported
    prose/tables, missing locations and multi-location findings stop conversion.
    """
    if set(reports) != {"security", "delivery", "complexity", "issues"}:
        raise AdapterError("all four final product reports are required")
    for name, text in reports.items():
        if not isinstance(text, str) or not text.strip():
            raise AdapterError("empty final report: " + name)
        if re.search(r"coverage gap|coverage unavailable", text, re.I):
            raise AdapterError("coverage gap in final report: " + name)
    # This exact block is deterministic coordinator metadata, not model findings.
    notice = ("\n## Context policy\n\nContext: ignored (explicit no-build review).\n"
              "Scope uses an explicit source-file inventory, not generated modules. Existing context is unverified optional guidance in no-refresh mode and excluded in ignored mode.\n"
              "Coverage is limited to assigned files and necessary supporting evidence; this does not establish complete architectural understanding.\n")
    reports = {key: text.replace(notice, "\n") for key, text in reports.items()}
    output = []
    security = sections(reports["security"], 2, "Findings")
    if not security:
        raise AdapterError("security report has no Findings sections")
    for _, body in security:
        blocks = sections(body, 3)
        if not blocks or body.split("### ", 1)[0].strip():
            raise AdapterError("unsupported security findings body")
        for title, detail in blocks:
            if title == "No security findings":
                if len(blocks) != 1 or not detail:
                    raise AdapterError("contradictory or incomplete no-security-findings report")
                continue
            if not re.match(r"^(?:[🔴🟠🟡🟢] )?(?:CRITICAL|HIGH|MEDIUM|LOW): .+", title):
                raise AdapterError("unsupported security finding heading: " + title)
            output.append(finding(title, detail, "where", bounds, producer))
    delivery = reports["delivery"]
    for axis in ("Goal / Spec Delivery", "Architecture Fit"):
        axis_sections = sections(delivery, 2, axis)
        if len(axis_sections) != 1:
            raise AdapterError("missing/duplicate delivery axis: " + axis)
        bodies = sections(axis_sections[0][1], 3, "Findings")
        if len(bodies) != 1:
            raise AdapterError("missing/duplicate delivery Findings")
        body = bodies[0][1]
        if body == "No findings.":
            continue
        blocks = sections(body, 4)
        if not blocks or body.split("#### ", 1)[0].strip():
            raise AdapterError("unsupported delivery findings body")
        for title, detail in blocks:
            if not re.fullmatch(r"(?:BLOCKER|IMPORTANT|ADVISORY) — .+", title):
                raise AdapterError("unsupported delivery finding heading")
            output.append(finding(axis + ": " + title, detail, "implementation evidence", bounds, producer))
    complexity = sections(reports["complexity"], 2)
    if not complexity:
        raise AdapterError("missing quality report sections")
    observed_quality = False
    for title, body in complexity:
        if title in ("Summary", "LOC Estimates vs Reality"):
            continue  # documented metrics, not logical findings
        if title not in QUALITY_SECTIONS:
            raise AdapterError("unsupported quality section: " + title)
        observed_quality = True
        if body == ZERO_QUALITY or body == "None.":
            continue
        # The production contract's compact bloat form: one bullet per issue.
        blocks = re.split(r"(?m)^- ", body)
        if blocks[0].strip() or len(blocks) < 2:
            raise AdapterError("unsupported quality findings list")
        for block in blocks[1:]:
            match = re.fullmatch(r"(`?[^`\n]+?:L?\d+(?:-L?\d+)?`?): (.+)", block.strip(), re.S)
            if not match:
                raise AdapterError("quality finding lacks explicit head evidence")
            file, start, end = location(match[1], bounds)
            output.append(dict(file=file, start_line=start, end_line=end, message=title + ": " + match[2], producer=producer))
    if not observed_quality:
        raise AdapterError("quality report contains only metrics")
    issues = reports["issues"]
    blocks = sections(issues, 2)
    if not blocks:
        # Ignore only the title and generated-by/context notice, not arbitrary prose.
        if ZERO_QUALITY not in issues or re.search(r"(?m)^- (?:where|problem):", issues):
            raise AdapterError("issues report is not explicitly empty")
        remaining = re.sub(r"(?m)^# Known Issues\s*$|^<!-- generated by edc-audit -->\s*$", "", issues)
        if remaining.strip() != ZERO_QUALITY:
            raise AdapterError("unsupported zero-issues report")
    for title, body in blocks:
        if not re.fullmatch(r"(?:CRITICAL|HIGH|MEDIUM|LOW|BLOCKER|IMPORTANT|ADVISORY) — .+", title):
            raise AdapterError("unsupported issues heading: " + title)
        output.append(finding(title, body, "where", bounds, producer))
    unique = {}
    for item in output:
        unique.setdefault(encoded(item), item)
    return list(unique.values())
