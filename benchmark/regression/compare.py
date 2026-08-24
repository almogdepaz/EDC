#!/usr/bin/env python3
"""Compare pre vs post regression runs.

Usage:
    compare.py --pre <sha> --post <sha> [--repo curl|redis|all] [--mode <mode>] [--label <label>] [--build-headroom 1.10] [--review-headroom 1.10]

Reads canonical benchmark/regression/results/<sha>/<mode>/<label>/<repo>/ results
and evidenced legacy <sha>/<label>/<repo>/ and <sha>/<repo>/ layouts. Exit 0 if all criteria pass, 1 otherwise.
"""

from __future__ import annotations

import argparse
import csv
import math
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "results"
RESULT_FILES = ("build-metrics.tsv", "review-metrics.tsv", "review-results.tsv")


def short(sha: str) -> str:
    return sha[:10]


def load_tsv(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with path.open() as f:
        return list(csv.DictReader(f, delimiter="\t"))


def median_or_none(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def result_dirs(
    sha_dir: Path,
    repo: str | None = None,
    mode: str | None = None,
    label: str | None = None,
) -> list[Path]:
    candidates = (p for pattern in ("*", "*/*", "*/*/*") for p in sha_dir.glob(pattern))
    matches = []
    for path in candidates:
        parts = path.relative_to(sha_dir).parts
        if mode is not None or label is not None:
            if len(parts) != 3:
                continue
            if mode is not None and parts[0] != mode:
                continue
            if label is not None and parts[1] != label:
                continue
        if path.is_dir() and (repo is None or path.name == repo) and any((path / name).is_file() for name in RESULT_FILES):
            matches.append(path)
    return sorted(matches)


def repos_under(sha_dir: Path, mode: str | None = None, label: str | None = None) -> list[str]:
    return sorted({p.name for p in result_dirs(sha_dir, mode=mode, label=label)})


def resolve_result_dir(sha: str, repo: str, mode: str | None, label: str | None) -> Path:
    dirs = result_dirs(ROOT / short(sha), repo, mode, label)
    selection = " ".join(part for part in (f"--mode {mode}" if mode else "", f"--label {label}" if label else "") if part)
    if not dirs:
        suffix = f" with {selection}" if selection else ""
        raise ValueError(f"missing result directory for SHA {short(sha)} repo {repo}{suffix}; verify the result path or selectors")
    if len(dirs) > 1:
        matches = ", ".join(str(path.relative_to(ROOT)) for path in dirs)
        raise ValueError(f"ambiguous result directories for SHA {short(sha)} repo {repo}: {matches}; pass --mode and --label")
    return dirs[0]


def aggregate(sha: str, repo: str, mode: str | None = None, label: str | None = None):
    result_dir = resolve_result_dir(sha, repo, mode, label)
    builds = load_tsv(result_dir / "build-metrics.tsv")
    reviews = load_tsv(result_dir / "review-metrics.tsv")
    scores = load_tsv(result_dir / "review-results.tsv")

    build_costs = [float(b["total_cost_usd"]) for b in builds if b.get("status") == "ok"]
    review_costs = [float(r["total_cost_usd"]) for r in reviews if r.get("status") == "ok"]

    # Recall is verdict-derived. Dual-phase rows carry their weighted score in
    # combined_score; legacy rows use `found`, while current rows use `verdict`.
    verdict_scores = {"exact": 1.0, "partial": 0.5, "missed": 0.0, "miss": 0.0}
    by_cve: dict[str, list[float]] = {}
    judge_errors = 0
    for row in scores:
        verdict = (row.get("verdict") or row.get("found") or "").strip()
        build_verdict = (row.get("build_verdict") or "").strip()
        combined = (row.get("combined_score") or "").strip()
        if "judge_error" in (verdict, build_verdict):
            judge_errors += 1
            continue
        if combined:
            try:
                value = float(combined)
            except ValueError:
                judge_errors += 1
                continue
            if not math.isfinite(value) or value < 0:
                judge_errors += 1
                continue
        else:
            value = verdict_scores.get(verdict)
        if value is None:
            judge_errors += 1
            continue
        cve = (row.get("cve") or "").strip()
        if not cve:
            judge_errors += 1
            continue
        by_cve.setdefault(cve, []).append(value)

    per_cve = {cve: max(values) for cve, values in by_cve.items()}
    recall = sum(per_cve.values()) / len(per_cve) if per_cve else 0.0

    # module coverage: every build-metrics row with status=ok must have module_count > 0
    module_ok = all(int(b["module_count"]) > 0 for b in builds if b.get("status") == "ok")

    return {
        "build_attempts": len(builds),
        "build_ok": sum(1 for b in builds if b.get("status") == "ok"),
        "median_build_cost": median_or_none(build_costs),
        "review_attempts": len(reviews),
        "median_review_cost": median_or_none(review_costs),
        "recall": recall,
        "per_cve": per_cve,
        "judge_errors": judge_errors,
        "module_ok": module_ok,
        "row_counts": {"build": len(builds), "review": len(reviews), "score": len(scores)},
    }


def fmt_money(x):
    return f"${x:.4f}" if x is not None else "—"


def pct_delta(pre, post):
    if pre is None or post is None or pre == 0:
        return None
    return (post - pre) / pre * 100.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pre", required=True)
    ap.add_argument("--post", required=True)
    ap.add_argument("--repo", default="all")
    ap.add_argument("--mode")
    ap.add_argument("--label")
    ap.add_argument("--build-headroom", type=float, default=1.10)
    ap.add_argument("--review-headroom", type=float, default=1.10)
    args = ap.parse_args()

    pre_dir = ROOT / short(args.pre)
    post_dir = ROOT / short(args.post)
    if not pre_dir.exists():
        print(f"missing pre dir: {pre_dir}", file=sys.stderr); sys.exit(2)
    if not post_dir.exists():
        print(f"missing post dir: {post_dir}", file=sys.stderr); sys.exit(2)

    if args.repo == "all":
        repos = sorted(set(repos_under(pre_dir, args.mode, args.label)) & set(repos_under(post_dir, args.mode, args.label)))
    else:
        repos = [args.repo]
    if not repos:
        print("no common repos with results", file=sys.stderr); sys.exit(1)

    overall_pass = True
    print(f"\n=== Regression compare: pre={short(args.pre)} post={short(args.post)} ===\n")

    for repo in repos:
        try:
            pre = aggregate(args.pre, repo, args.mode, args.label)
            post = aggregate(args.post, repo, args.mode, args.label)
        except ValueError as error:
            print(error, file=sys.stderr)
            sys.exit(1)
        print(f"── {repo} ──")
        print(f"  build attempts:  pre={pre['build_ok']}/{pre['build_attempts']}  post={post['build_ok']}/{post['build_attempts']}")
        print(f"  median build $:  pre={fmt_money(pre['median_build_cost'])}  post={fmt_money(post['median_build_cost'])}  Δ={pct_delta(pre['median_build_cost'], post['median_build_cost'])!r}")
        print(f"  median review $: pre={fmt_money(pre['median_review_cost'])}  post={fmt_money(post['median_review_cost'])}  Δ={pct_delta(pre['median_review_cost'], post['median_review_cost'])!r}")
        print(f"  recall:          pre={pre['recall']:.3f}  post={post['recall']:.3f}  Δ={post['recall']-pre['recall']:+.3f}")
        print(f"  judge errors:    pre={pre['judge_errors']}  post={post['judge_errors']}")

        cves = sorted(set(pre["per_cve"]) | set(post["per_cve"]))
        for cve in cves:
            a = pre["per_cve"].get(cve, 0.0)
            b = post["per_cve"].get(cve, 0.0)
            arrow = "→" if a == b else ("↑" if b > a else "↓")
            print(f"    {cve}: {a:.1f} {arrow} {b:.1f}")

        # Verdict
        repo_pass = True
        for side, result in (("pre", pre), ("post", post)):
            missing = [kind for kind, count in result["row_counts"].items() if not count]
            if missing:
                print(f"  ✗ FAIL {side} has no usable {', '.join(missing)} rows")
                repo_pass = False
        if post["judge_errors"] > 0:
            print(f"  ✗ FAIL unresolved judge/scoring errors: {post['judge_errors']}")
            repo_pass = False
        if post["recall"] < pre["recall"]:
            print(f"  ✗ FAIL recall: {post['recall']:.3f} < {pre['recall']:.3f}")
            repo_pass = False
        else:
            print("  ✓ recall non-regressed")

        if pre["median_build_cost"] is not None and post["median_build_cost"] is not None:
            cap = pre["median_build_cost"] * args.build_headroom
            if post["median_build_cost"] > cap:
                print(f"  ✗ FAIL build cost: {fmt_money(post['median_build_cost'])} > cap {fmt_money(cap)} ({args.build_headroom}×)")
                repo_pass = False
            else:
                print(f"  ✓ build cost within {args.build_headroom}× headroom")

        if pre["median_review_cost"] is not None and post["median_review_cost"] is not None:
            cap = pre["median_review_cost"] * args.review_headroom
            if post["median_review_cost"] > cap:
                print(f"  ✗ FAIL review cost: {fmt_money(post['median_review_cost'])} > cap {fmt_money(cap)} ({args.review_headroom}×)")
                repo_pass = False
            else:
                print(f"  ✓ review cost within {args.review_headroom}× headroom")

        if not post["module_ok"]:
            print("  ✗ FAIL module coverage: at least one build attempt had module_count=0")
            repo_pass = False
        else:
            print("  ✓ module coverage")

        print(f"  → {repo}: {'PASS' if repo_pass else 'FAIL'}\n")
        overall_pass = overall_pass and repo_pass

    print(f"OVERALL: {'PASS' if overall_pass else 'FAIL'}")
    sys.exit(0 if overall_pass else 1)


if __name__ == "__main__":
    main()
