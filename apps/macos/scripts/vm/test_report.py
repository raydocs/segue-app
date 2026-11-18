#!/usr/bin/env python3
"""Fail-count for the AI-lock matrix JSON. SUMMARY fails= is this number."""

import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import report


def _add(path, name, result, evidence="evidence", blocked_by=""):
    old = sys.stdin
    sys.stdin = io.StringIO(evidence)
    argv = ["report.py", "add", path, name, result]
    if blocked_by:
        argv.append(blocked_by)
    try:
        return report.main(argv)
    finally:
        sys.stdin = old


class ReportFailsTest(unittest.TestCase):
    def test_two_fails_are_two_not_a_boolean(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "matrix.json")
            self.assertEqual(
                report.main(
                    ["report.py", "init", path, "0", "all", "1", "core", "app", "satellite"]
                ),
                0,
            )
            self.assertEqual(_add(path, "armed-kernel-not-running", "PASS"), 0)
            self.assertEqual(_add(path, "restore-via-release-daemon", "FAIL", "no restore"), 0)
            self.assertEqual(_add(path, "expected-leak-doh-quic", "FAIL", "timeout"), 0)
            self.assertEqual(_add(path, "reboot-armed", "SKIP"), 0)
            self.assertEqual(_add(path, "reboot-clear", "PREPARED"), 0)
            self.assertEqual(_add(path, "dry", "DRY-RUN"), 0)

            document = report.load(path)
            self.assertEqual(report.count_fails(document), 2)
            self.assertEqual(document["host_kind"], "satellite")

            old_out = sys.stdout
            sys.stdout = io.StringIO()
            try:
                status = report.main(["report.py", "fails", path])
                printed = sys.stdout.getvalue().strip()
            finally:
                sys.stdout = old_out
            self.assertEqual(status, 0)
            self.assertEqual(printed, "2")

    def test_dump_wraps_the_document(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "matrix.json")
            self.assertEqual(
                report.main(["report.py", "init", path, "1", "all", "0", "", "", "vm"]),
                0,
            )
            self.assertEqual(_add(path, "one", "FAIL"), 0)
            text = report.dump_text(path)
            self.assertTrue(text.startswith("BEGIN-MATRIX-JSON\n"))
            self.assertTrue(text.endswith("END-MATRIX-JSON\n"))
            body = text[len("BEGIN-MATRIX-JSON\n") : -len("END-MATRIX-JSON\n")]
            document = json.loads(body)
            self.assertEqual(report.count_fails(document), 1)
            self.assertEqual(document["rows"][0]["name"], "one")

    def test_zero_rows_is_zero_fails(self):
        self.assertEqual(report.count_fails({"rows": []}), 0)
        self.assertEqual(report.count_fails({}), 0)

    def test_blocked_rows_are_fails_that_carry_the_arm_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "matrix.json")
            self.assertEqual(
                report.main(
                    ["report.py", "init", path, "0", "all", "1", "core", "app", "satellite"]
                ),
                0,
            )
            # A failed arm step no longer skips the later rows: each is a
            # FAIL that names the step in blocked_by.
            self.assertEqual(
                _add(path, "connected", "FAIL", "kernel never came up", "helper_kernel_up"),
                0,
            )
            self.assertEqual(
                _add(path, "kill-kernel", "FAIL", "no kernel pid file", "helper_kernel_up"),
                0,
            )
            self.assertEqual(_add(path, "expected-leak-doh-quic", "PASS"), 0)
            self.assertEqual(_add(path, "restore-via-release-daemon", "SKIP"), 0)

            document = report.load(path)
            rows = {row["name"]: row for row in document["rows"]}
            self.assertEqual(rows["connected"]["blocked_by"], "helper_kernel_up")
            self.assertEqual(rows["kill-kernel"]["blocked_by"], "helper_kernel_up")
            self.assertNotIn("blocked_by", rows["expected-leak-doh-quic"])
            self.assertNotIn("blocked_by", rows["restore-via-release-daemon"])
            # Blocked rows count in SUMMARY like any other FAIL.
            self.assertEqual(report.count_fails(document), 2)


if __name__ == "__main__":
    unittest.main()
