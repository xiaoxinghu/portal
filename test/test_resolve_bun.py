# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/resolve-bun.sh chooses Bun in its documented order, safely.

Stand-in Bun executables and archives served from file: URLs replace the real
ones, so no test downloads a compiler.  The build lock in build.sh is tested
here too, without building.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
RESOLVER = ROOT / "tools" / "resolve-bun.sh"
PINNED = "1.3.14"
PLATFORMS = ("darwin-aarch64", "darwin-x64", "darwin-x64-baseline",
             "linux-aarch64", "linux-x64", "linux-x64-baseline")
# The program that holds a file lock while a command runs: macOS's, or Linux's.
LOCK = ["lockf", "-k"] if sys.platform == "darwin" else ["flock"]


def fake_bun(path, version=PINNED, compatible=True):
    """Write a stand-in Bun that reports VERSION and passes Portal's check."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "#!/bin/sh\n"
        f'case "$1" in --version) echo {version} ;; -e) exit {0 if compatible else 1} ;; esac\n'
    )
    path.chmod(0o755)
    return path


class ResolveBunTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="portal bun ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.tools = self.root / "tools cache"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.archive = self.make_archive(fake_bun(self.root / "release" / "bun"))
        self.write_manifest(self.archive)

    def make_archive(self, bun):
        archive = self.root / "bun-release.zip"
        with zipfile.ZipFile(archive, "w") as zip_file:
            zip_file.write(bun, "bun-darwin-aarch64/bun")
        return archive

    def write_manifest(self, archive, digest=None):
        digest = digest or hashlib.sha256(archive.read_bytes()).hexdigest()
        self.manifest = self.root / "bun.manifest"
        self.manifest.write_text(
            f"# Test manifest\nversion {PINNED}\n"
            + "".join(f"{platform} {archive.as_uri()} {digest}\n" for platform in PLATFORMS)
        )

    def resolve(self, **environment):
        """Run the resolver with only the stand-in bin directory on PATH."""
        env = {
            "HOME": str(self.root),
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "PORTAL_BUN_MANIFEST": str(self.manifest),
            "PORTAL_TOOLS_DIR": str(self.tools),
        }
        env.update(environment)
        return subprocess.run(
            ["/bin/sh", str(RESOLVER)], env=env, capture_output=True, text=True, timeout=60
        )

    def cache_entries(self):
        return sorted(
            str(path.relative_to(self.tools)) for path in self.tools.rglob("*") if path.is_file()
        ) if self.tools.exists() else []

    def assert_chose(self, result, path, reason):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{path}\n")
        self.assertIn(f"({reason})", result.stderr)

    def test_explicit_bun_wins(self):
        fake_bun(self.bin / "bun")
        chosen = fake_bun(self.root / "chosen dir" / "bun", version="1.4.0")
        result = self.resolve(BUN=str(chosen))
        self.assert_chose(result, chosen, "BUN")
        self.assertIn("using Bun 1.4.0", result.stderr)
        self.assertEqual(self.cache_entries(), [])

    def test_invalid_explicit_bun_fails_without_fallback(self):
        fake_bun(self.bin / "bun")
        incompatible = fake_bun(self.root / "old" / "bun", version="1.0.0", compatible=False)
        for bun, message in (
            (str(self.root / "missing"), "not an executable file"),
            ("bun", "absolute file name"),
            (str(incompatible), "1.0.0"),
        ):
            with self.subTest(bun=bun):
                result = self.resolve(BUN=bun)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn(message, result.stderr)
        self.assertEqual(self.cache_entries(), [])

    def test_bun_on_path_is_never_taken(self):
        # The compiled host contains its Bun: the one shipped is the pinned one,
        # even with a newer bun on PATH, or an older one.
        for version, compatible in (("1.4.2", True), ("1.0.0", False)):
            with self.subTest(version=version):
                installed = fake_bun(self.bin / "bun", version=version, compatible=compatible)
                result = self.resolve()
                self.assertEqual(result.returncode, 0, result.stderr)
                chosen = Path(result.stdout.strip())
                self.assertNotEqual(chosen, installed)
                self.assertTrue(chosen.is_relative_to(self.tools / "bun" / PINNED))
                self.assertNotIn(str(installed), result.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "the Mac's hardware is read with sysctl")
    def test_platform_without_sbin_on_path(self):
        # GUI Emacs inherits launchd's PATH, which has /usr/sbin; a shell's may not.
        arm64 = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"],
                               capture_output=True, text=True).stdout.strip() == "1"
        result = self.resolve(PATH=f"{self.bin}:/usr/bin:/bin")
        self.assertEqual(result.returncode, 0, result.stderr)
        platform = Path(result.stdout.strip()).parent.name
        if arm64:
            self.assertEqual(platform, "darwin-aarch64")
        else:
            self.assertIn(platform, ("darwin-x64", "darwin-x64-baseline"))

    def test_download_populates_the_cache_once(self):
        first = self.resolve()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("(downloaded)", first.stderr)
        cached = Path(first.stdout.strip())
        self.assertTrue(cached.is_relative_to(self.tools / "bun" / PINNED))
        # Later builds, such as after a package upgrade, reuse the cache.
        self.archive.unlink()
        self.assert_chose(self.resolve(), cached, "Portal's cache")
        self.assertEqual(self.cache_entries(), [str(cached.relative_to(self.tools))])

    def test_no_download_mode(self):
        result = self.resolve(PORTAL_BUN_DOWNLOAD="0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("downloads are off", result.stderr)
        self.assertNotIn("downloading", result.stderr)
        self.assertEqual(self.cache_entries(), [])
        # A cached Bun still works without downloading.
        self.assertEqual(self.resolve().returncode, 0)
        self.assertIn("(Portal's cache)", self.resolve(PORTAL_BUN_DOWNLOAD="0").stderr)

    def test_checksum_mismatch_caches_nothing(self):
        self.write_manifest(self.archive, digest="0" * 64)
        result = self.resolve()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the expected", result.stderr)
        self.assertEqual(self.cache_entries(), [])
        self.assertEqual(list(self.tools.rglob(".download.*")), [])

    def test_download_failure(self):
        self.write_manifest(self.root / "absent.zip", digest="0" * 64)
        result = self.resolve()
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not download", result.stderr)
        self.assertEqual(self.cache_entries(), [])

    def test_unusable_download_is_not_cached(self):
        broken = fake_bun(self.root / "broken" / "bun", compatible=False)
        self.write_manifest(self.make_archive(broken))
        result = self.resolve()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not run", result.stderr)
        self.assertEqual(self.cache_entries(), [])

    def test_concurrent_requests_share_one_complete_bun(self):
        with ThreadPoolExecutor(4) as pool:
            results = list(pool.map(lambda _: self.resolve(), range(4)))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len({result.stdout for result in results}), 1)
        cached = Path(results[0].stdout.strip())
        self.assertEqual(self.cache_entries(), [str(cached.relative_to(self.tools))])
        self.assertEqual(subprocess.run([cached, "--version"], capture_output=True,
                                        text=True).stdout, f"{PINNED}\n")


class BuildScriptTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "only the Mac builds the app host")
    def test_bun_argument_is_the_explicit_choice(self):
        with tempfile.TemporaryDirectory(prefix="portal build ") as directory:
            checkout = Path(directory)
            shutil.copy(ROOT / "build.sh", checkout / "build.sh")
            shutil.copytree(ROOT / "tools", checkout / "tools")
            bin_directory = checkout / "bin"
            bin_directory.mkdir()
            # A stand-in cmake records its arguments; no other Bun exists.
            cmake = bin_directory / "cmake"
            cmake.write_text('#!/bin/sh\necho "cmake $*" >> "$(dirname "$0")/calls"\n')
            cmake.chmod(0o755)
            chosen = fake_bun(checkout / "chosen" / "bun")
            env = {
                "HOME": directory,
                "PATH": f"{bin_directory}:/usr/bin:/bin:/usr/sbin:/sbin",
                "PORTAL_BUN_DOWNLOAD": "0",
                "PORTAL_TOOLS_DIR": str(checkout / "no tools"),
            }
            result = subprocess.run(["/bin/sh", str(checkout / "build.sh"), f"-DBUN={chosen}"],
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("(BUN)", result.stderr)
            self.assertIn(f"-DBUN={chosen}", (bin_directory / "calls").read_text())
            # An unusable one fails rather than being replaced.
            result = subprocess.run(["/bin/sh", str(checkout / "build.sh"),
                                     f"-DBUN={checkout / 'missing'}"],
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 1)
            self.assertIn("not an executable file", result.stderr)

    @unittest.skipIf(sys.platform == "darwin", "the Mac builds the app host")
    def test_linux_builds_without_bun(self):
        with tempfile.TemporaryDirectory(prefix="portal build ") as directory:
            checkout = Path(directory)
            shutil.copy(ROOT / "build.sh", checkout / "build.sh")
            shutil.copytree(ROOT / "tools", checkout / "tools")
            bin_directory = checkout / "bin"
            bin_directory.mkdir()
            cmake = bin_directory / "cmake"
            cmake.write_text('#!/bin/sh\necho "cmake $*" >> "$(dirname "$0")/calls"\n')
            cmake.chmod(0o755)
            # Neither Bun nor a way to download one: build.sh asks for none.
            env = {
                "HOME": directory,
                "PATH": f"{bin_directory}:/usr/bin:/bin:/usr/sbin:/sbin",
                "PORTAL_BUN_DOWNLOAD": "0",
                "PORTAL_TOOLS_DIR": str(checkout / "no tools"),
            }
            result = subprocess.run(["/bin/sh", str(checkout / "build.sh")],
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("resolve-bun", result.stderr)
            self.assertNotIn("-DBUN", (bin_directory / "calls").read_text())
            self.assertFalse((checkout / "no tools").exists())


class BuildLockTests(unittest.TestCase):
    def test_second_build_stops_at_once(self):
        with tempfile.TemporaryDirectory(prefix="portal lock ") as directory:
            checkout = Path(directory)
            shutil.copy(ROOT / "build.sh", checkout / "build.sh")
            (checkout / "build").mkdir()
            holder = subprocess.Popen(
                [*LOCK, str(checkout / "build" / ".build.lock"), "sleep", "30"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
            try:
                time.sleep(0.5)
                started = time.monotonic()
                result = subprocess.run(["/bin/sh", str(checkout / "build.sh")],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 75)
                self.assertIn("another Portal build is running", result.stderr)
                self.assertLess(time.monotonic() - started, 5)
            finally:
                try:
                    os.killpg(holder.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                holder.wait()


if __name__ == "__main__":
    unittest.main()
