#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Release Portal: one commit that changes portal.el's Version: line, tagged
vX.Y.Z, with the branch stable moved to it.  docs/releasing.md explains it.

Usage:
  scripts/release.py                  the next MINOR, from origin/main
  scripts/release.py --patch          the next PATCH: 0.2.0 to 0.2.1
  scripts/release.py --major          the next MAJOR: 0.4.2 to 1.0.0
  scripts/release.py X.Y.Z            that version
  scripts/release.py --from REF       main as of an earlier commit, or a pushed branch
  scripts/release.py --pick COMMIT…   stable plus those commits alone, the next PATCH
  scripts/release.py --dry-run        everything but the publishing
  scripts/release.py --appkit-passed --keys-passed
                                      record the two checks outside CI as passed

It works in a fresh clone of the repository on GitHub, never in this checkout.
It pushes the release commit as the branch release/vX.Y.Z, runs Checks on it
without caches and waits.  When Checks fail, nothing else changes.  When they
pass, it composes the notes from the run's logs, then pushes the tag, stable
and main in one atomic push, creates the GitHub release with the logs attached
and deletes the candidate branch.  A dry run prints the notes instead.

It runs git and gh with your own credentials.  PORTAL_RELEASE_REMOTE replaces
the repository's URL and PORTAL_RELEASE_POLL the seconds between looks at the
run; the tests use both.
"""
# Why scripts/ and not tools/: portal-build--input-files in portal-build.el
# hashes CMakeLists.txt, CMakePresets.json, build.sh and everything under
# host/, native/ and tools/, and a change to any of them makes every user
# rebuild the native part.  This command is no part of the build, so it lives
# where that hash does not look.  Keep it, and whatever it reads, out of those.
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

GITHUB = "xiaoxinghu/portal"
README = f"https://github.com/{GITHUB}#readme"
WORKFLOW = "checks.yml"
MAIN_FILE = "portal.el"
# The checks docs/releasing.md asks for that CI cannot run.
OUTSIDE_CI = (("appkit", "The standalone AppKit checks"),
              ("keys", "Physical-key delivery, by hand"))
# How often a push is tried again when main moves under it.
PUSH_TRIES = 4

VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
HEADER = re.compile(r"^;; Version: *(\S+)[ \t]*$", re.M)
TASK_PREFIX = re.compile(r"^portal/[^:\s]+: ")
PULL_MERGE = re.compile(r"^Merge pull request #(\d+)\b")
RELEASE_SUBJECT = re.compile(r"^release: ")


class Refusal(Exception):
    """Why the release stops; nothing on GitHub has changed unless it says so."""


def say(message):
    print(f"release: {message}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Versions and the header: pure functions.

def parse_version(text):
    """(MAJOR, MINOR, PATCH) of X.Y.Z, or None."""
    match = VERSION.match(text or "")
    return tuple(int(part) for part in match.groups()) if match else None


def show(version):
    return "%d.%d.%d" % version


def tag_versions(tags):
    """The versions of the vX.Y.Z tags among TAGS, largest last."""
    return sorted(tuple(int(part) for part in match.groups())
                  for match in map(TAG.match, tags) if match)


def next_version(current, level):
    """The version after CURRENT at LEVEL: major, minor or patch."""
    major, minor, patch = current
    if level == "major":
        return (major + 1, 0, 0)
    if level == "minor":
        return (major, minor + 1, 0)
    if level == "patch":
        return (major, minor, patch + 1)
    raise ValueError(level)


def choose_version(tags, header, level=None, explicit=None):
    """The version to release, from the largest vX.Y.Z tag or, with none, the
    HEADER's version: EXPLICIT if given, else the next at LEVEL.  Refuses one
    that is not above every tag and the header."""
    versions = tag_versions(tags)
    current = versions[-1] if versions else parse_version(header)
    if current is None:
        raise Refusal(f"no vX.Y.Z tag, and the header says {header!r}, not X.Y.Z")
    if explicit:
        version = parse_version(explicit)
        if version is None:
            raise Refusal(f"{explicit} is not a version X.Y.Z")
    else:
        version = next_version(current, level)
    if "v" + show(version) in tags:
        raise Refusal(f"v{show(version)} is already tagged")
    if versions and version <= versions[-1]:
        raise Refusal(f"{show(version)} is not above v{show(versions[-1])}, the largest tag")
    header_version = parse_version(header)
    if header_version and version <= header_version:
        raise Refusal(f"{show(version)} is not above {header}, the version {MAIN_FILE} says")
    return version


def header_version(text):
    match = HEADER.search(text)
    return match.group(1) if match else None


def set_header(text, version):
    """TEXT with its Version: line saying VERSION and nothing else changed."""
    matches = list(HEADER.finditer(text))
    if len(matches) != 1:
        raise Refusal(f"{MAIN_FILE} has {len(matches)} Version: lines, not one")
    match = matches[0]
    return text[:match.start(1)] + version + text[match.end(1):]


# ---------------------------------------------------------------------------
# The notes: pure functions over subjects, paths and the run's logs.

def note_subject(subject, pull_title=None):
    """SUBJECT as a line of "What is new", or None for a release's own commits.
    PULL_TITLE gives a pull request's title from its number, or None."""
    if RELEASE_SUBJECT.match(subject):
        return None
    pull = PULL_MERGE.match(subject)
    if pull and pull_title:
        title = pull_title(pull.group(1))
        if title:
            return f"{title} (#{pull.group(1)})"
    return TASK_PREFIX.sub("", subject, count=1)


