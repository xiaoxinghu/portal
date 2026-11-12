# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/ghostty-version.py: its parsing, on fixtures taken from libghostty-spm
2.2.2026110702 and Rex 0.1.0-preview.14, and its report and bump against local
stand-ins for the package, Ghostty and a Rex server, offline."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tools" / "ghostty-version.py"
FIXTURES = ROOT / "test" / "fixtures" / "ghostty-version"
GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@invalid",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@invalid"}
for name in ("PORTAL_LIBGHOSTTY_SPM_CLONE", "PORTAL_GHOSTTY_CLONE", "PORTAL_REX_SERVER"):
    GIT_ENV.pop(name, None)

spec = importlib.util.spec_from_file_location("ghostty_version", SCRIPT)
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def fixture(name):
    return (FIXTURES / name).read_text()


def git(directory, *args):
    return subprocess.run(["git", "-C", str(directory), *args], check=True, env=GIT_ENV,
                          capture_output=True, text=True).stdout.strip()


class Parsing(unittest.TestCase):
    def test_ghostty_ref(self):
        self.assertEqual(tool.parse_ghostty_ref(fixture("Ghostty.ref")),
                         "042b16b6146ada29877dfeeea9f286889e4adeb1")
        self.assertIsNone(tool.parse_ghostty_ref("main\n"))

    def test_binary_target_of_the_package(self):
        target = tool.parse_binary_target(fixture("Package.swift"))
        self.assertEqual(target["commit"], "042b16b6146a")
        self.assertEqual(target["checksum"],
                         "1f5cd5cebcca5181ea5aaea008252a2b622ba1e94471601cf896ee125e9a5902")
        self.assertTrue(target["url"].endswith("/upstream.042b16b6146a/GhosttyKit.xcframework.zip"))

    def test_binary_target_of_a_rebuilt_upstream_tag(self):
        manifest = ('.binaryTarget(name: "libghostty", url: "https://example.invalid/'
                    'releases/download/upstream.1e9e14af5df1-3/GhosttyKit.xcframework.zip", '
                    'checksum: "abc")')
        self.assertEqual(tool.parse_binary_target(manifest)["commit"], "1e9e14af5df1")

    def test_tags_leave_out_upstream_and_storage(self):
        tags = tool.parse_ls_remote(fixture("ls-remote-tags.txt"))
        self.assertEqual(tags["2.2.2026110702"], "1d84cf66fe29abd1f24f10b88dcfc25882cf68ee")
        self.assertIn("upstream.042b16b6146a", tags)
        self.assertEqual(tool.releases(tags), [
            "1.2.9", "1.2.10", "2.2.2026102101", "2.2.2026110701", "2.2.2026110702"])

    def test_an_annotated_tag_names_its_commit(self):
        text = ("1111111111111111111111111111111111111111\trefs/tags/1.0\n"
                "2222222222222222222222222222222222222222\trefs/tags/1.0^{}\n"
                "4444444444444444444444444444444444444444\trefs/tags/2.0^{}\n"
                "3333333333333333333333333333333333333333\trefs/tags/2.0\n")
        self.assertEqual(tool.parse_ls_remote(text), {
            "1.0": "2222222222222222222222222222222222222222",
            "2.0": "4444444444444444444444444444444444444444"})

    def test_library_version(self):
        self.assertEqual(tool.parse_library_version("1.1.0-dev+5813c9461"), "5813c9461")
        self.assertEqual(tool.parse_library_version("1.3.1+0538f7535be0"), "0538f7535be0")
        self.assertIsNone(tool.parse_library_version("1.1.0-dev"))

    def test_library_version_in_a_binary(self):
        record = fixture("ghostty-build-record.txt").strip().encode()
        binary = b"\xcf\xfa\xed\xfe\x00\x00" + record + b"\x00more\x00"
        self.assertEqual(tool.find_library_version(binary), "1.1.0-dev+5813c9461")
        self.assertIsNone(tool.find_library_version(b"\x00no record\x00"))


