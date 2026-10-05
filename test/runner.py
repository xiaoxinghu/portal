# SPDX-License-Identifier: GPL-3.0-or-later
"""Portal's test runner, run as ./test.sh (docs/testing.md).

It plans a run from the suites CMake registers (test/suites.cmake) and the
manual checks below, refuses runs that lack the permission they need, builds
their prerequisites, runs the suites through CTest and records the evidence
in BUILD/test-runs/. It is no test framework: every automated suite is a
CTest test, and this decides only which ones run, how and with what record.
Python 3.9's standard library only."""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import datetime
import fcntl
import hashlib
import json
import os
import platform
import re
import select
import shutil
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CATEGORIES = ("unit", "integration", "gui", "stress", "external", "manual")
COMMANDS = {
    **{category: (category,) for category in CATEGORIES},
    "headless": ("unit", "integration"),
    "regression": ("unit", "integration", "gui", "stress"),
    "all": CATEGORIES,
}
PASSED, FAILED, REFUSED, INCOMPLETE, INTERRUPTED = 0, 1, 2, 3, 130
MAX_REPEAT = 20

# What each kind of suite needs built; see the portal-test-* targets in
# CMakeLists.txt. Headless runs never build the native module.
TARGETS = {"unit": "portal-test-unit", "integration": "portal-test-integration",
           "stress": "portal-test-unit", "desktop": "portal-test-desktop"}

# Variables that change what suites do; recorded, and part of a run's identity.
VARIABLES = ("EMACS", "EMACS_INCLUDE", "LIBRARY_PATH", "PORTAL_LAUNCHER_CONFIG",
             "PORTAL_LAUNCHER_EL", "PORTAL_LAUNCHER_SCREENSHOTS", "PORTAL_TEST_CLAUDE_DIRECTORY",
             "PORTAL_TEST_CODEX_DIRECTORY", "PORTAL_TEST_PI_AGENT_DIR")


class Refusal(Exception):
    """The run cannot start as asked; nothing ran."""


class Interrupted(Exception):
    """A signal stopped the run."""


@dataclasses.dataclass(frozen=True)
class Suite:
    """A registered CTest suite, as its labels and command describe it."""
    name: str
    category: str
    features: tuple
    effects: tuple = ()
    needs: tuple = ()
    command: tuple = ()
    timeout: float = 0
    allowed_skips: tuple = ()
    tests: tuple = ()

    @property
    def desktop(self):
        return "desktop" in self.effects


@dataclasses.dataclass(frozen=True)
class ManualCheck:
    """A check only a person can make. ROW names a row of the hands-on table
    in SOURCE; COMMAND, if any, is a script that helps make the check."""
    name: str
    features: tuple
    source: str
    row: str = ""
    procedure: str = ""
    command: tuple = ()
    category = "manual"
    effects = ("desktop",)
    needs = ()
    allowed_skips = ()
    tests = ()
    timeout = 0

    desktop = True

    def steps(self, root=ROOT):
        """The procedure and expected result, from its source document."""
        if not self.row:
            return self.procedure
        return hands_on_rows(root / self.source)[self.row]


LAUNCHER_DOC = "docs/launcher-daily-use.md"
MANUAL_CHECKS = (
    ManualCheck("global-shortcut-physical-keys", ("global-shortcut",), "test/global-shortcut-smoke.sh",
                procedure="Switch to another app when asked, then press the two printed chords once each "
                          "on the physical keyboard. It passes when the script reports both shortcuts ran "
                          "with the other app in front and exits 0.",
                command=("sh", "test/global-shortcut-smoke.sh")),
    *(ManualCheck(name, ("launcher",), LAUNCHER_DOC, row) for name, row in (
        ("launcher-normal-configuration", "Normal configuration"),
        ("launcher-selection-without-typing", "Selection without typing"),
        ("launcher-refresh-and-search", "Refresh and search"),
        ("launcher-cancellation", "Cancellation"),
        ("launcher-failure-and-recovery", "Failure and recovery"),
        ("launcher-fullscreen-and-spaces", "Fullscreen and Spaces"),
        ("launcher-monitor-changes", "Monitor changes"),
        ("launcher-ime", "Chinese/Japanese IME"),
        ("launcher-voiceover", "VoiceOver"),
        ("launcher-reload-and-rollback", "Reload and rollback"))),
)


def hands_on_rows(document):
    """Map each check of DOCUMENT's hands-on table to its procedure."""
    rows = {}
    for line in Path(document).read_text().splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if line.startswith("|") and len(cells) >= 2 and not set(cells[0]) <= set("- "):
            rows[cells[0]] = cells[1]
    return rows


