#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pack a tested Portal build as a runtime archive, and check one unpacked.

    python3 -B scripts/runtime-archive.py pack [--tag vX.Y.Z] --commit SHA BUILD OUT
    python3 -B scripts/runtime-archive.py unpack MANIFEST DESTINATION

`pack` tars what Portal runs from BUILD, as it is, into OUT, and writes the
manifest beside it: the build is the one the checks have just tested, and
nothing in it is rebuilt or changed.  It refuses a build that lacks a file
of the runtime, holds a link out of it, or names BUILD's own place, which
would not exist on another machine.  Without --tag the archive is named
after the build's version and the commit, and its manifest has no tag.

`unpack` checks the archive against its manifest, refuses a member that
would land outside DESTINATION, unpacks it there, a new or empty directory,
and checks what it unpacked: the files of the runtime and nothing else, the
build record the manifest names, and each binary's CPU, oldest system and
libraries.  On Linux that is each ELF binary's machine, on x86-64 the CPU
level its GNU property note says it needs, the newest glibc symbol
version it needs, its libraries and where it looks for them: those
of the system by name, Ghostty's from the runtime through the module's
$ORIGIN runpath.  Run on a machine of the archive's CPU, it also asks the
system's loader, ldd, where each library is found.  It does not load the
module: in a checkout of the same sources, `emacs --batch -Q -l
portal-build.el -f portal-build--probe-batch DESTINATION` does, and
test/render-smoke.sh DESTINATION draws a terminal from it.

test/fixtures/runtime-manifest.json is an example manifest: the tests of
this script and of the installer read it.  Runs with the Python of macOS's
Command Line Tools, 3.9, or newer.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
from pathlib import Path

FORMAT = 1

# What each target's archive holds, each entry with all beneath it, which of
# its files are binaries to check and which must be executable.  A Linux
# archive is one per CPU, for every glibc system of its floor or newer,
# whatever the distribution or desktop: it holds Ghostty's library under its
# soname too, and the resources, not the rest of Ghostty's install.
LINUX_ENTRIES = ["licenses", "portal-build.eld", "portal.so",
                 "ghostty-linux/lib/ghostty-internal.so", "ghostty-linux/lib/libghostty.so",
                 "ghostty-linux/share/ghostty", "ghostty-linux/share/terminfo"]
LINUX_REQUIRED = ["licenses/LICENSE", "licenses/README.md", "portal-build.eld", "portal.so",
                  "ghostty-linux/lib/libghostty.so",
                  "ghostty-linux/share/terminfo/x/xterm-ghostty"]
LINUX_BINARIES = ["portal.so", "ghostty-linux/lib/ghostty-internal.so"]
TARGETS = {
    "macos-arm64": {
        "entries": ["licenses", "portal-build.eld", "portal-host", "portal.bundle"],
        "required": ["licenses/LICENSE", "licenses/README.md", "portal-build.eld",
                     "portal-host", "portal.bundle/Contents/Info.plist",
                     "portal.bundle/Contents/MacOS/portal.dylib"],
        "binaries": ["portal.bundle/Contents/MacOS/portal.dylib", "portal-host"],
        "executables": ["portal-host"],
        "cpu": "arm64",
        "floor": {"macos": "13.0"},
    },
    "linux-x86_64-gnu": {
        "entries": LINUX_ENTRIES, "required": LINUX_REQUIRED, "binaries": LINUX_BINARIES,
        "executables": [], "cpu": "x86_64", "floor": {"glibc": "2.43"},
    },
    "linux-aarch64-gnu": {
        "entries": LINUX_ENTRIES, "required": LINUX_REQUIRED, "binaries": LINUX_BINARIES,
        "executables": [], "cpu": "aarch64", "floor": {"glibc": "2.43"},
    },
}

# Libraries a Mac binary may load: the system's.  Anything else would have
# to be on the user's machine, where it was on the builder's.
SYSTEM_LIBRARIES = ("/usr/lib/", "/System/Library/")