def is_native_input(path):
    """Whether portal-build--input-files lists PATH: what a native build hashes."""
    if path in ("CMakeLists.txt", "CMakePresets.json", "build.sh"):
        return True
    parts = path.split("/")
    return (len(parts) > 1 and parts[0] in ("host", "native", "tools")
            and not any(part.startswith(".") for part in parts)
            and "node_modules" not in parts[:-1])


def upgrade_cost(changed_paths, first):
    if first:
        return ("The first release: installing it builds the native part once, "
                "which takes several minutes.")
    native = sorted(path for path in changed_paths if is_native_input(path))
    if not native:
        return "Lisp only, no rebuild."
    return ("The first native command after upgrading offers a rebuild of several "
            f"minutes, then restart Emacs. The native sources changed in {len(native)} "
            f"file{'s' if len(native) != 1 else ''}.")


STAMP = re.compile(r"^\ufeff?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ?")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def job_log_sections(text):
    """The job log in steps: a list of each `Run` group's lines, without the
    timestamps, in the order the steps ran.  The command and environment the
    runner echoes before ##[endgroup] stay in, as the first lines."""
    sections = []
    for line in text.splitlines():
        line = ANSI.sub("", STAMP.sub("", line))
        if line.startswith("##[group]Run "):
            sections.append([])
        if sections:
            sections[-1].append(line)
    return sections


def step_logs(steps, text):
    """{step number: its lines of the job log}.  A step that ran has one `Run`
    group in the log, in order; the runner's own steps have none."""
    ran = [step for step in steps
           if step.get("conclusion") not in ("skipped", None)
           and step["name"] not in ("Set up job", "Complete job")
           and not step["name"].startswith("Post ")]
    sections = job_log_sections(text)
    if len(sections) != len(ran):
        raise Refusal(f"the job log has {len(sections)} steps and the run {len(ran)}: "
                      "they cannot be matched")
    return {step["number"]: section for step, section in zip(ran, sections)}


def output_of(section):
    """A step's lines after the command and environment the runner echoes."""
    for index, line in enumerate(section):
        if line.startswith("##[endgroup]"):
            return section[index + 1:]
    return section[1:]


def counts(passed=0, failed=0, skipped=0, unit="tests", total=None):
    total = passed + failed + skipped if total is None else total
    parts = [f"{passed} passed"]
    if failed:
        parts.append(f"{failed} failed")
    if skipped:
        parts.append(f"{skipped} skipped")
    return f"{total} {unit if total != 1 else unit[:-1]}: " + ", ".join(parts)


ERT_SUMMARY = re.compile(r"^(?:Aborted: )?Ran (\d+) tests?, (\d+) results? as expected, "
                         r"(\d+) unexpected(?:, (\d+) skipped)?")
ERT_SKIPPED = re.compile(r"^\s*SKIPPED\s+(\S+)(?:\s+(.*))?$")
CTEST_SUMMARY = re.compile(r"^\d+% tests passed(?:, (\d+) tests? failed)? out of (\d+)")
CTEST_NOT_RUN = re.compile(r"^\s*\d+ - (\S+) \((Skipped|Disabled|Not Run)\)")
PY_SUMMARY = re.compile(r"^Ran (\d+) tests? in ")
PY_RESULT = re.compile(r"^(OK|FAILED)(?: \((.*)\))?$")
PY_TEST = re.compile(r"^(test\w*) \(([\w.]+)\)")
PY_SKIPPED = re.compile(r" \.\.\. skipped '(.*)'$")
BUN_COUNT = re.compile(r"^\s*(\d+) (pass|skip|todo|fail)$")
BUN_SKIPPED = re.compile(r"^\(skip\) (.+?)(?: \[[\d.]+m?s\])?$")
SWIFT_SUMMARY = re.compile(r"Test run with (\d+) tests? (?:in \d+ suites? )?"
                           r"(passed|failed)(?:.*with (\d+) issues?)?")