# The registry.

def run_output(command, **options):
    """COMMAND's standard output, or an empty string if it cannot run."""
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=60,
                              **options).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def ctest():
    return shutil.which("ctest") or "ctest"


ERT_TEST = r"^\(ert-deftest\s+([^\s()]+)"


def static_tests(command, root=ROOT):
    """The test names a suite's files declare, found by reading them: Lisp
    test files, Bun and Python test files, and Lisp files a script names."""
    def scan(file, pattern, group=0):
        file = Path(file)
        if not file.is_file():
            return []
        return [match[group] if isinstance(match, tuple) else match
                for match in re.findall(pattern, file.read_text(), re.M)]
    names = []
    for index, argument in enumerate(command):
        if argument in ("portal-suite-batch", "portal-suite-graphical") and index + 1 < len(command):
            if not Path(command[index + 1]).is_file():
                raise Refusal(f"A suite runs {command[index + 1]}, which does not exist")
            names += scan(command[index + 1], ERT_TEST)
        elif argument.endswith(".test.ts"):
            names += scan(argument, r"^\s*test\(\s*([\"'`])(.*?)\1", 1)
        elif re.fullmatch(r"test_\w+\.py", argument) and index >= 3 and command[index - 1] == "-p":
            names += scan(Path(command[index - 2]) / argument, r"^    def (test_\w+)")
        elif argument.endswith(".sh") and Path(argument).is_file():
            for file in re.findall(r"test/(portal-[\w-]+-tests\.el)", Path(argument).read_text()):
                names += scan(root / "test" / file, ERT_TEST)
    return tuple(names)


def load_suites(build, root=ROOT):
    """The suites registered in BUILD, in registration order."""
    output = run_output([ctest(), "--test-dir", str(build), "-C", "opt-in", "--show-only=json-v1"])
    try:
        tests = json.loads(output)["tests"]
    except (ValueError, KeyError) as error:
        raise Refusal(f"Cannot read the test registry from {build}; configure it with "
                      f"./build.sh or cmake --preset dev") from error
    suites = []
    for test in tests:
        properties = {item["name"]: item["value"] for item in test.get("properties", ())}
        labels = properties.get("LABELS", [])
        categories = [label for label in labels if label in CATEGORIES]
        if len(categories) != 1:
            raise Refusal(f"Suite {test['name']} needs exactly one category label; "
                          f"register it with portal_suite (test/suites.cmake)")
        command = tuple(test.get("command", ()))
        skips = tuple(command[index + 1] for index, argument in enumerate(command[:-1])
                      if argument == "--allow-skip")
        suites.append(Suite(
            name=test["name"], category=categories[0],
            features=tuple(label[8:] for label in labels if label.startswith("feature=")),
            effects=tuple(label[7:] for label in labels if label.startswith("effect=")),
            needs=tuple(label[6:] for label in labels if label.startswith("needs=")),
            command=command, timeout=float(properties.get("TIMEOUT", 0)),
            allowed_skips=skips, tests=static_tests(command, root)))
    return suites


# Planning.

@dataclasses.dataclass
class Plan:
    command: str
    suites: list
    manual: list
    not_selected: list

    @property
    def automated_names(self):
        return [suite.name for suite in self.suites]

    def gates(self):
        """The options this plan needs, and why."""
        missing = []
        desktop = [suite.name for suite in self.suites if suite.desktop]
        if desktop:
            missing.append(("--allow-gui", "opens windows, takes focus or registers system hot keys",
                            desktop))
        external = [suite.name for suite in self.suites if "external" in suite.effects]
        if external:
            missing.append(("--allow-external", "uses credentials, real requests or third-party code",
                            external))
        if self.manual:
            missing.append(("--interactive", "asks a person to make and record checks",
                            [check.name for check in self.manual]))
            if not desktop:
                missing.append(("--allow-gui", "uses the desktop",
                                [check.name for check in self.manual]))
        return missing

    def targets(self):
        targets = []
        for suite in self.suites:
            target = TARGETS["desktop" if suite.desktop else suite.category]
            if target not in targets:
                targets.append(target)
        if self.manual and TARGETS["desktop"] not in targets:
            targets.append(TARGETS["desktop"])
        return targets


