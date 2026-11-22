# SPDX-License-Identifier: GPL-3.0-or-later
""".agents/skills/release/release.sh makes a release of a stand-in repository.

A bare repository stands in for GitHub and a script for `gh`: it records what
it was asked and answers from files, so no test reaches the network.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
RELEASE = ROOT / ".agents" / "skills" / "release" / "release.sh"
GH = """#!/bin/sh
echo "$*" >>"$STUB/asked"
case "$1 $2" in
    "release view") [ -e "$STUB/released" ] ;;
    "run list") cat "$STUB/runs" 2>/dev/null || : ;;
    "run view") case "$*" in *jobs*) echo "| Build | success |" ;; *) echo https://example/run/7 ;; esac ;;
    "run download") cp -R "$STUB/logs" "$7" ;;
    "release create") touch "$STUB/released" ;;
esac
"""
LOGS = {
    "environment.log": "ProductVersion: 27.0.1\nUSE_CACHE=false\nPORTAL_TEST_EXPENSIVE=1\n",
    "build.log": "resolve-bun: using Bun 1.3.14 at /somewhere (downloaded)\n",
    "ctest.log": "1/3 Test: input\nRan 21 tests, 19 results as expected, 0 unexpected, 2 skipped\n"
    '  SKIPPED  portal-input-evil  ((skip-unless (locate-library "evil")))\nTest Passed.\n'
    "2/3 Test: swift\n\u2714 Test run with 31 tests in 7 suites passed after 2 seconds.\nTest Passed.\n"
    "3/3 Test: app-host\n 55 pass\n 0 fail\nRan 55 tests across 7 files. [803.00ms]\nTest Passed.\n",
    "python.log": "test_a (test_x.X.test_a) ... skipped 'no network'\nRan 82 tests in 52.507s\n",
    "views/test.log": "Ran 78 tests, 78 results as expected, 0 unexpected\n",
    "input/test.log": "Ran 17 tests, 13 results as expected, 0 unexpected, 4 skipped\n",
    "launcher/test.log": "Ran 42 tests, 41 results as expected, 0 unexpected, 1 skipped\n",
    "terminal-shell-startup/test.log": "Ran 2 tests, 2 results as expected, 0 unexpected\n",
    "package/test.log": "9 checks passed\n6 checks passed\n",
}


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="portal release ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.stub = self.root / "stub"
        for name, text in LOGS.items():
            (self.stub / "logs" / name).parent.mkdir(parents=True, exist_ok=True)
            (self.stub / "logs" / name).write_text(text)
        (self.root / "bin").mkdir()
        (self.root / "bin" / "gh").write_text(GH)
        (self.root / "bin" / "gh").chmod(0o755)
        identity = {f"GIT_{who}_{what}": value for who in ("AUTHOR", "COMMITTER")
                    for what, value in (("NAME", "Tester"), ("EMAIL", "tester@example.invalid"))}
        self.env = {**os.environ, **identity, "STUB": str(self.stub), "PORTAL_RELEASE_POLL": "0",
                    "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                    "PORTAL_RELEASE_REMOTE": str(self.root / "github.git")}
        self.git("init", "-q", "--bare", "-b", "main", self.root / "github.git", cwd=self.root)
        self.git("clone", "-q", self.root / "github.git", "dev", cwd=self.root)
        self.dev = self.root / "dev"
        shutil.copy(ROOT / "portal-build.el", self.dev)
        (self.dev / "native").mkdir()
        (self.dev / "native" / "Package.swift").write_text("// one\n")
        (self.dev / "portal.el").write_text(";;; portal.el\n;; Version: 0.1.0\n;; Other: line\n")
        self.commit("portal/first: Portal exists")

    def git(self, *arguments, cwd=None):
        return subprocess.run(["git", *map(str, arguments)], cwd=cwd or self.dev, env=self.env,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, subject):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", subject)
        self.git("push", "-q", "origin", "HEAD:main")
        return self.git("rev-parse", "HEAD")

    def release(self, *arguments, ok=True, **environment):
        result = subprocess.run(["sh", str(RELEASE), *map(str, arguments)], cwd=self.root,
                                env={**self.env, **environment}, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        self.git("fetch", "-q", "--prune", "--tags", "origin")
        return result.stdout + result.stderr

    def asked(self):
        return (self.stub / "asked").read_text()

    def publish(self, version):
        """Release VERSION from main as a green run allows; return the release commit."""
        (self.stub / "runs").write_text("7\n")
        self.release("candidate", version)
        (self.root / "notes.md").write_text(self.release("notes", version))
        commit = self.git("rev-parse", f"origin/release/v{version}")
        self.release("publish", version, "notes.md")
        return commit

    def test_the_candidate_is_the_version_line_alone_checked_uncached(self):
        base = self.git("rev-parse", "HEAD")
        (self.stub / "runs").write_text("7\n")
        output = self.release("candidate")
        self.assertIn("Checks run 7", output)
        self.assertEqual(self.git("rev-parse", "origin/release/v0.2.0^"), base)
        self.assertEqual(self.git("diff", "--numstat", base, "origin/release/v0.2.0"),
                         "1\t1\tportal.el")
        self.assertIn(";; Version: 0.2.0", self.git("show", "origin/release/v0.2.0:portal.el"))
        self.assertIn("workflow run checks.yml --ref release/v0.2.0 -f cache=false", self.asked())
        self.assertEqual(self.git("rev-parse", "origin/main"), base)

    def test_a_version_not_above_the_current_one_is_refused(self):
        for version in ("0.1.0", "0.0.9", "next"):
            self.assertIn("release:", self.release("candidate", version, ok=False))
        self.assertEqual(self.git("branch", "-r", "--list", "origin/release/*"), "")

    def test_notes_give_every_count_and_skip_and_refuse_a_cached_run(self):
        (self.stub / "runs").write_text("7\n")
        self.release("candidate")
        (self.stub / "runs").write_text("")
        self.assertIn("no green Checks run", self.release("notes", "0.2.0", ok=False))
        (self.stub / "runs").write_text("7\n")
        notes = self.release("notes", "0.2.0")
        for line in ("The first release.", "- CTest input: passed; Ran 21 tests",
                     "- python: Ran 82 tests", "- package: 6 checks passed",
                     "- CTest swift: passed; Test run with 31 tests in 7 suites",
                     "- CTest app-host: passed; Ran 55 tests across 7 files.", "- views: Ran 78 tests", "| Build | success |",
                     "- CTest input: portal-input-evil  ((skip-unless",
                     "- python: test_a (test_x.X.test_a) ... skipped 'no network'",
                     "Bun 1.3.14", "https://example/run/7"):
            self.assertIn(line, notes)
        (self.root / "notes.md").write_text(notes)
        # Evidence with a suite's count missing is no notes at all.
        logs = self.stub / "logs"
        (logs / "package" / "test.log").write_text("package-gui: could not start\n")
        self.assertEqual(self.release("notes", "0.2.0", ok=False),
                         "release: the run's logs do not count package's tests\n")
        (logs / "package" / "test.log").write_text(LOGS["package/test.log"])
        (logs / "ctest.log").write_text(LOGS["ctest.log"] + "4/4 Test: quiet\nTest Passed.\n")
        self.assertIn("no count for the CTest suite quiet", self.release("notes", "0.2.0", ok=False))
        (logs / "ctest.log").write_text(LOGS["ctest.log"])
        # A run that left out the full set's checks is no evidence either.
        (self.stub / "logs" / "environment.log").write_text("USE_CACHE=false\nPORTAL_TEST_EXPENSIVE=\n")
        self.assertIn("left out the full set's checks", self.release("notes", "0.2.0", ok=False))
        (self.stub / "logs" / "environment.log").write_text("USE_CACHE=true\nPORTAL_TEST_EXPENSIVE=1\n")
        self.assertIn("no evidence", self.release("notes", "0.2.0", ok=False))
        self.assertIn("no evidence", self.release("publish", "0.2.0", "notes.md", ok=False))

    def test_publishing_moves_the_tag_stable_and_main_together(self):
        first = self.publish("0.2.0")
        for name in ("v0.2.0^{commit}", "origin/stable", "origin/main"):
            self.assertEqual(self.git("rev-parse", name), first)
        self.assertIn("release create v0.2.0 --verify-tag --title Portal 0.2.0", self.asked())
        self.assertEqual(self.git("branch", "-r", "--list", "origin/release/*"), "")

        # The next one: main moves on while the candidate is checked.
        self.git("pull", "-q", "origin", "main")
        (self.dev / "native" / "Package.swift").write_text("// two\n")
        base = self.commit("portal/second: the native part changed")
        self.release("candidate", "patch", base)
        (self.dev / "later.el").write_text(";; later\n")
        later = self.commit("portal/third: after the base")
        # Without Emacs the upgrade's cost is unknown, which is not "no rebuild".
        self.assertIn("no build identity",
                      self.release("notes", "0.2.1", ok=False, EMACS=self.root / "no-emacs"))
        notes = self.release("notes", "0.2.1")
        self.assertIn("- the native part changed", notes)
        self.assertNotIn("after the base", notes)
        self.assertIn("offers a rebuild", notes)
        second = self.git("rev-parse", "origin/release/v0.2.1")
        (self.root / "notes.md").write_text(notes)
        self.release("publish", "0.2.1", "notes.md")
        self.assertEqual(self.git("rev-parse", "origin/stable"), second)
        self.assertEqual(self.git("rev-parse", "origin/main^1", "origin/main^2"),
                         f"{later}\n{second}")
        self.assertIn(";; Version: 0.2.1", self.git("show", "origin/main:portal.el"))

    def test_a_base_that_stable_cannot_fast_forward_to_is_refused(self):
        first = self.publish("0.2.0")
        self.assertIn("nothing new since v0.2.0", self.release("candidate", "minor", first, ok=False))
        self.git("checkout", "-q", "-b", "side", f"{first}^")
        (self.dev / "side.el").write_text(";; side\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "a fix made from the wrong commit")
        self.git("push", "-q", "origin", "side")
        self.assertIn("stable is not an ancestor", self.release("candidate", "patch", "side", ok=False))
        self.assertEqual(self.git("branch", "-r", "--list", "origin/release/*"), "")


if __name__ == "__main__":
    unittest.main()
