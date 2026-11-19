# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/build-ghostty-linux.sh against a local stand-in for Ghostty's repository and for Zig."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tools" / "build-ghostty-linux.sh"
# The developer's Git settings, such as signing, must not reach the fixtures.
GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@invalid",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@invalid"}
# Stands in for Zig: records how it was called and installs what Ghostty's build would.
FAKE_ZIG = """#!/bin/sh
if [ "$1" = version ]; then echo 0.0.0; exit 0; fi
[ -f build.zig.zon ] || { echo "not run in the source copy" >&2; exit 1; }
printf '%s\\n' "$@" >"$ZIG_CALL"
[ -z "${ZIG_FAILS:-}" ] || exit 1
while [ "$#" -gt 0 ]; do
    [ "$1" = --prefix ] && prefix=$2
    shift
done
mkdir -p "$prefix/lib" "$prefix/include" "$prefix/share/ghostty"
cp source.txt "$prefix/lib/ghostty-internal.so"
"""


def git(directory, *args):
    return subprocess.run(["git", "-C", str(directory), *args], check=True, env=GIT_ENV,
                          capture_output=True, text=True).stdout.strip()


@unittest.skipUnless(sys.platform == "linux", "builds Ghostty's library on Linux only")
class BuildGhosttyLinux(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        git(self.upstream, "init", "-q")
        (self.upstream / "source.txt").write_text("one\ntwo\nthree\n")
        (self.upstream / "build.zig.zon").write_text('.{ .minimum_zig_version = "9.8.7" }\n')
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-q", "-m", "release")
        # Annotated, as Ghostty's release tags are.
        git(self.upstream, "tag", "-a", "-m", "v1.0.0", "v1.0.0")
        self.revision = git(self.upstream, "rev-parse", "HEAD")
        self.patches = self.root / "patches"
        self.patches.mkdir()
        self.source = self.root / "build" / "ghostty"
        self.prefix = self.root / "build" / "ghostty-linux"
        self.zig = self.root / "zig"
        self.zig.write_text(FAKE_ZIG)
        self.zig.chmod(0o755)
        self.zig_call = self.root / "zig-call"
        self.pin(self.revision)

    def tearDown(self):
        self.temporary.cleanup()

    def pin(self, revision):
        self.pin_file = self.root / "pin.json"
        self.pin_file.write_text(json.dumps({
            "url": self.upstream.as_uri(), "version": "v1.0.0", "revision": revision}, indent="\t"))

    def add_patch(self, name, old, new):
        """Write a patch, made with format-patch, that changes line OLD to NEW."""
        work = self.root / "work"
        subprocess.run(["git", "clone", "-q", str(self.upstream), str(work)], check=True,
                       env=GIT_ENV)
        path = work / "source.txt"
        path.write_text(path.read_text().replace(old, new))
        git(work, "commit", "-q", "-am", f"{old} to {new}")
        patch = git(work, "format-patch", "-1", "--stdout")
        (self.patches / name).write_text(patch + "\n")
        subprocess.run(["rm", "-rf", str(work)], check=True)

    def run_script(self, *args, **env):
        return subprocess.run(
            ["sh", str(SCRIPT), "--pin", str(self.pin_file), "--patches", str(self.patches),
             "--source", str(self.source), "--prefix", str(self.prefix), *args],
            env={**GIT_ENV, "ZIG": str(self.zig), "ZIG_CALL": str(self.zig_call), **env},
            capture_output=True, text=True)

    def built(self):
        """The patched source, as the stand-in for Zig installed it."""
        return (self.prefix / "lib" / "libghostty.so").read_text()

    def test_builds_the_patched_source_and_links_the_library_by_its_soname(self):
        self.add_patch("0001-one.patch", "one", "1")

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.built(), "1\ntwo\nthree\n")
        self.assertEqual(os.readlink(self.prefix / "lib" / "libghostty.so"), "ghostty-internal.so")
        self.assertIn("Patched Ghostty v1.0.0 with 1 patches", result.stdout)
        self.assertIn(f"resources  {self.prefix}/share/ghostty", result.stdout)
        self.assertEqual(self.zig_call.read_text().split("\n")[:-1], [
            "build", "-Dapp-runtime=none", "-Doptimize=ReleaseFast", "-Dversion-string=1.0.0",
            "-Demit-docs=false", "--prefix", str(self.prefix), "--cache-dir",
            f"{self.source}-cache"])

    def test_applies_the_patches_in_name_order(self):
        self.add_patch("0002-second.patch", "two", "2")
        # Applies only after 0002, against that patch's change.
        work = self.root / "first"
        subprocess.run(["git", "clone", "-q", str(self.upstream), str(work)], check=True,
                       env=GIT_ENV)
        subprocess.run(["git", "-C", str(work), "am", "-q", str(self.patches / "0002-second.patch")],
                       check=True, env=GIT_ENV, capture_output=True)
        path = work / "source.txt"
        path.write_text(path.read_text().replace("2", "TWO"))
        git(work, "commit", "-q", "-am", "2 to TWO")
        (self.patches / "0003-third.patch").write_text(git(work, "format-patch", "-1", "--stdout") + "\n")

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.built(), "one\nTWO\nthree\n")
        self.assertEqual(git(self.source, "rev-list", "--count", f"{self.revision}..HEAD"), "2")

    def test_the_mode_is_passed_to_zig(self):
        result = self.run_script("--optimize", "Debug")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-Doptimize=Debug", self.zig_call.read_text().split("\n"))
        self.assertIn("Built Ghostty v1.0.0 (Debug) with 0 patches", result.stdout)

    def test_another_mode_is_refused_before_anything_is_fetched(self):
        # ReleaseSafe among them: Ghostty at the pin does not compile in it.
        result = self.run_script("--optimize", "ReleaseSafe")

        self.assertEqual(result.returncode, 2)
        self.assertIn("not ReleaseSafe", result.stderr)
        self.assertFalse(self.source.exists())

    def test_relative_paths_are_the_callers_not_the_source_copys(self):
        result = subprocess.run(
            ["sh", str(SCRIPT), "--pin", "pin.json", "--patches", "patches",
             "--source", "build/ghostty", "--prefix", "out"],
            cwd=self.root, capture_output=True, text=True,
            env={**GIT_ENV, "ZIG": str(self.zig), "ZIG_CALL": str(self.zig_call)})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "out" / "lib" / "libghostty.so").read_text(),
                         "one\ntwo\nthree\n")
        self.assertEqual(git(self.source, "status", "--porcelain"), "")

    def test_keeps_a_current_copy_and_builds_the_changes_made_in_it(self):
        self.add_patch("0001-one.patch", "one", "1")
        self.assertEqual(self.run_script().returncode, 0)
        (self.source / "source.txt").write_text("edited\n")

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.built(), "edited\n")
        self.assertIn("with the changes made in it", result.stderr)

    def test_replaces_the_copy_when_a_patch_changes(self):
        self.add_patch("0001-one.patch", "one", "1")
        self.assertEqual(self.run_script().returncode, 0)
        (self.source / "source.txt").write_text("edited\n")
        self.add_patch("0001-one.patch", "one", "uno")

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.built(), "uno\ntwo\nthree\n")
        self.assertEqual(result.stderr, "")

    def test_a_patch_that_does_not_apply_fails_and_keeps_the_copy(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.zig_call.unlink()
        # A patch against a line the release does not have.
        self.add_patch("0001-missing.patch", "one", "1")
        content = (self.patches / "0001-missing.patch").read_text()
        (self.patches / "0001-missing.patch").write_text(
            content.replace("-one\n+1", "-uno\n+1"))

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0001-missing.patch does not apply to Ghostty v1.0.0", result.stderr)
        self.assertEqual((self.source / "source.txt").read_text(), "one\ntwo\nthree\n")
        self.assertFalse(self.zig_call.exists(), "nothing was built")
        self.assertFalse(Path(f"{self.source}.new").exists())

    def test_a_tag_at_another_revision_fails(self):
        self.pin("0" * 40)

        result = self.run_script()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"tag v1.0.0 is {self.revision}, not the revision", result.stderr)
        self.assertFalse(self.source.exists())
        self.assertFalse(self.zig_call.exists(), "nothing was built")

    def test_a_local_clone_stands_in_for_the_url(self):
        self.pin_file.write_text(self.pin_file.read_text().replace(
            self.upstream.as_uri(), "https://invalid.invalid/ghostty.git"))

        result = self.run_script(PORTAL_GHOSTTY_CLONE=str(self.upstream))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.built(), "one\ntwo\nthree\n")

    def test_a_missing_zig_names_the_version_ghostty_asks_for(self):
        result = self.run_script(ZIG=str(self.root / "no-zig"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("builds with Zig 9.8.7", result.stderr)

    def test_a_failed_build_fails_and_names_both_versions(self):
        result = self.run_script(ZIG_FAILS="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("asks for Zig 9.8.7", result.stderr)
        self.assertIn("is 0.0.0", result.stderr)
        self.assertFalse((self.prefix / "lib" / "libghostty.so").exists())

    def test_the_patches_in_the_tree_are_the_pinned_ones(self):
        """Each patch names its place in the set, so that one left out or left over shows."""
        patches = sorted((ROOT / "native" / "patches" / "ghostty").glob("*.patch"))
        self.assertTrue(patches)
        for number, patch in enumerate(patches, start=1):
            self.assertTrue(patch.name.startswith(f"{number:04d}-"), patch.name)
            subject = next(line for line in patch.read_text().splitlines()
                           if line.startswith("Subject: "))
            # format-patch numbers a set of one "[PATCH]".
            self.assertIn("[PATCH]" if len(patches) == 1 else f"[PATCH {number}/{len(patches)}]",
                          subject)
        pin = json.loads((ROOT / "native" / "ghostty.json").read_text())
        self.assertRegex(pin["revision"], "^[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