def plan(command, selectors, suites, manual=MANUAL_CHECKS):
    """Select COMMAND's suites, narrowed to SELECTORS: exact suite names or
    features. Each suite appears once, in category then registry order."""
    if command not in COMMANDS:
        raise Refusal(f"Unknown command {command}; use one of {', '.join(COMMANDS)}")
    categories = COMMANDS[command]
    everything = list(suites) + list(manual)
    known = {item.name for item in everything} | {feature for item in everything
                                                  for feature in item.features}
    unknown = [selector for selector in selectors if selector not in known]
    if unknown:
        raise Refusal(f"Unknown suite or feature: {', '.join(unknown)}. "
                      f"./test.sh all --list shows every suite and feature")
    chosen = [item for category in categories for item in everything
              if item.category == category
              and (not selectors or item.name in selectors or set(item.features) & set(selectors))]
    if not chosen:
        raise Refusal(f"No {command} suite matches {', '.join(selectors)}")
    names = {item.name for item in chosen}
    return Plan(command, [item for item in chosen if item.category != "manual"],
                [item for item in chosen if item.category == "manual"],
                [item for item in everything if item.name not in names])


def preflight(plan, environment, root=ROOT, interactive=None, build=None):
    """Missing setup the plan needs, described without values."""
    problems = []
    for item in plan.suites:
        for need in item.needs:
            kind, name = need.split(":", 1)
            if kind == "env":
                value = environment.get(name, "")
                if not value:
                    problems.append(f"{item.name} needs {name} set")
                elif not Path(value).exists():
                    problems.append(f"{item.name} needs {name} to name an existing path")
            elif kind == "program" and not shutil.which(name, path=environment.get("PATH")):
                problems.append(f"{item.name} needs {name} on PATH")
    if plan.manual:
        if not (sys.stdin.isatty() if interactive is None else interactive):
            problems.append("manual checks need a person at an interactive terminal")
        for check in plan.manual:
            try:
                check.steps(root)
            except (OSError, KeyError):
                problems.append(f"{check.name}'s procedure is missing from {check.source}")
    emacs = cache_value(build, "EMACS") if build else ""
    if emacs and any(item.desktop for item in plan.suites + plan.manual):
        front = run_output(["lsappinfo", "front"])
        if front and "loginwindow" in run_output(["lsappinfo", "info", "-only", "name", front]):
            problems.append("the screen is locked; native input cannot reach test windows")
        if "NS" not in run_output(
                [emacs, "--batch", "-Q", "--eval", "(princ system-configuration-features)"]).split():
            problems.append(f"{emacs} is not a graphical NS Emacs")
    return problems


# Building.

def cache_value(build, name):
    """NAME's value in BUILD's CMake cache, or an empty string."""
    try:
        text = (Path(build) / "CMakeCache.txt").read_text()
    except OSError:
        return ""
    match = re.search(rf"^{re.escape(name)}:[A-Z]+=(.*)$", text, re.M)
    return match.group(1) if match else ""


def registry_inputs(root):
    return [root / "CMakeLists.txt", root / "native/Core/CMakeLists.txt", root / "test/suites.cmake"]


def configure(build, root, log):
    """Configure BUILD if it is new, or if the registry changed since."""
    registry = Path(build) / "CTestTestfile.cmake"
    if (Path(build) / "CMakeCache.txt").exists() and registry.exists() and all(
            path.stat().st_mtime <= registry.stat().st_mtime for path in registry_inputs(root)):
        return
    command = ["cmake", "-S", str(root), "-B", str(build)]
    if not (Path(build) / "CMakeCache.txt").exists():
        if Path(build).resolve() == (root / "build").resolve():
            command = ["cmake", "--preset", "dev"]
        else:
            command += ["-G", "Ninja"]
        # As build.sh does, honor the environment's Emacs.
        command += [f"-D{name}={os.environ[name]}" for name in ("EMACS", "EMACS_INCLUDE")
                    if os.environ.get(name)]
    log(f"Configuring {build}: {' '.join(command)}")
    if subprocess.run(command, cwd=root).returncode:
        raise Refusal("Configuring the build failed")


def build_targets(build, targets, log):
    """Build TARGETS incrementally; return the seconds it took."""
    started = time.monotonic()
    log(f"Building {', '.join(targets)}")
    if subprocess.run(["cmake", "--build", str(build), "--target", *targets]).returncode:
        raise Refusal("Building the test prerequisites failed")
    return round(time.monotonic() - started, 2)


# Identity of what a run tested.

def git(root, *arguments, input=None):
    return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True,
                          input=input, check=True).stdout