SWIFT_SKIPPED = re.compile(r'Test "(.+?)" skipped(?:: "(.*)")?')
XCTEST_SUMMARY = re.compile(r"Executed (\d+) tests?, with (\d+) failures?")
PACKAGE_PASSED = re.compile(r"^(\d+) checks passed$")


def suite_counts(lines):
    """What LINES, one suite's output, say it ran: (counts or None, [(skipped test,
    reason)]).  Reads ERT, CTest, Python's unittest, Bun, Swift Testing, XCTest
    and the package suite's own count; None when none of them is there."""
    lines = [ANSI.sub("", line) for line in lines]
    skipped, found = [], None
    ert = [ERT_SUMMARY.match(line) for line in lines]
    ert = [match for match in ert if match]
    if ert:
        total = sum(int(match.group(1)) for match in ert)
        expected = sum(int(match.group(2)) for match in ert)
        unexpected = sum(int(match.group(3)) for match in ert)
        skips = sum(int(match.group(4) or 0) for match in ert)
        found = counts(expected, unexpected, skips, total=total)
        skipped += [(match.group(1), (match.group(2) or "").strip() or None)
                    for match in map(ERT_SKIPPED.match, lines) if match]
    for line in lines:
        match = CTEST_SUMMARY.match(line)
        if match:
            failed, total = int(match.group(1) or 0), int(match.group(2))
            not_run = [m.group(1) for m in map(CTEST_NOT_RUN.match, lines) if m]
            found = counts(total - failed - len(not_run), failed, len(not_run),
                           unit="suites", total=total)
            skipped += [(name, "CTest did not run it") for name in not_run]
    python = [PY_SUMMARY.match(line) for line in lines]
    python = [match for match in python if match]
    if python:
        total = int(python[-1].group(1))
        details = {}
        for match in map(PY_RESULT.match, lines):
            if match and match.group(2):
                for part in match.group(2).split(", "):
                    key, _, value = part.partition("=")
                    details[key] = int(value)
        failed = details.get("failures", 0) + details.get("errors", 0)
        skips = details.get("skipped", 0)
        found = counts(total - failed - skips, failed, skips, total=total)
        test = None
        for line in lines:
            name = PY_TEST.match(line)
            if name:
                test = name.group(2)
            skip = PY_SKIPPED.search(line)
            if skip and test:
                skipped.append((test, skip.group(1)))
    bun = {}
    for match in map(BUN_COUNT.match, lines):
        if match:
            bun[match.group(2)] = bun.get(match.group(2), 0) + int(match.group(1))
    if bun:
        found = counts(bun.get("pass", 0), bun.get("fail", 0),
                       bun.get("skip", 0) + bun.get("todo", 0))
        skipped += [(match.group(1), None) for match in map(BUN_SKIPPED.match, lines)
                    if match]
    for line in lines:
        match = SWIFT_SUMMARY.search(line)
        if match:
            swift_skips = [m for m in map(SWIFT_SKIPPED.search, lines) if m]
            total = int(match.group(1))
            failed = int(match.group(3) or 0) if match.group(2) == "failed" else 0
            found = counts(total - failed - len(swift_skips), failed, len(swift_skips),
                           total=total)
            skipped += [(m.group(1), m.group(2)) for m in swift_skips]
        match = XCTEST_SUMMARY.search(line)
        if match and not found:
            total, failed = int(match.group(1)), int(match.group(2))
            found = counts(total - failed, failed, total=total)
    package = [int(match.group(1)) for match in map(PACKAGE_PASSED.match, lines) if match]
    if package:
        failed = sum(1 for line in lines if line.startswith("FAIL "))
        found = counts(sum(package), failed, unit="checks")
    return found, skipped


CTEST_LOG_START = re.compile(r"^\d+/\d+ Testing: (\S+)$")
CTEST_LOG_RESULT = re.compile(r"^Test (Passed|Failed|Skipped|Not Run)\b")


