import contextlib
import csv
import importlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCHMARK_DIR = REPO_ROOT / "benchmark"
sys.path.insert(0, str(BENCHMARK_DIR))


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


compare = load_module("edc_compare", REPO_ROOT / "benchmark/regression/compare.py")
score = load_module("edc_score", REPO_ROOT / "benchmark/score.py")
audit = importlib.import_module("audit")
compute_baseline = importlib.import_module("compute_baseline")
rejudge = importlib.import_module("rejudge")
rescore = importlib.import_module("rescore")
scoring_helpers = importlib.import_module("scoring_helpers")


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
            result_dir = root / "revision" / "v2" / "label" / "repo"
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

    def test_regression_verdicts_follow_shared_current_and_legacy_contract(self):
        cases = (
            ("legacy error", "found", "error", {"CVE-1": 0.0}, 0),
            ("unsupported miss", "verdict", "miss", {}, 1),
        )
        for label, field, verdict, expected_scores, expected_errors in cases:
            with self.subTest(label=label):
                result = self.aggregate_rows(
                    ["cve", field],
                    [{"cve": "CVE-1", field: verdict}],
                )
                self.assertEqual(result["per_cve"], expected_scores)
                self.assertEqual(result["judge_errors"], expected_errors)

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

    def test_distinct_canonical_runs_require_explicit_selection(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for revision in ("pre", "post"):
                for label, verdict, cost in (("haiku", "missed", "1.0"), ("sonnet", "exact", "9.0")):
                    result_dir = root / revision / "v2" / label / "repo"
                    result_dir.mkdir(parents=True)
                    for filename, fieldnames, row in (
                        ("build-metrics.tsv", ["status", "total_cost_usd", "module_count"], {"status": "ok", "total_cost_usd": cost, "module_count": "1"}),
                        ("review-metrics.tsv", ["status", "total_cost_usd"], {"status": "ok", "total_cost_usd": cost}),
                        ("review-results.tsv", ["cve", "verdict"], {"cve": "CVE-1", "verdict": verdict}),
                    ):
                        with (result_dir / filename).open("w", newline="") as handle:
                            writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t")
                            writer.writeheader()
                            writer.writerow(row)

            previous_root, previous_argv = compare.ROOT, sys.argv
            compare.ROOT = root
            try:
                sys.argv = ["compare.py", "--pre", "pre", "--post", "post", "--repo", "repo"]
                stderr = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as ambiguous:
                    compare.main()
                self.assertEqual(ambiguous.exception.code, 1)
                self.assertIn("ambiguous", stderr.getvalue())
                self.assertIn("--mode", stderr.getvalue())
                self.assertIn("--label", stderr.getvalue())

                sys.argv = [
                    "compare.py", "--pre", "pre", "--post", "post", "--repo", "repo",
                    "--mode", "v2", "--label", "haiku",
                ]
                output = io.StringIO()
                with contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as selected:
                    compare.main()
                self.assertEqual(selected.exception.code, 0)
                self.assertIn("median build $:  pre=$1.0000  post=$1.0000", output.getvalue())
                self.assertIn("recall:          pre=0.000  post=0.000", output.getvalue())
                self.assertNotIn("$9.0000", output.getvalue())
            finally:
                compare.ROOT, sys.argv = previous_root, previous_argv

    def test_evidenced_legacy_result_layouts_are_supported(self):
        for relative_dir, cve in ((Path("repo"), "CVE-FLAT"), (Path("label/repo"), "CVE-LABEL")):
            with self.subTest(relative_dir=relative_dir), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                result_dir = root / "revision" / relative_dir
                result_dir.mkdir(parents=True)
                with (result_dir / "review-results.tsv").open("w", newline="") as handle:
                    writer = csv.DictWriter(handle, fieldnames=["cve", "found"], delimiter="\t")
                    writer.writeheader()
                    writer.writerow({"cve": cve, "found": "exact"})
                (root / "revision" / "mode" / "label" / "not-a-result").mkdir(parents=True)
                previous_root = compare.ROOT
                compare.ROOT = root
                try:
                    result = compare.aggregate("revision", "repo")
                    repos = compare.repos_under(root / "revision")
                finally:
                    compare.ROOT = previous_root
                self.assertEqual(result["per_cve"], {cve: 1.0})
                self.assertEqual(repos, ["repo"])

    def test_requested_repo_without_rows_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for revision in ("pre", "post"):
                (root / revision / "v2" / "label" / "repo").mkdir(parents=True)
            previous_root, previous_argv = compare.ROOT, sys.argv
            compare.ROOT = root
            sys.argv = ["compare.py", "--pre", "pre", "--post", "post", "--repo", "repo"]
            try:
                stderr = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                    compare.main()
            finally:
                compare.ROOT, sys.argv = previous_root, previous_argv
        self.assertEqual(raised.exception.code, 1)
        self.assertIn("missing result directory", stderr.getvalue())


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


class AutoresearchScoreTests(unittest.TestCase):
    def write_results(self, path, verdict_field, verdicts):
        with path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=["cve", verdict_field], delimiter="\t")
            writer.writeheader()
            for index, verdict in enumerate(verdicts, start=1):
                writer.writerow({"cve": f"CVE-{index}", verdict_field: verdict})

    def test_resolved_results_use_weighted_mean_for_current_and_legacy_rows(self):
        with tempfile.TemporaryDirectory() as temp:
            for verdict_field in ("verdict", "found"):
                with self.subTest(verdict_field=verdict_field):
                    results_file = Path(temp) / f"{verdict_field}.tsv"
                    self.write_results(results_file, verdict_field, ["exact", "partial", "missed"])
                    self.assertEqual(score.mean_result_score(results_file), 0.5)

    def test_result_count_mismatch_exits_nonzero_without_score(self):
        with tempfile.TemporaryDirectory() as temp:
            for verdicts, expected_count in ((["exact"], 2), (["exact", "missed"], 1)):
                with self.subTest(rows=len(verdicts), expected_count=expected_count):
                    results_file = Path(temp) / f"{len(verdicts)}-of-{expected_count}.tsv"
                    self.write_results(results_file, "verdict", verdicts)
                    proc = subprocess.run(
                        [
                            sys.executable,
                            str(REPO_ROOT / "benchmark/score.py"),
                            "--score-results", str(results_file),
                            "--expected-count", str(expected_count),
                        ],
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        check=False,
                    )
                    self.assertNotEqual(proc.returncode, 0)
                    self.assertEqual(proc.stdout, "")
                    self.assertIn(f"expected {expected_count} benchmark result rows", proc.stderr)
                    self.assertIn(f"found {len(verdicts)}", proc.stderr)

    def test_unresolved_or_empty_results_exit_nonzero_without_score(self):
        with tempfile.TemporaryDirectory() as temp:
            for label, verdicts, evidence in (
                ("unresolved", ["judge_error"], "judge_error"),
                ("empty", [], "no benchmark result rows"),
            ):
                with self.subTest(label=label):
                    results_file = Path(temp) / f"{label}.tsv"
                    self.write_results(results_file, "verdict", verdicts)
                    proc = subprocess.run(
                        [sys.executable, str(REPO_ROOT / "benchmark/score.py"), "--score-results", str(results_file)],
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        check=False,
                    )
                    self.assertNotEqual(proc.returncode, 0)
                    self.assertEqual(proc.stdout, "")
                    self.assertIn(evidence, proc.stderr)