class Refusal(Exception):
    """Why an archive, its manifest or a build is refused."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_record(path: Path) -> dict:
    """The identity and version in a build record, portal-build.eld."""
    try:
        text = path.read_text()
    except OSError:
        raise Refusal(f"no build record at {path}")
    record = {}
    for key in ("identity", "version"):
        match = re.search(r':%s\s+"([^"\\]*)"' % key, text)
        if not match:
            raise Refusal(f"the build record {path} has no :{key}")
        record[key] = match.group(1)
    return record


# Manifests.

def check_manifest(manifest: object) -> dict:
    """Return MANIFEST, a parsed manifest, or refuse it, saying why."""
    def need(condition, what):
        if not condition:
            raise Refusal(f"the manifest {what}")

    need(isinstance(manifest, dict), "is not an object")
    need(manifest.get("format") == FORMAT, f"is not of format {FORMAT}")
    need(set(manifest) == {"format", "tag", "version", "commit", "identity", "archives"},
         "has other keys than format, tag, version, commit, identity and archives")
    version = manifest["version"]
    need(isinstance(version, str) and re.fullmatch(r"\d+\.\d+\.\d+", version),
         "has no version X.Y.Z")
    need(manifest["tag"] is None or manifest["tag"] == f"v{version}",
         f"has a tag other than v{version} or null")
    need(isinstance(manifest["commit"], str) and re.fullmatch(r"[0-9a-f]{40}", manifest["commit"]),
         "has no commit of 40 hexadecimal digits")
    need(isinstance(manifest["identity"], str)
         and re.fullmatch(r"[0-9a-f]{64}", manifest["identity"]),
         "has no source identity of 64 hexadecimal digits")
    archives = manifest["archives"]
    need(isinstance(archives, list) and archives, "lists no archives")
    for archive in archives:
        need(isinstance(archive, dict)
             and set(archive) == {"target", "floor", "name", "size", "sha256"},
             "has an archive without exactly target, floor, name, size and sha256")
        need(archive["target"] in TARGETS, f"names an unknown target {archive['target']!r}")
        need(archive["floor"] == TARGETS[archive["target"]]["floor"],
             f"gives {archive['target']} another floor than {TARGETS[archive['target']]['floor']}")
        need(archive["name"] == archive_name(manifest, archive["target"]),
             f"names an archive {archive['name']!r}, not "
             f"{archive_name(manifest, archive['target'])!r}")
        need(isinstance(archive["size"], int) and archive["size"] > 0,
             f"gives {archive['name']} no size")
        need(isinstance(archive["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", archive["sha256"]),
             f"gives {archive['name']} no SHA-256")
    need(len({archive["target"] for archive in archives}) == len(archives),
         "lists a target twice")
    return manifest


def archive_name(manifest: dict, target: str) -> str:
    label = manifest["tag"] or f"{manifest['version']}-{manifest['commit'][:7]}"
    return f"portal-runtime-{label}-{target}.tar.gz"


def manifest_name(manifest: dict) -> str:
    return archive_name(manifest, manifest["archives"][0]["target"])[:-len(".tar.gz")] + ".json"


# Mach-O, as much as the checks need: the CPU, the oldest macOS, and the
# libraries loaded and paths searched.

CPUS = {0x0100000C: "arm64", 0x01000007: "x86_64"}
LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX, LC_RPATH = 0x32, 0x24, 0x8000001C
# Loads: LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
# LC_LAZY_LOAD_DYLIB and LC_LOAD_UPWARD_DYLIB.
LOADS = {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023}
PLATFORM_MACOS = 1


def macho(path: Path) -> dict:
    """The CPU, platform, oldest system, loads and rpaths of a thin Mach-O."""
    data = path.read_bytes()
    if len(data) < 32:
        raise Refusal(f"{path} is not a Mach-O binary")
    magic = struct.unpack_from("<I", data)[0]
    if struct.unpack_from(">I", data)[0] in (0xCAFEBABE, 0xCAFEBABF):
        raise Refusal(f"{path} is a universal binary, not one for a single CPU")
    if magic != 0xFEEDFACF:
        raise Refusal(f"{path} is not a 64-bit Mach-O binary")
    cpu, _, _, ncmds, _, _, _ = struct.unpack_from("<iIIIIII", data, 4)
    found = {"cpu": CPUS.get(cpu & 0xFFFFFFFF, hex(cpu & 0xFFFFFFFF)), "platform": None,
             "minos": None, "loads": [], "rpaths": []}

    def string(start, offset, size):
        raw = data[start + offset:start + size]
        return raw.split(b"\0", 1)[0].decode("utf-8", "replace")

    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > len(data):
            raise Refusal(f"{path} has a damaged load command")
        if cmd == LC_BUILD_VERSION:
            found["platform"], minos = struct.unpack_from("<II", data, offset + 8)
            found["minos"] = version_text(minos)
        elif cmd == LC_VERSION_MIN_MACOSX:
            found["platform"] = PLATFORM_MACOS
            found["minos"] = version_text(struct.unpack_from("<I", data, offset + 8)[0])
        elif cmd in LOADS:
            found["loads"].append(string(offset, struct.unpack_from("<I", data, offset + 8)[0], size))
        elif cmd == LC_RPATH:
            found["rpaths"].append(string(offset, struct.unpack_from("<I", data, offset + 8)[0], size))
        offset += size
    return found


def version_text(encoded: int) -> str:
    major, minor, patch = encoded >> 16, (encoded >> 8) & 0xFF, encoded & 0xFF
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def version_key(text: str) -> tuple:
    return tuple(int(part) for part in text.split("."))


def check_binary(root: Path, name: str, target: str) -> str:
    """Refuse a binary, NAME in the runtime ROOT, that would not run on every
