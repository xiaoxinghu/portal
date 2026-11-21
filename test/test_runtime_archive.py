# SPDX-License-Identifier: GPL-3.0-or-later
"""scripts/runtime-archive.py packs a stand-in build and checks it unpacked.

The build's binaries are small Mach-O and ELF files written here, so these
tests run anywhere, without a build.  The manifest's format is the fixture's,
test/fixtures/runtime-manifest.json, which the installer's tests read too.
"""
from pathlib import Path
import contextlib
import importlib.util
import io
import json
import os
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

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


def elf(machine=62, kind=3, needed=("libc.so.6",), soname=None, runpath=(), rpath=(),
        versions=(("libc.so.6", ("GLIBC_2.2.5", "GLIBC_2.34")),), x86_isa=None):
    """A 64-bit little-endian ELF file with these dynamic entries and
needed symbol versions in its sections, and no code."""
    strings = bytearray(b"\0")

    def string(text):
        offset = len(strings)
        strings.extend(text.encode() + b"\0")
        return offset

    dynamic = b"".join(struct.pack("<qQ", 1, string(name)) for name in needed)
    for tag, value in ((14, soname), (29, ":".join(runpath)), (15, ":".join(rpath))):
        if value:
            dynamic += struct.pack("<qQ", tag, string(value))
    dynamic += struct.pack("<qQ", 0, 0)
    verneed = b""
    for index, (file, names) in enumerate(versions):
        aux = b"".join(struct.pack("<IHHII", 0, 0, 2 + number, string(name),
                                   16 if number < len(names) - 1 else 0)
                       for number, name in enumerate(names))
        following = 16 + len(aux) if index < len(versions) - 1 else 0
        verneed += struct.pack("<HHIII", 1, len(names), string(file), 16, following) + aux
    strings = bytes(strings).ljust((len(strings) + 7) // 8 * 8, b"\0")
    # A GNU property note, as GCC writes it, with the x86 ISA level needed
    # and another property before it.
    note = b""
    if x86_isa is not None:
        properties = (struct.pack("<II", 0xC0000002, 4) + struct.pack("<I", 3).ljust(8, b"\0")
                      + struct.pack("<II", 0xC0008002, 4) + struct.pack("<I", x86_isa).ljust(8, b"\0"))
        note = struct.pack("<III", 4, len(properties), 5) + b"GNU\0" + properties
    offsets = [64, 64 + len(strings), 64 + len(strings) + len(dynamic),
               64 + len(strings) + len(dynamic) + len(verneed)]
    shoff = offsets[3] + len(note)

    def section(kind_, offset, size, link=0, info=0):
        return struct.pack("<IIQQQQIIQQ", 0, kind_, 0, 0, offset, size, link, info, 8, 0)

    sections = (section(0, 0, 0) + section(3, offsets[0], len(strings))
                + section(6, offsets[1], len(dynamic), link=1)
                + section(0x6FFFFFFE, offsets[2], len(verneed), link=1, info=len(versions))
                + section(7, offsets[3], len(note)))
    header = (b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
              + struct.pack("<HHIQQQIHHHHHH", kind, machine, 1, 0, 0, shoff, 0, 64, 56, 0,
                            64, 5, 0))
    return header + strings + dynamic + verneed + note + sections


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
        self.refused("escape links to ../../../../etc, outside the runtime", self.pack)

    def test_follows_links_on_disk_to_see_where_they_lead(self):
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
        self.refused("licenses/b links to a/../.., outside", self.pack)
        (self.build / "licenses" / "b").unlink()
        # An absolute target is the machine's, even one into the build.
        (self.build / "licenses" / "texts" / "abs").symlink_to(self.build / "licenses" / "LICENSE")
        self.refused("licenses/texts/abs links to /", self.pack)
        (self.build / "licenses" / "texts" / "abs").unlink()
        # Links that loop lead nowhere.
        (self.build / "licenses" / "c").symlink_to("d")
        (self.build / "licenses" / "d").symlink_to("c")
        self.refused("licenses/c links to d, outside the runtime or to nothing", self.pack)

    def test_unpack_writes_nothing_through_a_link_or_outside(self):
        for members, pattern in (
                ([("licenses/a", "."), ("licenses/b", "a/../..")], "links licenses/b to a/../.."),
                ([("licenses/texts/abs", "/etc/hosts")], "links licenses/texts/abs to /etc/hosts"),
                ([("licenses/./a", ".."), ("licenses/b", "a/.."), ("licenses/b/payload", None)],
                 "'licenses/./a', which is not a plain path"),
                ([("licenses//x", None)], "not a plain path"),
                ([("licenses/a", None), ("licenses/a", "..")], "'licenses/a' twice"),
                # A file beneath a link: written first, so the link finds its place taken.
                ([("licenses/up", ".."), ("licenses/up/payload", None)],
                 "licenses/up is already there"),
                # Each link made through the one before, to the parent.
                ([("licenses/a", "."), ("licenses/a/b", ".."), ("licenses/b/c", ".."),
                  ("licenses/b/c/payload", None)], "licenses/a/b goes through licenses/a"),
                # The same through names a case-insensitive disk takes as one,
                # as macOS's usually is; a case-sensitive one fails it later.
                ([("licenses/a", "."), ("licenses/A/b", ".."), ("licenses/B/c", ".."),
                  ("licenses/B/C/payload", None)], "")):
            with self.subTest(members):
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
                parent = self.root / "unpacked"
                parent.mkdir()
                self.refused(pattern, archive.unpack, written, parent / "portal")
                # Nothing written beside the destination, and nothing left in it.
                self.assertEqual(list(parent.iterdir()), [])
                parent.rmdir()

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


class LinuxRuntimeArchiveTests(unittest.TestCase):
    """The Linux archives: one per CPU, Ghostty's library and resources
beside the module, the system's libraries by name."""
    LIBRARY = "ghostty-linux/lib/ghostty-internal.so"

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="portal runtime ")
        self.addCleanup(directory.cleanup)
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
            "ghostty-linux/share/ghostty/shell-integration/bash/ghostty.bash": "bash",
            "ghostty-linux/share/terminfo/x/xterm-ghostty": "terminfo",
            # Ghostty's install, besides what Portal runs.
            "ghostty-linux/include/ghostty.h": "header",
            "ghostty-linux/share/man/man1/ghostty.1": "manual",
            "CMakeCache.txt": f"CMAKE_HOME={self.build}",
        }
        for name, text in files.items():
            (self.build / name).parent.mkdir(parents=True, exist_ok=True)
            (self.build / name).write_text(text)
        self.binary("portal.so", self.module())
        self.binary(self.LIBRARY, self.library())
        (self.build / "ghostty-linux/lib/libghostty.so").symlink_to("ghostty-internal.so")
        # The loader is asked only on a Linux machine of the archive's CPU,
        # and these binaries are not ones it could load.
        patch = mock.patch.object(archive, "check_loader", return_value="")
        patch.start()
        self.addCleanup(patch.stop)

    @staticmethod
    def module(**changes):
        fields = {"needed": ("libghostty.so", "libgtk-3.so.0", "libwayland-client.so.0",
                             "libc.so.6"),
                  "runpath": ("$ORIGIN/ghostty-linux/lib",), "x86_isa": 1}
        return elf(**{**fields, **changes})

    @staticmethod
    def library(**changes):
        fields = {"needed": ("libEGL.so.1", "libm.so.6", "libc.so.6"), "soname": "libghostty.so",
                  "versions": (("libm.so.6", ("GLIBC_2.2.5", "GLIBC_2.43")),
                               ("libc.so.6", ("GLIBC_2.2.5", "GLIBC_2.34")))}
        return elf(**{**fields, **changes})

    def binary(self, name, data):
        (self.build / name).parent.mkdir(parents=True, exist_ok=True)
        (self.build / name).write_bytes(data)

    def pack(self, target="linux-x86_64-gnu"):
        for path in self.out.glob("*"):
            path.unlink()
        return archive.pack(self.build, self.out, COMMIT, "v0.3.0", target)

    def refused(self, pattern, function, *arguments):
        with self.assertRaisesRegex(archive.Refusal, pattern):
            function(*arguments)

    def test_packs_the_module_with_ghostty_and_unpacks_it_elsewhere(self):
        written = self.pack()
        manifest = json.loads(written.read_text())
        entry = manifest["archives"][0]
        self.assertEqual((entry["target"], entry["floor"], entry["name"], written.name),
                         ("linux-x86_64-gnu", {"glibc": "2.43"},
                          "portal-runtime-v0.3.0-linux-x86_64-gnu.tar.gz",
                          "portal-runtime-v0.3.0-linux-x86_64-gnu.json"))
        with tarfile.open(self.out / entry["name"]) as tar:
            members = {member.name: member for member in tar.getmembers()}
        self.assertEqual({name.split("/")[0] for name in members},
                         {"licenses", "portal-build.eld", "portal.so", "ghostty-linux"})
        self.assertEqual(members["ghostty-linux/lib/libghostty.so"].linkname, "ghostty-internal.so")
        for name in ("ghostty-linux", "ghostty-linux/lib", "ghostty-linux/share"):
            self.assertTrue(members[name].isdir(), name)
        self.assertFalse([name for name in members if "include" in name or "man" in name])

        destination = self.root / "elsewhere" / "portal"
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            archive.unpack(written, destination)
        self.assertEqual((destination / "ghostty-linux/lib/libghostty.so").read_bytes(),
                         self.library())
        self.assertEqual(os.readlink(destination / "ghostty-linux/lib/libghostty.so"),
                         "ghostty-internal.so")
        report = out.getvalue()
        self.assertIn("portal.so: x86_64, x86-64 baseline, GLIBC_2.34 at most; system libraries libgtk-3.so.0, "
                      "libwayland-client.so.0, libc.so.6; libghostty.so from the runtime's "
                      "ghostty-linux/lib/libghostty.so by its runpath $ORIGIN/ghostty-linux/lib",
                      report)
        self.assertIn(f"{self.LIBRARY}: x86_64, no x86-64 level marked, GLIBC_2.43 at most; "
                      "system libraries "
                      "libEGL.so.1, libm.so.6, libc.so.6", report)

    def test_one_archive_a_cpu(self):
        self.refused("portal.so is for x86_64, not aarch64", archive.unpack,
                     self.pack("linux-aarch64-gnu"), self.root / "arm")
        self.binary("portal.so", self.module(machine=183))
        self.binary(self.LIBRARY, self.library(machine=183))
        archive.unpack(self.pack("linux-aarch64-gnu"), self.root / "arm")

    def test_refuses_binaries_that_would_not_run_on_every_claimed_system(self):
        for name, data, pattern in (
                (self.LIBRARY, self.library(versions=(("libm.so.6", ("GLIBC_2.44",)),)),
                 "needs GLIBC_2.44, newer than the floor, glibc 2.43"),
                (self.LIBRARY, self.library(versions=(("libc.so.6", ("GLIBC_PRIVATE",)),)),
                 "glibc's private symbols"),
                (self.LIBRARY, self.library(needed=("libstdc++.so.6",)),
                 "needs libstdc\\+\\+.so.6, which is neither the system's nor the runtime's"),
                (self.LIBRARY, self.library(kind=2), "not a shared object"),
                (self.LIBRARY, self.library(soname="ghostty-internal.so"), "another soname"),
                ("portal.so", self.module(runpath=()), "needs libghostty.so, which is neither"),
                ("portal.so", self.module(rpath=("$ORIGIN/ghostty-linux/lib",)), "has an RPATH"),
                ("portal.so", self.module(runpath=(f"{self.build}/ghostty-linux/lib",)),
                 "not a place beside it"),
                ("portal.so", self.module(runpath=("$ORIGIN/../..",)), "outside the runtime"),
                ("portal.so", self.module(x86_isa=1 | 4),
                 "needs x86-64-v3, a newer CPU than the baseline"),
                ("portal.so", self.module(x86_isa=2), "needs x86-64-v2"),
                ("portal.so", b"#!/bin/sh\n" + bytes(64), "not an ELF binary")):
            with self.subTest(pattern):
                original = (self.build / name).read_bytes()
                self.binary(name, data)
                self.refused(pattern, archive.unpack, self.pack(), self.root / "unpacked")
                self.assertFalse((self.root / "unpacked").exists())
                self.binary(name, original)

    def test_refuses_what_ghostty_installs_besides_the_runtime(self):
        for name, directory in (("ghostty-linux/include/ghostty.h", False),
                                ("ghostty-linux/share/man", True),
                                ("ghostty-linux", False)):
            with self.subTest(name):
                written = self.pack()
                manifest = json.loads(written.read_text())
                tarball = self.out / manifest["archives"][0]["name"]
                with tarfile.open(tarball, "w:gz") as tar:
                    info = tarfile.TarInfo(name)
                    if directory:
                        info.type = tarfile.DIRTYPE
                        tar.addfile(info)
                    else:
                        info.size = 1
                        tar.addfile(info, io.BytesIO(b"x"))
                manifest["archives"][0]["size"] = tarball.stat().st_size
                manifest["archives"][0]["sha256"] = archive.sha256(tarball)
                written.write_text(json.dumps(manifest))
                self.refused("not of the runtime", archive.unpack, written, self.root / "unpacked")

    def test_refuses_a_build_whose_ghostty_directory_is_a_link(self):
        (self.build / "ghostty-linux").rename(self.root / "elsewhere")
        (self.build / "ghostty-linux").symlink_to(self.root / "elsewhere")
        self.refused("the build's ghostty-linux is not a directory", self.pack)