def ctest_log_suites(text):
    """[(suite, result, counts, skipped)] from CTest's LastTest.log, in the
    order of the log."""
    suites, name, lines = [], None, []

    def close():
        if name:
            result = next((match.group(1).lower() for match in
                           map(CTEST_LOG_RESULT.match, lines) if match), "not run")
            found, skipped = suite_counts(lines)
            suites.append((name, result, found, skipped))

    for line in text.splitlines():
        match = CTEST_LOG_START.match(line)
        if match:
            close()
            name, lines = match.group(1), []
        elif name:
            lines.append(line)
    close()
    return sorted(suites)


ENVIRONMENT_EXTRAS = (re.compile(r"^GNU Emacs \d"), re.compile(r"^ of \d{4}-\d\d-\d\d "),
                      re.compile(r"^emacs-module\.h from "),
                      re.compile(r"^resolve-bun: using Bun "))


def evidence(run, job_log, logs_dir):
    """The notes' Evidence section, read from RUN (gh's JSON of the run), its
    JOB_LOG and the files of its logs artifact in LOGS_DIR."""
    job = run["jobs"][0]
    sections = step_logs(job["steps"], job_log)
    out = []
    record = next((sections.get(step["number"]) for step in job["steps"]
                   if step["name"] == "Record the environment"), None)
    if record is None:
        raise Refusal("the run's log has no \"Record the environment\" step")
    cached = [line.split(":", 1)[1].strip() for line in record
              if line.strip().startswith("USE_CACHE:")]
    if cached != ["false"]:
        raise Refusal(f"run {run['url']} restored cached downloads: it is no evidence "
                      "for a release")
    out.append(f"Commit `{run['headSha']}`, Checks run {run['url']}, without cached downloads.")
    environment = [line for line in output_of(record) if line.strip()]
    extras = [line for lines in sections.values() if lines is not record
              for line in output_of(lines)]
    build_log = Path(logs_dir) / "build.log"
    if build_log.exists():
        extras += build_log.read_text(errors="replace").splitlines()
    # The first of each, in the order the steps ran: later steps resolve Bun again.
    for pattern in ENVIRONMENT_EXTRAS:
        line = next((line for line in extras if pattern.match(line)), None)
        if line and line not in environment:
            environment.append(line)
    out += ["", "### Environment", "", "```", *environment, "```"]

    rows, skipped = [], []
    for step in job["steps"]:
        name = step["name"]
        if name in ("Set up job", "Complete job") or name.startswith("Post "):
            continue
        result = {"success": "passed", "failure": "failed", "skipped": "not run",
                  "cancelled": "cancelled"}.get(step.get("conclusion"), step.get("conclusion"))
        section = sections.get(step["number"])
        found, skips = suite_counts(output_of(section)) if section else (None, [])
        rows.append(f"| {name} | {result} | {found} |" if found else f"| {name} | {result} | |")
        skipped += [(test, reason, name) for test, reason in skips]
    out += ["", "### Steps", "",
            "Each step of the run. A step not run proves nothing; counts are as the step's log "
            "gives them.", "", "| Step | Result | Counts |", "| --- | --- | --- |", *rows]

    ctest_log = Path(logs_dir) / "ctest.log"
    if ctest_log.exists():
        suites = ctest_log_suites(ctest_log.read_text(errors="replace"))
        out += ["", "<details><summary>CTest suites</summary>", "",
                "| Suite | Result | Counts |", "| --- | --- | --- |"]
        for name, result, found, skips in suites:
            out.append(f"| {name} | {result} | {found or 'one program, no count'} |")
            skipped += [(test, reason, f"CTest {name}") for test, reason in skips]
        out += ["", "</details>"]
    else:
        out += ["", "CTest's own log, `ctest.log`, is not among the run's logs: the tests "
                "skipped inside its suites cannot be named."]

    out += ["", "### Skipped tests", ""]
    if skipped:
        out += [f"- `{test}`, in {where}" + (f": {reason}" if reason else ": no reason given")
                for test, reason, where in skipped]
    else:
        out.append("None.")
    return out


def compose_notes(version, subjects, first, changed_paths, evidence_lines, outside):
    """The GitHub release's notes, as Markdown."""
    lines = ["## What is new", ""]
    if first:
        lines.append(f"The first release of Portal. What it does and how to install it is in "
                     f"the [README]({README}).")
    else:
        lines += [f"- {subject}" for subject in subjects] or ["Nothing but fixes."]
    lines += ["", "## What upgrading costs", "", upgrade_cost(changed_paths, first)]
    lines += ["", "## Evidence", "", *evidence_lines]
    lines += ["", "### Checks outside CI", ""]
    lines += [f"- {label}: {'passed' if outside.get(key) else 'not run'}"
              for key, label in OUTSIDE_CI]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Git and gh.

