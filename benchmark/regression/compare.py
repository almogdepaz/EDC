#!/usr/bin/env python3
"""Compare pre vs post regression runs.

Usage:
    compare.py --pre <sha> --post <sha> [--repo curl|redis|all] [--build-headroom 1.10] [--review-headroom 1.10]

Reads benchmark/regression/results/<sha>/<repo>/{build-metrics.tsv,review-metrics.tsv,review-results.tsv}
and prints a verdict. Exit 0 if all criteria pass, 1 otherwise.
"""

from __future__ import annotations

import argparse
import csv
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "results"


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


def repos_under(sha_dir: Path) -> list[str]:
    return sorted(p.name for p in sha_dir.iterdir() if p.is_dir())


def aggregate(sha: str, repo: str):
    d = ROOT / short(sha) / repo
    builds = load_tsv(d / "build-metrics.tsv")
    reviews = load_tsv(d / "review-metrics.tsv")
    scores = load_tsv(d / "review-results.tsv")

    build_costs = [float(b["total_cost_usd"]) for b in builds if b.get("status") == "ok"]
    review_costs = [float(r["total_cost_usd"]) for r in reviews if r.get("status") == "ok"]

    # recall: per CVE, take best confidence across attempts; partial=0.5, exact=1.0
    by_cve: dict[str, list[str]] = {}
    for s in scores:
        by_cve.setdefault(s["cve"], []).append(s.get("confidence", "miss"))

    def best(confs):
        if any(c == "exact" for c in confs):
            return 1.0
        if any(c == "partial" for c in confs):
            return 0.5
        return 0.0

    if by_cve:
        per_cve = {cve: best(confs) for cve, confs in by_cve.items()}
        recall = sum(per_cve.values()) / len(per_cve)
    else:
        per_cve = {}
        recall = 0.0

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
        "module_ok": module_ok,
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
        repos = sorted(set(repos_under(pre_dir)) & set(repos_under(post_dir)))
    else:
        repos = [args.repo]

    overall_pass = True
    print(f"\n=== Regression compare: pre={short(args.pre)} post={short(args.post)} ===\n")

    for repo in repos:
        pre = aggregate(args.pre, repo)
        post = aggregate(args.post, repo)
        print(f"── {repo} ──")
        print(f"  build attempts:  pre={pre['build_ok']}/{pre['build_attempts']}  post={post['build_ok']}/{post['build_attempts']}")
        print(f"  median build $:  pre={fmt_money(pre['median_build_cost'])}  post={fmt_money(post['median_build_cost'])}  Δ={pct_delta(pre['median_build_cost'], post['median_build_cost'])!r}")
        print(f"  median review $: pre={fmt_money(pre['median_review_cost'])}  post={fmt_money(post['median_review_cost'])}  Δ={pct_delta(pre['median_review_cost'], post['median_review_cost'])!r}")
        print(f"  recall:          pre={pre['recall']:.3f}  post={post['recall']:.3f}  Δ={post['recall']-pre['recall']:+.3f}")

        cves = sorted(set(pre["per_cve"]) | set(post["per_cve"]))
        for cve in cves:
            a = pre["per_cve"].get(cve, 0.0)
            b = post["per_cve"].get(cve, 0.0)
            arrow = "→" if a == b else ("↑" if b > a else "↓")
            print(f"    {cve}: {a:.1f} {arrow} {b:.1f}")

        # Verdict
        repo_pass = True
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