def source_manifest(root=ROOT):
    """Each tracked or untracked, unignored file and its Git blob ID, as the
    working tree holds it. Nothing is written to the repository."""
    manifest = {}
    for line in git(root, "ls-files", "-s", "-z").split(b"\0"):
        if line:
            fields, path = line.split(b"\t", 1)
            manifest[path.decode()] = fields.split()[1].decode()
    changed = [path for path in git(root, "diff", "--name-only", "-z").split(b"\0") if path]
    changed += [path for path in git(root, "ls-files", "-o", "--exclude-standard", "-z").split(b"\0")
                if path]
    present = [path for path in changed if (root / path.decode()).is_file()]
    for path in changed:
        manifest.pop(path.decode(), None)
    if present:
        blobs = git(root, "hash-object", "--stdin-paths", input=b"\n".join(present) + b"\n").split()
        manifest.update({path.decode(): blob.decode() for path, blob in zip(present, blobs)})
    return dict(sorted(manifest.items()))


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def file_digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


def artifacts(plan, build):
    """Digests of the built files the plan's suites run."""
    build = Path(build).resolve()
    paths = set()
    for suite in plan.suites:
        for argument in suite.command:
            for candidate in re.findall(r"(/[^\"=\s]+)", argument):
                path = Path(candidate)
                if str(path).startswith(str(build)) and path.is_file():
                    paths.add(path)
        if suite.desktop:
            paths |= {build / "portal.bundle/Contents/MacOS/portal.dylib", build / "portal-host"}
    return {str(path.relative_to(build)): file_digest(path) for path in sorted(paths) if path.is_file()}


def environment_record(plan, build, environment):
    """Tools, variables and artifacts that bear on the run."""
    emacs = cache_value(build, "EMACS")
    bun = cache_value(build, "BUN")
    python = cache_value(build, "Python3_EXECUTABLE")
    tools = {
        "emacs": run_output([emacs, "--batch", "-Q", "--eval",
                             "(princ (format \"%s %s\" emacs-version emacs-repository-version))"])
        if emacs else "",
        "bun": run_output([bun, "--version"]) if bun else "",
        "cmake": run_output(["cmake", "--version"]).split("\n")[0],
        "python": run_output([python, "--version"]) if python else "",
        "swift": run_output(["xcrun", "swift", "--version"]).split("\n")[0],
        "macos": " ".join([run_output(["sw_vers", "-productVersion"]),
                           run_output(["sw_vers", "-buildVersion"])]).strip(),
        "machine": platform.machine(),
    }
    variables = {"EMACS": emacs, "EMACS_INCLUDE": cache_value(build, "EMACS_INCLUDE")}
    for name in VARIABLES:
        if environment.get(name) and name not in variables:
            value = environment[name]
            variables[name] = value
            if Path(value).is_file():
                variables[name + " sha256"] = file_digest(value)
    record = {"tools": tools, "variables": variables, "artifacts": artifacts(plan, build)}
    record["identity"] = digest(record)
    return record


def changed_paths(before, after):
    return sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path))


def documentation_only(paths):
    """Whether only prose changed. docs/launcher.md's examples are tests."""
    return all(path.endswith(".md") and path != "docs/launcher.md" for path in paths)


# Running.

def descendants(pid):
    children = {}
    for line in run_output(["ps", "-axo", "pid=,ppid="]).splitlines():
        fields = line.split()
        if len(fields) == 2:
            children.setdefault(int(fields[1]), []).append(int(fields[0]))
    found, pending = [], [pid]
    while pending:
        for child in children.get(pending.pop(), []):
            found.append(child)
            pending.append(child)
    return found


def stop(process):
    """Stop PROCESS and everything it started, and nothing else."""
    if process.poll() is not None:
        return
    victims = [process.pid] + descendants(process.pid)
    for signal_number, wait in ((signal.SIGTERM, 5), (signal.SIGKILL, 5)):
        for pid in victims:
            with contextlib.suppress(OSError):
                os.kill(pid, signal_number)
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=wait)
            if not any(alive(pid) for pid in victims[1:]):
                return


def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


@contextlib.contextmanager
def interruptible():
    """Turn SIGINT, SIGTERM and SIGHUP into `Interrupted' while running."""
    def interrupt(number, _frame):
        raise Interrupted(number)
    previous = {number: signal.signal(number, interrupt)
                for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def stream(command, log_file, environment, timeout):
    """Run COMMAND, copying its output here and to LOG_FILE, for at most
    TIMEOUT seconds; return its exit status."""
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               env=environment, start_new_session=True)
    deadline = time.monotonic() + timeout
    descriptor = process.stdout.fileno()
    try:
        while True:
            if time.monotonic() > deadline:
                message = f"test.sh: stopped {command[0]} after {timeout} seconds\n".encode()
                sys.stdout.buffer.write(message)
                log_file.write(message)
                stop(process)
                return process.wait()
            if not select.select([descriptor], [], [], 1)[0]:
                continue
            data = os.read(descriptor, 65536)
            if not data:
                return process.wait()
            sys.stdout.buffer.write(data)
            sys.stdout.flush()
            log_file.write(data)
            log_file.flush()
    except BaseException:
        stop(process)
        raise
    finally:
        process.stdout.close()


