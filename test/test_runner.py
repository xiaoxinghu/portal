"""./test.sh's planning, gates, evidence and cleanup, and the Lisp suite
runner, with harmless fake suites: nothing here opens a window or takes focus."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "test"))
import runner  # noqa: E402

EMACS = os.environ.get("EMACS") or shutil.which("emacs") or "emacs"

# Fake suites, registered through the real portal_suite. Each records that it
# ran; some write the Lisp runner's results file as portal-suite.el would.
REGISTRY = r'''
cmake_minimum_required(VERSION 3.29)
project(fake NONE)
include(CTest)
include("@ROOT@/test/suites.cmake")
set(mark "echo ran >> ${CMAKE_BINARY_DIR}/ran-$PORTAL_TEST_SUITE")
portal_suite(alpha CATEGORY unit FEATURES one COMMAND sh -c "${mark}")
portal_suite(beta CATEGORY unit FEATURES two COMMAND sh -c "${mark}")
portal_suite(gamma CATEGORY integration FEATURES one two COMMAND sh -c "${mark}")
portal_suite(declared CATEGORY unit FEATURES skips COMMAND sh -c
    "${mark}; printf '%s' '{\"tests\":[{\"name\":\"a\",\"status\":\"passed\"},{\"name\":\"b\",\"status\":\"declared-skip\"}]}' > $PORTAL_TEST_RESULTS_DIR/$PORTAL_TEST_SUITE.json"
    --allow-skip b)
portal_suite(skipping CATEGORY unit FEATURES bad COMMAND sh -c
    "printf '%s' '{\"tests\":[{\"name\":\"c\",\"status\":\"skipped\"}]}' > $PORTAL_TEST_RESULTS_DIR/$PORTAL_TEST_SUITE.json; exit 1")
portal_suite(failing CATEGORY unit FEATURES bad COMMAND sh -c "exit 3")
portal_suite(slow CATEGORY unit FEATURES slow TIMEOUT 1 COMMAND sh -c "sleep 20")
portal_suite(lingering CATEGORY unit FEATURES lingering TIMEOUT 60 COMMAND sh -c
    "sleep 300 & echo $! > ${CMAKE_BINARY_DIR}/child; sleep 300")
portal_suite(window CATEGORY gui FEATURES one EFFECTS desktop COMMAND sh -c "${mark}")
portal_suite(churn CATEGORY stress FEATURES one COMMAND sh -c "${mark}")
portal_suite(churn-window CATEGORY stress FEATURES one EFFECTS desktop COMMAND sh -c "${mark}")
portal_suite(service CATEGORY external FEATURES one EFFECTS desktop external
    NEEDS env:PORTAL_FAKE_SERVICE program:sh COMMAND sh -c "${mark}")
'''


def run_count(build, name):
    path = Path(build) / f"ran-{name}"
    return len(path.read_text().splitlines()) if path.exists() else 0


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.build = Path(self.temporary.name) / "build"
        source = Path(self.temporary.name) / "source"
        source.mkdir()
        (source / "CMakeLists.txt").write_text(REGISTRY.replace("@ROOT@", str(ROOT)))
        subprocess.run(["cmake", "-S", str(source), "-B", str(self.build)], check=True,
                       capture_output=True, timeout=60)
        self.lock = Path(self.temporary.name) / "desktop.lock"
        self.environment = dict(os.environ, PORTAL_TEST_DESKTOP_LOCK=str(self.lock))
        self.environment.pop("PORTAL_FAKE_SERVICE", None)

    def tsh(self, *arguments, timeout=60, **options):
        return subprocess.run([str(ROOT / "test.sh"), *arguments, "--build-dir", str(self.build),
                               "--no-build"], capture_output=True, text=True, timeout=timeout,
                              env=options.pop("env", self.environment), **options)

    def runs(self):
        return runner.previous_runs(self.build / "test-runs")

    def test_plans_exact_selections_once_in_category_order(self):
        suites = runner.load_suites(self.build)
        names = lambda command, *selectors: [s.name for s in runner.plan(command, selectors, suites, ()).suites]
        self.assertEqual(names("headless", "one", "alpha", "gamma"), ["alpha", "gamma"])
        self.assertEqual(names("unit", "two"), ["beta"])
        self.assertEqual(names("regression", "one"), ["alpha", "gamma", "window", "churn", "churn-window"])
        self.assertNotIn("service", names("regression"))
        self.assertEqual(names("all", "one")[-1], "service")
        for command, selectors, message in (("nope", (), "Unknown command"),
                                            ("unit", ("alph",), "Unknown suite or feature"),
                                            ("unit", ("lingerin",), "Unknown suite or feature"),
                                            ("gui", ("two",), "No gui suite matches")):
            with self.subTest(command=command, selectors=selectors):
                with self.assertRaisesRegex(runner.Refusal, message):
                    runner.plan(command, selectors, suites, ())

    def test_list_shows_the_plan_and_needs_without_running(self):
        result = self.tsh("all", "--suite", "one", "--list")
        self.assertEqual(result.returncode, 0, result.stderr)
        for text in ("Needs --allow-gui", "Needs --allow-external", "window", "service",
                     "setup: env:PORTAL_FAKE_SERVICE, program:sh", "Not selected"):
            self.assertIn(text, result.stdout)
        self.assertFalse((self.build / "test-runs").exists())
        self.assertEqual(run_count(self.build, "window"), 0)

    def test_gates_refuse_before_anything_runs(self):
        for arguments, option in ((("gui",), "--allow-gui"), (("regression", "--suite", "one"), "--allow-gui"),
                                  (("external", "--allow-gui"), "--allow-external"),
                                  (("manual", "--allow-gui"), "--interactive"),
                                  (("stress",), "--allow-gui")):
            with self.subTest(arguments=arguments):
                result = self.tsh(*arguments)
                self.assertEqual(result.returncode, runner.REFUSED, result.stdout)
                self.assertIn(f"{option} is required", result.stderr)
        self.assertFalse((self.build / "test-runs").exists())
        # A headless stress selection needs no permission.
        result = self.tsh("stress", "--suite", "churn")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(run_count(self.build, "churn"), 1)

    def test_missing_setup_is_incomplete_and_runs_nothing(self):
        result = self.tsh("external", "--allow-external", "--allow-gui")
        self.assertEqual(result.returncode, runner.INCOMPLETE)
        self.assertIn("service needs PORTAL_FAKE_SERVICE set", result.stderr)
        result = self.tsh("external", "--allow-external", "--allow-gui",
                              env=dict(self.environment, PORTAL_FAKE_SERVICE="/nonexistent/path"))
        self.assertIn("to name an existing path", result.stderr)
        self.assertEqual(run_count(self.build, "service"), 0)
        result = self.tsh("external", "--allow-external", "--allow-gui",
                              env=dict(self.environment, PORTAL_FAKE_SERVICE=self.temporary.name))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(run_count(self.build, "service"), 1)
        # Manual checks need a person at a terminal, which a pipe is not.
        result = self.tsh("manual", "--interactive", "--allow-gui", stdin=subprocess.DEVNULL)
        self.assertEqual(result.returncode, runner.INCOMPLETE)
        self.assertIn("interactive terminal", result.stderr)

    def test_results_failures_timeouts_and_skips_reach_the_record(self):
        result = self.tsh("unit", "--suite", "alpha", "--suite", "skips", "--suite", "bad",
                              "--suite", "slow")
        self.assertEqual(result.returncode, runner.FAILED)
        (run,) = self.runs()
        statuses = {item["name"]: item for item in run["results"]}
        self.assertEqual(statuses["alpha"]["status"], "passed")
        self.assertEqual(statuses["declared"]["status"], "passed")
        self.assertEqual(statuses["declared"]["declared_skips"], ["b"])
        self.assertEqual(statuses["skipping"]["status"], "failed")
        self.assertEqual(statuses["skipping"]["skipped"], ["c"])
        self.assertEqual(statuses["failing"]["status"], "failed")
        self.assertEqual(statuses["slow"]["message"], "Timeout")
        self.assertEqual(run["status"], "failed")
        self.assertIn("unexpected skips: c", result.stdout)
        self.assertIn("declared skips: b", result.stdout)
        self.assertIn("Status: failed", result.stdout)
        # Not selected suites are listed as such.
        self.assertIn("gamma", run["not_selected"]["integration"])
        self.assertTrue(run["inputs"]["files"]["test/runner.py"])
        self.assertTrue(run["inputs_stable"])

    def test_declared_skips_leave_the_exhaustive_run_incomplete(self):
        self.assertEqual(self.tsh("unit", "--suite", "skips").returncode, 0)
        result = self.tsh("all", "--suite", "skips", "--reason", "exhaustive scope")
        self.assertEqual(result.returncode, runner.INCOMPLETE, result.stdout)
        self.assertEqual(self.runs()[-1]["status"], "incomplete")

    def test_unchanged_inputs_reuse_evidence_and_reruns_need_a_reason(self):
        self.assertEqual(self.tsh("unit", "--suite", "one", "--suite", "two").returncode, 0)
        self.assertEqual(run_count(self.build, "alpha"), 1)
        # A covered subset with the same inputs cites the earlier run.
        result = self.tsh("unit", "--suite", "alpha")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Not run:", result.stdout)
        self.assertEqual(run_count(self.build, "alpha"), 1)
        self.assertEqual(len(self.runs()), 1)
        result = self.tsh("unit", "--suite", "alpha", "--reason", "checking the runner")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(run_count(self.build, "alpha"), 2)
        latest = self.runs()[-1]
        self.assertEqual(latest["reason"], "checking the runner")
        self.assertEqual(len(latest["earlier_attempts"]), 1)
        # Retrying a failure unchanged is refused; every attempt stays recorded.
        self.assertEqual(self.tsh("unit", "--suite", "failing").returncode, runner.FAILED)
        result = self.tsh("unit", "--suite", "failing")
        self.assertEqual(result.returncode, runner.REFUSED)
        self.assertIn("needs --reason", result.stderr)
        result = self.tsh("unit", "--suite", "failing", "--repeat", "2", "--reason", "flake check")
        self.assertEqual(result.returncode, runner.FAILED)
        repeated = self.runs()[-1]
        self.assertEqual([item["iteration"] for item in repeated["results"]], [1, 2])
        self.assertEqual(len(self.runs()), 4)
        self.assertNotEqual(self.tsh("unit", "--repeat", "2").returncode, 0)

    def test_desktop_runs_hold_one_lock_across_worktrees(self):
        with open(self.lock, "a+") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            held.write('{"worktree": "elsewhere"}\n')
            held.flush()
            result = self.tsh("gui", "--allow-gui", "--suite", "window")
            self.assertEqual(result.returncode, runner.REFUSED)
            self.assertIn("Another desktop test run holds", result.stderr)
            self.assertIn("elsewhere", result.stderr)
            self.assertEqual(run_count(self.build, "window"), 0)
            # Headless runs never wait for the desktop.
            self.assertEqual(self.tsh("unit", "--suite", "alpha").returncode, 0)
        result = self.tsh("gui", "--allow-gui", "--suite", "window")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(run_count(self.build, "window"), 1)
        # The lock is free again, and says nothing stale.
        with open(self.lock, "a+") as file:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            file.seek(0)
            self.assertEqual(file.read(), "")

    def test_interruption_stops_the_suites_children_and_records_it(self):
        process = subprocess.Popen([str(ROOT / "test.sh"), "unit", "--suite", "lingering",
                                    "--build-dir", str(self.build), "--no-build"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   env=self.environment)
        child = self.build / "child"
        for _ in range(200):
            if child.exists() and child.read_text().strip():
                break
            time.sleep(0.05)
        pid = int(child.read_text())
        self.assertTrue(runner.alive(pid))
        process.send_signal(signal.SIGINT)
        output, _ = process.communicate(timeout=30)
        self.assertEqual(process.returncode, runner.INTERRUPTED, output)
        for _ in range(100):
            if not runner.alive(pid):
                break
            time.sleep(0.05)
        self.assertFalse(runner.alive(pid))
        (run,) = self.runs()
        self.assertEqual(run["status"], "interrupted")
        self.assertTrue(run["finished"])

    def test_manual_checks_record_what_a_person_reports(self):
        main, secondary = pty.openpty()
        process = subprocess.Popen([str(ROOT / "test.sh"), "manual", "--interactive", "--allow-gui",
                                    "--suite", "launcher-voiceover", "--build-dir", str(self.build),
                                    "--no-build"], stdin=secondary, stdout=secondary, stderr=secondary,
                                   env=self.environment)
        os.close(secondary)
        output = b""
        answers = [(b"Result?", b"n\n"), (b"Notes", b"VoiceOver unavailable here\n")]
        deadline = time.monotonic() + 30
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([main], [], [], 0.1)[0]:
                with contextlib.suppress(OSError):
                    output += os.read(main, 4096)
                if answers and answers[0][0] in output.split(b"Procedure")[-1]:
                    os.write(main, answers.pop(0)[1])
        process.wait(timeout=10)
        os.close(main)
        self.assertEqual(process.returncode, runner.INCOMPLETE, output.decode())
        self.assertIn(b"VoiceOver", output)
        (run,) = self.runs()
        (check,) = run["results"]
        self.assertEqual((check["name"], check["status"], check["notes"]),
                         ("launcher-voiceover", "not-tested", "VoiceOver unavailable here"))
        self.assertTrue(check["operator"])

    def test_every_manual_check_has_its_procedure(self):
        for check in runner.MANUAL_CHECKS:
            with self.subTest(check=check.name):
                self.assertGreater(len(check.steps()), 40)
                for part in check.command:
                    if part.endswith(".sh"):
                        self.assertTrue((ROOT / part).is_file())

    def test_evidence_compares_recorded_inputs_with_the_tree(self):
        self.assertEqual(self.tsh("unit", "--suite", "alpha").returncode, 0)
        (run,) = self.runs()
        result = self.tsh("evidence", run["path"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Suites: alpha", result.stdout)
        self.assertTrue(runner.documentation_only(["docs/testing.md", "tasks/x.md"]))
        self.assertFalse(runner.documentation_only(["docs/launcher.md"]))
        self.assertFalse(runner.documentation_only(["test/runner.py"]))
        before = {"a": "1", "b": "2"}
        self.assertEqual(runner.changed_paths(before, {"a": "1", "c": "3"}), ["b", "c"])


class SuiteRunnerTests(unittest.TestCase):
    """test/portal-suite.el runs exactly one file's tests and reports skips."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        (self.directory / "other-tests.el").write_text(
            "(require 'ert)\n(ert-deftest other-fails () (should nil))\n(provide 'other-tests)\n")
        (self.directory / "mine-tests.el").write_text(
            "(require 'other-tests)\n(ert-deftest mine-passes () (should t))\n"
            "(ert-deftest mine-skips () (skip-unless nil))\n")

    def suite(self, file, *options):
        results = self.directory / "results"
        result = subprocess.run(
            [EMACS, "--batch", "-Q", "-L", str(self.directory), "-l", str(ROOT / "test/portal-suite.el"),
             "-f", "portal-suite-batch", str(self.directory / file), *options],
            capture_output=True, text=True, timeout=60,
            env=dict(os.environ, PORTAL_TEST_RESULTS_DIR=str(results), PORTAL_TEST_SUITE="mine"))
        report = results / "mine.json"
        return result, (json.loads(report.read_text()) if report.exists() else None)

    def test_runs_only_the_files_own_tests_and_fails_on_undeclared_skips(self):
        result, report = self.suite("mine-tests.el")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual({test["name"]: test["status"] for test in report["tests"]},
                         {"mine-passes": "passed", "mine-skips": "skipped"})
        self.assertIn("1 passed, 0 failed, 1 skipped, 0 declared skips", result.stderr)
        result, report = self.suite("mine-tests.el", "--allow-skip", "mine-skips")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([test["status"] for test in report["tests"]], ["passed", "declared-skip"])

    def test_failures_empty_files_unknown_skips_and_load_errors_fail(self):
        (self.directory / "empty-tests.el").write_text(";; No tests.\n")
        (self.directory / "broken-tests.el").write_text("(ert-deftest broken (should t)\n")
        for file, options in (("other-tests.el", ()), ("empty-tests.el", ()),
                              ("mine-tests.el", ("--allow-skip", "no-such-test")),
                              ("broken-tests.el", ()), ("missing-tests.el", ())):
            with self.subTest(file=file, options=options):
                result, _ = self.suite(file, *options)
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_helper_files_define_no_tests(self):
        """Loading a shared fixture file must not add another suite's tests."""
        elpa = Path(os.environ.get("PORTAL_TEST_ELPA") or ROOT / "build/elpa")
        load_path = ["-L", str(ROOT), "-L", str(ROOT / "test")]
        for package in sorted(elpa.glob("*")):
            load_path += ["-L", str(package)]
        helpers = sorted(ROOT.glob("test/portal-*-testing.el")) + [
            ROOT / "test/portal-suite.el", ROOT / "test/portal-fake-native.el",
            ROOT / "test/portal-launcher-examples.el"]
        self.assertGreaterEqual(len(helpers), 7)
        for helper in helpers:
            with self.subTest(helper=helper.name):
                result = subprocess.run(
                    [EMACS, "--batch", "-Q", *load_path, "-l", str(helper), "--eval",
                     "(progn (require 'ert) (princ (length (ert-select-tests t t))) (kill-emacs 0))"],
                    capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "0", result.stderr)


if __name__ == "__main__":
    unittest.main()
