#!/usr/bin/env python3
"""Container-test verdicts: only a suite that asserted something and skipped
nothing may count as green (scripts/container-test/accounting.py)."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ACCOUNTING = ROOT / "scripts/container-test/accounting.py"
sys.dont_write_bytecode = True  # keep __pycache__ out of the image directory
sys.path.insert(0, str(ACCOUNTING.parent))
from accounting import judge, slug  # noqa: E402


class JudgeTest(unittest.TestCase):
    def test_verdicts(self):
        cases = [
            ("PASS: a\nPASS: b\n=== Results: 2 passed, 0 failed ===", 0, "pass"),
            ("Core model catalog: 5 passed, 0 failed", 0, "pass"),
            ("PASS: UTF-8 read boundaries\n", 0, "pass"),  # native test, no summary line
            ("=== Results: 0 passed, 0 failed ===", 0, "no_assertions"),
            ("", 0, "no_assertions"),
            ("SKIP: python3 not available", 0, "skipped"),
            ("PASS: a\n  SKIP: broker unavailable\n=== Results: 1 passed, 0 failed ===", 0, "partial_skip"),
            ("=== Results: 3 passed, 1 failed ===", 0, "fail"),  # counts beat a clean exit
            ("=== Results: 3 passed, 0 failed ===", 1, "fail"),
            ("SCRIPT ERROR: Parse Error\n=== Results: 3 passed, 0 failed ===", 0, "fail"),
            ("PASS: a", None, "not_run"),
            # The wrapper's suite count is not an assertion count.
            ("Functional suite: 1 passed, 0 failed", 0, "no_assertions"),
        ]
        for log, rc, expected in cases:
            with self.subTest(log=log, rc=rc):
                self.assertEqual(judge(log, rc)["verdict"], expected)

    def test_last_summary_wins(self):
        log = "sub: 9 passed, 0 failed\n=== Results: 4 passed, 2 failed ==="
        self.assertEqual((judge(log, 1)["passed"], judge(log, 1)["failed"]), (4, 2))
        wrapped = "=== 82 passed, 0 failed ===\n  -> PASS (t)\nFunctional suite: 1 passed, 0 failed"
        self.assertEqual(judge(wrapped, 0)["passed"], 82)


class RunTest(unittest.TestCase):
    def run_accounting(self, suites):
        with tempfile.TemporaryDirectory() as tmp:
            logs = Path(tmp)
            (logs / "tests.txt").write_text("\n".join(name for name, _, _ in suites) + "\n")
            for name, log, rc in suites:
                (logs / f"{slug(name)}.log").write_text(log)
                if rc is not None:
                    (logs / f"{slug(name)}.rc").write_text(f"{rc}\n")
            proc = subprocess.run([sys.executable, str(ACCOUNTING), str(logs),
                                   str(logs / "tests.txt"), str(logs / "results.json")],
                                  capture_output=True, text=True)
            return proc.returncode, json.loads((logs / "results.json").read_text())

    def test_green_only_when_every_suite_passes(self):
        ok = ("test/test_a.gd", "=== Results: 2 passed, 0 failed ===", 0)
        rc, results = self.run_accounting([ok, ("app-smoke", "PASS: up\n=== Results: 1 passed, 0 failed ===", 0)])
        self.assertEqual((rc, results["green"], results["passed_checks"]), (0, True, 3))

        # A skipped suite exits 0 under run-functional-tests.sh; here it is not green.
        rc, results = self.run_accounting([ok, ("test/test_b.gd", "SKIP: no plugin", 0)])
        self.assertEqual((rc, results["green"]), (1, False))
        # A suite killed before it wrote an exit code is not run, not passed.
        rc, results = self.run_accounting([ok, ("test/test_c.gd", "PASS: partial", None)])
        self.assertEqual((rc, results["suites"][1]["verdict"]), (1, "not_run"))


if __name__ == "__main__":
    unittest.main()