system TARGET claims."""
    if "glibc" in TARGETS[target]["floor"]:
        return check_elf(root, name, target)
    path = root / name
    spec = TARGETS[target]
    found = macho(path)
    if found["cpu"] != spec["cpu"]:
        raise Refusal(f"{name} is for {found['cpu']}, not {spec['cpu']}")
    floor = spec["floor"]["macos"]
    if found["platform"] != PLATFORM_MACOS or not found["minos"]:
        raise Refusal(f"{name} names no oldest macOS")
    if version_key(found["minos"]) > version_key(floor):
        raise Refusal(f"{name} needs macOS {found['minos']}, newer than the floor, {floor}")
    foreign = [load for load in found["loads"] if not load.startswith(SYSTEM_LIBRARIES)]
    if foreign:
        raise Refusal(f"{name} loads libraries that are not the system's: {', '.join(foreign)}")
    # A search path matters only to a load through @rpath, which the check
    # above refuses; the toolchain's, which Swift links in, are then inert.
    rpaths = f"; inert rpaths {', '.join(found['rpaths'])}" if found["rpaths"] else ""
    return (f"{name}: {found['cpu']}, macOS {found['minos']} or later, "
            f"{len(found['loads'])} system libraries{rpaths}")


# ELF, as much as the checks need: the machine, the libraries needed and
# where they are looked for, the soname, and the symbol versions needed.

MACHINES = {62: "x86_64", 183: "aarch64"}
ET_DYN, SHT_DYNAMIC, SHT_NOTE, SHT_GNU_VERNEED = 3, 6, 7, 0x6FFFFFFE
# The x86-64 levels a binary says it needs, in its GNU property note, which
# GCC and binutils write and glibc's loader enforces: x86-64 itself, then
# v2, v3 (Haswell's AVX2) and v4 (AVX-512).
NT_GNU_PROPERTY_TYPE_0, GNU_PROPERTY_X86_ISA_1_NEEDED = 5, 0xC0008002
X86_LEVELS = [(1, "x86-64"), (2, "x86-64-v2"), (4, "x86-64-v3"), (8, "x86-64-v4")]
DT_NEEDED, DT_SONAME, DT_RPATH, DT_RUNPATH = 1, 14, 15, 29

# Libraries a Linux binary may load by name from the system: glibc's, and
# GTK 3, Wayland's client and EGL, with the libraries GTK's pkg-config
# links.  The system supplies them, the archive never.  Anything else would
# have to be on the user's machine, where it was on the builder's.
LINUX_SYSTEM_LIBRARIES = {
    "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1",
    "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1",
    "libgtk-3.so.0", "libgdk-3.so.0", "libpangocairo-1.0.so.0", "libpango-1.0.so.0",
    "libharfbuzz.so.0", "libatk-1.0.so.0", "libcairo-gobject.so.2", "libcairo.so.2",
    "libgdk_pixbuf-2.0.so.0", "libgio-2.0.so.0", "libgobject-2.0.so.0", "libglib-2.0.so.0",
    "libgmodule-2.0.so.0", "libwayland-client.so.0", "libEGL.so.1",
}


def elf(path: Path) -> dict:
    """The machine, type, libraries, soname, search paths and needed
