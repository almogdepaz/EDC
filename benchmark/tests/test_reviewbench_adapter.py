"""Offline ReviewBench conversion and receipt contracts. No model calls."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ADAPTER = Path(__file__).resolve().parents[1] / "pr-review/reviewbench/adapter.py"
sys.path.insert(0, str(ADAPTER.parent))

SECURITY = """# Review: target
## Module: `source`
# Security Review Report
## Findings
### HIGH: unchecked value
- where: `src/main.py:2-3`
- impact: untrusted input reaches execution.
- recommendation: validate input.
## Limitations
None.
"""
DELIVERY = """# Delivery / Architecture Review
## Goal / Spec Delivery
### Findings
No findings.
## Architecture Fit
### Findings
No findings.
"""
QUALITY = """# Code Quality Audit
## Summary
- Quality risk score: 0/10
## Duplication
No actionable code-quality findings in the inspected scope.
"""
ISSUES = "# Known Issues\n\nNo actionable code-quality findings in the inspected scope.\n"


class AdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("reviewbench_adapter", ADAPTER)
        cls.adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.adapter)

    def reports(self):
        return dict(security=SECURITY, delivery=DELIVERY, complexity=QUALITY, issues=ISSUES)

    def convert(self, reports=None, bounds=None):
        return self.adapter.convert_reports(reports or self.reports(), bounds or {"src/main.py": 4}, "edc")

    def test_extract_final_logical_finding(self):
        findings = self.convert()
        self.assertEqual(len(findings), 1)
        self.assertEqual((findings[0]["file"], findings[0]["start_line"], findings[0]["end_line"]), ("src/main.py", 2, 3))
        self.assertIn("untrusted input", findings[0]["message"])
        self.assertEqual(findings[0]["producer"], "edc")

    def test_explicit_zero_not_malformed(self):
        reports = self.reports()
        reports["security"] = "## Findings\n### No security findings\nChecked validation.\n"
        self.assertEqual(self.convert(reports), [])
        for malformed in ["", "## Findings\n", "## Findings\nlooks fine", "## Findings\n### HIGH: lost location\n- impact: bad"]:
            reports["security"] = malformed
            with self.subTest(malformed=malformed), self.assertRaises(self.adapter.AdapterError):
                self.convert(reports)

    def test_delivery_quality_and_exact_deduplication(self):
        reports = self.reports()
        reports["delivery"] = DELIVERY.replace("No findings.", "#### IMPORTANT — wrong behavior\n- implementation evidence: `src/main.py:1`\n- why it matters: loses data.", 1)
        reports["complexity"] = QUALITY.replace("No actionable code-quality findings in the inspected scope.", "- src/main.py:L3-L4: yagni: duplicate wrapper. Inline it.")
        reports["issues"] = "# Known Issues\n## HIGH — error dropped\n- where: src/main.py:2\n- problem: errors silently disappear.\n"
        reports["security"] += SECURITY
        self.assertEqual(len(self.convert(reports)), 4)

    def test_unsupported_ambiguous_and_unsafe_evidence(self):
        for location in ["../secret:1", "/tmp/secret:1", "./src/main.py:1", "src\\main.py:1", "src/main.py:0", "src/main.py:3-2", "src/main.py:4-5", "missing.py:1", "src/main.py:1 and src/main.py:2", "src/main.py", "src/main.py:2 (base)"]:
            reports = self.reports()
            reports["security"] = SECURITY.replace("src/main.py:2-3", location)
            with self.subTest(location=location), self.assertRaises(self.adapter.AdapterError):
                self.convert(reports)
        reports = self.reports()
        reports["complexity"] = "# Code Quality Audit\n## Duplication\n- a problem without a location\n"
        with self.assertRaises(self.adapter.AdapterError):
            self.convert(reports)

    def test_coverage_gap_never_empty_success(self):
        reports = self.reports()
        reports["security"] = "## Findings\n### No security findings\n## Security Review Coverage Gap\nUnavailable.\n"
        with self.assertRaises(self.adapter.AdapterError):
            self.convert(reports)
        result = dict(kind="review-all", status="success-with-warning", exitCode=0, phases=[])
        with self.assertRaises(self.adapter.AdapterError):
            self.adapter.validate_result(result, "a" * 40)

    def test_result_requires_committed_candidate_and_matching_base(self):
        result = dict(schemaVersion=1, kind="review-all", status="success", exitCode=0,
                      startedHead="a" * 40, finishedHead="a" * 40, candidateCommit="a" * 40,
                      base="b" * 40, scope="differential", candidateKind="committed",
                      dirtyTrackedIncluded=False, untrackedIncluded=False,
                      phases=[dict(phase=p, status="success", exitCode=0, childExitCode=0)
                              for p in ("security", "delivery", "quality")])
        self.adapter.validate_result(result, "a" * 40, "b" * 40)
        for key, value in [("base", "c" * 40), ("dirtyTrackedIncluded", True), ("untrackedIncluded", True), ("scope", "full")]:
            with self.subTest(key=key), self.assertRaises(self.adapter.AdapterError):
                self.adapter.validate_result(dict(result, **{key: value}), "a" * 40, "b" * 40)

    def test_receipt_resume_checks_identity_and_all_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "job"
            identity = {"source": "source", "base": "a", "head": "b", "runtime": "r", "config": "c", "converter": "v"}
            self.assertFalse(self.adapter.begin_job(root, identity))
            with self.assertRaises(self.adapter.AdapterError):
                self.adapter.begin_job(root, identity)
            (root / "raw.txt").write_text("report")
            self.adapter.complete_job(root, identity)
            self.assertTrue(self.adapter.begin_job(root, identity))
            for key in identity:
                with self.subTest(key=key), self.assertRaises(self.adapter.AdapterError):
                    self.adapter.begin_job(root, dict(identity, **{key: "changed"}))
            (root / "raw.txt").write_text("corrupted")
            with self.assertRaises(self.adapter.AdapterError):
                self.adapter.begin_job(root, identity)

    def test_real_coordinator_context_notice_is_not_a_finding(self):
        notice = ("\n## Context policy\n\nContext: ignored (explicit no-build review).\n"
                  "Scope uses an explicit source-file inventory, not generated modules. Existing context is unverified optional guidance in no-refresh mode and excluded in ignored mode.\n"
                  "Coverage is limited to assigned files and necessary supporting evidence; this does not establish complete architectural understanding.\n")
        reports = {key: value + notice for key, value in self.reports().items()}
        self.assertEqual(len(self.convert(reports)), 1)

    def test_partial_receipt_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "job"
            root.mkdir()
            (root / "receipt.json").write_text('{"state":"succeeded"}')
            with self.assertRaises(self.adapter.AdapterError):
                self.adapter.begin_job(root, {})


if __name__ == "__main__":
    unittest.main()