def read_junit(path):
    """Each suite's CTest result in the JUnit file at PATH."""
    results = {}
    with contextlib.suppress(OSError, ElementTree.ParseError):
        for case in ElementTree.parse(path).getroot().iter("testcase"):
            failure = case.find("failure")
            skipped = case.find("skipped")
            status = {"run": "passed", "fail": "failed"}.get(case.get("status"), "not-run")
            message = (failure if failure is not None else skipped)
            results[case.get("name")] = {
                "status": status, "seconds": round(float(case.get("time") or 0), 2),
                "message": message.get("message", "") if message is not None else ""}
    return results


def read_ert(directory, name):
    """The Lisp suite runner's per-test results for suite NAME, if any."""
    with contextlib.suppress(OSError, ValueError):
        return json.loads((Path(directory) / f"{name}.json").read_text())
    return None


@contextlib.contextmanager
def desktop_lock(path, holder):
    """Hold the lock that keeps desktop runs of every worktree apart."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a+") as file:
        try:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            file.seek(0)
            raise Refusal(f"Another desktop test run holds {path}: {file.read().strip() or 'unknown'}. "
                          f"Wait for it to finish; desktop runs cannot share focus") from None
        file.truncate(0)
        file.write(json.dumps(holder) + "\n")
        file.flush()
        try:
            yield
        finally:
            file.truncate(0)
            fcntl.flock(file, fcntl.LOCK_UN)


def lock_path(root, build):
    configured = os.environ.get("PORTAL_TEST_DESKTOP_LOCK")
    if configured:
        return Path(configured)
    common = run_output(["git", "-C", str(root), "rev-parse", "--path-format=absolute",
                         "--git-common-dir"])
    return Path(common) / "portal-desktop-tests.lock" if common else Path(build) / "desktop-tests.lock"


def suite_result(suite, junit, ert):
    """SUITE's outcome from CTest's JUNIT results and the Lisp runner's ERT ones."""
    result = {"name": suite.name, "category": suite.category, "features": list(suite.features),
              "effects": list(suite.effects),
              **junit.get(suite.name, {"status": "not-run", "seconds": 0,
                                       "message": "No result: the run stopped first"})}
    if ert:
        tests = ert.get("tests", [])
        result["tests"] = tests
        result["declared_skips"] = [test["name"] for test in tests if test["status"] == "declared-skip"]
        result["skipped"] = [test["name"] for test in tests if test["status"] == "skipped"]
        result["failed_tests"] = [test["name"] for test in tests if test["status"] == "failed"]
    return result


def ask(prompt, choices=None):
    """A person's answer to PROMPT: one of CHOICES' keys, mapped, or any text."""
    while True:
        try:
            answer = input(prompt).strip()
        except EOFError:
            raise Interrupted("end of input") from None
        if choices is None:
            return answer
        if answer.lower() in choices:
            return choices[answer.lower()]


def manual_checks(checks, root, log, log_file):
    """Guide a person through CHECKS and record what they report."""
    operator = run_output(["git", "-C", str(root), "config", "user.name"]) or os.environ.get("USER", "")
    results = []
    for number, check in enumerate(checks, 1):
        print(f"\n[{number}/{len(checks)}] {check.name} ({', '.join(check.features)})")
        print(f"Procedure, from {check.source}{': ' + check.row if check.row else ''}:")
        print(f"  {check.steps(root)}")
        exit_status = None
        if check.command and ask("Run its helper script now? [y/n] ", {"y": True, "n": False}):
            log(f"Running {' '.join(check.command)}")
            exit_status = stream(list(check.command), log_file, dict(os.environ), 600)
            print(f"The helper exited with status {exit_status}.")
        status = ask("Result? [p]ass, [f]ail, [n]ot tested: ",
                     {"p": "passed", "f": "failed", "n": "not-tested"})
        notes = ask("Notes (environment, symptoms): ")
        results.append({"name": check.name, "category": "manual", "features": list(check.features),
                        "status": status, "notes": notes, "operator": operator,
                        "helper_exit_status": exit_status, "at": now()})
    return results


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")


def overall(command, results, inputs_stable):
    """The run's status from its suites' and checks' results."""
    statuses = [result["status"] for result in results]
    if any(status in ("failed", "not-run") for status in statuses):
        return "failed"
    incomplete = (not inputs_stable or "not-tested" in statuses
                  or (command == "all" and any(result.get("declared_skips") for result in results)))
    return "incomplete" if incomplete else "passed"