symbol versions of a 64-bit little-endian ELF file."""
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise Refusal(f"{path} is not an ELF binary")
    if data[4] != 2 or data[5] != 1:
        raise Refusal(f"{path} is not a 64-bit little-endian ELF binary")
    kind, machine = struct.unpack_from("<HH", data, 16)
    shoff, = struct.unpack_from("<Q", data, 40)
    shentsize, shnum = struct.unpack_from("<HH", data, 58)
    found = {"machine": MACHINES.get(machine, str(machine)), "type": kind, "needed": [],
             "soname": None, "rpath": [], "runpath": [], "versions": {}, "x86_isa": None}
    if shentsize != 64 or shoff + shnum * 64 > len(data):
        raise Refusal(f"{path} has damaged section headers")
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + index * 64)
                for index in range(shnum)]

    def section(index):
        if index >= len(sections):
            raise Refusal(f"{path} has a damaged section link")
        _, _, _, _, offset, size, link, info, _, _ = sections[index]
        if offset + size > len(data):
            raise Refusal(f"{path} has a damaged section")
        return offset, size, link, info

    def string(table, at):
        offset, size, _, _ = section(table)
        if at >= size:
            raise Refusal(f"{path} has a damaged string table")
        return data[offset + at:data.index(b"\0", offset + at)].decode("utf-8", "replace")

    for index, header in enumerate(sections):
        if header[1] == SHT_DYNAMIC:
            offset, size, strings, _ = section(index)
            for at in range(offset, offset + size - 15, 16):
                tag, value = struct.unpack_from("<qQ", data, at)
                if tag == 0:
                    break
                if tag == DT_NEEDED:
                    found["needed"].append(string(strings, value))
                elif tag == DT_SONAME:
                    found["soname"] = string(strings, value)
                elif tag in (DT_RPATH, DT_RUNPATH):
                    key = "rpath" if tag == DT_RPATH else "runpath"
                    found[key] += [part for part in string(strings, value).split(":") if part]
        elif header[1] == SHT_NOTE:
            offset, size, _, _ = section(index)
            align = max(4, header[8])
            at, end = offset, offset + size
            while at + 12 <= end:
                namesz, descsz, kind_ = struct.unpack_from("<III", data, at)
                name = data[at + 12:at + 12 + namesz]
                desc = at + (12 + namesz + align - 1) // align * align
                if name == b"GNU\0" and kind_ == NT_GNU_PROPERTY_TYPE_0:
                    there = desc
                    while there + 8 <= desc + descsz:
                        property_, datasz = struct.unpack_from("<II", data, there)
                        if property_ == GNU_PROPERTY_X86_ISA_1_NEEDED and datasz >= 4:
                            found["x86_isa"] = (found["x86_isa"] or 0) | \
                                struct.unpack_from("<I", data, there + 8)[0]
                        there += 8 + (datasz + 7) // 8 * 8
                at = desc + (descsz + align - 1) // align * align
        elif header[1] == SHT_GNU_VERNEED:
            offset, size, strings, count = section(index)
            at = offset
            for _ in range(count):
                _, entries, file, aux, following = struct.unpack_from("<HHIII", data, at)
                names = found["versions"].setdefault(string(strings, file), [])
                there = at + aux
                for _ in range(entries):
                    _, _, _, name, after = struct.unpack_from("<IHHII", data, there)
                    names.append(string(strings, name))
                    there += after
                at += following
    return found


def glibc_version(name: str):
    match = re.fullmatch(r"GLIBC_(\d+(?:\.\d+)+)", name)
    return match and version_key(match.group(1))


def search_paths(root: Path, name: str, found: dict) -> list:
    """The directories the binary NAME in ROOT names in its runpath, with