def run(command, cwd=None, check=True, quiet=False):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()
        shown = [command[0], *command[3:5]] if command[1:2] == ["-C"] else command[:3]
        raise Refusal(f"{' '.join(shown)} failed: {detail}")
    return result


class Repository:
    """The release's clone of the repository on GitHub."""

    def __init__(self, path):
        self.path = path

    def git(self, *args, check=True):
        return run(["git", "-C", str(self.path), *args], check=check)

    def out(self, *args):
        return self.git(*args).stdout.strip()

    def commit_of(self, ref):
        result = self.git("rev-parse", "--verify", "-q", f"{ref}^{{commit}}", check=False)
        return result.stdout.strip() if result.returncode == 0 else None

    def is_ancestor(self, older, newer):
        return self.git("merge-base", "--is-ancestor", older, newer, check=False).returncode == 0

    def fetch(self):
        # Tags are never pruned: the release's own tag waits here between tries.
        self.git("fetch", "-q", "--prune", "--tags", "origin")

    def tags(self):
        return self.out("tag", "--list", "v*").split()

    def show(self, commit, path):
        return self.out("show", f"{commit}:{path}")


class GitHub:
    def __init__(self, slug):
        self.slug = slug
        self.titles = {}

    def gh(self, *args, check=True):
        # gh api takes the repository in its path, every other command -R.
        repo = [] if args[0] == "api" else ["-R", self.slug]
        try:
            return run(["gh", *args, *repo], check=check)
        except FileNotFoundError:
            raise Refusal("gh, the GitHub CLI, is not installed")

    def json(self, *args):
        return json.loads(self.gh(*args).stdout or "null")

    def signed_in(self):
        try:
            return run(["gh", "auth", "status"], check=False).returncode == 0
        except FileNotFoundError:
            raise Refusal("gh, the GitHub CLI, is not installed")

    def runs(self, *filters):
        return self.json("run", "list", "--workflow", WORKFLOW, *filters, "-L", "50", "--json",
                         "databaseId,headSha,headBranch,event,status,conclusion,url")

    def view(self, run_id):
        return self.json("run", "view", str(run_id), "--json",
                         "databaseId,headSha,status,conclusion,url,jobs")

    def pull_title(self, number):
        if number not in self.titles:
            result = self.gh("pr", "view", number, "--json", "title", check=False)
            self.titles[number] = (json.loads(result.stdout).get("title")
                                   if result.returncode == 0 else None)
        return self.titles[number]

    def has_release(self, tag):
        return self.gh("release", "view", tag, "--json", "tagName", check=False).returncode == 0


# ---------------------------------------------------------------------------
# The release.