def previous_runs(directory):
    """The runs recorded in DIRECTORY, oldest first."""
    runs = []
    for path in Path(directory).glob("*/run.json"):
        with contextlib.suppress(OSError, ValueError):
            record = json.loads(path.read_text())
            record["path"] = str(path.parent)
            runs.append(record)
    return sorted(runs, key=lambda run: (run.get("started") or "", run["path"]))


def covering_runs(runs, inputs, environment, names):
    """Finished earlier runs of these inputs whose selection covers NAMES."""
    return [run for run in runs
            if run.get("inputs", {}).get("identity") == inputs
            and run.get("environment", {}).get("identity") == environment
            and run.get("inputs_stable")
            and run.get("status") in ("passed", "failed", "incomplete")
            and set(names) <= set(run.get("selection", {}).get("suites", []))]


# Reporting.

def not_selected(plan):
    """The registered suites and checks outside PLAN, by category."""
    names = {}
    for item in plan.not_selected:
        names.setdefault(item.category, []).append(item.name)
    return names


def describe_plan(plan, args, root=ROOT, detail=False):
    lines = [f"Plan: {plan.command}, {len(plan.suites)} automated suites and "
             f"{len(plan.manual)} manual checks"]
    gates = plan.gates()
    if gates:
        for option, why, names in gates:
            lines.append(f"Needs {option}: it {why} ({', '.join(names)})")
    targets = plan.targets()
    if targets:
        lines.append(f"Builds: {', '.join(targets)}")
    for item in plan.suites + plan.manual:
        effects = ", ".join(item.effects) or "headless"
        line = f"  {item.category:<12} {item.name:<26} {effects:<18} features: {', '.join(item.features)}"
        if item.tests:
            line += f"; {len(item.tests)} tests"
        lines.append(line)
        if item.needs:
            lines.append(f"      setup: {', '.join(item.needs)}")
        if item.allowed_skips:
            lines.append(f"      declared optional skips: {', '.join(item.allowed_skips)}")
        if detail:
            if item.category == "manual":
                lines.append(f"      {item.source}{': ' + item.row if item.row else ''}")
            for test in item.tests:
                lines.append(f"      {test}")
    if plan.not_selected:
        lines.append("Not selected: " + "; ".join(f"{category} ({len(names)})"
                                                   for category, names in not_selected(plan).items()))
    if detail:
        lines.append("Test names are read from the suites' files; C programs report one result.")
    return "\n".join(lines)


def summary(record):
    lines = [f"\nPortal tests: {record['command']} ({record['path']})"]
    for result in record["results"]:
        line = (f"  {result['category']:<12} {result['name']:<26} "
                f"{result['status']:<11} {result.get('seconds', 0):>7.1f} s")
        if record["selection"]["repeat"] > 1:
            line += f"  iteration {result['iteration']}"
        notes = []
        if "tests" in result:
            notes.append(f"{len(result['tests'])} tests")
        for key, label in (("failed_tests", "failed"), ("skipped", "unexpected skips"),
                           ("declared_skips", "declared skips")):
            if result.get(key):
                notes.append(f"{label}: {', '.join(result[key])}")
        if result.get("message") and result["status"] != "passed":
            notes.append(result["message"])
        if result.get("notes"):
            notes.append(result["notes"])
        if notes:
            line += "  " + "; ".join(notes)
        lines.append(line)
    for category, names in record["not_selected"].items():
        lines.append(f"  {category:<12} not selected: {', '.join(names)}")
    counts = {}
    for result in record["results"]:
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    lines.append("Results: " + ", ".join(f"{count} {status}" for status, count in counts.items())
                 + f"; build {record['build']['seconds']} s")
    if not record["inputs_stable"]:
        lines.append("Inputs changed during the run: these results describe no single tree.")
    if record["command"] == "regression":
        lines.append("External and manual checks are outside the regression; "
                     "./test.sh all includes them.")
    lines.append(f"Status: {record['status']}")
    return "\n".join(lines)


# Commands.

