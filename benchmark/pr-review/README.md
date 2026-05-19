# PR review benchmark

This benchmark is for real PRs, not CVE ground-truth scoring. It compares Cursor-backed review in these modes:

1. **ignore-context** — `edc-review.sh --ignore-context`; no build/update, no manifest/routing, and the task explicitly avoids EDC context. This is the pure baseline cell.
2. **no-refresh** — `edc-review.sh --no-context-refresh`; no build/update/recovery, but existing usable context may be used. This isolates the cost of refreshing context from review behavior.
3. **context** — normal `edc-review.sh`; context is built/updated if missing/stale, then review routes by module.

The runner records spend/usage telemetry from EDC spawn logs and copies review artifacts. Finding quality is manually adjudicated because real PRs do not have a ground-truth answer key.

## Usage

```bash
bash /Users/home/Dev/edc/benchmark/pr-review/run-cursor-pr-benchmark.sh \
  --repo ~/Dev/chia-blockchain \
  --target HEAD \
  --base main
```

For a GitHub PR URL:

```bash
bash /Users/home/Dev/edc/benchmark/pr-review/run-cursor-pr-benchmark.sh \
  --repo ~/Dev/chia-blockchain \
  --target https://github.com/Chia-Network/chia-blockchain/pull/12345
```

To include first-build cost explicitly:

```bash
bash /Users/home/Dev/edc/benchmark/pr-review/run-cursor-pr-benchmark.sh \
  --repo ~/Dev/chia-blockchain \
  --target HEAD \
  --base main \
  --force-build-context
```

To run only the no-refresh cell:

```bash
bash /Users/home/Dev/edc/benchmark/pr-review/run-cursor-pr-benchmark.sh \
  --repo ~/Dev/chia-blockchain \
  --target HEAD \
  --base main \
  --mode no-refresh
```

## Outputs

Default output path:

```text
benchmark/pr-review/results/<timestamp>-<repo>-<target>/
```

Key files:

| file | purpose |
|---|---|
| `summary.tsv` | one row per cell with spawns, cost, duration, token totals |
| `ignore-context/review-*.md` | copied pure-baseline review artifact |
| `no-refresh/review-*.md` | copied no-refresh review artifact, if that mode was run |
| `context-review/review-*.md` | copied context-backed review artifact |
| `*/spawn-log.jsonl` | raw EDC per-spawn metrics |
| `*/metrics.json` | aggregated metrics for that cell |
| `*/transcripts/` | preserved Cursor stream-json transcripts |
| `manual-findings.tsv` | fill this manually after reading findings |

## Interpreting results

Use `summary.tsv` for spend/time/tokens. Use `manual-findings.tsv` for quality:

```tsv
mode	finding_id	status	severity	file	summary	notes
ignore-context	N1	accepted	high	src/foo.py	missing validation	confirmed bug
context	C1	false-positive	medium	src/bar.py	claimed race	intentional lock ordering
```

Recommended comparison metrics:

- accepted findings
- false positives
- duplicates
- unclear findings
- total cost
- wall time / duration
- files read and tool calls from transcripts, if needed

## Caveat

`--ignore-context` is a practical baseline, not a sandbox proof. If Cursor has external memory/extensions enabled, keep the environment consistent across cells. `--no-context-refresh` is not a pure baseline: it may still use existing EDC context; it only prevents build/update/recovery.