$ORIGIN, its own directory, expanded."""
    origin = (root / name).parent
    places = []
    for entry in found["runpath"]:
        if not re.match(r"\$(ORIGIN|\{ORIGIN\})(/|$)", entry):
            raise Refusal(f"{name} searches {entry} for libraries, not a place beside it")
        place = Path(os.path.normpath(origin / re.sub(r"^\$(ORIGIN|\{ORIGIN\})", ".", entry)))
        if os.path.commonpath([os.path.realpath(place), str(root.resolve())]) != str(root.resolve()):
            raise Refusal(f"{name} searches {entry} for libraries, outside the runtime")
        places.append(place)
    return places


def check_elf(root: Path, name: str, target: str) -> str:
    spec = TARGETS[target]
    found = elf(root / name)
    if found["machine"] != spec["cpu"]:
        raise Refusal(f"{name} is for {found['machine']}, not {spec['cpu']}")
    if found["type"] != ET_DYN:
        raise Refusal(f"{name} is not a shared object")
    if found["rpath"]:
        raise Refusal(f"{name} has an RPATH, {':'.join(found['rpath'])}, which overrides "
                      "the user's library path; a runpath is what it needs")
    level = ""
    if found["machine"] == "x86_64":
        marked = found["x86_isa"]
        newer = [name for bit, name in X86_LEVELS[1:] if marked and marked & bit]
        if newer:
            raise Refusal(f"{name} needs {newer[-1]}, a newer CPU than the baseline, x86-64")
        level = ", x86-64 baseline" if marked else ", no x86-64 level marked"
    floor = spec["floor"]["glibc"]
    newest, others = None, []
    for library, names in sorted(found["versions"].items()):
        for version in names:
            key = glibc_version(version)
            if key is None:
                others.append(f"{version} of {library}")
            elif newest is None or key > glibc_version(newest):
                newest = version
    if any(version.startswith("GLIBC_PRIVATE") for version in others):
        raise Refusal(f"{name} needs glibc's private symbols, which change with every release")
    if newest and glibc_version(newest) > version_key(floor):
        raise Refusal(f"{name} needs {newest}, newer than the floor, glibc {floor}")
    places = search_paths(root, name, found)
    own, system = [], []
    for library in found["needed"]:
        inside = next((place / library for place in places if (place / library).is_file()), None)
        if inside:
            if elf(inside)["soname"] != library:
                raise Refusal(f"{name} needs {library}, and the runtime's "
                              f"{inside.relative_to(root)} has another soname")
            own.append((library, inside))
        elif library in LINUX_SYSTEM_LIBRARIES:
            system.append(library)
        else:
            raise Refusal(f"{name} needs {library}, which is neither the system's nor "
                          "the runtime's")
    found_by_loader = check_loader(root, name, own, spec["cpu"])
    return (f"{name}: {found['machine']}{level}, {newest or 'no glibc versions'} at most"
            f"{', also ' + ', '.join(others) if others else ''}; "
            f"system libraries {', '.join(system) or 'none'}"
            + "".join(f"; {library} from the runtime's "
                      f"{inside.relative_to(root).as_posix()} by its runpath "
                      f"{':'.join(found['runpath'])}" for library, inside in own)
            + found_by_loader)


def check_loader(root: Path, name: str, own: list, cpu: str) -> str:
    """Ask the system's loader, through ldd, where it finds each library