def parse(argv):
    parser = argparse.ArgumentParser(
        prog="./test.sh", description="Run Portal's tests by category (docs/testing.md).",
        epilog="Exit status: 0 passed, 1 failed, 2 refused (nothing ran), 3 incomplete, "
               "130 interrupted.")
    parser.add_argument("command", nargs="?", default="headless",
                        help="unit, integration, gui, stress, external, manual, headless "
                             "(the default), regression, all or evidence")
    parser.add_argument("run", nargs="?", help="for evidence: a run directory")
    parser.add_argument("--suite", action="append", default=[], metavar="NAME",
                        help="only this suite or feature, by exact name; repeatable")
    parser.add_argument("--list", action="store_true", help="print the plan and run nothing")
    parser.add_argument("--allow-gui", action="store_true",
                        help="permit windows, focus changes and system hot keys")
    parser.add_argument("--allow-external", action="store_true",
                        help="permit credentials, real requests and third-party code")
    parser.add_argument("--interactive", action="store_true",
                        help="guide a person through manual checks")
    parser.add_argument("--repeat", type=int, default=1, metavar="N",
                        help=f"run the selection N times, at most {MAX_REPEAT}; needs --reason")
    parser.add_argument("--reason", default="", help="why this run repeats earlier ones")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1),
                        help="headless suites to run at once")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build")
    parser.add_argument("--no-build", action="store_true",
                        help="use the build directory as it is")
    args = parser.parse_args(argv)
    if args.command != "evidence" and args.run:
        parser.error(f"unexpected argument {args.run}")
    if not 1 <= args.repeat <= MAX_REPEAT:
        parser.error(f"--repeat must be between 1 and {MAX_REPEAT}")
    if args.repeat > 1 and not args.reason:
        parser.error("--repeat needs --reason: say what the repetition investigates")
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    return args


def evidence(args):
    """List recorded runs, or compare one with the working tree."""
    runs = previous_runs(args.build_dir / "test-runs")
    if not runs:
        print(f"No recorded runs in {args.build_dir / 'test-runs'}")
        return PASSED
    current = source_manifest()
    if not args.run:
        for run in runs[-15:]:
            changed = changed_paths(run.get("inputs", {}).get("files", {}), current)
            state = ("inputs unchanged" if not changed
                     else f"{len(changed)} files changed" + (", prose only" if documentation_only(changed) else ""))
            print(f"{run['path']}: {run.get('command')} {run.get('status')}, "
                  f"{len(run.get('selection', {}).get('suites', []))} suites; {state}")
        return PASSED
    path = Path(args.run)
    run = next((run for run in runs if Path(run["path"]).resolve() == path.resolve()), None)
    if not run:
        raise Refusal(f"No recorded run at {path}")
    print(f"{run['path']}: {run['command']} {run['status']} at {run['started']}")
    print(f"Suites: {', '.join(run['selection']['suites']) or 'none'}")
    changed = changed_paths(run["inputs"]["files"], current)
    if not changed:
        print("Sources unchanged since this run.")
    else:
        print(f"Changed since this run ({'prose only' if documentation_only(changed) else 'includes code or tests'}):")
        for name in changed[:40]:
            print(f"  {name}")
        if len(changed) > 40:
            print(f"  … and {len(changed) - 40} more")
    print("Compare tools and artifacts with the recorded environment before citing it:")
    print(json.dumps(run["environment"], indent=2))
    return PASSED


def main(argv=None, root=ROOT):
    args = parse(sys.argv[1:] if argv is None else argv)
    say = lambda text: print(f"test.sh: {text}", flush=True)
    try:
        if args.command == "evidence":
            return evidence(args)
        build = args.build_dir
        if not args.no_build:
            configure(build, root, say)
        the_plan = plan(args.command, args.suite, load_suites(build, root))
        if args.list:
            print(describe_plan(the_plan, args, root, detail=True))
            return PASSED
        if args.repeat > 1 and the_plan.manual:
            raise Refusal("--repeat applies to automated suites, not manual checks")
        flags = {"--allow-gui": args.allow_gui, "--allow-external": args.allow_external,
                 "--interactive": args.interactive}
        missing = [(option, why, names) for option, why, names in the_plan.gates() if not flags[option]]
        if missing:
            raise Refusal("\n".join(
                [f"{option} is required: this run {why} ({', '.join(names)})"
                 for option, why, names in missing]
                + ["Agents: ask before using the desktop or external services, and say what will run."]))
        problems = preflight(the_plan, os.environ, root, build=build)
        if problems:
            print("Incomplete before starting: missing prerequisites", file=sys.stderr)
            for problem in problems:
                print(f"  {problem}", file=sys.stderr)
            return INCOMPLETE
        print(describe_plan(the_plan, args, root), flush=True)
        build_seconds = 0
        if not args.no_build:
            build_seconds = build_targets(build, the_plan.targets(), say)
        return execute(args, the_plan, build, build_seconds, root, say)
    except Refusal as refusal:
        print(f"test.sh: {refusal}", file=sys.stderr)
        return REFUSED