class ResultSchemaContractTests(unittest.TestCase):
    def write_result(self, path, verdict_field, verdict):
        fieldnames = ["cve", verdict_field, "confidence", "notes"]
        with path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t")
            writer.writeheader()
            writer.writerow({"cve": "CVE-1", verdict_field: verdict, "confidence": "0", "notes": "reason=test"})

    def test_result_initializer_is_canonical_and_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            results_file = Path(temp) / "results.tsv"
            command = [sys.executable, str(BENCHMARK_DIR / "score.py"), "--init-results", str(results_file)]
            subprocess.run(command, check=True)
            initialized = results_file.read_text()
            subprocess.run(command, check=True)
            self.assertEqual(results_file.read_text(), initialized)
            self.assertEqual(
                initialized.rstrip("\n").split("\t"),
                list(scoring_helpers.CANONICAL_RESULT_FIELDS),
            )

            legacy_file = Path(temp) / "legacy.tsv"
            self.write_result(legacy_file, "found", "exact")
            legacy_contents = legacy_file.read_text()
            subprocess.run(
                [sys.executable, str(BENCHMARK_DIR / "score.py"), "--init-results", str(legacy_file)],
                check=True,
            )
            self.assertEqual(legacy_file.read_text(), legacy_contents)

    def test_append_result_round_trips_free_text_for_current_and_legacy_schemas(self):
        notes = 'judge said "partial"\tfirst line\nsecond line'
        build_notes = 'build "evidence"\talpha\nbeta'
        with tempfile.TemporaryDirectory() as temp:
            for verdict_field in ("verdict", "found"):
                with self.subTest(verdict_field=verdict_field):
                    results_file = Path(temp) / f"{verdict_field}.tsv"
                    fieldnames = [
                        verdict_field if field == "verdict" else field
                        for field in scoring_helpers.CANONICAL_RESULT_FIELDS
                    ]
                    with results_file.open("w", newline="") as handle:
                        csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t").writeheader()
                    previous_results_file = score.RESULTS_FILE
                    score.RESULTS_FILE = results_file
                    try:
                        with contextlib.redirect_stdout(io.StringIO()):
                            score.append_result(
                                "CVE-1", "category", "high", "partial", 0.8, 7, notes,
                                build_verdict="missed", build_confidence=0.2,
                                combined_score=0.5, build_notes=build_notes,
                            )
                    finally:
                        score.RESULTS_FILE = previous_results_file
                    with results_file.open(newline="") as handle:
                        reader = csv.DictReader(handle, delimiter="\t")
                        rows = list(reader)
                    self.assertEqual(reader.fieldnames, fieldnames)
                    self.assertEqual(len(rows), 1)
                    self.assertEqual(rows[0][verdict_field], "partial")
                    self.assertEqual(rows[0]["confidence"], "0.8")
                    self.assertEqual(rows[0]["combined_score"], "0.5")
                    self.assertEqual(rows[0]["notes"], notes)
                    self.assertEqual(rows[0]["build_notes"], build_notes)

    def test_audit_reads_current_and_legacy_review_verdicts(self):
        for verdict_field in ("verdict", "found"):
            with self.subTest(verdict_field=verdict_field):
                failure_class, _, _ = audit.classify(
                    {verdict_field: "exact", "notes": ""}, "", [], "CVE-1"
                )
                self.assertEqual(failure_class, "ok")

    def test_rejudge_mutation_preserves_current_and_legacy_verdict_field(self):
        for verdict_field in ("verdict", "found"):
            with self.subTest(verdict_field=verdict_field):
                row = {"cve": "CVE-1", verdict_field: "judge_error", "confidence": "0", "notes": "reason=test"}
                original_fields = set(row)
                with mock.patch.object(rejudge, "find_analysis_text", return_value=("analysis", "fixture")), \
                     mock.patch.object(rejudge, "prompt_verdict", return_value="exact"), \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.assertTrue(rejudge.rejudge_phase(row, "review", Path("results.tsv"), None, False))
                self.assertEqual(row[verdict_field], "exact")
                self.assertEqual(set(row), original_fields)
                self.assertNotIn("found" if verdict_field == "verdict" else "verdict", row)

    def test_rescore_mutation_preserves_current_and_legacy_verdict_field(self):
        ground_truth = {
            "CVE-1": {
                "bug_pattern": "pattern",
                "category": "category",
                "description": "description",
                "affected_files": "src/file.c",
            }
        }
        for verdict_field in ("verdict", "found"):
            with self.subTest(verdict_field=verdict_field), tempfile.TemporaryDirectory() as temp:
                results_file = Path(temp) / "results.tsv"
                output_file = Path(temp) / "rescored.tsv"
                self.write_result(results_file, verdict_field, "missed")
                with mock.patch.object(rescore, "repo_from_tsv", return_value="repo"), \
                     mock.patch.object(rescore, "load_ground_truth", return_value=ground_truth), \
                     mock.patch.object(rescore, "find_analysis", return_value=("analysis", "fixture")), \
                     mock.patch.object(rescore, "score_cve", return_value=("exact", 1.0, "rescored")), \
                     mock.patch.object(sys, "argv", ["rescore.py", str(results_file), "--out", str(output_file)]), \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(rescore.main(), 0)
                with output_file.open(newline="") as handle:
                    reader = csv.DictReader(handle, delimiter="\t")
                    row = next(reader)
                    fields = list(reader.fieldnames or [])
                self.assertEqual(row[verdict_field], "exact")
                self.assertEqual(row[f"original_{verdict_field}"], "missed")
                self.assertNotIn("found" if verdict_field == "verdict" else "verdict", fields)


class ComputeBaselineTests(unittest.TestCase):
    def test_load_results_round_trips_quoted_free_text(self):
        notes = 'judge said "exact"\tfirst line\nsecond line'
        with tempfile.TemporaryDirectory() as temp:
            results_file = Path(temp) / "results.tsv"
            with results_file.open("w", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=["cve", "verdict", "notes"], delimiter="\t")
                writer.writeheader()
                writer.writerow({"cve": "CVE-1", "verdict": "exact", "notes": notes})

            rows = compute_baseline.load_results(results_file)

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["cve"], "CVE-1")
        self.assertEqual(rows[0]["verdict"], "exact")
        self.assertEqual(rows[0]["notes"], notes)

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
