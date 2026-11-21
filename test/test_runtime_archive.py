# SPDX-License-Identifier: GPL-3.0-or-later
"""scripts/runtime-archive.py packs a stand-in build and checks it unpacked.

The build's binaries are small Mach-O files written here, so these tests run
anywhere, without a build.  The manifest's format is the fixture's,
test/fixtures/runtime-manifest.json, which the installer's tests read too.
"""
from pathlib import Path
import contextlib
import importlib.util
import io
import json
import struct
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "runtime-archive.py"
FIXTURE = ROOT / "test" / "fixtures" / "runtime-manifest.json"
COMMIT = "eaa7f52d4a44fb83dfa04ad37b217a0357d80af2"
IDENTITY = "885c5ee63016d8280cb017114e47c8e24cca959d714746c1c17df4dbc8cd454e"
MODULE = "portal.bundle/Contents/MacOS/portal.dylib"

spec = importlib.util.spec_from_file_location("runtime_archive", SCRIPT)
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


def macho(cpu=0x0100000C, minos=(13, 0), loads=("/usr/lib/libSystem.B.dylib",),
          rpaths=("@loader_path", "/Applications/Xcode.app/usr/lib/swift-6.2/macosx")):
    """A thin 64-bit Mach-O header with these load commands, and no code."""
    def command(cmd, body):
        size = (8 + len(body) + 7) // 8 * 8
        return struct.pack("<II", cmd, size) + body.ljust(size - 8, b"\0")

    commands = [command(0x32, struct.pack("<IIII", 1, minos[0] << 16 | minos[1] << 8,
                                          27 << 16, 0))]
    commands += [command(0xC, struct.pack("<IIII", 24, 0, 0, 0) + name.encode() + b"\0")
                 for name in loads]
    commands += [command(0x8000001C, struct.pack("<I", 12) + path.encode() + b"\0")
                 for path in rpaths]
    body = b"".join(commands)
    return struct.pack("<IiIIIIII", 0xFEEDFACF, cpu, 0, 6, len(commands), len(body), 0, 0) + body


class RuntimeArchiveTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="portal runtime ")
        self.addCleanup(directory.cleanup)
        # What the script prints is for a job's log.
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        self.root = Path(directory.name)
        self.build = self.root / "checkout" / "build"
        self.out = self.root / "out"
        files = {
            "portal-build.eld": f'(:identity "{IDENTITY}" :version "0.3.0")',
            "licenses/LICENSE": "GPL",
            "licenses/README.md": "Notices",
            "portal.bundle/Contents/Info.plist": "<plist/>",
            "portal.bundle/Contents/Resources/terminfo/78/xterm-ghostty": "terminfo",
        }
        for name, text in files.items():
            (self.build / name).parent.mkdir(parents=True, exist_ok=True)
            (self.build / name).write_text(text)
        self.binary(MODULE, macho())
        self.binary("portal-host", macho(loads=("/usr/lib/libc++.1.dylib",), rpaths=()))
        (self.build / "portal-host").chmod(0o755)
        # What a build directory holds besides the runtime.
        (self.build / "CMakeCache.txt").write_text(f"CMAKE_HOME={self.build}")
        (self.build / "tools").mkdir()
        (self.build / "tools" / "bun").write_text("a compiler")

    def binary(self, name, data):
        (self.build / name).parent.mkdir(parents=True, exist_ok=True)
        (self.build / name).write_bytes(data)

    def pack(self, tag=None):
        return archive.pack(self.build, self.out, COMMIT, tag, "macos-arm64")

    def refused(self, pattern, function, *arguments):
        with self.assertRaisesRegex(archive.Refusal, pattern):
            function(*arguments)

    def test_the_fixture_is_a_manifest(self):
        fixture = json.loads(FIXTURE.read_text())
        self.assertEqual(archive.check_manifest(fixture), fixture)
        self.assertEqual(archive.manifest_name(fixture), "portal-runtime-v0.3.0-macos-arm64.json")

    def test_packs_the_runtime_alone_with_a_manifest_like_the_fixture(self):
        manifest = json.loads(self.pack(tag="v0.3.0").read_text())
        fixture = json.loads(FIXTURE.read_text())
        self.assertEqual(sorted(manifest), sorted(fixture))
        self.assertEqual(sorted(manifest["archives"][0]), sorted(fixture["archives"][0]))
        self.assertEqual((manifest["tag"], manifest["version"], manifest["identity"]),
                         ("v0.3.0", "0.3.0", IDENTITY))
        entry = manifest["archives"][0]
        self.assertEqual((entry["target"], entry["floor"], entry["name"]),
                         ("macos-arm64", {"macos": "13.0"}, "portal-runtime-v0.3.0-macos-arm64.tar.gz"))
        tarball = self.out / entry["name"]
        self.assertEqual(entry["size"], tarball.stat().st_size)
        self.assertEqual(entry["sha256"], archive.sha256(tarball))
        with tarfile.open(tarball) as tar:
            members = tar.getmembers()
        names = [member.name for member in members]
        self.assertEqual(names, sorted(names))
        self.assertEqual({name.split("/")[0] for name in names},
                         {"licenses", "portal-build.eld", "portal-host", "portal.bundle"})
        self.assertIn(MODULE, names)
        for member in members:
            self.assertEqual((member.uid, member.gid, member.uname, member.gname), (0, 0, "", ""))
        host = next(member for member in members if member.name == "portal-host")
        self.assertEqual(host.mode & 0o777, 0o755)

    def test_names_an_archive_outside_a_release_by_its_commit(self):
        manifest = json.loads(self.pack().read_text())
        self.assertIsNone(manifest["tag"])
        self.assertEqual(manifest["archives"][0]["name"],
                         "portal-runtime-0.3.0-eaa7f52-macos-arm64.tar.gz")

    def test_unpacks_the_same_files_elsewhere(self):
        written = self.pack(tag="v0.3.0")
        destination = self.root / "elsewhere" / "portal"
        archive.unpack(written, destination)
        for name in ("portal-build.eld", "portal-host", MODULE, "licenses/README.md",
                     "portal.bundle/Contents/Resources/terminfo/78/xterm-ghostty"):
            self.assertEqual((destination / name).read_bytes(), (self.build / name).read_bytes())
        self.assertEqual((destination / "portal-host").stat().st_mode & 0o777, 0o755)
        self.assertFalse((destination / "CMakeCache.txt").exists())

    def test_refuses_an_incomplete_or_mismatched_build(self):
        self.refused("not the build's version", self.pack, "v9.9.9")
        (self.build / "licenses" / "README.md").unlink()
        self.refused("lacks licenses/README.md", self.pack)

    def test_refuses_a_build_that_names_its_place_or_links_out(self):
        (self.build / "portal.bundle/Contents/Info.plist").write_text(f"<string>{self.build}</string>")
        self.refused("names the build's place", self.pack)
        (self.build / "portal.bundle/Contents/Info.plist").write_text("<plist/>")
        (self.build / "portal.bundle/Contents/Resources/escape").symlink_to("../../../../etc")
        self.refused("links outside the runtime", self.pack)

    def test_follows_chained_links_to_see_where_they_lead(self):
        # Inside: a chain to a file of the runtime, as a soname link is.
        (self.build / "licenses" / "texts").mkdir()
        (self.build / "licenses" / "texts" / "zlib").write_text("zlib")
        (self.build / "licenses" / "current").symlink_to("texts")
        (self.build / "licenses" / "zlib").symlink_to("current/zlib")
        archive.unpack(self.pack(), self.root / "inside")
        self.assertEqual((self.root / "inside" / "licenses" / "zlib").read_text(), "zlib")
        # Outside: each step counts as inside, the chain leads to the parent.
        (self.build / "licenses" / "a").symlink_to(".")
        (self.build / "licenses" / "b").symlink_to("a/../..")
        self.refused("licenses/b links outside the runtime", self.pack)
        # An absolute target, below the top too, is the checking machine's.
        (self.build / "licenses" / "b").unlink()
        (self.build / "licenses" / "texts" / "abs").symlink_to(self.build / "licenses" / "LICENSE")
        self.refused("licenses/texts/abs links outside the runtime", self.pack)
        (self.build / "licenses" / "texts" / "abs").unlink()
        # Links that loop lead nowhere.
        (self.build / "licenses" / "c").symlink_to("d")
        (self.build / "licenses" / "d").symlink_to("c")
        self.refused("links outside the runtime", self.pack)

    def test_unpack_follows_the_archives_own_links(self):
        for members, pattern in (
                ([("licenses/a", "."), ("licenses/b", "a/../..")], "links licenses/b outside"),
                ([("licenses/up", ".."), ("licenses/up/up", ".."), ("licenses/up/up/x", None)],
                 "links licenses/up/up outside"),
                ([("licenses/texts/abs", "/etc/hosts")], "links licenses/texts/abs outside"),
                ([("licenses/up", ".."), ("licenses/up/Makefile", None)],
                 "'licenses/up/Makefile', which a link takes outside")):
            with self.subTest(pattern):
                written = self.pack()
                manifest = json.loads(written.read_text())
                tarball = self.out / manifest["archives"][0]["name"]
                with tarfile.open(tarball, "w:gz") as tar:
                    for name, link in members:
                        info = tarfile.TarInfo(name)
                        if link is None:
                            info.size = 1
                            tar.addfile(info, io.BytesIO(b"x"))
                        else:
                            info.type, info.linkname = tarfile.SYMTYPE, link
                            tar.addfile(info)
                manifest["archives"][0]["size"] = tarball.stat().st_size
                manifest["archives"][0]["sha256"] = archive.sha256(tarball)
                written.write_text(json.dumps(manifest))
                self.refused(pattern, archive.unpack, written, self.root / "unpacked")
                self.assertFalse((self.root / "unpacked").exists())

    def test_a_binary_may_name_the_build_in_its_debug_map(self):
        self.binary(MODULE, macho() + str(self.build / "Backend.o").encode())
        archive.unpack(self.pack(), self.root / "elsewhere")

    def test_refuses_binaries_that_would_not_run_on_every_claimed_system(self):
        for data, pattern in ((macho(cpu=0x01000007), "for x86_64, not arm64"),
                              (macho(minos=(14, 0)), "needs macOS 14.0, newer than the floor"),
                              (macho(loads=("/opt/homebrew/lib/libz.dylib",)), "not the system's"),
                              (macho(loads=("@rpath/libghostty.dylib",)), "not the system's"),
                              (struct.pack(">I", 0xCAFEBABE) + bytes(60), "universal binary")):
            with self.subTest(pattern):
                self.binary(MODULE, data)
                for path in self.out.glob("*"):
                    path.unlink()
                self.refused(pattern, archive.unpack, self.pack(), self.root / pattern)

    def test_refuses_an_archive_its_manifest_does_not_describe(self):
        written = self.pack()
        manifest = json.loads(written.read_text())
        tarball = self.out / manifest["archives"][0]["name"]
        tarball.write_bytes(tarball.read_bytes()[:-1])
        self.refused("bytes, not the manifest's", archive.unpack, written, self.root / "a")
        self.assertFalse((self.root / "a").exists())
        written = self.pack()
        tarball.write_bytes(tarball.read_bytes()[:-1] + b"\1")
        self.refused("SHA-256", archive.unpack, written, self.root / "b")
        written = self.pack()
        manifest = json.loads(written.read_text())
        manifest["identity"] = "f" * 64
        written.write_text(json.dumps(manifest))
        self.refused("identity", archive.unpack, written, self.root / "c")

    def test_refuses_members_outside_the_runtime(self):
        for name, pattern in (("../escape", "outside the runtime"),
                              ("/etc/escape", "outside the runtime"),
                              ("Makefile", "not of the runtime")):
            with self.subTest(name):
                written = self.pack()
                manifest = json.loads(written.read_text())
                tarball = self.out / manifest["archives"][0]["name"]
                with tarfile.open(tarball, "w:gz") as tar:
                    info = tarfile.TarInfo(name)
                    info.size = 1
                    tar.addfile(info, io.BytesIO(b"x"))
                manifest["archives"][0]["size"] = tarball.stat().st_size
                manifest["archives"][0]["sha256"] = archive.sha256(tarball)
                written.write_text(json.dumps(manifest))
                self.refused(pattern, archive.unpack, written, self.root / "unpacked")
                self.assertFalse((self.root / "unpacked").exists())

    def test_unpacks_only_into_a_new_or_empty_directory(self):
        written = self.pack()
        (self.root / "full").mkdir()
        (self.root / "full" / "kept").write_text("")
        self.refused("not a new or empty directory", archive.unpack, written, self.root / "full")

    def test_refuses_manifests_out_of_format(self):
        fixture = json.loads(FIXTURE.read_text())
        for change, pattern in ((lambda m: m.update(tag="v0.4.0"), "tag other than"),
                                (lambda m: m.update(extra=1), "other keys"),
                                (lambda m: m["archives"][0].update(target="beos-m68k"), "unknown target"),
                                (lambda m: m["archives"][0].update(floor={"macos": "12.0"}), "another floor"),
                                (lambda m: m["archives"][0].update(name="portal.tar.gz"), "names an archive"),
                                (lambda m: m["archives"].append(dict(m["archives"][0])), "target twice")):
            with self.subTest(pattern):
                manifest = json.loads(json.dumps(fixture))
                change(manifest)
                self.refused(pattern, archive.check_manifest, manifest)

    def test_the_command_line_says_why_it_refuses(self):
        self.assertEqual(archive.main(["pack", "--commit", "eaa7f52", str(self.build), str(self.out)]), 1)
        self.assertEqual(archive.main(["pack", "--commit", COMMIT, str(self.build), str(self.out)]), 0)


if __name__ == "__main__":
    unittest.main()