def run_phase(build, suites, jobs, results, log_file):
    """Run SUITES through CTest, JOBS at a time, keeping their results in
    RESULTS; return the phase's record and the suites' results."""
    results.mkdir(parents=True)
    junit = results / "junit.xml"
    names = "|".join(re.escape(suite.name) for suite in suites)
    command = [ctest(), "--test-dir", str(build), "-C", "opt-in", "-R", f"^({names})$",
               "--output-on-failure", "--no-tests=error", "-j", str(jobs), "--output-junit", str(junit)]
    started = time.monotonic()
    code = stream(command, log_file, dict(os.environ, PORTAL_TEST_RESULTS_DIR=str(results)),
                  sum(suite.timeout or 60 for suite in suites) + 300)
    outcomes = read_junit(junit)
    return ({"exit": code, "seconds": round(time.monotonic() - started, 2)},
            [suite_result(suite, outcomes, read_ert(results, suite.name)) for suite in suites])


def execute(args, the_plan, build, build_seconds, root, say):
    """Run THE_PLAN and record it as it goes; return the exit status."""
    files = source_manifest(root)
    record = {
        "schema": 1, "command": args.command, "argv": sys.argv[1:], "reason": args.reason,
        "selection": {"suites": the_plan.automated_names,
                      "manual": [check.name for check in the_plan.manual],
                      "features": args.suite, "repeat": args.repeat},
        "not_selected": not_selected(the_plan),
        "inputs": {"identity": digest(files), "files": files,
                   "head": run_output(["git", "-C", str(root), "rev-parse", "HEAD"]),
                   "changes": run_output(["git", "-C", str(root), "status", "--porcelain"]).splitlines()},
        "inputs_stable": True, "environment": environment_record(the_plan, build, os.environ),
        "build": {"targets": [] if args.no_build else the_plan.targets(), "seconds": build_seconds},
        "phases": [], "results": [], "status": "running",
    }
    earlier = covering_runs(previous_runs(Path(build) / "test-runs"), record["inputs"]["identity"],
                            record["environment"]["identity"], the_plan.automated_names)
    if earlier and the_plan.suites and not the_plan.manual and not args.reason:
        latest = earlier[-1]
        if latest["status"] == "passed":
            say(f"Not run: {latest['path']} passed these suites with the same inputs, tools and "
                f"artifacts. Cite it, or pass --reason to run them again.")
            return PASSED
        raise Refusal(f"{latest['path']} {latest['status']} with the same inputs. Rerunning "
                      f"unchanged inputs needs --reason, such as the documented issue it investigates")
    record["earlier_attempts"] = [run["path"] for run in earlier]
    with contextlib.ExitStack() as stack:
        if any(item.desktop for item in the_plan.suites + the_plan.manual):
            stack.enter_context(desktop_lock(lock_path(root, build), {
                "pid": os.getpid(), "worktree": str(root), "command": args.command, "since": now()}))
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        directory = Path(build) / "test-runs" / f"{stamp}-{args.command}-{os.getpid()}"
        directory.mkdir(parents=True)
        record.update(path=str(directory), started=now(), finished=None)
        write = lambda: (directory / "run.json").write_text(json.dumps(record, indent=2) + "\n")
        write()
        phases = (("headless", [suite for suite in the_plan.suites if not suite.desktop], args.jobs),
                  ("desktop", [suite for suite in the_plan.suites if suite.desktop], 1))
        status = "interrupted"
        try:
            with interruptible(), open(directory / "run.log", "ab") as log_file:
                for iteration in range(1, args.repeat + 1):
                    for name, suites, jobs in phases:
                        if not suites:
                            continue
                        say(f"Running {len(suites)} {name} suites"
                            + (f", iteration {iteration} of {args.repeat}" if args.repeat > 1 else ""))
                        phase, results = run_phase(build, suites, jobs,
                                                   directory / f"iteration-{iteration}" / name, log_file)
                        record["phases"].append({"name": name, "iteration": iteration, **phase})
                        record["results"] += [dict(result, iteration=iteration) for result in results]
                        write()
                if the_plan.manual:
                    record["results"] += manual_checks(the_plan.manual, root, say, log_file)
            after = source_manifest(root)
            record["inputs_stable"] = digest(after) == record["inputs"]["identity"]
            if not record["inputs_stable"]:
                record["inputs_changed"] = changed_paths(files, after)
            status = overall(args.command, record["results"], record["inputs_stable"])
        except Interrupted as interruption:
            say(f"Interrupted ({interruption.args[0]}); recorded what finished")
        finally:
            record.update(status=status, finished=now())
            write()
    print(summary(record))
    return {"passed": PASSED, "failed": FAILED, "incomplete": INCOMPLETE}.get(status, INTERRUPTED)


if __name__ == "__main__":
    sys.exit(main())