class LoaderTests(unittest.TestCase):
    """What ldd says decides where the runtime's libraries come from."""
    LDD = """\tlinux-vdso.so.1 (0x0000ffff8a5f0000)
\tlibghostty.so => {library} (0x0000ffff88000000)
\tlibgtk-3.so.0 => /usr/lib/libgtk-3.so.0 (0x0000ffff87a00000)
\tlibc.so.6 => /usr/lib/libc.so.6 (0x0000ffff87800000)
\t/lib/ld-linux-aarch64.so.1 (0x0000ffff8a5b0000)
"""

    def ask(self, stdout, own, machine="aarch64", system="linux"):
        result = subprocess.CompletedProcess([], 0, stdout, "")
        with mock.patch.object(archive.sys, "platform", system), \
                mock.patch.object(archive.platform, "machine", return_value=machine), \
                mock.patch.object(archive.subprocess, "run", return_value=result) as run:
            answer = archive.check_loader(Path("/runtime"), "portal.so", own, "aarch64")
        return answer, run

    def test_the_runtimes_library_comes_from_the_runtime(self):
        own = [("libghostty.so", Path("/runtime/ghostty-linux/lib/libghostty.so"))]
        answer, run = self.ask(self.LDD.format(library="/runtime/ghostty-linux/lib/libghostty.so"),
                               own)
        self.assertEqual(answer, "; the loader finds 3 libraries, the runtime's in it")
        self.assertNotIn("LD_LIBRARY_PATH", run.call_args.kwargs["env"])
        with self.assertRaisesRegex(archive.Refusal, "at /usr/lib/libghostty.so, not in the runtime"):
            self.ask(self.LDD.format(library="/usr/lib/libghostty.so"), own)
        with self.assertRaisesRegex(archive.Refusal, "does not find libghostty.so"):
            self.ask(self.LDD.format(library="not found"), own)

    def test_is_asked_only_on_a_linux_machine_of_the_cpu(self):
        for machine, system in (("x86_64", "linux"), ("arm64", "darwin")):
            answer, run = self.ask("", [], machine, system)
            self.assertIn("not asked", answer)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