of the binary NAME, when this is a Linux machine of its CPU: the runtime's
must be found in ROOT, and none missing."""
    if not sys.platform.startswith("linux") or platform.machine() != cpu:
        return "; the loader not asked: this is not a Linux machine of its CPU"
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("LD_")}
    result = subprocess.run(["ldd", str(root / name)], capture_output=True, text=True,
                            env=environment)
    if result.returncode != 0:
        raise Refusal(f"ldd cannot read {name}: {result.stderr.strip() or result.stdout.strip()}")
    where = {}
    for line in result.stdout.splitlines():
        match = re.match(r"\s*(\S+) => (.*?)(?: \(0x[0-9a-f]+\))?$", line)
        if match:
            where[match.group(1)] = match.group(2)
    missing = [library for library, place in where.items() if place == "not found"]
    if missing:
        raise Refusal(f"the loader does not find {', '.join(missing)} for {name}")
    for library, inside in own:
        if os.path.realpath(where.get(library, "")) != os.path.realpath(inside):
            raise Refusal(f"the loader finds {library} for {name} at "
                          f"{where.get(library, 'no place')}, not in the runtime")
    return f"; the loader finds {len(where)} libraries, the runtime's in it"


# Packing.

def files_under(root: Path, entries: list) -> list:
    """Every path under ENTRIES of ROOT, sorted, relative to ROOT."""
    paths = []
    for entry in entries:
        top = root / entry
        if not os.path.lexists(top):
            raise Refusal(f"the build lacks {entry}")
        # The directories it is in, which must be directories, not links.
        for parent in list(Path(entry).parents)[:-1]:
            if not stat.S_ISDIR(os.lstat(root / parent).st_mode):
                raise Refusal(f"the build's {parent} is not a directory")
            paths.append(parent)
        paths.append(Path(entry))
        if top.is_dir() and not top.is_symlink():
            for directory, subdirectories, files in os.walk(top):
                subdirectories.sort()
                for name in sorted(subdirectories + files):
                    paths.append((Path(directory) / name).relative_to(root))
    return sorted(set(paths), key=lambda path: path.as_posix())


def within(link: Path, root: Path) -> bool:
    """Whether LINK leads to something that is in ROOT, as the disk says.
An absolute target is the machine's, wherever it leads today."""
    if os.readlink(link).startswith("/"):
        return False
    real = os.path.realpath(link)
    return os.path.exists(link) and os.path.commonpath([real, str(root)]) == str(root)


def extract(tar: tarfile.TarFile, members: list, root: Path) -> None:
    """Write MEMBERS into ROOT, a resolved directory, judging the disk, not names.
Files and directories go first and links last, so nothing is written
through a link of the archive.  Before each, every directory above it must
be a real one as the filesystem sees it, which also catches names that it
takes as the same, such as A and a on macOS, and its own place must be
free.  Then each link must lead to something in ROOT."""
    def place(name: str, directory: bool = False) -> Path:
        path = root
        for part in name.split("/")[:-1]:
            path = path / part
            try:
                mode = os.lstat(path).st_mode
            except FileNotFoundError:
                os.mkdir(path, 0o755)
                continue
            if not stat.S_ISDIR(mode):
                raise Refusal(f"the archive's {name} goes through {path.relative_to(root)}, "
                              "which is not a directory")
        path = path / name.split("/")[-1]
        if os.path.lexists(path) and not (directory and stat.S_ISDIR(os.lstat(path).st_mode)):
            raise Refusal(f"the archive's {name} is already there, under that name or another")
        return path

    directories = []
    for member in members:
        if member.isdir():
            path = place(member.name, directory=True)
            if not os.path.lexists(path):
                os.mkdir(path, 0o755)
            directories.append((path, member))
        elif member.isfile():
            path = place(member.name)
            with tar.extractfile(member) as source, open(path, "xb") as target:
                shutil.copyfileobj(source, target)
            os.chmod(path, member.mode & 0o777)
            os.utime(path, (member.mtime, member.mtime))
    for member in members:
        if member.issym():
            os.symlink(member.linkname, place(member.name))
    for member in members:
        if member.issym() and not within(root / member.name, root):
            raise Refusal(f"the archive links {member.name} to {member.linkname}, "
                          "outside the runtime or to nothing")
    # Deepest first, so that a directory's own mode never stops the next.
    for path, member in reversed(directories):
        os.chmod(path, member.mode & 0o777)
        os.utime(path, (member.mtime, member.mtime))


