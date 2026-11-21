# SPDX-License-Identifier: GPL-3.0-or-later
"""Every file under tools/ is one the build reads.

portal-build-source-identity hashes every file under host/, native/ and
tools/, so a file in tools/ that never reaches the build would make every
build look stale when it changed: a pointless rebuild for a user, and a
build from source for someone on main.  Scripts the build never runs, such
as the Ghostty version report and the test VM's recipes, live in scripts/.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
# What the build starts from: build.sh, and the CMake it runs.
ENTRY_POINTS = ("CMakeLists.txt", "build.sh")


def tool_files():
    """The files under tools/ that the identity hashes: none hidden, at any depth."""
    return sorted(
        path for path in TOOLS.rglob("*")
        if path.is_file()
        and not any(part.startswith(".") for part in path.relative_to(TOOLS).parts)
    )


def reached_tools():
    """The tools the build reads: those an entry point names as tools/NAME, and
    those a reached tool names by their path inside tools/, as resolve-bun.sh
    names bun.manifest beside it."""
    entry = "\n".join((ROOT / name).read_text() for name in ENTRY_POINTS)
    pending = {path.relative_to(TOOLS).as_posix(): path for path in tool_files()}
    reached = {name: path for name, path in pending.items() if f"tools/{name}" in entry}
    texts = [path.read_text(errors="replace") for path in reached.values()]
    while texts:
        text = texts.pop()
        for name, path in pending.items():
            if name not in reached and name in text:
                reached[name] = path
                texts.append(path.read_text(errors="replace"))
    return set(reached)


class ToolsTests(unittest.TestCase):
    def test_every_file_under_tools_reaches_the_build(self):
        names = {path.relative_to(TOOLS).as_posix() for path in tool_files()}
        self.assertTrue(names)
        self.assertEqual(
            sorted(names - reached_tools()), [],
            "these files under tools/ are not named by CMakeLists.txt or build.sh, nor by a "
            "tool they name, yet change the build's identity: move them to scripts/ or "
            "beside the tests that use them")

    def test_the_build_reaches_its_known_tools(self):
        # The check itself finds what the build is known to read.
        self.assertLessEqual(
            {"resolve-bun.sh", "bun.manifest", "patch-libghostty-spm.sh",
             "build-ghostty-linux.sh"},
            reached_tools())


if __name__ == "__main__":
    unittest.main()
