# SPDX-License-Identifier: GPL-3.0-or-later
"""Native test failures must exit with status 1, never terminate by signal."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

DRIVER = r'''
import Foundation

@main
struct CheckFailureReporting {
    enum Failure: Error { case expected }

    static func main() {
        runChecks {
            switch CommandLine.arguments[1] {
            case "pass":
                var calls = 0
                func predicate() -> Bool { calls += 1; return true }
                check(predicate())
                check(calls == 1)
                let value: Int = require(42)
                check(value == 42)
            case "condition":
                check(false, "Expected condition failure", file: "fixture.swift", line: 17)
            case "missing":
                let _: Int = require(nil, "Expected missing value", file: "fixture.swift", line: 18)
            case "decode":
                let _: Any = require(try JSONSerialization.jsonObject(with: Data()))
            case "error":
                throw Failure.expected
            case "explicit":
                fail("Expected explicit failure", file: "fixture.swift", line: 19)
            default:
                fail("Unknown scenario")
            }
        }
        print("Completed")
    }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "compiles the macOS checks' helpers with Swift")
class NativeCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        driver = directory / "driver.swift"
        driver.write_text(DRIVER)
        cls.executable = directory / "check-native-failures"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
            str(ROOT / "test/native-checks.swift"), str(driver), "-o", str(cls.executable),
        ], check=True, capture_output=True, text=True, timeout=60)

    def run_scenario(self, scenario):
        return subprocess.run([str(self.executable), scenario], capture_output=True,
                              text=True, timeout=10)

    def test_success_continues(self):
        result = self.run_scenario("pass")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Completed\n")
        self.assertEqual(result.stderr, "")

    def test_failures_exit_without_crashing(self):
        for scenario, diagnostic in [
            ("condition", "fixture.swift:17: FAIL: Expected condition failure"),
            ("missing", "fixture.swift:18: FAIL: Expected missing value"),
            ("decode", "FAIL: Unexpected error:"),
            ("error", "FAIL: Unexpected error: expected"),
            ("explicit", "fixture.swift:19: FAIL: Expected explicit failure"),
        ]:
            with self.subTest(scenario=scenario):
                result = self.run_scenario(scenario)
                # subprocess uses a negative return code for termination by signal.
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(diagnostic, result.stderr)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
