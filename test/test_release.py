# SPDX-License-Identifier: GPL-3.0-or-later
""".agents/skills/release/release.sh makes a release of a stand-in repository.

A bare repository stands in for GitHub and a script for `gh`: it records what
it was asked, keeps the releases, their assets and the runs' artifacts in
files, and answers from them, so no test reaches the network. A directory
stands in for the public downloads of each release's assets.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
RELEASE = ROOT / ".agents" / "skills" / "release" / "release.sh"
# The answers of GitHub as `gh` gives them, to the questions release.sh asks.
# Artifacts are the files in STUB/artifacts/RUN, gone when they expire;
# releases are in STUB/releases.json and their assets' bytes in STUB/assets.
# A file STUB/fail-upload naming an asset makes its next upload stop halfway.
GH = """#!{python}
import hashlib, json, os, shutil, subprocess, sys
from pathlib import Path

stub = Path(os.environ["STUB"])
args = sys.argv[1:]
with open(stub / "asked", "a") as asked:
    asked.write(" ".join(args) + "\\n")
state = stub / "releases.json"
releases = json.loads(state.read_text()) if state.exists() else []

def save():
    state.write_text(json.dumps(releases))

def option(name):
    return args[args.index(name) + 1] if name in args else None

def refuse(message):
    print(f"HTTP 422: {{message}}", file=sys.stderr)
    sys.exit(1)

def of_tag(tag):
    return [r for r in releases if r["tag"] == tag] or [None]

def artifacts(run):
    directory = stub / "artifacts" / run
    return sorted(directory.iterdir()) if directory.is_dir() else []

def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()

command = " ".join(args[:2])
if command == "release view":
    release = of_tag(args[2])[0]
    if release is None:
        sys.exit(1)
    print(str(release["draft"]).lower(), str(release.get("prerelease", False)).lower())
elif command == "run list":
    runs = stub / "runs"
    print(runs.read_text().split("\\n")[0] if runs.exists() else "")
elif command == "run view":
    print("| Build | success |" if "jobs" in args else "https://example/run/7")
elif command == "run download":
    if not (stub / option("-n")).is_dir():
        sys.exit(f"no artifact {{option('-n')}}")
    shutil.copytree(stub / option("-n"), option("-D"))
elif command == "workflow run":
    pass
elif args[0] == "api":
    method = option("-X") or "GET"
    path = next(a for a in args[1:] if a.startswith("repos/")).split("?")[0].split("/")[3:]
    if path == ["immutable-releases"]:
        print("false" if (stub / "mutable").exists() else "true")
    elif path[:2] == ["actions", "runs"]:
        for number, file in enumerate(artifacts(path[2])):
            print(f"{{path[2]}}{{number}} {{digest(file.read_bytes())}} {{file.name}}")
    elif path[:2] == ["actions", "artifacts"]:
        run, number = path[2][:-1], int(path[2][-1])
        sys.stdout.buffer.write(artifacts(run)[number].read_bytes())
    elif path == ["releases"]:
        for r in releases:
            print(r["id"], r["tag"], str(r["draft"]).lower(), str(r["immutable"]).lower())
    elif path[0] == "releases" and path[2:] == ["assets"]:
        for r in releases:
            if str(r["id"]) == path[1]:
                for a in r["assets"]:
                    print(a["id"], a["size"], a["digest"], a["state"], a["name"])
    elif path[:2] == ["releases", "assets"] and method == "DELETE":
        for r in releases:
            if any(str(a["id"]) == path[2] for a in r["assets"]):
                if r["immutable"]:
                    refuse("Cannot delete asset from an immutable release")
                r["assets"] = [a for a in r["assets"] if str(a["id"]) != path[2]]
        save()
    else:
        sys.exit(f"gh stand-in: no answer for {{args}}")
