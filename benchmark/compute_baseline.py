#!/usr/bin/env python3
"""
Aggregate baseline metrics across N runs.

Usage:
    python3 compute_baseline.py --model sonnet \
        --pairs "run1:results.tsv:metrics.tsv" "run2:..." ... \
        --out baseline-metrics.json
"""
import argparse
import json
import statistics
from pathlib import Path


VERDICT_SCORE = {"exact": 1.0, "partial": 0.5, "missed": 0.0, "error": 0.0}


def load_results(path: Path):
    rows = []
    with open(path) as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < len(header):
                continue
            rows.append(dict(zip(header, parts)))
    return rows


def load_metrics(path):
    if path is None or str(path) in ("", ".") or not path.exists() or path.is_dir():
        return {}
    out = {}
    with open(path) as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < len(header):
                continue
            row = dict(zip(header, parts))
            out[row["cve"]] = row
    return out


def stats(xs):
    if not xs:
        return {}
    xs_sorted = sorted(xs)
    n = len(xs)
    return {
        "n": n,
        "mean": statistics.fmean(xs),
        "std": statistics.pstdev(xs) if n > 1 else 0.0,
        "min": xs_sorted[0],
        "max": xs_sorted[-1],
        "p50": xs_sorted[n // 2],
        "p95": xs_sorted[min(n - 1, int(0.95 * n))],
        "sum": sum(xs),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--pairs", nargs="+", required=True,
                    help="run_label:results.tsv:metrics.tsv tuples")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    runs = []
    for p in args.pairs:
        label, res_path, met_path = p.split(":", 2)
        res = load_results(Path(res_path))
        met = load_metrics(Path(met_path) if met_path else None)
        runs.append({"label": label, "results": res, "metrics": met})

    per_run_score = []
    all_dur = []
    all_in = []
    all_out = []
    all_cache_read = []
    all_cache_create = []
    all_cost = []
    all_turns = []
    all_score = []

    for run in runs:
        n = len(run["results"])
        run_score = sum(VERDICT_SCORE.get(r.get("verdict", r.get("found", "")), 0) for r in run["results"]) / n if n else 0
        per_run_score.append(run_score)
        for r in run["results"]:
            verdict = VERDICT_SCORE.get(r.get("verdict", r.get("found", "")), 0)
            all_score.append(verdict)
            m = run["metrics"].get(r["cve"], {})
            if m:
                try:
                    all_dur.append(float(m.get("duration_s", 0)))
                    all_in.append(int(m.get("input_tokens", 0)))
                    all_out.append(int(m.get("output_tokens", 0)))
                    all_cache_read.append(int(m.get("cache_read", 0)))
                    all_cache_create.append(int(m.get("cache_create", 0)))
                    all_cost.append(float(m.get("total_cost", 0)))
                    all_turns.append(int(m.get("num_turns", 0)))
                except (ValueError, TypeError):
                    pass

    total_tokens = [i + o for i, o in zip(all_in, all_out)]

    out = {
        "model": args.model,
        "n_runs": len(runs),
        "n_cves": sum(len(r["results"]) for r in runs),
        "per_run_score": per_run_score,
        "aggregate": {
            "score": stats(per_run_score),
            "per_cve_verdict": stats(all_score),
            "per_cve_duration_s": stats(all_dur),
            "per_cve_input_tokens": stats(all_in),
            "per_cve_output_tokens": stats(all_out),
            "per_cve_total_tokens": stats(total_tokens),
            "per_cve_cache_read": stats(all_cache_read),
            "per_cve_cache_create": stats(all_cache_create),
            "per_cve_total_cost_usd": stats(all_cost),
            "per_cve_num_turns": stats(all_turns),
        },
    }

    Path(args.out).write_text(json.dumps(out, indent=2))
    print(f"Wrote {args.out}")
    print(f"  model={args.model} n_runs={out['n_runs']}")
    print(f"  score:  mean={out['aggregate']['score']['mean']:.3f}  std={out['aggregate']['score']['std']:.3f}")
    if out['aggregate']['per_cve_duration_s'].get('mean'):
        a = out['aggregate']
        print(f"  dur/cve (s):     mean={a['per_cve_duration_s']['mean']:.1f}  p95={a['per_cve_duration_s']['p95']:.1f}")
        print(f"  tokens in/cve:   mean={a['per_cve_input_tokens']['mean']:.0f}")
        print(f"  tokens out/cve:  mean={a['per_cve_output_tokens']['mean']:.0f}")
        print(f"  cost/cve (USD):  mean=${a['per_cve_total_cost_usd']['mean']:.3f}  sum=${a['per_cve_total_cost_usd']['sum']:.2f}")


if __name__ == "__main__":
    main()
