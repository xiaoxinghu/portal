# SPDX-License-Identifier: GPL-3.0-or-later
"""scripts/release.py: its versions, header edit and notes, on the logs of a real
Checks run in test/fixtures/release, and whole releases against a local bare
repository standing in for GitHub, with gh stubbed."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "release.py"
FIXTURES = ROOT / "test" / "fixtures" / "release"
# The developer's Git settings, such as signing, must not reach the fixtures.
GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@invalid",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@invalid"}
for name in ("PORTAL_RELEASE_REMOTE", "PORTAL_RELEASE_POLL", "GIT_DIR", "GIT_WORK_TREE"):
    GIT_ENV.pop(name, None)

spec = importlib.util.spec_from_file_location("release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

HEADER = textwrap.dedent("""\
    ;;; portal.el --- Native web views and terminals for macOS -*- lexical-binding: t; -*-

    ;; URL: https://github.com/xiaoxinghu/portal
    ;; Version: {version}
    ;; Package-Requires: ((emacs "31.1"))

    ;;; Code:
    (provide 'portal)
    """)

# gh, as far as the release command uses it: runs come from the state file
# GH_STUB names, their jobs and logs from the fixtures.
GH_STUB = textwrap.dedent("""\
    import json, os, shutil, subprocess, sys
    path = os.environ["GH_STUB"]
    with open(path) as f:
        state = json.load(f)
    args = sys.argv[1:]
    if "-R" in args:
        del args[args.index("-R"):args.index("-R") + 2]
    state["calls"].append(args)

    def save():
        with open(path, "w") as f:
            json.dump(state, f)

    def option(name):
        return args[args.index(name) + 1] if name in args else None

    def finish(code=0, out=None):
        save()
        if out is not None:
            print(out if isinstance(out, str) else json.dumps(out))
        sys.exit(code)

    fixtures = state["fixtures"]
    if args[:2] == ["auth", "status"]:
        finish(state.get("auth", 0))
    if args[:2] == ["run", "list"]:
        runs = [r for r in state["runs"]
                if all(not option(flag) or r[key] == option(flag) for flag, key in
                       (("--branch", "headBranch"), ("--event", "event"),
                        ("--commit", "headSha")))]
        finish(0, runs)
    if args[:2] == ["workflow", "run"]:
        branch = option("--ref")
        sha = subprocess.run(["git", "-C", state["bare"], "rev-parse", "refs/heads/" + branch],
                             capture_output=True, text=True, check=True).stdout.strip()
        number = 1000 + len(state["runs"])
        state["runs"].append({
            "databaseId": number, "headSha": sha, "headBranch": branch,
            "event": "workflow_dispatch", "inputs": args[3:],
            "status": "in_progress" if state.get("hold") else "completed",
            "conclusion": None if state.get("hold") else state["conclusion"],
            "url": "https://github.invalid/runs/%d" % number})
        state["dispatches"].append([branch, sha] + args[3:])
        save()
        if state.get("on_dispatch"):
            subprocess.run(state["on_dispatch"], shell=True, check=True)
        finish(0)
    if args[:2] == ["run", "view"]:
        found = [r for r in state["runs"] if r["databaseId"] == int(args[2])][0]
        with open(os.path.join(fixtures, "run.json")) as f:
            jobs = json.load(f)["jobs"]
        if found["conclusion"] == "failure":
            jobs[0]["conclusion"] = "failure"
            for step in jobs[0]["steps"]:
                if step["name"] == "CTest":
                    step["conclusion"] = "failure"
        if found["status"] != "completed":
            jobs[0]["steps"][8]["status"] = "in_progress"
        finish(0, dict(found, jobs=jobs))
    if args[:2] == ["run", "download"]:
        shutil.copytree(os.path.join(fixtures, "logs"), option("-D"))
        finish(0)
    if args[0] == "api":
        with open(os.path.join(fixtures, "job.log")) as f:
            finish(0, f.read())
    if args[:2] == ["pr", "view"]:
        title = state["pulls"].get(args[2])
        finish(0 if title else 1, {"title": title} if title else None)
    if args[:2] == ["release", "view"]:
        finish(0 if args[2] in state["releases"] else 1, {"tagName": args[2]})
    if args[:2] == ["release", "create"]:
        tag = args[2]
        assert "--verify-tag" in args
        if subprocess.run(["git", "-C", state["bare"], "rev-parse", "-q", "--verify",
                           "refs/tags/" + tag], capture_output=True).returncode:
            finish(1, "tag %s does not exist" % tag)
        with open(option("--notes-file")) as f:
            notes = f.read()
        state["releases"][tag] = {"title": option("--title"), "notes": notes,
                                  "assets": [os.path.basename(a) for a in args[3:]
                                             if a.endswith(".zip")]}
        finish(0)
    finish(2, "the stub does not know: %s" % args)
    """)


def git(directory, *args, env=None):
    return subprocess.run(["git", "-C", str(directory), *args], check=True, env=env or GIT_ENV,
                          capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------------------
# Pure parts.

class Versions(unittest.TestCase):
    def test_levels(self):
        self.assertEqual(release.next_version((0, 2, 0), "patch"), (0, 2, 1))
        self.assertEqual(release.next_version((0, 2, 3), "minor"), (0, 3, 0))
        self.assertEqual(release.next_version((0, 4, 2), "major"), (1, 0, 0))

    def test_without_a_tag_the_header_is_the_current_version(self):
        self.assertEqual(release.choose_version([], "0.1.0", "minor"), (0, 2, 0))

    def test_the_largest_tag_is_the_current_version(self):
        tags = ["v0.2.0", "v0.10.1", "v0.9.0", "not-a-version", "v1.0"]
        self.assertEqual(release.choose_version(tags, "0.10.1", "patch"), (0, 10, 2))
        self.assertEqual(release.choose_version(tags, "0.10.1", "minor"), (0, 11, 0))
        self.assertEqual(release.choose_version(tags, "0.10.1", "major"), (1, 0, 0))

    def test_an_explicit_version(self):
        self.assertEqual(release.choose_version(["v0.2.0"], "0.2.0", explicit="0.5.0"),
                         (0, 5, 0))

    def test_refusals(self):
        for tags, header, explicit, said in (
                (["v0.2.0"], "0.2.0", "0.2.0", "already tagged"),
                (["v0.2.0", "v0.3.0"], "0.3.0", "0.2.5", "not above v0.3.0"),
                ([], "0.1.0", "0.1.0", "not above 0.1.0"),
                ([], "0.1.0", "1.0", "not a version"),
                ([], "unknown", None, "no vX.Y.Z tag")):
            with self.subTest(explicit=explicit), \
                    self.assertRaisesRegex(release.Refusal, said):
                release.choose_version(tags, header, "minor", explicit)


class Header(unittest.TestCase):
    def test_the_version_line_alone_changes(self):
        before = HEADER.format(version="0.1.0")
        after = release.set_header(before, "0.2.0")
        self.assertEqual(release.header_version(after), "0.2.0")
        self.assertEqual(after, HEADER.format(version="0.2.0"))

    def test_one_version_line_or_none(self):
        with self.assertRaisesRegex(release.Refusal, "2 Version: lines"):
            release.set_header(HEADER.format(version="1.0.0") + ";; Version: 2\n", "1.1.0")
        with self.assertRaisesRegex(release.Refusal, "0 Version: lines"):
            release.set_header(";;; nothing here\n", "1.1.0")


class Notes(unittest.TestCase):
    def setUp(self):
        self.run_view = json.loads((FIXTURES / "run.json").read_text())
        self.job_log = (FIXTURES / "job.log").read_text()

    def evidence(self):
        return "\n".join(release.evidence(self.run_view, self.job_log, FIXTURES / "logs"))

    def test_subjects(self):
        titles = {"12": "A title"}.get
        self.assertEqual(release.note_subject("portal/web-find: finds start in view", titles),
                         "finds start in view")
        self.assertEqual(release.note_subject("Merge pull request #12 from x/y", titles),
                         "A title (#12)")
        self.assertEqual(release.note_subject("Merge pull request #13 from x/y", titles),
                         "Merge pull request #13 from x/y")
        self.assertIsNone(release.note_subject("release: merge Portal 0.2.0 into main"))
        self.assertEqual(release.note_subject("docs: say it plainly"), "docs: say it plainly")

    def test_upgrade_cost_follows_the_native_inputs(self):
        self.assertTrue(release.is_native_input("native/Sources/Portal/Web.swift"))
        self.assertTrue(release.is_native_input("build.sh"))
        self.assertFalse(release.is_native_input("native/.hidden/file"))
        self.assertFalse(release.is_native_input("host/node_modules/x/index.js"))
        self.assertFalse(release.is_native_input("scripts/release.py"))
        self.assertFalse(release.is_native_input("docs/install.md"))
        self.assertEqual(release.upgrade_cost(["portal.el", "scripts/release.py"], False),
                         "Lisp only, no rebuild.")
        self.assertIn("offers a rebuild of several minutes, then restart Emacs",
                      release.upgrade_cost(["portal.el", "tools/bun.manifest"], False))

    def test_every_step_with_its_counts(self):
        text = self.evidence()
        steps = {line.split(" | ")[0][2:]: line.split(" | ")[1:]
                 for line in text.splitlines() if line.startswith("| ")}
        self.assertEqual(steps["CTest"], ["passed", "34 suites: 34 passed |"])
        self.assertEqual(steps["Python"], ["passed", "51 tests: 51 passed |"])
        self.assertEqual(steps["Input (graphical)"],
                         ["passed", "17 tests: 13 passed, 4 skipped |"])
        self.assertEqual(steps["Launcher (graphical)"],
                         ["passed", "42 tests: 41 passed, 1 skipped |"])
        self.assertEqual(steps["Save Homebrew downloads"], ["not run", "|"])
        # The CTest suites' own counts, from ctest.log.
        self.assertEqual(steps["input"], ["passed", "21 tests: 19 passed, 2 skipped |"])
        self.assertEqual(steps["libghostty-spm"], ["passed", "31 tests: 31 passed |"])
        self.assertEqual(steps["app-host"], ["passed", "55 tests: 55 passed |"])
        self.assertEqual(steps["channel"], ["passed", "one program, no count |"])

    def test_every_skipped_test_by_name(self):
        text = self.evidence()
        for name, where in (
                ("portal-launcher-gui-minibuffer-panel-stays-on-its-display",
                 "Launcher (graphical)"),
                ("portal-input-gui-web-fullscreen-page-closes-with-its-buffer",
                 "Input (graphical)"),
                ("portal-input-chords-use-evil-state-keymaps", "CTest input")):
            self.assertIn(f"- `{name}`, in {where}", text)

    def test_the_environment_and_the_commit(self):
        text = self.evidence()
        self.assertIn(f"Commit `{self.run_view['headSha']}`", text)
        self.assertIn(self.run_view["url"], text)
        for line in ("ProductVersion:\t\t27.0.1", "Xcode 27.1", "cmake version 4.4.5",
                     "emacs-module.h from /Applications/Emacs.app/Contents/Resources/include"):
            self.assertIn(line, text)
        self.assertRegex(text, r"\nGNU Emacs 31\.1 ")
        self.assertRegex(text, r"\nresolve-bun: using Bun 1\.3\.14 ")

    def test_a_cached_run_is_no_evidence(self):
        self.job_log = self.job_log.replace("USE_CACHE: false", "USE_CACHE: true")
        with self.assertRaisesRegex(release.Refusal, "restored cached downloads"):
            self.evidence()

    def test_counts_of_each_kind_of_suite(self):
        found, skipped = release.suite_counts([
            "test_a (test_x.T.test_a) ... ok",
            "test_b (test_x.T.test_b) ... skipped 'needs a display'",
            "Ran 2 tests in 0.1s", "OK (skipped=1)"])
        self.assertEqual(found, "2 tests: 1 passed, 1 skipped")
        self.assertEqual(skipped, [("test_x.T.test_b", "needs a display")])
        found, skipped = release.suite_counts([
            "Ran 3 tests, 2 results as expected, 0 unexpected, 1 skipped (…)",
            "1 skipped results:", "  SKIPPED  portal-x  ((skip-unless (featurep 'evil)))"])
        self.assertEqual(found, "3 tests: 2 passed, 1 skipped")
        self.assertEqual(skipped, [("portal-x", "((skip-unless (featurep 'evil)))")])
        found, _ = release.suite_counts(["Graphical Emacs: setup", "ok   a: t",
                                         "9 checks passed", "Graphical Emacs: use",
                                         "6 checks passed"])
        self.assertEqual(found, "15 checks: 15 passed")
        found, skipped = release.suite_counts([" 3 pass", " 1 skip", " 0 fail",
                                               "(skip) host > serves nothing"])
        self.assertEqual(found, "4 tests: 3 passed, 1 skipped")
        self.assertEqual(skipped, [("host > serves nothing", None)])

    def test_the_notes(self):
        text = release.compose_notes("0.3.0", ["finds start in view"], False, ["portal.el"],
                                     ["(evidence)"], {"appkit": True})
        self.assertIn("## What is new\n\n- finds start in view\n", text)
        self.assertIn("## What upgrading costs\n\nLisp only, no rebuild.\n", text)
        self.assertIn("- The standalone AppKit checks: passed", text)
        self.assertIn("- Physical-key delivery, by hand: not run", text)
        first = release.compose_notes("0.2.0", [], True, [], [], {})
        self.assertIn("The first release of Portal", first)
        self.assertIn(release.README, first)


# ---------------------------------------------------------------------------
# Whole releases against a stand-in for GitHub.

class Releases(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bare = self.root / "github.git"
        git(self.root, "init", "-q", "--bare", "-b", "main", str(self.bare))
        self.pushes = self.root / "pushes.log"
        hook = self.bare / "hooks" / "post-receive"
        hook.write_text(f'#!/bin/sh\n{{ cat; echo ---; }} >> "{self.pushes}"\n')
        hook.chmod(0o755)
        self.dev = self.root / "dev"
        git(self.root, "clone", "-q", str(self.bare), str(self.dev))
        self.write("portal.el", HEADER.format(version="0.1.0"))
        self.write("native/core.c", "int core;\n")
        self.commit("portal/start: the beginning")
        self.write("feature.el", "one\n")
        self.commit("portal/feature: a feature in Lisp")
        git(self.dev, "push", "-q", "origin", "main")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        stub = self.bin / "gh"
        stub.write_text(f"#!{sys.executable}\n" + GH_STUB)
        stub.chmod(0o755)
        self.state = self.root / "gh.json"
        self.set_state(bare=str(self.bare), fixtures=str(FIXTURES), conclusion="success",
                       runs=[], dispatches=[], releases={}, pulls={}, calls=[])
        self.env = {**GIT_ENV, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                    "GH_STUB": str(self.state), "PORTAL_RELEASE_REMOTE": str(self.bare),
                    "PORTAL_RELEASE_POLL": "0"}

    def tearDown(self):
        self.temporary.cleanup()

    # The stand-ins.
    def set_state(self, **values):
        state = json.loads(self.state.read_text()) if self.state.exists() else {}
        state.update(values)
        self.state.write_text(json.dumps(state))

    def gh(self):
        return json.loads(self.state.read_text())

    def write(self, path, text):
        (self.dev / path).parent.mkdir(parents=True, exist_ok=True)
        (self.dev / path).write_text(text)

    def commit(self, subject):
        git(self.dev, "add", "-A")
        git(self.dev, "commit", "-q", "-m", subject)
        return git(self.dev, "rev-parse", "HEAD")

    def on_github(self, ref):
        result = subprocess.run(["git", "-C", str(self.bare), "rev-parse", "-q", "--verify",
                                 ref], capture_output=True, text=True, env=GIT_ENV)
        return result.stdout.strip() or None

    def refs(self):
        return git(self.bare, "for-each-ref", "--format=%(refname) %(objectname)")

    def push_count(self):
        return self.pushes.read_text().count("---\n") if self.pushes.exists() else 0

    def release(self, *args, check=0):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                                capture_output=True, text=True, timeout=120)
        if check is not None:
            self.assertEqual(result.returncode, check, result.stderr)
        return result

    def header_blame(self, ref):
        git(self.dev, "fetch", "-q", "origin")
        return git(self.dev, "blame", "--porcelain", "-L", "/^;; Version:/,+1", ref, "--",
                   "portal.el").split()[0]

    def first_release(self):
        """Release 0.2.0 from main and bring the stand-in developer's main up to it."""
        self.release()
        git(self.dev, "pull", "-q", "--ff-only", "origin", "main")
        return self.on_github("refs/tags/v0.2.0^{commit}")

    # The cases.
    def test_a_green_run_publishes_the_tag_stable_and_main_in_one_push(self):
        main = self.on_github("refs/heads/main")
        before = self.push_count()
        result = self.release()
        commit = self.on_github("refs/tags/v0.2.0^{commit}")
        self.assertEqual(git(self.bare, "cat-file", "-t", "v0.2.0"), "tag")
        self.assertEqual(git(self.bare, "rev-parse", f"{commit}^"), main)
        self.assertEqual(self.on_github("refs/heads/stable"), commit)
        self.assertEqual(self.on_github("refs/heads/main"), commit)
        self.assertEqual(git(self.bare, "log", "-1", "--format=%s", commit),
                         "release: Portal 0.2.0")
        self.assertEqual(git(self.bare, "diff", "--numstat", main, commit), "1\t1\tportal.el")
        # The candidate's push, the release's push, the candidate's deletion.
        self.assertEqual(self.push_count() - before, 3)
        pushes = self.pushes.read_text().split("---\n")
        self.assertRegex(pushes[-3], r"refs/tags/v0\.2\.0\n")
        self.assertIn("refs/heads/stable", pushes[-3])
        self.assertIn("refs/heads/main", pushes[-3])
        self.assertIsNone(self.on_github("refs/heads/release/v0.2.0"))
        state = self.gh()
        self.assertEqual(state["dispatches"], [["release/v0.2.0", commit, "--ref",
                                                "release/v0.2.0", "-f", "cache=false"]])
        made = state["releases"]["v0.2.0"]
        self.assertEqual(made["title"], "Portal 0.2.0")
        self.assertEqual(made["assets"], ["portal-0.2.0-checks-logs.zip"])
        self.assertIn("The first release of Portal", made["notes"])
        self.assertIn("34 suites: 34 passed", made["notes"])
        self.assertIn("released", result.stderr)

    def test_the_next_release_lists_what_is_new(self):
        self.first_release()
        self.write("native/core.c", "int core2;\n")
        self.commit("portal/native-change: the core changes")
        git(self.dev, "commit", "-q", "--allow-empty", "-m", "Merge pull request #7 from a/b")
        git(self.dev, "push", "-q", "origin", "main")
        self.set_state(pulls={"7": "Better things"})
        self.release()
        notes = self.gh()["releases"]["v0.3.0"]["notes"]
        self.assertIn("- Better things (#7)\n- the core changes\n", notes)
        self.assertNotIn("a feature in Lisp", notes)
        self.assertIn("offers a rebuild of several minutes", notes)

    def test_main_having_moved_ends_in_a_merge(self):
        self.write("later.el", "later\n")
        later = self.commit("portal/later: merged while Checks ran")
        self.set_state(on_dispatch=f"git -C {self.dev} push -q origin main")
        main = self.on_github("refs/heads/main")
        self.release()
        commit = self.on_github("refs/tags/v0.2.0^{commit}")
        self.assertEqual(self.on_github("refs/heads/stable"), commit)
        merge = self.on_github("refs/heads/main")
        self.assertEqual(git(self.bare, "rev-list", "--parents", "-n1", merge).split()[1:],
                         [later, commit])
        self.assertEqual(git(self.bare, "rev-parse", f"{commit}^"), main)
        self.assertEqual(self.header_blame("origin/main"), commit)

    def test_main_moving_during_the_push_is_merged_and_pushed_again(self):
        self.write("racing.el", "race\n")
        racing = self.commit("portal/race: merged during the push")
        hooks = self.root / "hooks"
        hooks.mkdir()
        marker = self.root / "raced"
        hook = hooks / "pre-push"
        hook.write_text(textwrap.dedent(f"""\
            #!/bin/sh
            grep -q refs/heads/stable || exit 0
            [ -e "{marker}" ] && exit 0
            touch "{marker}"
            env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \\
                git -c core.hooksPath=/dev/null -C "{self.dev}" push -q origin main
            """))
        hook.chmod(0o755)
        self.env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="core.hooksPath",
                        GIT_CONFIG_VALUE_0=str(hooks))
        result = self.release()
        self.assertTrue(marker.exists())
        self.assertIn("main moved while pushing", result.stderr)
        commit = self.on_github("refs/tags/v0.2.0^{commit}")
        self.assertEqual(git(self.bare, "rev-list", "--parents", "-n1",
                             self.on_github("refs/heads/main")).split()[1:], [racing, commit])

    def test_stable_not_an_ancestor_is_refused(self):
        self.first_release()
        git(self.dev, "checkout", "-q", "-b", "elsewhere", "HEAD~1")
        self.write("other.el", "other\n")
        self.commit("portal/other: not on stable")
        git(self.dev, "push", "-q", "origin", "elsewhere")
        refs, pushes = self.refs(), self.push_count()
        result = self.release("--from", "elsewhere", check=1)
        self.assertIn("stable", result.stderr)
        self.assertIn("is not an ancestor", result.stderr)
        self.assertEqual((self.refs(), self.push_count()), (refs, pushes))
        self.assertEqual(self.gh()["dispatches"][1:], [])

    def test_a_red_run_leaves_every_ref_where_it_was(self):
        self.set_state(conclusion="failure")
        refs = self.refs()
        result = self.release(check=1)
        self.assertIn("at CTest", result.stderr)
        self.assertIn("https://github.invalid/runs/1000", result.stderr)
        after = self.refs().splitlines()
        candidate = [line for line in after if "refs/heads/release/v0.2.0" in line]
        self.assertEqual(len(candidate), 1, "the candidate stays for reading")
        self.assertEqual([line for line in after if line not in candidate], refs.splitlines())
        self.assertEqual(self.gh()["releases"], {})

    def test_from_an_earlier_commit_of_main_ends_in_a_merge(self):
        earlier = self.on_github("refs/heads/main")
        self.write("unreleased.el", "not yet\n")
        unreleased = self.commit("portal/unreleased: waits for the next release")
        git(self.dev, "push", "-q", "origin", "main")
        self.release("--from", earlier)
        commit = self.on_github("refs/tags/v0.2.0^{commit}")
        self.assertEqual(git(self.bare, "rev-parse", f"{commit}^"), earlier)
        self.assertEqual(self.on_github("refs/heads/stable"), commit)
        self.assertEqual(git(self.bare, "rev-list", "--parents", "-n1",
                             self.on_github("refs/heads/main")).split()[1:],
                         [unreleased, commit])
        self.assertEqual(self.header_blame("origin/main"), commit)

    def test_a_dry_run_prints_the_notes_and_publishes_nothing(self):
        refs = self.refs()
        result = self.release("--dry-run", "--keys-passed")
        self.assertIn("## What is new", result.stdout)
        self.assertIn("- Physical-key delivery, by hand: passed", result.stdout)
        self.assertEqual(self.refs(), refs)
        self.assertEqual(len(self.gh()["dispatches"]), 1)
        self.assertEqual(self.gh()["releases"], {})

    def test_a_failed_base_run_on_main_stops_unless_told_to_go_on(self):
        main = self.on_github("refs/heads/main")
        self.set_state(runs=[{"databaseId": 5, "headSha": main, "headBranch": "main",
                              "event": "push", "status": "completed",
                              "conclusion": "failure", "url": "https://github.invalid/runs/5"}])
        result = self.release(check=1)
        self.assertIn("Checks on main failed", result.stderr)
        self.assertEqual(self.gh()["dispatches"], [])
        self.release("--ignore-base-checks")
        self.assertIsNotNone(self.on_github("refs/tags/v0.2.0"))

    def test_a_second_run_after_an_interruption(self):
        self.set_state(hold=True)
        self.env["PORTAL_RELEASE_POLL"] = "0.2"
        process = subprocess.Popen([sys.executable, str(SCRIPT)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 60
        while not self.gh()["dispatches"] and time.monotonic() < deadline:
            time.sleep(0.1)
        time.sleep(0.5)
        process.send_signal(signal.SIGINT)
        _, err = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 130, err)
        candidate = self.on_github("refs/heads/release/v0.2.0")
        self.assertIsNotNone(candidate)
        self.assertIsNone(self.on_github("refs/tags/v0.2.0"))
        # The run finishes meanwhile; the next run takes it and the candidate up.
        state = self.gh()
        for run in state["runs"]:
            run.update(status="completed", conclusion="success")
        self.set_state(runs=state["runs"], hold=False)
        self.env["PORTAL_RELEASE_POLL"] = "0"
        result = self.release()
        self.assertIn("continuing with release/v0.2.0", result.stderr)
        self.assertEqual(self.on_github("refs/tags/v0.2.0^{commit}"), candidate)
        self.assertEqual(len(self.gh()["dispatches"]), 1)
        # A third run publishes nothing again.
        refs = self.refs()
        self.assertIn("already tagged", self.release("0.2.0", check=1).stderr)
        self.assertIn("nothing to release", self.release(check=1).stderr)
        self.assertEqual(self.refs(), refs)
        self.assertEqual(list(self.gh()["releases"]), ["v0.2.0"])

    def test_a_tag_without_its_github_release_stops_the_next(self):
        self.first_release()
        self.set_state(releases={})
        self.write("more.el", "more\n")
        self.commit("portal/more: more")
        git(self.dev, "push", "-q", "origin", "main")
        result = self.release(check=1)
        self.assertIn("v0.2.0 is tagged but has no GitHub release", result.stderr)

    def test_a_pick_that_conflicts_pushes_nothing(self):
        self.write("shared.el", "one\n")
        self.commit("portal/shared: one")
        git(self.dev, "push", "-q", "origin", "main")
        self.first_release()
        self.write("shared.el", "two\n")
        self.commit("portal/two: two")
        self.write("shared.el", "three\n")
        fix = self.commit("portal/three: three, which needs two")
        git(self.dev, "push", "-q", "origin", "main")
        # stable says one; the fix changes two to three.
        refs, pushes = self.refs(), self.push_count()
        result = self.release("--pick", fix, check=1)
        self.assertIn("does not apply to stable", result.stderr)
        self.assertIn("--from", result.stderr)
        self.assertEqual((self.refs(), self.push_count()), (refs, pushes))
        self.assertEqual(self.gh()["dispatches"][1:], [])

    def test_a_pick_before_the_first_release_is_refused(self):
        main = self.on_github("refs/heads/main")
        self.assertIn("--pick needs stable", self.release("--pick", main, check=1).stderr)

    def test_two_fix_releases_by_pick_and_by_from(self):
        self.first_release()
        self.write("unreleased.el", "not yet\n")
        self.commit("portal/unreleased: waits for 0.3.0")
        self.write("fix.el", "fixed\n")
        fix = self.commit("portal/fix: the fix")
        git(self.dev, "push", "-q", "origin", "main")

        self.release("--pick", fix)
        patch = self.on_github("refs/tags/v0.2.1^{commit}")
        self.assertEqual(self.on_github("refs/heads/stable"), patch)
        picked = git(self.bare, "log", "-1", "--format=%B", f"{patch}^")
        self.assertIn(f"(cherry picked from commit {fix})", picked)
        self.assertNotIn("unreleased.el", git(self.bare, "ls-tree", "--name-only", patch))
        self.assertRegex(self.gh()["releases"]["v0.2.1"]["notes"],
                         r"## What is new\n\n- the fix\n\n")
        self.assertStableInMainAndBlamed(patch)

        git(self.dev, "fetch", "-q", "origin")
        git(self.dev, "checkout", "-q", "-b", "fix-two", "origin/stable")
        self.write("fix-two.el", "fixed again\n")
        self.commit("portal/fix-two: the second fix")
        git(self.dev, "push", "-q", "origin", "fix-two")
        self.release("--patch", "--from", "fix-two")
        second = self.on_github("refs/tags/v0.2.2^{commit}")
        self.assertEqual(self.on_github("refs/heads/stable"), second)
        self.assertStableInMainAndBlamed(second)
        self.assertIn("unreleased.el", git(self.bare, "ls-tree", "--name-only", "main"))

    def assertStableInMainAndBlamed(self, commit):
        self.assertEqual(subprocess.run(
            ["git", "-C", str(self.bare), "merge-base", "--is-ancestor", "stable", "main"],
            env=GIT_ENV).returncode, 0, "stable is an ancestor of main")
        self.assertEqual(self.header_blame("origin/main"), commit)


if __name__ == "__main__":
    unittest.main()
