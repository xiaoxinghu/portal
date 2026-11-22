#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run test/test_*.py modules in parallel, preserving unittest's log format.

Output keeps every verbose test line (including `... skipped ...` reasons)
and emits a single combined `Ran N tests in X.XXXs` footer so release.sh
parses counts and skips identically to `python3 -B -m unittest discover -v`.
"""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import re
import subprocess
import sys
import time

TEST_DIR = Path(__file__).resolve().parent
ROOT = TEST_DIR.parent
FOOTER_RE = re.compile(
    r"(?:\A|\n)-{70}\nRan (?P<ran>\d+) tests? in [0-9.]+s\n\n(?P<status>OK|FAILED)"
    r"(?: \((?P<details>[^)]*)\))?\n?\Z"
)


def run_module(module: str) -> tuple[str, int, str]:
    env = {**os.environ}
    existing = env.get("PYTHONPATH")
    env["PYTHONPATH"] = f"{TEST_DIR}{os.pathsep}{existing}" if existing else str(TEST_DIR)
    result = subprocess.run(
        [sys.executable, "-B", "-m", "unittest", "-v", module],
        cwd=str(ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return module, result.returncode, result.stdout


def main() -> int:
    modules = sorted(path.stem for path in TEST_DIR.glob("test_*.py"))
    if not modules:
        print("No test_*.py modules found under test/", file=sys.stderr)
        return 1

    started = time.monotonic()
    workers = min(len(modules), os.cpu_count() or 4)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(run_module, modules))
    elapsed = time.monotonic() - started

    total_ran = 0
    counts: dict[str, int] = {}
    failed = False

    for module, returncode, output in results:
        match = FOOTER_RE.search(output)
        if match:
            body = output[: match.start()]
            if body:
                print(body)
            total_ran += int(match.group("ran"))
            details = match.group("details") or ""
            for item in details.split(","):
                item = item.strip()
                if "=" in item:
                    key, value = item.split("=", 1)
                    counts[key] = counts.get(key, 0) + int(value)
            if returncode != 0 or match.group("status") != "OK":
                failed = True
        else:
            if output:
                print(output, end="" if output.endswith("\n") else "\n")
            failed = True

    print("-" * 70)
    unit = "test" if total_ran == 1 else "tests"
    print(f"Ran {total_ran} {unit} in {elapsed:.3f}s\n")
    detail_order = ("failures", "errors", "skipped", "expected failures", "unexpected successes")
    ordered = [f"{key}={counts[key]}" for key in detail_order if counts.get(key)]
    for key, value in counts.items():
        if key not in detail_order and value:
            ordered.append(f"{key}={value}")
    status = "FAILED" if failed else "OK"
    print(f"{status} ({', '.join(ordered)})" if ordered else status)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