elif command == "release create":
    tag = args[2]
    if subprocess.run(["git", "--git-dir", os.environ["PORTAL_RELEASE_REMOTE"], "rev-parse",
                       "-q", "--verify", f"refs/tags/{{tag}}"], capture_output=True).returncode:
        refuse("tag does not exist")
    releases.append({{"id": 100 + len(releases), "tag": tag, "draft": "--draft" in args,
                     "immutable": False, "assets": []}})
    save()
elif command == "release edit":
    release = of_tag(args[2])[0]
    if "--draft=false" in args:
        release["draft"] = False
        release["immutable"] = not (stub / "mutable").exists()
        public = stub / "public" / release["tag"]
        public.mkdir(parents=True)
        for a in release["assets"]:
            shutil.copy(stub / "assets" / str(a["id"]), public / a["name"])
    save()
elif command == "release upload":
    release, file = of_tag(args[2])[0], Path(args[3])
    if release["immutable"] or any(a["name"] == file.name for a in release["assets"]):
        refuse("Cannot upload asset to an immutable release" if release["immutable"]
               else "already_exists")
    data = file.read_bytes()
    failing = stub / "fail-upload"
    halfway = failing.exists() and failing.read_text().strip() == file.name
    if halfway:
        failing.unlink()
        data = data[: len(data) // 2]
    asset = {{"id": 1 + max([1000, *(a["id"] for r in releases for a in r["assets"])]),
             "name": file.name, "size": len(data), "digest": digest(data),
             "state": "starter" if halfway else "uploaded"}}
    (stub / "assets").mkdir(exist_ok=True)
    (stub / "assets" / str(asset["id"])).write_bytes(data)
    release["assets"].append(asset)
    save()
    if halfway:
        sys.exit("connection reset")
elif command == "release verify":
    release = of_tag(args[2])[0]
    sys.exit(0 if release and release["immutable"] and not release["draft"] else 1)
else:
    sys.exit(f"gh stand-in: no answer for {{args}}")
""".format(python=sys.executable)
LOGS = {
    "environment.log": "ProductVersion: 27.0.1\nUSE_CACHE=false\nPORTAL_TEST_EXPENSIVE=1\n",
    "build.log": "resolve-bun: using Bun 1.3.14 at /somewhere (downloaded)\n",
    "ctest.log": "1/3 Test: input\nRan 21 tests, 19 results as expected, 0 unexpected, 2 skipped\n"
    '  SKIPPED  portal-input-evil  ((skip-unless (locate-library "evil")))\nTest Passed.\n'
    "2/3 Test: swift\n✔ Test run with 31 tests in 7 suites passed after 2 seconds.\nTest Passed.\n"
    "3/3 Test: app-host\n 55 pass\n 0 fail\nRan 55 tests across 7 files. [803.00ms]\nTest Passed.\n",
    "python.log": "test_a (test_x.X.test_a) ... skipped 'no network'\nRan 82 tests in 52.507s\n",
    "views/test.log": "Ran 78 tests, 78 results as expected, 0 unexpected\n",
    "input/test.log": "Ran 17 tests, 13 results as expected, 0 unexpected, 4 skipped\n",
    "launcher/test.log": "Ran 42 tests, 41 results as expected, 0 unexpected, 1 skipped\n",
    "terminal-shell-startup/test.log": "Ran 2 tests, 2 results as expected, 0 unexpected\n",
    "package/test.log": "9 checks passed\n6 checks passed\n",
}
# Each Linux job's logs, logs-TARGET: its environment, CTest and Python.
LINUX_LOGS = {
    "environment.log": "USE_CACHE=false\nPORTAL_TEST_EXPENSIVE=1\nPRETTY_NAME=\"Ubuntu 26.04\"\n",
    "ctest.log": "1/2 Test: runtime\nRan 22 tests, 22 results as expected, 0 unexpected\nTest Passed.\n"
    "2/2 Test: gui-runner\nRan 0 tests, 0 results as expected, 0 unexpected, 1 skipped\n"
    "  SKIPPED  portal-gui-runner  ((skip-unless (executable-find \"bun\")))\nTest Passed.\n",
    "python.log": "Ran 108 tests in 9.1s\n",
}
LINUX = ("linux-x86_64-gnu", "linux-aarch64-gnu")
TARGETS = ("macos-arm64", *LINUX)
# A pre-receive hook: GitHub refuses stable while STUB/refuse-stable exists.
HOOK = """#!/bin/sh
pushed=$(cat)
! { [ -e "$STUB/refuse-stable" ] && echo "$pushed" | grep -q ' refs/heads/stable$'; }
"""


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="portal release ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.stub = self.root / "stub"
        for name, text in LOGS.items():
            (self.stub / "logs" / name).parent.mkdir(parents=True, exist_ok=True)
            (self.stub / "logs" / name).write_text(text)
        for target in LINUX:
            for name, text in LINUX_LOGS.items():
                (self.stub / f"logs-{target}").mkdir(exist_ok=True)
                (self.stub / f"logs-{target}" / name).write_text(text)
        (self.root / "bin").mkdir()
        (self.root / "bin" / "gh").write_text(GH)
        (self.root / "bin" / "gh").chmod(0o755)
        identity = {f"GIT_{who}_{what}": value for who in ("AUTHOR", "COMMITTER")
                    for what, value in (("NAME", "Tester"), ("EMAIL", "tester@example.invalid"))}
        self.env = {**os.environ, **identity, "STUB": str(self.stub), "PORTAL_RELEASE_POLL": "0",
                    "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                    "PORTAL_RELEASE_REMOTE": str(self.root / "github.git"),
                    "PORTAL_RELEASE_DOWNLOADS": (self.stub / "public").as_uri(),
                    "PORTAL_RELEASE_RETRIES": "0", "PORTAL_RELEASE_SETTLE": "1"}
        self.git("init", "-q", "--bare", "-b", "main", self.root / "github.git", cwd=self.root)
        hook = self.root / "github.git" / "hooks" / "pre-receive"
        hook.write_text(HOOK)
        hook.chmod(0o755)
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
        self.git("fetch", "-q", "--prune", "--prune-tags", "--tags", "origin")
        return result.stdout + result.stderr

    def asked(self):
        return (self.stub / "asked").read_text()

    def run_kept(self, version, run="7", seed=b""):
        """Make RUN the green run of release/vVERSION, keeping its runtime artifacts.

        It packs an archive for each of the three systems, as Checks does, and
        writes their manifests, each copied into its job's logs; SEED changes
        the archives' bytes."""
        commit = self.git("rev-parse", f"origin/release/v{version}")
        runs = self.stub / "runs"
        listed = runs.read_text() if runs.exists() else ""
        if listed.split("\n")[0] != run:
            runs.write_text(run + "\n" + listed)
        kept = self.stub / "artifacts" / run
        kept.mkdir(parents=True)
        for target in TARGETS:
            name = f"portal-runtime-v{version}-{target}"
            data = f"{target} {commit} ".encode() + seed + bytes(range(256)) * 8
            (kept / f"{name}.tar.gz").write_bytes(data)
            (kept / f"{name}.json").write_text(json.dumps({
                "format": 1, "tag": f"v{version}", "version": version, "commit": commit,
                "identity": "0" * 64, "archives": [{
                    "target": target, "floor": {}, "name": f"{name}.tar.gz", "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest()}]}))
        self.logs_from(kept, version)
        return kept

    def logs_from(self, kept, version):
        """Make the logs the green run gives those of the run that kept KEPT."""
        for target in TARGETS:
            logs = self.stub / ("logs" if target == "macos-arm64" else f"logs-{target}")
            (logs / "runtime").mkdir(exist_ok=True)
            name = f"portal-runtime-v{version}-{target}.json"
            shutil.copy(kept / name, logs / "runtime" / name)

    def releases(self):
        return json.loads((self.stub / "releases.json").read_text())

    def public(self, version):
        directory = self.stub / "public" / f"v{version}"
        return sorted(p.name for p in directory.iterdir()) if directory.exists() else []

    def publish(self, version):
        """Release VERSION from main as a green run allows; return the release commit."""
        (self.stub / "runs").write_text("7\n")
        self.release("candidate", version)
        self.run_kept(version)
        (self.root / "notes.md").write_text(self.release("notes", version))
        commit = self.git("rev-parse", f"origin/release/v{version}")
        self.release("publish", version, "notes.md")
        return commit

    def candidate_with_notes(self, version="0.2.0"):
        (self.stub / "runs").write_text("7\n")
        self.release("candidate", version)
        kept = self.run_kept(version)
        (self.root / "notes.md").write_text(self.release("notes", version))
        return self.git("rev-parse", f"origin/release/v{version}"), kept

    def assert_unmoved(self, base):
        """Assert that GitHub's stable is not at a release and main is at BASE."""
        self.assertEqual(self.git("branch", "-r", "--list", "origin/stable"), "")
        self.assertEqual(self.git("rev-parse", "origin/main"), base)

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
        kept = self.run_kept("0.2.0")
        notes = self.release("notes", "0.2.0")
        archive = kept / "portal-runtime-v0.2.0-macos-arm64.tar.gz"
        for line in ("The first release.", "- CTest input: passed; Ran 21 tests",
                     "- python: Ran 82 tests", "- package: 6 checks passed",
                     "- CTest swift: passed; Test run with 31 tests in 7 suites",
                     "- CTest app-host: passed; Ran 55 tests across 7 files.", "- views: Ran 78 tests", "| Build | success |",
                     "- CTest input: portal-input-evil  ((skip-unless",
                     "- python: test_a (test_x.X.test_a) ... skipped 'no network'",
                     "Bun 1.3.14", "https://example/run/7",
                     "- linux-x86_64-gnu CTest runtime: passed; Ran 22 tests",
                     "- linux-aarch64-gnu python: Ran 108 tests",
                     "- linux-aarch64-gnu CTest gui-runner: portal-gui-runner  ((skip-unless"):
            self.assertIn(line, notes)
        for target in TARGETS:
            archive = kept / f"portal-runtime-v0.2.0-{target}.tar.gz"
            self.assertIn(f"- `{archive.name}`, {archive.stat().st_size} bytes, SHA-256 "
                          f"`{hashlib.sha256(archive.read_bytes()).hexdigest()}`", notes)
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
        # Each Linux job's evidence is the release's as much as the Mac's.
        linux = self.stub / "logs-linux-x86_64-gnu"
        (linux / "python.log").write_text("Traceback\n")
        self.assertIn("do not count linux-x86_64-gnu python's tests",
                      self.release("notes", "0.2.0", ok=False))
        (linux / "python.log").write_text(LINUX_LOGS["python.log"])
        (linux / "environment.log").write_text("USE_CACHE=true\nPORTAL_TEST_EXPENSIVE=1\n")
        self.assertIn("restored cached downloads", self.release("notes", "0.2.0", ok=False))
        (linux / "environment.log").write_text(LINUX_LOGS["environment.log"])
        # A Linux manifest other than the one its job packed and logged.
        manifest = linux / "runtime" / "portal-runtime-v0.2.0-linux-x86_64-gnu.json"
        manifest.write_text(manifest.read_text().replace('"size"', '"size" '))
        self.assertIn("other than the one Checks run 7 packed",
                      self.release("notes", "0.2.0", ok=False))
        self.logs_from(kept, "0.2.0")
        shutil.move(linux, self.root / "kept-linux-logs")
        self.assertIn("keeps no logs-linux-x86_64-gnu", self.release("notes", "0.2.0", ok=False))
        shutil.move(self.root / "kept-linux-logs", linux)
        # Nor is a run whose archive has expired.
        (kept / "portal-runtime-v0.2.0-macos-arm64.json").unlink()
        self.assertIn("keeps no portal-runtime-v0.2.0-macos-arm64.json",
                      self.release("notes", "0.2.0", ok=False))
        # A run that left out the full set's checks is no evidence either.
        (self.stub / "logs" / "environment.log").write_text("USE_CACHE=false\nPORTAL_TEST_EXPENSIVE=\n")
        self.assertIn("left out the full set's checks", self.release("notes", "0.2.0", ok=False))
        (self.stub / "logs" / "environment.log").write_text("USE_CACHE=true\nPORTAL_TEST_EXPENSIVE=1\n")
        self.assertIn("no evidence", self.release("notes", "0.2.0", ok=False))
        self.assertIn("no evidence", self.release("publish", "0.2.0", "notes.md", ok=False))

    def test_publishing_attaches_the_tested_runtimes_before_stable_moves(self):
        first = self.publish("0.2.0")
        for name in ("v0.2.0^{commit}", "origin/stable", "origin/main"):
            self.assertEqual(self.git("rev-parse", name), first)
        asked = self.asked()
        created = asked.index("release create v0.2.0 --verify-tag --draft --title Portal 0.2.0")
        published = asked.index("release edit v0.2.0 --draft=false")
        names = [f"portal-runtime-v0.2.0-{target}{extension}"
                 for target in TARGETS for extension in (".json", ".tar.gz")]
        for name in ("logs.zip", *names):
            self.assertTrue(created < asked.index(f"/{name}\n") < published, name)
        self.assertLess(published, asked.index("release verify v0.2.0"))
        [release] = self.releases()
        self.assertEqual((release["draft"], release["immutable"]), (False, True))
        self.assertEqual(self.public("0.2.0"), sorted(["logs.zip", *names]))
        kept = self.stub / "artifacts" / "7"
        for name in names:
            self.assertEqual((self.stub / "public" / "v0.2.0" / name).read_bytes(),
                             (kept / name).read_bytes())
        # The logs it attaches are every job's.
        with zipfile.ZipFile(self.stub / "public" / "v0.2.0" / "logs.zip") as logs:
            listed = logs.namelist()
        for name in ("logs/ctest.log", "logs-linux-x86_64-gnu/ctest.log",
                     "logs-linux-aarch64-gnu/runtime/portal-runtime-v0.2.0-linux-aarch64-gnu.json"):
            self.assertIn(name, listed)
        self.assertEqual(self.git("branch", "-r", "--list", "origin/release/*"), "")

        # The next one: main moves on while the candidate is checked.
        self.git("pull", "-q", "origin", "main")
        (self.dev / "native" / "Package.swift").write_text("// two\n")
        base = self.commit("portal/second: the native part changed")
        (self.stub / "runs").write_text("8\n")
        self.release("candidate", "patch", base)
        self.run_kept("0.2.1", run="8")
        (self.dev / "later.el").write_text(";; later\n")
        later = self.commit("portal/third: after the base")
        # Without Emacs the upgrade's cost is unknown, which is not "no rebuild".
        self.assertIn("no build identity",
                      self.release("notes", "0.2.1", ok=False, EMACS=self.root / "no-emacs"))
        notes = self.release("notes", "0.2.1")
        self.assertIn("- the native part changed", notes)
        self.assertNotIn("after the base", notes)
        self.assertIn("offers this release's runtime", notes)
        second = self.git("rev-parse", "origin/release/v0.2.1")
        (self.root / "notes.md").write_text(notes)
        self.release("publish", "0.2.1", "notes.md")
        self.assertEqual(self.git("rev-parse", "origin/stable"), second)
        self.assertEqual(self.git("rev-parse", "origin/main^1", "origin/main^2"),
                         f"{later}\n{second}")
        self.assertIn(";; Version: 0.2.1", self.git("show", "origin/main:portal.el"))
        # The older release's assets are as they were.
        self.assertEqual(self.public("0.2.0"), sorted(["logs.zip", *names]))

    def test_nothing_is_published_without_immutable_releases(self):
        base = self.git("rev-parse", "HEAD")
        self.candidate_with_notes()
        (self.stub / "mutable").touch()
        self.assertIn("immutable releases are off",
                      self.release("publish", "0.2.0", "notes.md", ok=False))
        self.assertEqual(self.git("tag"), "")
        self.assertFalse((self.stub / "releases.json").exists())
        self.assert_unmoved(base)

    def test_an_expired_archive_is_never_rebuilt_and_a_new_run_is_published(self):
        base = self.git("rev-parse", "HEAD")
        commit, kept = self.candidate_with_notes()
        shutil.rmtree(kept)
        output = self.release("publish", "0.2.0", "notes.md", ok=False)
        self.assertIn("Checks run 7 keeps no portal-runtime-v0.2.0-macos-arm64.json", output)
        self.assertIn("Run Checks again on release/v0.2.0, uncached", output)
        self.assertEqual(self.git("tag"), "")
        self.assertFalse((self.stub / "releases.json").exists())
        self.assert_unmoved(base)
        # A new run of the same release commit is the cure.
        kept = self.run_kept("0.2.0", run="8")
        self.release("publish", "0.2.0", "notes.md")
        self.assertEqual(self.git("rev-parse", "origin/stable"), commit)
        archive = "portal-runtime-v0.2.0-macos-arm64.tar.gz"
        self.assertEqual((self.stub / "public" / "v0.2.0" / archive).read_bytes(),
                         (kept / archive).read_bytes())

    def test_a_failed_upload_publishes_nothing_and_publishing_again_finishes(self):
        base = self.git("rev-parse", "HEAD")
        commit, _ = self.candidate_with_notes()
        archive = "portal-runtime-v0.2.0-macos-arm64.tar.gz"
        (self.stub / "fail-upload").write_text(archive)
        output = self.release("publish", "0.2.0", "notes.md", ok=False)
        self.assertIn(f"uploading {archive} to the draft of v0.2.0 failed: nothing is published",
                      output)
        # The tag is there, the draft holds half an archive, nobody sees it.
        self.assertEqual(self.git("rev-parse", "v0.2.0^{commit}"), commit)
        [draft] = self.releases()
        self.assertTrue(draft["draft"])
        self.assertIn("starter", [a["state"] for a in draft["assets"]])
        self.assertEqual(self.public("0.2.0"), [])
        self.assert_unmoved(base)
        # The candidate cannot be passed over while it is unfinished.
        self.assertIn("v0.2.0 has no published GitHub release",
                      self.release("candidate", "0.3.0", ok=False))
        # Notes drafted again, as after a new run, do not take the pushed
        # tag for the previous release.
        notes = self.release("notes", "0.2.0")
        self.assertIn("The first release.", notes)
        self.assertIn("Nothing to upgrade from", notes)

        output = self.release("publish", "0.2.0", "notes.md")
        self.assertIn(f"removing {archive} from the draft of v0.2.0", output)
        [release] = self.releases()
        self.assertEqual(len(release["assets"]), 7)
        self.assertEqual({a["state"] for a in release["assets"]}, {"uploaded"})
        self.assertEqual(self.git("rev-parse", "origin/stable"), commit)
        kept = self.stub / "artifacts" / "7" / archive
        self.assertEqual((self.stub / "public" / "v0.2.0" / archive).read_bytes(),
                         kept.read_bytes())

    def test_publishing_again_never_changes_a_published_release(self):
        base = self.git("rev-parse", "HEAD")
        commit, kept = self.candidate_with_notes()
        (self.stub / "refuse-stable").touch()
        self.assertIn("stable and main did not move: v0.2.0 is published",
                      self.release("publish", "0.2.0", "notes.md", ok=False))
        self.assert_unmoved(base)
        self.assertIn("stable is not at v0.2.0", self.release("candidate", "0.3.0", ok=False))
        published = (self.stub / "public" / "v0.2.0").iterdir()
        before = {p.name: p.read_bytes() for p in published}

        # A later run of the release commit tested other bytes: what is
        # published is not its evidence, so stable stays.
        (self.stub / "refuse-stable").unlink()
        self.run_kept("0.2.0", run="8", seed=b"rebuilt")
        (self.stub / "asked").write_text("")
        self.assertIn("other than the one Checks run 8 packed",
                      self.release("publish", "0.2.0", "notes.md", ok=False))
        self.assert_unmoved(base)
        # With the run that tested them, it checks and finishes, changing nothing.
        (self.stub / "runs").write_text("7\n")
        self.logs_from(kept, "0.2.0")
        output = self.release("publish", "0.2.0", "notes.md")
        self.assertIn("v0.2.0 is published already: checking it, changing nothing", output)
        self.assertNotIn("release upload", self.asked())
        self.assertNotIn("DELETE", self.asked())
        self.assertNotIn("actions/artifacts", self.asked())
        self.assertEqual({p.name: p.read_bytes()
                          for p in (self.stub / "public" / "v0.2.0").iterdir()}, before)
        self.assertEqual(self.git("rev-parse", "origin/stable"), commit)

    def test_a_published_release_short_of_its_tested_assets_never_moves_stable(self):
        base = self.git("rev-parse", "HEAD")
        self.candidate_with_notes()
        (self.stub / "refuse-stable").touch()
        self.release("publish", "0.2.0", "notes.md", ok=False)
        (self.stub / "refuse-stable").unlink()
        public = self.stub / "public" / "v0.2.0"
        archive = public / "portal-runtime-v0.2.0-macos-arm64.tar.gz"
        good = archive.read_bytes()

        # What anyone downloads by the tag differs from what GitHub holds.
        archive.write_bytes(good[:-1] + b"x")
        self.assertIn("is not the asset GitHub holds, so stable stays",
                      self.release("publish", "0.2.0", "notes.md", ok=False))
        archive.unlink()
        self.assertIn("nobody can download portal-runtime-v0.2.0-macos-arm64.tar.gz",
                      self.release("publish", "0.2.0", "notes.md", ok=False))
        archive.write_bytes(good)
        # Published without its archive, as by hand: it stays so, and stable stays.
        releases = self.releases()
        releases[0]["assets"] = [a for a in releases[0]["assets"] if a["name"] != archive.name]
        (self.stub / "releases.json").write_text(json.dumps(releases))
        self.assertIn("v0.2.0 is published and stays so, but stable stays",
                      self.release("publish", "0.2.0", "notes.md", ok=False))
        # Published but not immutable.
        releases[0]["immutable"] = False
        (self.stub / "releases.json").write_text(json.dumps(releases))
        self.assertIn("v0.2.0 is published but not immutable",
                      self.release("publish", "0.2.0", "notes.md", ok=False))
        self.assertNotIn("release upload v0.2.0 ", self.asked().split("--draft=false")[1])
        self.assert_unmoved(base)

        # It cannot be mended, nor passed over by accident.
        self.assertIn("stable is not at v0.2.0", self.release("candidate", "patch", ok=False))
        # The owner marks it a pre-release, which abandons it: the next PATCH
        # goes above it, from main, and stable can move to that.
        releases[0]["prerelease"] = True
        (self.stub / "releases.json").write_text(json.dumps(releases))
        (self.stub / "runs").write_text("9\n")
        output = self.release("candidate", "patch")
        self.assertIn("v0.2.0 is a pre-release: passed over as abandoned", output)
        self.assertEqual(self.git("rev-parse", "origin/release/v0.2.1^"), base)
        self.run_kept("0.2.1", run="9")
        (self.root / "notes.md").write_text(self.release("notes", "0.2.1"))
        self.release("publish", "0.2.1", "notes.md")
        self.assertEqual(self.git("rev-parse", "origin/stable"),
                         self.git("rev-parse", "v0.2.1^{commit}"))

    def test_a_tag_on_another_commit_is_refused(self):
        base = self.git("rev-parse", "HEAD")
        self.candidate_with_notes()
        self.git("tag", "-a", "v0.2.0", "-m", "someone else's", base)
        self.git("push", "-q", "origin", "v0.2.0")
        self.assertIn("v0.2.0 on GitHub is not",
                      self.release("publish", "0.2.0", "notes.md", ok=False))
        self.assertFalse((self.stub / "releases.json").exists())
        self.assert_unmoved(base)

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