class Verdict(unittest.TestCase):
    D = tool.Distance

    def test_up_to_date_with_the_server(self):
        self.assertTrue(tool.verdict("2.0", "2.0", "abc", self.D(0, 3), None)
                        .startswith("Up to date:"))

    def test_a_newer_release_has_the_server(self):
        line = tool.verdict("1.0", "2.0", "abc", self.D(5, 0), self.D(0, 0))
        self.assertEqual(line, "A newer release exists: bump to 2.0, whose Ghostty has every "
                         "commit of the Rex server's.")

    def test_the_newest_release_is_behind(self):
        line = tool.verdict("2.0", "2.0", "abc", self.D(169, 0), self.D(169, 0))
        self.assertTrue(line.startswith("The newest release is still behind the server"))
        self.assertIn("lacks 169 commits", line)
        line = tool.verdict("1.0", "2.0", "abc", self.D(200, 0), self.D(169, 0))
        self.assertIn("2.0 is newer than the pin, but its Ghostty lacks 169 commits", line)

    def test_by_date(self):
        line = tool.verdict("2.0", "2.0", "abc", self.D(days=5), None)
        self.assertIn("is 5 days older", line)
        self.assertTrue(tool.verdict("2.0", "2.0", "abc", self.D(days=-2), None)
                        .startswith("Unknown:"))

    def test_a_server_whose_ghostty_cannot_be_read(self):
        self.assertEqual(tool.verdict("2.0", "2.0", None, None, None, server_found=True),
                         "Unknown: the Rex server's Ghostty could not be read.")

    def test_without_a_server(self):
        self.assertEqual(tool.verdict("1.0", "2.0", None, None, None),
                         "A newer release exists: 2.0. No Rex server was found to compare with.")
        self.assertTrue(tool.verdict("2.0", "2.0", None, None, None)
                        .startswith("Up to date with the newest release."))
        self.assertTrue(tool.verdict("2.0", None, None, None, None).startswith("Unknown:"))


