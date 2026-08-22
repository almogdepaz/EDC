import contextlib
import csv
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


compare = load_module("edc_compare", REPO_ROOT / "benchmark/regression/compare.py")
score = load_module("edc_score", REPO_ROOT / "benchmark/score.py")


class VerdictScoreTests(unittest.TestCase):
    def test_verdict_to_score_accepts_resolved_values(self):
        helper = load_module("edc_scoring_helpers", REPO_ROOT / "benchmark/scoring_helpers.py")
        self.assertEqual(helper.verdict_to_score("exact", context="unit"), 1.0)
        self.assertEqual(helper.verdict_to_score("partial", context="unit"), 0.5)
        self.assertEqual(helper.verdict_to_score("missed", context="unit"), 0.0)
        self.assertEqual(helper.verdict_to_score("error", context="unit"), 0.0)

    def test_verdict_to_score_rejects_unresolved_values_with_context(self):
        helper = load_module("edc_scoring_helpers", REPO_ROOT / "benchmark/scoring_helpers.py")
        for verdict in ("judge_error", "", "unknown"):
            with self.subTest(verdict=verdict):
                with self.assertRaisesRegex(helper.UnresolvedVerdictError, "unit-context"):
                    helper.verdict_to_score(verdict, context="unit-context")


class RegressionAggregationTests(unittest.TestCase):
    def aggregate_rows(self, fieldnames, rows):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            result_dir = root / "revision" / "repo"
            result_dir.mkdir(parents=True)
            with (result_dir / "review-results.tsv").open("w", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t")
                writer.writeheader()
                writer.writerows(rows)
            previous_root = compare.ROOT
            compare.ROOT = root
            try:
                return compare.aggregate("revision", "repo")
            finally:
                compare.ROOT = previous_root

    def test_legacy_found_verdict_drives_recall(self):
        result = self.aggregate_rows(
            ["cve", "found", "confidence"],
            [
                {"cve": "CVE-1", "found": "exact", "confidence": "0.99"},
                {"cve": "CVE-2", "found": "missed", "confidence": "0.99"},
            ],
        )
        self.assertEqual(result["recall"], 0.5)
        self.assertEqual(result["per_cve"], {"CVE-1": 1.0, "CVE-2": 0.0})

    def test_current_verdict_and_dual_phase_score_are_supported(self):
        result = self.aggregate_rows(
            ["cve", "verdict", "confidence", "build_verdict", "combined_score"],
            [
                {"cve": "CVE-1", "verdict": "exact", "confidence": "0.99", "build_verdict": "exact", "combined_score": "0.5"},
                {"cve": "CVE-2", "verdict": "partial", "confidence": "0.8", "build_verdict": "", "combined_score": ""},
            ],
        )
        self.assertEqual(result["recall"], 0.5)
        self.assertEqual(result["per_cve"], {"CVE-1": 0.5, "CVE-2": 0.5})

    def test_judge_errors_are_unscored_and_reported(self):
        result = self.aggregate_rows(
            ["cve", "verdict", "confidence", "combined_score"],
            [
                {"cve": "CVE-1", "verdict": "judge_error", "confidence": "0", "combined_score": "-1.0"},
                {"cve": "CVE-2", "verdict": "exact", "confidence": "0.9", "combined_score": "1.0"},
            ],
        )
        self.assertEqual(result["recall"], 1.0)
        self.assertEqual(result["per_cve"], {"CVE-2": 1.0})
        self.assertEqual(result["judge_errors"], 1)

    def test_build_judge_error_cannot_fall_back_to_exact_review(self):
        result = self.aggregate_rows(
            ["cve", "verdict", "build_verdict", "combined_score"],
            [
                {"cve": "CVE-1", "verdict": "exact", "build_verdict": "judge_error", "combined_score": "-1.0"},
            ],
        )
        self.assertEqual(result["recall"], 0.0)
        self.assertEqual(result["per_cve"], {})
        self.assertEqual(result["judge_errors"], 1)

    def test_present_invalid_combined_score_cannot_fall_back_to_exact_review(self):
        for combined_score in ("malformed", "-1.0"):
            with self.subTest(combined_score=combined_score):
                result = self.aggregate_rows(
                    ["cve", "verdict", "build_verdict", "combined_score"],
                    [
                        {"cve": "CVE-1", "verdict": "exact", "build_verdict": "missed", "combined_score": combined_score},
                    ],
                )
                self.assertEqual(result["recall"], 0.0)
                self.assertEqual(result["per_cve"], {})
                self.assertEqual(result["judge_errors"], 1)


class BenchmarkSummaryTests(unittest.TestCase):
    def test_summary_counts_review_verdict_not_build_verdict(self):
        with tempfile.TemporaryDirectory() as temp:
            results_file = Path(temp) / "results.tsv"
            with results_file.open("w", newline="") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=[
                        "cve",
                        "repo",
                        "category",
                        "affected_file",
                        "verdict",
                        "confidence",
                        "duration",
                        "notes",
                        "build_verdict",
                        "build_confidence",
                        "combined_score",
                        "build_notes",
                    ],
                    delimiter="\t",
                )
                writer.writeheader()
                writer.writerow(
                    {
                        "cve": "CVE-1",
                        "repo": "repo",
                        "category": "auth",
                        "affected_file": "src/auth.py",
                        "verdict": "missed",
                        "confidence": "0.0",
                        "duration": "1",
                        "notes": "review missed it",
                        "build_verdict": "exact",
                        "build_confidence": "1.0",
                        "combined_score": "0.5",
                        "build_notes": "build found it",
                    }
                )

            previous_results_file = score.RESULTS_FILE
            score.RESULTS_FILE = results_file
            try:
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    score.print_summary()
            finally:
                score.RESULTS_FILE = previous_results_file

        summary = output.getvalue()
        self.assertIn("Total CVEs tested: 1", summary)
        self.assertIn("Scored (auto):     1/1", summary)
        self.assertIn("Exact match:  0", summary)
        self.assertIn("Missed:       1", summary)


class ComputeBaselineTests(unittest.TestCase):
    def test_unresolved_verdict_exits_nonzero_without_output(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            results_file = temp_path / "results.tsv"
            output_file = temp_path / "baseline.json"
            output_file.write_text('{"stale": true}\n')
            with results_file.open("w", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=["cve", "verdict"], delimiter="\t")
                writer.writeheader()
                writer.writerow({"cve": "CVE-1", "verdict": "judge_error"})

            proc = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "benchmark/compute_baseline.py"),
                    "--model",
                    "test-model",
                    "--pairs",
                    f"run1:{results_file}:.",
                    "--out",
                    str(output_file),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("judge_error", proc.stderr)
            self.assertIn("run1", proc.stderr)
            self.assertIn("CVE-1", proc.stderr)
            self.assertFalse(output_file.exists())


class KeywordScoringTests(unittest.TestCase):
    def test_category_regexes_match_semantic_sequences(self):
        value, notes = score.keyword_score(
            "The function can free one pointer and later free the same allocation again.",
            "",
            "double-free",
            "",
        )
        self.assertGreater(value, 0)
        self.assertIn("cat=1/", notes)
        self.assertNotIn("file_mentioned", notes)

    def test_empty_affected_files_do_not_count_as_a_file_match(self):
        value, notes = score.keyword_score("unrelated report", "", "unknown", "")
        self.assertEqual(value, 0)
        self.assertNotIn("file_mentioned", notes)


if __name__ == "__main__":
    unittest.main()
