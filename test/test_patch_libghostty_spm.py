# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/patch-libghostty-spm.sh against a local stand-in for the package's repository."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tools" / "patch-libghostty-spm.sh"
# The developer's Git settings, such as signing, must not reach the fixtures.
GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@invalid",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@invalid"}


def git(directory, *args):
    return subprocess.run(["git", "-C", str(directory), *args], check=True, env=GIT_ENV,
                          capture_output=True, text=True).stdout.strip()


class PatchLibghosttySpm(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        git(self.upstream, "init", "-q")
        (self.upstream / "Package.swift").write_text("one\ntwo\nthree\n")
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-q", "-m", "release")
        git(self.upstream, "tag", "1.0")
        self.revision = git(self.upstream, "rev-parse", "HEAD")
        self.patches = self.root / "patches"
        self.patches.mkdir()
        self.dest = self.root / "build" / "libghostty-spm"
        self.pin(self.revision)

    def tearDown(self):
        self.temporary.cleanup()

    def pin(self, revision):
        self.pin_file = self.root / "pin.json"
        self.pin_file.write_text(json.dumps({
            "url": self.upstream.as_uri(), "version": "1.0", "revision": revision}))

    def add_patch(self, name, old, new):
        """Write a patch, made with format-patch, that changes line OLD to NEW."""
        work = self.root / "work"
        subprocess.run(["git", "clone", "-q", str(self.upstream), str(work)], check=True,
                       env=GIT_ENV)
        path = work / "Package.swift"
        path.write_text(path.read_text().replace(old, new))
        git(work, "commit", "-q", "-am", f"{old} to {new}")
        patch = git(work, "format-patch", "-1", "--stdout")
        (self.patches / name).write_text(patch + "\n")
        subprocess.run(["rm", "-rf", str(work)], check=True)

    def run_script(self):
        return subprocess.run(
            ["sh", str(SCRIPT), str(self.pin_file), str(self.patches), str(self.dest)],
            env=GIT_ENV, capture_output=True, text=True)

    def package(self):
        return (self.dest / "Package.swift").read_text()

    def test_applies_the_patches_in_name_order(self):
        self.add_patch("0002-second.patch", "two", "2")
        # Applies only after 0002, against that patch's change.
        work = self.root / "first"
        subprocess.run(["git", "clone", "-q", str(self.upstream), str(work)], check=True,
                       env=GIT_ENV)
        subprocess.run(["git", "-C", str(work), "am", "-q", str(self.patches / "0002-second.patch")],
                       check=True, env=GIT_ENV, capture_output=True)
        path = work / "Package.swift"
        path.write_text(path.read_text().replace("2", "TWO"))
        git(work, "commit", "-q", "-am", "2 to TWO")
        (self.patches / "0003-third.patch").write_text(git(work, "format-patch", "-1", "--stdout") + "\n")

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.package(), "one\nTWO\nthree\n")
        self.assertIn("with 2 patches", result.stdout)
        self.assertEqual(git(self.dest, "rev-list", "--count", f"{self.revision}..HEAD"), "2")

    def test_keeps_a_current_copy_and_the_changes_made_in_it(self):
        self.add_patch("0001-one.patch", "one", "1")
        self.assertEqual(self.run_script().returncode, 0)
        (self.dest / "Package.swift").write_text("edited\n")

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.package(), "edited\n")
        self.assertIn("with the changes made in it", result.stderr)

    def test_replaces_the_copy_when_a_patch_changes(self):
        self.add_patch("0001-one.patch", "one", "1")
        self.assertEqual(self.run_script().returncode, 0)
        (self.dest / "Package.swift").write_text("edited\n")
        self.add_patch("0001-one.patch", "one", "uno")

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.package(), "uno\ntwo\nthree\n")
        self.assertEqual(result.stderr, "")

    def test_a_patch_that_does_not_apply_fails_and_keeps_the_copy(self):
        self.assertEqual(self.run_script().returncode, 0)
        # A patch against a line the release does not have.
        self.add_patch("0001-missing.patch", "one", "1")
        content = (self.patches / "0001-missing.patch").read_text()
        (self.patches / "0001-missing.patch").write_text(
            content.replace("-one\n+1", "-uno\n+1"))

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0001-missing.patch does not apply to libghostty-spm 1.0", result.stderr)
        self.assertEqual(self.package(), "one\ntwo\nthree\n")

    def test_a_tag_at_another_revision_fails(self):
        self.pin("0" * 40)

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"tag 1.0 is {self.revision}, not the revision", result.stderr)
        self.assertFalse(self.dest.exists())


if __name__ == "__main__":
    unittest.main()