class Stand_ins(unittest.TestCase):
    """A Ghostty of three commits, a package with releases 1.0 (the first commit)
    and 2.0 (the third), a server on the third, and a checkout pinned to 1.0."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.dir = Path(self.temporary.name)
        self.ghostty = self.dir / "ghostty"
        self.ghostty.mkdir()
        git(self.ghostty, "init", "-q")
        self.commits = []
        for n in range(3):
            git(self.ghostty, "commit", "-q", "--allow-empty", "-m", f"g{n}")
            self.commits.append(git(self.ghostty, "rev-parse", "HEAD"))

        self.package = self.dir / "package"
        self.package.mkdir()
        git(self.package, "init", "-q")
        # Far enough apart that a patch to one line has none of another in its context.
        gap = "".join(f"{n}\n" for n in range(6))
        self.release("1.0", self.commits[0], f"one\n{gap}two\n{gap}three\n")
        self.release("2.0", self.commits[2], f"one\n{gap}TWO\n{gap}three\n")
        git(self.package, "tag", f"upstream.{self.commits[2][:12]}")
        git(self.package, "tag", "storage.9.9")

        self.checkout = self.dir / "portal"
        (self.checkout / "native" / "patches" / "libghostty-spm").mkdir(parents=True)
        (self.checkout / "native" / "libghostty-spm.json").write_text(json.dumps(
            {"url": "https://example.invalid/libghostty-spm.git", "version": "1.0",
             "revision": git(self.package, "rev-parse", "1.0")}, indent="\t") + "\n")

        self.rex = self.dir / "rex"
        record = fixture("ghostty-build-record.txt").strip().replace(
            "5813c9461", self.commits[2][:9])
        self.rex.write_text(f'#!/bin/sh\necho "rex 0.0.0-test"\nexit 0\n{record}\n')
        self.rex.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def release(self, tag, ghostty, notes):
        (self.package / "Ghostty.ref").write_text(ghostty + "\n")
        (self.package / "Package.swift").write_text(
            '.binaryTarget(name: "libghostty", url: "https://example.invalid/'
            f'upstream.{ghostty[:12]}/GhosttyKit.xcframework.zip", checksum: "00")\n')
        (self.package / "NOTES").write_text(notes)
        git(self.package, "add", ".")
        git(self.package, "commit", "-q", "-m", tag)
        git(self.package, "tag", tag)

    def patch(self, name, old, new, at="2.0"):
        """A patch, made with format-patch at AT, that changes NOTES line OLD to NEW."""
        work = self.dir / "work"
        subprocess.run(["git", "clone", "-q", "-b", at, str(self.package), str(work)],
                       check=True, env=GIT_ENV, capture_output=True)
        notes = work / "NOTES"
        notes.write_text(notes.read_text().replace(old, new))
        git(work, "commit", "-q", "-am", f"{old} to {new}")
        (self.checkout / "native" / "patches" / "libghostty-spm" / name).write_text(
            git(work, "format-patch", "-1", "--stdout") + "\n")
        subprocess.run(["rm", "-rf", str(work)], check=True)

    def run_tool(self, *args, rex=None):
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), *args, "--offline", "--root", str(self.checkout),
             "--package", str(self.package), "--ghostty", str(self.ghostty),
             "--rex", str(rex or self.rex)],
            env=GIT_ENV, capture_output=True, text=True)

    def pin(self):
        return json.loads((self.checkout / "native" / "libghostty-spm.json").read_text())

    def test_report(self):
        result = self.run_tool()

        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertRegex(out, rf"Portal's pin: +libghostty-spm 1\.0 +Ghostty {self.commits[0][:12]} of ")
        self.assertRegex(out, rf"Newest release: +libghostty-spm 2\.0 +Ghostty {self.commits[2][:12]} of ")
        self.assertRegex(out, rf"Rex server: +rex 0\.0\.0-test \(1\.1\.0-dev\+{self.commits[2][:9]}\) +Ghostty ")
        self.assertIn("Portal's Ghostty lacks 2 commits of the server's (counted in the Ghostty clone).", out)
        self.assertIn("The newest release's Ghostty is the server's.", out)
        self.assertIn("Verdict: A newer release exists: bump to 2.0", out)
        self.assertNotIn("Could not find out", out)

    def test_report_does_not_count_in_a_shallow_clone(self):
        git(self.ghostty, "tag", "first", self.commits[0])
        shallow = self.dir / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth", "1", self.ghostty.as_uri(), str(shallow)],
                       check=True, env=GIT_ENV, capture_output=True)
        git(shallow, "fetch", "-q", "--depth", "1", "origin", "refs/tags/first:refs/tags/first")

        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--offline", "--root", str(self.checkout),
             "--package", str(self.package), "--ghostty", str(shallow), "--rex", str(self.rex)],
            env=GIT_ENV, capture_output=True, text=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("counted in the Ghostty clone", result.stdout)
        self.assertIn("Portal's Ghostty is from the same day as the server's (by date", result.stdout)

    def test_report_with_an_unreadable_server(self):
        self.rex.write_text('#!/bin/sh\necho "rex 0.0.0-test"\n')

        result = self.run_tool()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verdict: Unknown: the Rex server's Ghostty could not be read.", result.stdout)
        self.assertIn("no library_version in it", result.stdout)

    def test_report_with_a_server_it_cannot_read(self):
        self.rex.chmod(0o000)

        result = self.run_tool()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verdict: Unknown: the Rex server's Ghostty could not be read.", result.stdout)
        self.assertIn(f"Rex server at {self.rex}: cannot read it", result.stdout)

    def test_report_without_rex(self):
        result = self.run_tool(rex=self.dir / "no-rex")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Portal's pin:", result.stdout)
        self.assertIn("Newest release:", result.stdout)
        self.assertNotIn("Rex server:", result.stdout)
        self.assertIn("Verdict: A newer release exists: 2.0. No Rex server", result.stdout)
        self.assertIn(f"Note: Rex server not found at {self.dir / 'no-rex'}.", result.stdout)

    def test_report_says_what_it_could_not_find_out(self):
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--offline", "--root", str(self.checkout),
             "--rex", str(self.rex)], env=GIT_ENV, capture_output=True, text=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verdict: Unknown:", result.stdout)
        self.assertIn("Could not find out the Ghostty of the pinned release 1.0.", result.stdout)
        self.assertIn("Could not find out the newest release", result.stdout)

    def test_bump_to_the_newest(self):
        self.patch("0001-one.patch", "one", "1")

        result = self.run_tool("bump")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.pin()["version"], "2.0")
        self.assertEqual(self.pin()["revision"], git(self.package, "rev-parse", "2.0"))
        self.assertIn("The one patch applies to 2.0.", result.stdout)
        self.assertIn("Nothing is committed.", result.stdout)
        self.assertIn("./build.sh", result.stdout)

    def test_bump_from_a_relative_clone(self):
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "bump", "--offline", "--root", "portal",
             "--package", "package"], cwd=self.dir, env=GIT_ENV, capture_output=True, text=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.pin()["version"], "2.0")

    def test_bump_offline_does_not_resolve(self):
        (self.checkout / "native" / "Package.swift").write_text("// not to be read\n")

        result = self.run_tool("bump")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Did not refresh native/Package.resolved: --offline", result.stdout)

    def test_bump_names_a_patch_that_does_not_apply(self):
        self.patch("0001-one.patch", "one", "1")
        # Made at 1.0, against the line 2.0 changed.
        self.patch("0002-two.patch", "two", "2", at="1.0")
        self.patch("0003-three.patch", "three", "3")

        result = self.run_tool("bump")

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.pin()["version"], "2.0")
        self.assertIn("Does not apply to 2.0: native/patches/libghostty-spm/0002-two.patch",
                      result.stdout)
        self.assertNotIn("0001-one", result.stdout)
        self.assertNotIn("0003-three", result.stdout)
        repair = self.checkout / "build" / "libghostty-spm-bump"
        self.assertIn("build/libghostty-spm-bump holds 2.0", result.stdout)
        self.assertIn("format-patch", result.stdout)
        # Stopped at 0002, after 0001, to be fixed and continued.
        self.assertTrue((repair / ".git" / "rebase-apply").is_dir())
        self.assertEqual(git(repair, "log", "-1", "--format=%s"), "one to 1")
        self.assertIn("2.0", git(repair, "log", "--format=%s"))

    def test_bump_again_names_the_patch_still_failing(self):
        self.patch("0001-two.patch", "two", "2", at="1.0")
        self.assertEqual(self.run_tool("bump").returncode, 1)

        result = self.run_tool("bump")

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("The pin is already libghostty-spm 2.0", result.stdout)
        self.assertIn("Does not apply to 2.0: native/patches/libghostty-spm/0001-two.patch",
                      result.stdout)

    def test_the_linked_library_wins_over_ghostty_ref(self):
        git(self.package, "checkout", "-q", "2.0")
        (self.package / "Ghostty.ref").write_text(self.commits[1] + "\n")
        git(self.package, "commit", "-q", "-am", "a Ghostty.ref the library does not match")
        git(self.package, "tag", "3.0")

        result = self.run_tool()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, rf"Newest release: +libghostty-spm 3\.0 +Ghostty {self.commits[2][:12]} ")
        self.assertIn(f"Note: 3.0's Ghostty.ref names {self.commits[1][:12]} but its binaryTarget "
                      f"upstream.{self.commits[2][:12]}.", result.stdout)
        self.assertIn("Verdict: A newer release exists: bump to 3.0", result.stdout)

    def test_bump_to_a_named_release(self):
        result = self.run_tool("bump", "1.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already", result.stdout)

        result = self.run_tool("bump", "upstream." + self.commits[2][:12])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not a release", result.stderr)
        self.assertEqual(self.pin()["version"], "1.0")


if __name__ == "__main__":
    unittest.main()