class Release:
    def __init__(self, options, work):
        self.options = options
        self.work = Path(work)
        self.repo = Repository(self.work / "portal")
        self.github = GitHub(GITHUB)
        self.remote = os.environ.get("PORTAL_RELEASE_REMOTE") or f"https://github.com/{GITHUB}.git"
        self.poll = float(os.environ.get("PORTAL_RELEASE_POLL", "30"))

    # 1. A clean clone and the base.
    def clone(self):
        say(f"cloning {self.remote}")
        run(["git", "clone", "-q", "--no-checkout", self.remote, str(self.repo.path)])

    def base(self):
        """The commit the release commit goes on, and the commits picked, if any."""
        options, repo = self.options, self.repo
        if options.pick:
            stable = repo.commit_of("origin/stable")
            if not stable:
                raise Refusal("--pick needs stable, which the first release makes")
            repo.git("checkout", "-q", "--detach", stable)
            for name in options.pick:
                commit = repo.commit_of(name)
                if not commit:
                    raise Refusal(f"{name} is not a commit on GitHub")
                merge = len(repo.out("rev-list", "--parents", "-n1", commit).split()) > 2
                picked = repo.git("cherry-pick", "-x", *(["-m", "1"] if merge else []), commit,
                                  check=False)
                if picked.returncode:
                    conflicts = repo.out("diff", "--name-only", "--diff-filter=U").split()
                    repo.git("cherry-pick", "--abort", check=False)
                    raise Refusal(
                        f"{name} does not apply to stable"
                        + (f" (conflicts in {', '.join(conflicts)})" if conflicts else "")
                        + ". Nothing was pushed. Make the branch by hand from stable, push it, "
                        "and release it with --from BRANCH.")
            return repo.out("rev-parse", "HEAD")
        ref = options.base or "main"
        for candidate in (f"origin/{ref}", ref):
            commit = repo.commit_of(candidate)
            if commit:
                return commit
        raise Refusal(f"{ref} is not on GitHub: push it first")

    # 2 and 3. The version and the refusals.
    def check(self, base):
        repo, github = self.repo, self.github
        tags = repo.tags()
        header = header_version(repo.show(base, MAIN_FILE))
        level = ("major" if self.options.major else "patch"
                 if self.options.patch or self.options.pick else "minor")
        version = choose_version(tags, header, level, self.options.version)
        versions = tag_versions(tags)
        previous = "v" + show(versions[-1]) if versions else None
        if previous and not github.has_release(previous):
            raise Refusal(f"{previous} is tagged but has no GitHub release: an earlier run "
                          "stopped after publishing. Create that release before the next.")
        stable = repo.commit_of("origin/stable")
        if stable and not repo.is_ancestor(stable, base):
            raise Refusal(f"stable ({stable[:12]}) is not an ancestor of {base[:12]}: "
                          "releasing it would rewrite stable")
        if previous and not [s for s in self.subjects(previous, base)]:
            raise Refusal(f"nothing to release: {base[:12]} adds nothing to {previous}")
        if not self.options.pick and repo.is_ancestor(base, "origin/main"):
            self.check_base_run(base)
        return version, previous

    def check_base_run(self, base):
        runs = [r for r in self.github.runs("--commit", base)
                if r.get("event") == "push" and r.get("headBranch") == "main"]
        if not runs:
            say(f"{base[:12]} has no Checks run of its own on main")
            return
        latest = max(runs, key=lambda r: r["databaseId"])
        if latest.get("status") != "completed":
            say(f"Checks on main for {base[:12]} are still running: {latest['url']}")
        elif latest.get("conclusion") != "success":
            message = (f"Checks on main failed for {base[:12]} ({latest.get('conclusion')}): "
                       f"{latest['url']}")
            if not self.options.ignore_base_checks:
                raise Refusal(message + ". Fix it, or go on with --ignore-base-checks.")
            say(message + "; going on, as asked")
        else:
            say(f"Checks on main passed for {base[:12]}")

    def subjects(self, since, base):
        """The first-parent subjects from SINCE to BASE, as notes' lines."""
        log = self.repo.out("log", "--first-parent", "--format=%s", f"{since}..{base}")
        lines = [note_subject(subject, self.github.pull_title)
                 for subject in log.splitlines() if subject]
        return [line for line in lines if line]

    # 4. The release commit, pushed as the candidate.
    def is_release_commit(self, commit, version):
        repo = self.repo
        parents = repo.out("rev-list", "--parents", "-n1", commit).split()[1:]
        if len(parents) != 1:
            return False
        if repo.out("log", "-1", "--format=%s", commit) != f"release: Portal {version}":
            return False
        numstat = repo.out("diff", "--numstat", parents[0], commit)
        return (numstat == f"1\t1\t{MAIN_FILE}"
                and header_version(repo.show(commit, MAIN_FILE)) == version)

    def candidate(self, base, version):
        """The release commit for VERSION on BASE: the candidate branch's when
        an earlier run left an equal one, else a new one, pushed."""
        repo, branch = self.repo, f"release/v{version}"
        existing = repo.commit_of(f"origin/{branch}")
        if existing and self.is_release_commit(existing, version):
            parent = repo.out("rev-parse", f"{existing}^")
            same = parent == base or (
                self.options.pick
                and repo.out("rev-parse", f"{parent}^{{tree}}") == repo.out(
                    "rev-parse", f"{base}^{{tree}}")
                and repo.is_ancestor("origin/stable", parent)
                and repo.out("rev-list", "--count", f"origin/stable..{parent}")
                == str(len(self.options.pick)))
            if same:
                say(f"continuing with {branch} ({existing[:12]}), left by an earlier run")
                return existing, parent
        repo.git("checkout", "-q", "--detach", base)
        path = repo.path / MAIN_FILE
        path.write_text(set_header(path.read_text(), version))
        repo.git("commit", "-q", "-m", f"release: Portal {version}", "--", MAIN_FILE)
        commit = repo.out("rev-parse", "HEAD")
        if not self.is_release_commit(commit, version):
            raise Refusal("the release commit changes more than the Version: line")
        blamed = repo.out("blame", "--porcelain", "-L", "/^;; Version:/,+1", commit, "--",
                          MAIN_FILE).split()[0]
        if blamed != commit:
            raise Refusal(f"git blame names {blamed[:12]} for the Version: line, not the "
                          "release commit")
        lease = [f"--force-with-lease=refs/heads/{branch}:{existing}"] if existing else []
        if existing:
            say(f"replacing {branch}, which an earlier run left on another base")
        repo.git("push", "-q", *lease, "origin", f"{commit}:refs/heads/{branch}")
        say(f"pushed {branch} ({commit[:12]}): release: Portal {version}")
        return commit, base

    # 5. Checks, uncached.
    def checks(self, commit, version):
        github, branch = self.github, f"release/v{version}"
        runs = [r for r in github.runs("--branch", branch, "--event", "workflow_dispatch")
                if r["headSha"] == commit]
        going = [r for r in runs if r.get("status") != "completed"
                 or r.get("conclusion") == "success"]
        if going:
            found = max(going, key=lambda r: r["databaseId"])
            say(f"continuing with Checks run {found['url']}, started by an earlier run")
        else:
            before = {r["databaseId"] for r in runs}
            github.gh("workflow", "run", WORKFLOW, "--ref", branch, "-f", "cache=false")
            say(f"started Checks on {branch}, without cached downloads")
            found, deadline = None, time.monotonic() + 300
            while not found:
                runs = [r for r in github.runs("--branch", branch, "--event",
                                               "workflow_dispatch")
                        if r["headSha"] == commit and r["databaseId"] not in before]
                if runs:
                    found = max(runs, key=lambda r: r["databaseId"])
                elif time.monotonic() > deadline:
                    raise Refusal(f"no Checks run appeared for {commit[:12]} on {branch}")
                else:
                    time.sleep(min(self.poll, 5))
        return self.wait(found["databaseId"])

    def wait(self, run_id):
        started, last = time.monotonic(), None
        while True:
            view = self.github.view(run_id)
            if view.get("status") == "completed":
                return view
            steps = [step for job in view.get("jobs", []) for step in job.get("steps", [])
                     if step.get("status") == "in_progress"]
            doing = f", at {steps[0]['name']}" if steps else ""
            message = f"waiting for Checks {view['url']}: {view.get('status')}{doing}"
            if message != last:
                minutes = int((time.monotonic() - started) // 60)
                say(message + (f" ({minutes} min so far)" if minutes else ""))
                last = message
            time.sleep(self.poll)

    # 6. Red.
    def red(self, view, version):
        failed = [step["name"] for job in view.get("jobs", []) for step in job.get("steps", [])
                  if step.get("conclusion") in ("failure", "cancelled", "timed_out")]
        raise Refusal(f"Checks {view.get('conclusion')} on release/v{version}"
                      + (f", at {', '.join(failed)}" if failed else "")
                      + f": {view['url']}. Nothing is tagged or moved; release/v{version} "
                      "stays for reading and the next run replaces it.")

    # 7. Green: the notes.
    def notes(self, view, version, base, previous):
        github, logs = self.github, self.work / "logs"
        github.gh("run", "download", str(view["databaseId"]), "-n", "logs", "-D", str(logs))
        job = view["jobs"][0]
        job_log = github.gh("api", "--allow-escape-sequences",
                           f"repos/{GITHUB}/actions/jobs/{job['databaseId']}/logs").stdout
        (logs / "job.log").write_text(job_log)
        commit = view["headSha"]
        first = previous is None
        changed = [] if first else self.repo.out(
            "diff", "--name-only", previous, commit).splitlines()
        subjects = [] if first else self.subjects(previous, base)
        outside = {"appkit": self.options.appkit_passed, "keys": self.options.keys_passed}
        text = compose_notes(version, subjects, first, changed,
                             evidence(view, job_log, logs), outside)
        notes = self.work / "notes.md"
        notes.write_text(text)
        asset = self.work / f"portal-{version}-checks-logs.zip"
        with zipfile.ZipFile(asset, "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(logs.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(logs))
        return notes, asset

    # 8. Green: publish.
    def publish(self, commit, version, notes, asset):
        repo, tag = self.repo, f"v{version}"
        repo.git("tag", "-a", tag, "-m", f"Portal {version}", commit)
        stable = repo.commit_of("origin/stable")
        for attempt in range(1, PUSH_TRIES + 1):
            repo.fetch()
            if repo.git("ls-remote", "--exit-code", "--tags", "origin", f"refs/tags/{tag}",
                        check=False).returncode == 0:
                raise Refusal(f"{tag} appeared on GitHub meanwhile; nothing was pushed")
            if repo.commit_of("origin/stable") != stable:
                raise Refusal("stable moved meanwhile; nothing was pushed")
            main = repo.out("rev-parse", "origin/main")
            if repo.is_ancestor(main, commit):
                target, how = commit, "fast-forwarded"
            else:
                merged = repo.git("merge-tree", "--write-tree", main, commit, check=False)
                if merged.returncode:
                    raise Refusal(f"merging the release into main conflicts: {merged.stdout}"
                                  "; nothing was pushed")
                tree = merged.stdout.split()[0]
                target = repo.out("commit-tree", tree, "-p", main, "-p", commit, "-m",
                                  f"release: merge Portal {version} into main")
                how = "merged"
            pushed = repo.git("push", "--atomic", "--porcelain", "origin",
                              f"refs/tags/{tag}:refs/tags/{tag}",
                              f"{commit}:refs/heads/stable", f"{target}:refs/heads/main",
                              check=False)
            if pushed.returncode == 0:
                say(f"pushed {tag}, stable at {commit[:12]} and main {how} ({target[:12]})")
                break
            repo.fetch()
            if repo.out("rev-parse", "origin/main") == main or attempt == PUSH_TRIES:
                raise Refusal(f"the push was refused; nothing was pushed:\n"
                              f"{pushed.stdout}{pushed.stderr}")
            say("main moved while pushing; merging again")
        self.published = tag
        self.github.gh("release", "create", tag, "--verify-tag", "--title", f"Portal {version}",
                       "--notes-file", str(notes), str(asset))
        say(f"released https://github.com/{GITHUB}/releases/tag/{tag}")

    def delete_candidate(self, version):
        self.repo.git("push", "-q", "origin", "--delete", f"release/v{version}", check=False)

    def main(self):
        if not self.github.signed_in():
            raise Refusal("gh is not signed in: run gh auth login")
        self.clone()
        base = self.base()
        version, previous = self.check(base)
        version = show(version)
        say(f"releasing Portal {version} from {base[:12]}"
            + (f", after {previous}" if previous else ", the first release"))
        commit, base = self.candidate(base, version)
        view = self.checks(commit, version)
        if view.get("conclusion") != "success":
            self.red(view, version)
        notes, asset = self.notes(view, version, base, previous)
        if self.options.dry_run:
            print(notes.read_text(), end="")
            self.delete_candidate(version)
            say(f"dry run: nothing published; release/v{version} deleted")
            return
        self.publish(commit, version, notes, asset)
        self.delete_candidate(version)


def parse(argv):
    parser = argparse.ArgumentParser(
        prog="release", description="Release Portal: see docs/releasing.md.")
    parser.add_argument("version", nargs="?", metavar="X.Y.Z", help="the version to release")
    level = parser.add_mutually_exclusive_group()
    level.add_argument("--patch", action="store_true", help="the next PATCH version")
    level.add_argument("--major", action="store_true", help="the next MAJOR version")
    base = parser.add_mutually_exclusive_group()
    base.add_argument("--from", dest="base", metavar="REF",
                      help="release this commit, tag or branch on GitHub instead of main's tip")
    base.add_argument("--pick", nargs="+", metavar="COMMIT",
                      help="release stable with these commits cherry-picked onto it")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the notes instead of publishing")
    parser.add_argument("--appkit-passed", action="store_true",
                        help="the standalone AppKit checks passed at this commit")
    parser.add_argument("--keys-passed", action="store_true",
                        help="physical-key delivery was checked by hand at this commit")
    parser.add_argument("--ignore-base-checks", action="store_true",
                        help="go on when Checks on main failed for the base commit")
    options = parser.parse_args(argv)
    if options.version and (options.patch or options.major):
        parser.error("give a version or a level, not both")
    return options


def main(argv=None):
    options = parse(sys.argv[1:] if argv is None else argv)
    work = tempfile.mkdtemp(prefix="portal-release-")
    release = Release(options, work)
    release.published = None
    keep = False
    try:
        release.main()
        return 0
    except (Refusal, KeyboardInterrupt) as stop:
        say(str(stop) if isinstance(stop, Refusal) else "interrupted")
        tag = release.published
        if tag:
            # Pushed but not released: what finishes it, with what this run made.
            keep = True
            say(f"{tag} is pushed. {work} keeps the notes and logs; create the release with:\n"
                f"  gh release create {tag} --verify-tag -R {GITHUB} --title 'Portal "
                f"{tag[1:]}' --notes-file {work}/notes.md {work}/*.zip")
        return 130 if isinstance(stop, KeyboardInterrupt) else 1
    finally:
        if not keep:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