def pack(build: Path, out: Path, commit: str, tag: str | None, target: str) -> Path:
    given = Path(os.path.abspath(build))
    build = build.resolve()
    spec = TARGETS[target]
    record = read_record(build / "portal-build.eld")
    if tag is not None and tag != f"v{record['version']}":
        raise Refusal(f"the tag {tag} is not the build's version, v{record['version']}")
    for name in spec["required"]:
        if not (build / name).is_file():
            raise Refusal(f"the build lacks {name}")
    # The build's own place, which another machine would not have: no file
    # of the runtime may name it.  A binary's debug map names the objects it
    # was linked from there, which only a debugger reads, so binaries are
    # checked by what they load instead, when unpacked.
    places = sorted({str(place).encode() for directory in (given, build)
                     for place in (directory, directory.parent)}, key=len, reverse=True)
    paths = files_under(build, spec["entries"])
    for path in paths:
        full = build / path
        mode = full.lstat().st_mode
        if stat.S_ISLNK(mode):
            if not within(full, build):
                raise Refusal(f"{path} links to {os.readlink(full)}, outside the runtime "
                              "or to nothing")
        elif stat.S_ISREG(mode):
            if path.as_posix() in spec["binaries"]:
                continue
            data = full.read_bytes()
            for place in places:
                if place in data:
                    raise Refusal(f"{path} names the build's place, {place.decode()}")
        elif not stat.S_ISDIR(mode):
            raise Refusal(f"{path} is neither a file, a directory nor a link")

    manifest = {"format": FORMAT, "tag": tag, "version": record["version"], "commit": commit,
                "identity": record["identity"],
                "archives": [{"target": target, "floor": spec["floor"],
                              "name": "", "size": 0, "sha256": ""}]}
    entry = manifest["archives"][0]
    entry["name"] = archive_name(manifest, target)
    out.mkdir(parents=True, exist_ok=True)
    archive = out / entry["name"]

    def normal(info):
        # Nobody's: the builder's user and group mean nothing elsewhere.
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        return info

    partial = archive.with_name(archive.name + ".partial")
    # Named as the archive, so that gzip's header names the tar in it.
    with partial.open("wb") as stream, \
            tarfile.open(archive.name, "w:gz", fileobj=stream, format=tarfile.PAX_FORMAT) as tar:
        for path in paths:
            tar.add(build / path, arcname=path.as_posix(), recursive=False, filter=normal)
    partial.replace(archive)
    entry["size"] = archive.stat().st_size
    entry["sha256"] = sha256(archive)
    check_manifest(manifest)
    written = out / manifest_name(manifest)
    written.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Packed {len(paths)} paths of {build} into {archive}")
    print(f"  {entry['size']} bytes, SHA-256 {entry['sha256']}")
    print(f"  version {record['version']}, tag {tag or 'none'}, commit {commit}")
    print(f"  identity {record['identity']}")
    print(f"Manifest {written}")
    return written


# Unpacking.

def check_unpacked(destination: Path, archive: Path, manifest: dict, spec: dict,
                   count: int, digest: str) -> None:
    """Check the runtime unpacked in DESTINATION against its MANIFEST."""
    entry = manifest["archives"][0]
    tops = sorted(path.name for path in destination.iterdir())
    wanted = sorted({entry.split("/")[0] for entry in spec["entries"]})
    if tops != wanted:
        raise Refusal(f"{archive.name} holds {', '.join(tops)}, not {', '.join(wanted)}")
    for name in spec["required"]:
        if not (destination / name).is_file():
            raise Refusal(f"{archive.name} lacks {name}")
    record = read_record(destination / "portal-build.eld")
    for key in ("identity", "version"):
        if record[key] != manifest[key]:
            raise Refusal(f"the archive's build record has {key} {record[key]}, "
                          f"not the manifest's {manifest[key]}")
    for name in spec["executables"]:
        if not os.access(destination / name, os.X_OK):
            raise Refusal(f"the archive's {name} is not executable")
    print(f"Unpacked {archive.name} into {destination}: {count} paths, "
          f"SHA-256 {digest}")
    print(f"  version {record['version']}, identity {record['identity']}")
    for name in spec["binaries"]:
        print("  " + check_binary(destination, name, entry["target"]))


def of_runtime(name: str, directory: bool, spec: dict) -> bool:
    """Whether NAME is an entry of the runtime, beneath one, or a directory
an entry is in."""
    return any(name == entry or name.startswith(entry + "/")
               or (directory and entry.startswith(name + "/"))
               for entry in spec["entries"])


def unpack(manifest_path: Path, destination: Path) -> None:
    try:
        manifest = check_manifest(json.loads(manifest_path.read_text()))
    except (OSError, ValueError) as error:
        raise Refusal(f"cannot read the manifest {manifest_path}: {error}")
    if len(manifest["archives"]) != 1:
        raise Refusal("the manifest lists more than one archive; unpack takes one")
    entry = manifest["archives"][0]
    spec = TARGETS[entry["target"]]
    archive = manifest_path.with_name(entry["name"])
    if not archive.is_file():
        raise Refusal(f"no archive {archive} beside the manifest")
    size = archive.stat().st_size
    if size != entry["size"]:
        raise Refusal(f"{archive.name} has {size} bytes, not the manifest's {entry['size']}")
    digest = sha256(archive)
    if digest != entry["sha256"]:
        raise Refusal(f"{archive.name} has SHA-256 {digest}, not the manifest's {entry['sha256']}")
    if destination.exists() and (not destination.is_dir() or any(destination.iterdir())):
        raise Refusal(f"{destination} is not a new or empty directory")

    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        # Names as pack writes them, each once.
        seen = set()
        for member in members:
            name = member.name
            if name.startswith("/") or ".." in name.split("/"):
                raise Refusal(f"{archive.name} holds {name!r}, which is outside the runtime")
            if any(part in ("", ".") for part in name.split("/")):
                raise Refusal(f"{archive.name} holds {name!r}, which is not a plain path")
            if name in seen:
                raise Refusal(f"{archive.name} holds {name!r} twice")
            seen.add(name)
        for member in members:
            if not of_runtime(member.name, member.isdir(), spec):
                raise Refusal(f"{archive.name} holds {member.name!r}, which is not of the runtime")
            if not (member.issym() or member.isfile() or member.isdir()):
                raise Refusal(f"{archive.name} holds {member.name!r}, neither a file, "
                              "a directory nor a link")
        # The outermost directory this makes, to remove on a refusal: the
        # destination was new or empty, so nothing else is in it.
        made = None
        top = destination.absolute()
        while not top.exists():
            made, top = top, top.parent
        destination.mkdir(parents=True, exist_ok=True)
        try:
            extract(tar, members, destination.resolve())
            check_unpacked(destination, archive, manifest, spec, len(members), digest)
        except Refusal:
            if made:
                shutil.rmtree(made)
            else:
                for path in destination.iterdir():
                    if path.is_dir() and not path.is_symlink():
                        shutil.rmtree(path)
                    else:
                        path.unlink()
            raise


def main(arguments: list) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    packing = commands.add_parser("pack", help="tar a tested build and write its manifest")
    packing.add_argument("--tag", help="the release's tag, vX.Y.Z; none outside a release")
    packing.add_argument("--commit", required=True, help="the commit the build is of")
    packing.add_argument("--target", default="macos-arm64", choices=sorted(TARGETS),
                         help="what the build is for: this job's CPU and system")
    packing.add_argument("build", type=Path)
    packing.add_argument("out", type=Path)
    unpacking = commands.add_parser("unpack", help="check an archive and unpack it elsewhere")
    unpacking.add_argument("manifest", type=Path)
    unpacking.add_argument("destination", type=Path)
    options = parser.parse_args(arguments)
    try:
        if options.command == "pack":
            if not re.fullmatch(r"[0-9a-f]{40}", options.commit):
                raise Refusal(f"--commit {options.commit} is not a full commit")
            pack(options.build, options.out, options.commit, options.tag, options.target)
        else:
            unpack(options.manifest, options.destination)
    except Refusal as refusal:
        print(f"runtime-archive: {refusal}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
