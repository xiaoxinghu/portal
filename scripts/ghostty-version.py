#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""How far Portal's Ghostty is from a Rex server's, and a bump of the pin.

Usage:
  scripts/ghostty-version.py [report] [--offline] [--package DIR] [--ghostty DIR] [--rex PATH]
  scripts/ghostty-version.py bump [VERSION] [--offline] [--package DIR]

report prints Portal's Ghostty, the newest release, the installed Rex
server's Ghostty and how far each release's Ghostty is from the server's, then
one line of verdict.  On macOS Portal's Ghostty is that of the libghostty-spm
release native/libghostty-spm.json pins and the server is in Rex's bundle; on
Linux it is the Ghostty native/ghostty.json pins, the newest release Ghostty's,
and the server is rex on PATH.  It changes nothing.  It reads what is on disk
first and asks the network only for what is missing, never with --offline, and
says what it could not find out.

bump moves the pin to VERSION, or to the newest release, refreshes
native/Package.resolved, and names the patches under
native/patches/libghostty-spm/ that no longer apply.  It does not commit and
runs no checks; it ends by naming them.

--package and $PORTAL_LIBGHOSTTY_SPM_CLONE name a clone of libghostty-spm;
--ghostty and $PORTAL_GHOSTTY_CLONE a clone of Ghostty, for counting commits;
--rex and $PORTAL_REX_SERVER the Rex server's executable.
"""
import argparse
import datetime
import json
import mmap
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
# Relative to a checkout of Portal.
PIN = Path("native/libghostty-spm.json")
LINUX_PIN = Path("native/ghostty.json")
PATCHES = Path("native/patches/libghostty-spm")
RESOLVED = Path("native/Package.resolved")
COPY = Path("build/libghostty-spm")
REPAIR = Path("build/libghostty-spm-bump")
GHOSTTY_REPO = "ghostty-org/ghostty"
GHOSTTY_URL = f"https://github.com/{GHOSTTY_REPO}.git"
# The Go bindings a Linux Rex server builds its Ghostty with.
GO_MODULE = "go.mitchellh.com/libghostty"
REX_SERVERS = [
    Path.home() / "Library/Application Support/com.superlogical.rex/RexServer/Versions/Current"
    / "Rex Server.app/Contents/MacOS/rex",
    Path("/Applications/Rex Server.app/Contents/MacOS/rex"),
]
NETWORK_TIMEOUT = 20

# ---------------------------------------------------------------------------
# Parsing: pure functions over what the package, Git and the server give.

RELEASE = re.compile(r"^\d+(?:\.\d+)+$")
# Ghostty's own releases, as native/ghostty.json pins them; vt-* tags are
# libghostty-vt's.
GHOSTTY_RELEASE = re.compile(r"^v\d+\.\d+\.\d+$")
LIB_VT_TAG = "vt-"
COMMIT = re.compile(r"^[0-9a-f]{7,40}$")


def parse_ghostty_ref(text):
    """The Ghostty commit a release's Ghostty.ref names, or None."""
    ref = text.strip()
    return ref if COMMIT.match(ref) else None


def parse_binary_target(package_swift):
    """The binaryTarget of a libghostty-spm Package.swift: its url, checksum, and
    the Ghostty commit its upstream.<commit> tag names, or None for each not found."""
    target = re.search(r"\.binaryTarget\s*\((.*?)\)", package_swift, re.S)
    if not target:
        return None
    body = target.group(1)
    url = re.search(r'url:\s*"([^"]+)"', body)
    checksum = re.search(r'checksum:\s*"([^"]+)"', body)
    commit = re.search(r"/upstream\.([0-9a-f]{7,40})(?:-\d+)?/", url.group(1)) if url else None
    return {"url": url and url.group(1), "checksum": checksum and checksum.group(1),
            "commit": commit and commit.group(1)}


def release_key(name):
    return tuple(int(part) for part in name.removeprefix("v").split("."))


def releases(tags, pattern=RELEASE):
    """The release names among TAGS, oldest first.  Tags named upstream.* hold the
    prebuilt library and others, such as storage.*, are not releases either."""
    return sorted((tag for tag in tags if pattern.match(tag)), key=release_key)


def parse_ls_remote(text):
    """Tag name to commit from `git ls-remote --tags` or `git show-ref --tags -d`:
    an annotated tag's peeled commit wins over the tag object."""
    tags = {}
    peeled = set()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 2 or not parts[1].startswith("refs/tags/"):
            continue
        sha, name = parts[0], parts[1][len("refs/tags/"):]
        if name.endswith("^{}"):
            name = name[:-3]
            tags[name] = sha
            peeled.add(name)
        elif name not in peeled:
            tags[name] = sha
    return tags


def parse_library_version(version):
    """The Ghostty commit in a library_version such as 1.1.0-dev+5813c9461."""
    match = re.match(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+([0-9a-f]{7,40})$", version.strip())
    return match.group(1) if match else None


def parse_library_release(version):
    """The libghostty-vt release a library_version such as 1.0.1 names, or None.
    Ghostty's build gives a version without -dev and without a commit only to a
    build of the tag vt-<version>, or of the source tarball made from it."""
    version = version.strip()
    return version if re.match(r"^\d+\.\d+\.\d+$", version) else None


def find_go_module(data, module=GO_MODULE):
    """The version of MODULE in a Go binary's build information, or None."""
    match = re.search(rb"(?:^|\n)dep\t" + re.escape(module.encode()) + rb"\t(v[0-9A-Za-z.+-]{1,100})\t",
                      data)
    return match.group(1).decode("ascii") if match else None


def pseudo_version_date(version):
    """The commit date a Go pseudo-version such as v0.0.0-20261107144202-b13f277ddcb2
    records, in UTC, or None for a tagged version."""
    match = re.search(r"(?:^|[.-])(\d{14})-[0-9a-f]{12}(?:\+incompatible)?$", version)
    if not match:
        return None
    return datetime.datetime.strptime(match.group(1), "%Y%m%d%H%M%S").replace(
        tzinfo=datetime.timezone.utc)


def find_library_version(data):
    """The library_version string in a binary's bytes (Ghostty's build record), or None."""
    match = re.search(rb'"library_version"\s*:\s*"([^"]{1,100})"', data)
    return match.group(1).decode("ascii", "replace") if match else None


def same_commit(a, b):
    return bool(a and b) and (a.startswith(b) or b.startswith(a))


# ---------------------------------------------------------------------------
# Distance and verdict.

class Distance:
    """How a Ghostty stands against the server's: COMMITS the server's has that it
    lacks and EXTRA it has that the server's lacks, counted; or only DAYS older
    (negative: newer) when nothing could count commits."""

    def __init__(self, missing=None, extra=None, days=None, source=None):
        self.missing, self.extra, self.days, self.source = missing, extra, days, source

    @property
    def counted(self):
        return self.missing is not None

    def covers(self):
        """True when it has every commit of the server's, False when it lacks
        some, None when that is not known."""
        if self.counted:
            return self.missing == 0
        if self.days is not None and self.days > 0:
            return False
        return None

    def describe(self, what):
        if self.counted:
            if self.missing == 0 and self.extra == 0:
                return f"{what} is the server's"
            parts = []
            if self.missing:
                parts.append(f"lacks {plural(self.missing, 'commit')} of the server's")
            if self.extra:
                parts.append(f"has {plural(self.extra, 'commit')} the server's lacks")
            return f"{what} {' and '.join(parts)} ({self.source})"
        if self.days is not None:
            if self.days == 0:
                when = "is from the same day as the server's"
            elif self.days > 0:
                when = f"is {plural(self.days, 'day')} older than the server's"
            else:
                when = f"is {plural(-self.days, 'day')} newer than the server's"
            return f"{what} {when} (by date; no commit count)"
        return None

    def lacking(self):
        """What it lacks of the server's, for a verdict."""
        if self.counted and self.missing:
            return f"lacks {plural(self.missing, 'commit')} of the Rex server's"
        if self.days:
            return f"is {plural(self.days, 'day')} older than the Rex server's"
        return "lacks some of the Rex server's"


def plural(count, word):
    return f"{count} {word}" if count == 1 else f"{count} {word}s"


def verdict(pin, newest, server, pin_distance, newest_distance, server_found=None):
    """One line: PIN and NEWEST are release names (NEWEST None when unknown),
    SERVER the server's Ghostty commit or None, the distances Distance or None.
    SERVER_FOUND is whether a Rex server is installed, when SERVER is None."""
    newer = newest if newest and release_key(newest) > release_key(pin) else None
    if server is None and server_found:
        tail = f" A newer release exists: {newer}." if newer else ""
        return f"Unknown: the Rex server's Ghostty could not be read.{tail}"
    if server is None:
        if newest is None:
            return "Unknown: neither the newest release nor a Rex server could be found."
        if newer:
            return f"A newer release exists: {newer}. No Rex server was found to compare with."
        return "Up to date with the newest release. No Rex server was found to compare with."
    pin_covers = pin_distance.covers() if pin_distance else None
    newest_covers = newest_distance.covers() if newest_distance else None
    if pin_covers:
        return "Up to date: Portal's Ghostty has every commit of the Rex server's."
    if pin_covers is None:
        tail = f" A newer release exists: {newer}." if newer else ""
        return f"Unknown: could not tell whether Portal's Ghostty has the Rex server's.{tail}"
    if newer:
        if newest_covers:
            return (f"A newer release exists: bump to {newer}, whose Ghostty has every commit "
                    "of the Rex server's.")
        if newest_covers is None:
            return (f"A newer release exists: {newer}; whether its Ghostty has the Rex server's "
                    "is unknown.")
        return (f"The newest release is still behind the server: {newer} is newer than the pin, "
                f"but its Ghostty {newest_distance.lacking()}.")
    if newest is None:
        return (f"Behind the server: Portal's Ghostty {pin_distance.lacking()}, and the newest "
                "release is unknown.")
    return (f"The newest release is still behind the server: Portal pins it, and its Ghostty "
            f"{pin_distance.lacking()}.")


# ---------------------------------------------------------------------------
# Sources: a clone on disk first, then the network unless offline.

def run(args, cwd=None, env=None, timeout=None):
    try:
        result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True,
                                timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None


def git(directory, *args, timeout=None):
    return run(["git", "-C", str(directory), *args], timeout=timeout)


def is_clone(directory):
    return bool(directory) and Path(directory).is_dir() and git(directory, "rev-parse", "--git-dir") is not None


def fetch_url(url):
    """The body at URL, or None: curl, so that the system's certificates are used."""
    return run(["curl", "-fsSL", "-m", str(NETWORK_TIMEOUT), "-H", "User-Agent: portal-ghostty-version",
                url], timeout=NETWORK_TIMEOUT + 5)


def github_path(url):
    """owner/repo of a GitHub URL, or None."""
    match = re.match(r"^https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?$", url)
    return match.group(1) if match else None


class Tags:
    """A repository's tags: from the network unless offline, else from a clone."""

    def __init__(self, url, clone=None, offline=False):
        self.url, self.offline = url, offline
        self.clone = clone if is_clone(clone) else None
        self._tags = None
        self.tag_source = None

    def tags(self):
        """Tag name to commit, or None when no source answered."""
        if self._tags is None:
            if not self.offline:
                text = run(["git", "ls-remote", "--tags", self.url], timeout=NETWORK_TIMEOUT)
                if text:
                    self._tags, self.tag_source = parse_ls_remote(text), self.url
            if self._tags is None and self.clone:
                text = git(self.clone, "show-ref", "--tags", "-d")
                if text:
                    self._tags = parse_ls_remote(text)
                    self.tag_source = f"the clone at {self.clone}, as last fetched"
        return self._tags

    def missing(self, what):
        """Why TAGS gave nothing, for a line of what could not be found out."""
        return (f"no clone of {what}" + ("" if self.offline else " and no answer from the network"))


class Package(Tags):
    """libghostty-spm's tags and files at a ref: from a clone, the build's patched
    copy (for the pinned revision only) and the network."""

    def __init__(self, url, clone=None, copy=None, offline=False):
        super().__init__(url, clone, offline)
        self.copy = copy if is_clone(copy) else None

    def file(self, ref, path, revision=None):
        """PATH at REF (a tag, or REVISION for the build's copy), or None."""
        for directory, at in ((self.clone, ref), (self.copy, revision)):
            if directory and at:
                text = git(directory, "show", f"{at}:{path}")
                if text is not None:
                    return text
        repo = github_path(self.url)
        if repo and not self.offline:
            return fetch_url(f"https://raw.githubusercontent.com/{repo}/{ref}/{path}")
        return None


class Ghostty:
    """Ghostty commits' dates and distances: from a clone, else GitHub's API."""

    def __init__(self, clone=None, offline=False):
        self.clone = clone if is_clone(clone) else None
        self.offline = offline

    def _resolve(self, commit):
        if self.clone:
            full = git(self.clone, "rev-parse", "--verify", "--quiet", f"{commit}^{{commit}}")
            if full:
                return full.strip()
        return None

    def _api(self, path):
        if self.offline:
            return None
        text = fetch_url(f"https://api.github.com/repos/{GHOSTTY_REPO}/{path}")
        try:
            return json.loads(text) if text else None
        except ValueError:
            return None

    def date(self, commit):
        """The commit's date as a datetime, or None."""
        full = self._resolve(commit)
        if full:
            text = git(self.clone, "show", "-s", "--format=%cI", full)
            if text:
                return datetime.datetime.fromisoformat(text.strip())
        data = self._api(f"commits/{commit}")
        try:
            stamp = data["commit"]["committer"]["date"]
        except (TypeError, KeyError):
            return None
        return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))

    def distance(self, commit, server, dates=None):
        """A Distance from COMMIT to the server's commit SERVER."""
        if same_commit(commit, server):
            return Distance(0, 0, source="the same commit")
        mine, theirs = self._resolve(commit), self._resolve(server)
        # A shallow clone counts from its cut, not from where the two histories meet.
        shallow = self.clone and (git(self.clone, "rev-parse", "--is-shallow-repository")
                                  or "").strip() == "true"
        if mine and theirs and not shallow:
            text = git(self.clone, "rev-list", "--left-right", "--count", f"{mine}...{theirs}")
            if text:
                extra, missing = (int(n) for n in text.split())
                return Distance(missing, extra, source="counted in the Ghostty clone")
        data = self._api(f"compare/{commit}...{server}")
        if isinstance(data, dict) and "ahead_by" in data:
            return Distance(data["ahead_by"], data["behind_by"], source="counted by GitHub")
        if dates and dates.get(commit) and dates.get(server):
            return Distance(days=(dates[server] - dates[commit]).days)
        return Distance()


def read_pin(root):
    return json.loads((root / PIN).read_text())


def write_pin(root, pin):
    (root / PIN).write_text(json.dumps(pin, indent="\t") + "\n")


def release_ghostty(package, version, revision=None):
    """The Ghostty commit of a release, and a note when its two records disagree.
    The binaryTarget's commit wins: that is the library Portal links."""
    ref_text = package.file(version, "Ghostty.ref", revision)
    manifest = package.file(version, "Package.swift", revision)
    from_ref = parse_ghostty_ref(ref_text) if ref_text else None
    target = parse_binary_target(manifest) if manifest else None
    from_target = target and target["commit"]
    note = None
    if from_ref and from_target and not same_commit(from_ref, from_target):
        note = (f"{version}'s Ghostty.ref names {from_ref[:12]} but its binaryTarget "
                f"upstream.{from_target}")
    return from_target or from_ref, note


def find_rex(explicit=None, platform="macos", search=None):
    """The Rex server's executable: EXPLICIT, else rex on SEARCH (PATH) on Linux or
    in Rex's bundle on macOS, or None."""
    if explicit:
        candidates = [Path(explicit)]
    elif platform == "linux":
        found = shutil.which("rex", path=search)
        candidates = [Path(found)] if found else []
    else:
        candidates = REX_SERVERS
    for path in candidates:
        if path.is_file():
            return path
    return None


def rex_version(executable):
    """The Rex server's own version, such as rex 0.1.0-preview.14, or None."""
    text = run([str(executable), "version"], timeout=10)
    if text and text.strip():
        return text.splitlines()[0].strip()
    plist = executable.parent.parent / "Info.plist"
    text = run(["plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", str(plist)])
    return f"rex {text.strip()}" if text else None


def rex_library_version(executable):
    """library_version and the version of the Go module GO_MODULE from the server's
    binary, as nothing the server answers gives them, and why the first is None
    when it is."""
    try:
        with open(executable, "rb") as handle, \
                mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
            found, module = find_library_version(data), find_go_module(data)
    except (OSError, ValueError) as error:
        return None, None, f"cannot read it: {getattr(error, 'strerror', None) or error}"
    return found, module, None if found else "no library_version in it"


# ---------------------------------------------------------------------------
# report

def short(commit):
    return commit[:12] if commit else "unknown"


def day(date):
    """The date in UTC, the one zone both a clone and GitHub give."""
    return date.astimezone(datetime.timezone.utc).date().isoformat() if date else "date unknown"


class Own:
    """Portal's Ghostty and the newest release's: release names, as the pin and the
    tags spell them, their Ghostty commits, and how a row names a release."""

    def __init__(self, pin, pin_commit, newest, newest_commit, name):
        self.pin, self.pin_commit = pin, pin_commit
        self.newest, self.newest_commit = newest, newest_commit
        self.name = name


def macos_ghostty(args, unknown, notes):
    """Own on macOS: the libghostty-spm release the pin names and the newest one."""
    pin = read_pin(args.root)
    package = Package(pin["url"], args.package, args.root / COPY, args.offline)

    pin_commit, note = release_ghostty(package, pin["version"], pin["revision"])
    notes += [note] if note else []
    if not pin_commit:
        unknown.append(f"the Ghostty of the pinned release {pin['version']}")

    tags = package.tags()
    newest = releases(tags)[-1] if tags and releases(tags) else None
    newest_commit = None
    if newest is None:
        unknown.append("the newest release: no release among libghostty-spm's tags" if tags else
                       "the newest release: " + package.missing("libghostty-spm"))
    elif newest == pin["version"]:
        newest_commit = pin_commit
    else:
        newest_commit, note = release_ghostty(package, newest)
        notes += [note] if note else []
        if not newest_commit:
            unknown.append(f"the Ghostty of the newest release {newest}")
        elif same_commit(newest_commit, pin_commit):
            notes.append(f"{newest} ships the same Ghostty as the pin")
    if tags and package.tag_source and package.tag_source != pin["url"]:
        notes.append(f"Releases read from {package.tag_source}")
    return Own(pin["version"], pin_commit, newest, newest_commit,
               lambda version: f"libghostty-spm {version}")


def linux_ghostty(args, ghostty_tags, unknown, notes):
    """Own on Linux: the Ghostty native/ghostty.json pins, whose revision is its
    commit, and Ghostty's newest release."""
    pin = json.loads((args.root / LINUX_PIN).read_text())
    tags = ghostty_tags.tags()
    known = releases(tags, GHOSTTY_RELEASE) if tags else []
    newest = known[-1] if known else None
    newest_commit = None
    if newest is None:
        unknown.append("the newest release: no release among Ghostty's tags" if tags else
                       "the newest release: " + ghostty_tags.missing("Ghostty"))
    elif newest == pin["version"]:
        newest_commit = pin["revision"]
    else:
        newest_commit = tags[newest]
    if tags and ghostty_tags.tag_source and ghostty_tags.tag_source != GHOSTTY_URL:
        notes.append(f"Releases read from {ghostty_tags.tag_source}")
    return Own(pin["version"], pin["revision"], newest, newest_commit,
               lambda version: f"Ghostty {version}")


def server_ghostty(version, ghostty_tags):
    """The Ghostty commit a server's library_version VERSION names, how it was
    found, and why it is None when it is."""
    commit = parse_library_version(version)
    if commit:
        return commit, None, None
    release = parse_library_release(version)
    if not release:
        return None, None, f"no commit in {version}"
    tag = LIB_VT_TAG + release
    tags = ghostty_tags.tags()
    if tags and tag in tags:
        return tags[tag], f"its library_version {version} is libghostty-vt's release, the tag {tag}", None
    why = f"Ghostty has no tag {tag}" if tags else ghostty_tags.missing("Ghostty")
    return None, None, f"{version} is libghostty-vt's release {tag}, whose commit is unknown: {why}"


def report(args):
    unknown = []
    notes = []
    ghostty = Ghostty(args.ghostty, args.offline)
    ghostty_tags = Tags(GHOSTTY_URL, args.ghostty, args.offline)
    if args.platform == "linux":
        own = linux_ghostty(args, ghostty_tags, unknown, notes)
    else:
        own = macos_ghostty(args, unknown, notes)

    executable = find_rex(args.rex, args.platform)
    server_version = server_commit = server_rex = module = None
    if executable is None:
        where = (args.rex or ("no rex on PATH" if args.platform == "linux" else
                              " or ".join(str(p) for p in REX_SERVERS)))
        notes.append(f"Rex server not found: {where}" if where == "no rex on PATH" else
                     f"Rex server not found at {where}")
    else:
        server_rex = rex_version(executable)
        server_version, module, why = rex_library_version(executable)
        if server_version:
            server_commit, how, why = server_ghostty(server_version, ghostty_tags)
            notes += [f"The Rex server's Ghostty: {how}"] if how else []
        if not server_commit:
            unknown.append(f"the Ghostty of the Rex server at {executable}: {why}")

    commits = [c for c in (own.pin_commit, own.newest_commit, server_commit) if c]
    dates = {c: ghostty.date(c) for c in dict.fromkeys(commits)}
    for commit, date in dates.items():
        if date is None:
            unknown.append(f"the date of Ghostty {short(commit)}")

    rows = [("Portal's pin", own.name(own.pin), own.pin_commit)]
    if own.newest:
        same = " (the pin)" if own.newest == own.pin else ""
        rows.append(("Newest release", own.name(own.newest) + same, own.newest_commit))
    if server_commit or executable:
        label = server_rex or "rex"
        rows.append(("Rex server", f"{label} ({server_version or 'no library_version'})",
                     server_commit))
    width = max(len(r[1]) for r in rows)
    for name, what, commit in rows:
        when = f" of {day(dates.get(commit))}" if commit else ""
        print(f"{name + ':':16}{what:{width}}  Ghostty {short(commit):<12}{when}")

    pin_distance = newest_distance = None
    lines = []
    if server_commit:
        if own.pin_commit:
            pin_distance = ghostty.distance(own.pin_commit, server_commit, dates)
        if own.newest_commit:
            newest_distance = (pin_distance if own.newest_commit == own.pin_commit
                               else ghostty.distance(own.newest_commit, server_commit, dates))
        compared = [("Portal's Ghostty", own.pin_commit, pin_distance)]
        if own.newest and own.newest != own.pin:
            compared.append(("The newest release's Ghostty", own.newest_commit, newest_distance))
        for what, commit, distance in compared:
            line = distance.describe(what) if distance else None
            if line:
                lines.append(line + ".")
            elif commit:
                unknown.append(f"how far {what[0].lower() + what[1:]} is from the server's: "
                               "no Ghostty clone, no answer from GitHub and no dates")
    elif executable and module:
        lines.append(module_line(module, dates.get(own.pin_commit)))
    if lines:
        print()
        print("\n".join(lines))

    print()
    print("Verdict: " + verdict(own.pin, own.newest, server_commit, pin_distance, newest_distance,
                                executable is not None))
    for note in notes:
        print(f"Note: {note}.")
    for item in unknown:
        print(f"Could not find out {item}.")
    return 0


def module_line(module, pin_date):
    """One line on the date of the server's Go module, against that of Portal's
    Ghostty, when the server's Ghostty is unknown."""
    date = pseudo_version_date(module)
    head = f"The Rex server's Go module {GO_MODULE} is {module}"
    if date is None:
        return head + ", which has no date."
    if pin_date is None:
        return f"{head}, of {day(date)}; Portal's Ghostty's date is unknown."
    days = (date.date() - pin_date.astimezone(datetime.timezone.utc).date()).days
    when = ("the same day as" if days == 0 else
            f"{plural(abs(days), 'day')} {'after' if days > 0 else 'before'}")
    return (f"{head}, of {day(date)}, {when} Portal's Ghostty of {day(pin_date)}; "
            "a module's date does not date the Ghostty it builds.")


# ---------------------------------------------------------------------------
# bump

def git_in(work):
    """Git in WORK, with signing and hooks off, as the build's patch step has it."""
    def quiet(*args):
        return subprocess.run(["git", "-C", str(work), "-c", "user.name=Portal",
                               "-c", "user.email=portal@invalid", "-c", "commit.gpgsign=false",
                               "-c", "core.hooksPath=/dev/null", *args],
                              capture_output=True, text=True)
    return quiet


def checkout(source, version, revision, work):
    """WORK, a new repository holding VERSION fetched from SOURCE, checked out."""
    quiet = git_in(work)
    subprocess.run(["git", "init", "-q", str(work)], check=True)
    fetched = quiet("fetch", "-q", "--depth", "1", source, f"refs/tags/{version}")
    if fetched.returncode != 0:
        raise SystemExit(f"ghostty-version: cannot fetch libghostty-spm {version} from {source}: "
                         f"{fetched.stderr.strip()}")
    head = quiet("rev-parse", "FETCH_HEAD^{commit}").stdout.strip()
    if head != revision:
        raise SystemExit(f"ghostty-version: libghostty-spm's tag {version} is {head}, not {revision}")
    quiet("checkout", "-q", "--detach", head)
    return quiet


def try_patches(source, version, revision, patches, work):
    """Fetch VERSION from SOURCE into WORK and apply each patch in name order,
    skipping one that fails.  Returns the names that did not apply."""
    quiet = checkout(source, version, revision, work)
    failed = []
    for patch in sorted(patches.glob("*.patch")):
        if quiet("am", "-q", "--committer-date-is-author-date", str(patch)).returncode != 0:
            quiet("am", "--abort")
            failed.append(patch.name)
    return failed


def repair_checkout(source, version, revision, patches, work):
    """WORK, VERSION with the patches applied by one `git am` that stops at the
    first that fails, to fix there and continue.  One for the same revision is
    kept, with the work done in it.  Returns whether it was kept."""
    record = work / ".git" / "portal-bump"
    if record.is_file() and record.read_text().strip() == revision:
        return True
    shutil.rmtree(work, ignore_errors=True)
    quiet = checkout(source, version, revision, work)
    record.write_text(revision + "\n")
    quiet("am", "-q", "--3way", "--committer-date-is-author-date",
          *[str(patch) for patch in sorted(patches.glob("*.patch"))])
    return False


def resolve(root, copy, scratch, offline=False):
    """Refresh ROOT's native/Package.resolved against COPY.  Returns an error or None."""
    if offline:
        # SwiftPM fetches the wrapper's dependencies and its prebuilt library.
        return "--offline, and resolving fetches the wrapper's dependencies"
    if not (root / "native" / "Package.swift").is_file():
        return "no native/Package.swift"
    if shutil.which("xcrun") is None:
        return "xcrun not found"
    env = {**os.environ, "PORTAL_LIBGHOSTTY_SPM": str(copy)}
    include = root / "build" / "emacs-include.txt"
    if "EMACS_INCLUDE" not in env and not include.exists():
        # The manifest wants it; resolving reads no header.
        env["EMACS_INCLUDE"] = str(scratch)
    result = subprocess.run(["xcrun", "swift", "package", "resolve", "--package-path",
                             str(root / "native"), "--scratch-path", str(scratch)],
                            env=env, capture_output=True, text=True)
    if result.returncode != 0:
        lines = (result.stderr or result.stdout).strip().splitlines()
        return lines[-1] if lines else "swift package resolve failed"
    return None


def bump(args):
    root = args.root
    pin = read_pin(root)
    package = Package(pin["url"], args.package, None, args.offline)
    tags = package.tags()
    if not tags:
        raise SystemExit("ghostty-version: cannot read libghostty-spm's tags: no network and no clone")
    known = releases(tags)
    version = args.version or (known[-1] if known else None)
    if version is None:
        raise SystemExit("ghostty-version: libghostty-spm has no release tags")
    if version not in tags or not RELEASE.match(version):
        raise SystemExit(f"ghostty-version: {version} is not a release of libghostty-spm; "
                         f"the newest is {known[-1] if known else 'unknown'}")
    if not args.version and release_key(version) < release_key(pin["version"]):
        raise SystemExit(f"ghostty-version: the pin, {pin['version']}, is newer than the newest "
                         f"release found, {version}")
    revision = tags[version]
    # Pinned already, perhaps by a bump that stopped short: check the patches and
    # resolve again all the same.
    already = version == pin["version"] and revision == pin["revision"]

    old_commit, _ = release_ghostty(package, pin["version"])
    new_commit, _ = release_ghostty(package, version)
    source = package.clone if package.clone and version in parse_ls_remote(
        git(package.clone, "show-ref", "--tags", "-d") or "") else pin["url"]

    with tempfile.TemporaryDirectory(prefix="portal-bump-") as temporary:
        copy = Path(temporary) / "libghostty-spm"
        failed = try_patches(source, version, revision, root / PATCHES, copy)
        if not already:
            write_pin(root, {**pin, "version": version, "revision": revision})
        repair = root / REPAIR
        kept = failed and repair_checkout(source, version, revision, root / PATCHES, repair)
        resolved = root / RESOLVED
        before = resolved.read_text() if resolved.exists() else None
        error = resolve(root, copy, Path(temporary) / "swift", args.offline)
        after = resolved.read_text() if resolved.exists() else None

    if already:
        print(f"The pin is already libghostty-spm {version} (Ghostty {short(new_commit)}); "
              "checked its patches and resolved again.")
    else:
        print(f"Moved the pin from libghostty-spm {pin['version']} (Ghostty {short(old_commit)}) "
              f"to {version} (Ghostty {short(new_commit)}), revision {revision}.")
    if error:
        print(f"Did not refresh native/Package.resolved: {error}. Configuring resolves it.")
    else:
        print("native/Package.resolved " + ("updated." if before != after else "unchanged."))
    count = len(list((root / PATCHES).glob("*.patch")))
    if failed:
        for name in failed:
            print(f"Does not apply to {version}: native/patches/libghostty-spm/{name}")
    else:
        print(f"The one patch applies to {version}." if count == 1 else
              f"All {count} patches apply to {version}." if count else "There are no patches.")
    if failed:
        print(f"{REPAIR} holds {version} with the patches applied up to the first that fails, "
              "where git am stopped" + (", kept from an earlier bump." if kept else "."))
    print()
    print("Nothing is committed. Next:")
    steps = []
    if failed:
        steps += [
            f"fix that patch in {REPAIR}: resolve, git add, git am --continue; then each "
            "next one that stops",
            "write the set back: rm native/patches/libghostty-spm/*.patch; "
            f"git -C {REPAIR} format-patch --zero-commit --no-signature "
            f"-o \"$PWD/native/patches/libghostty-spm\" {revision}",
            f"scripts/ghostty-version.py bump {version}, to check they apply",
        ]
    steps += [
        "./build.sh, which configures and remakes the patched copy",
        "update the release and Ghostty versions in docs/terminals.md",
        "scripts/ghostty-version.py, to see where the new pin stands",
        "the default loop in CONTRIBUTING.md, then the full set before merging",
    ]
    for number, step in enumerate(steps, 1):
        print(f"  {number}. {step}")
    return 1 if failed else 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="ghostty-version.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("command", nargs="?", default="report", choices=["report", "bump"])
    parser.add_argument("version", nargs="?", help="bump: the release to pin; the newest if omitted")
    parser.add_argument("--offline", action="store_true", help="use only what is on disk")
    parser.add_argument("--package", default=os.environ.get("PORTAL_LIBGHOSTTY_SPM_CLONE"),
                        help="a clone of libghostty-spm")
    parser.add_argument("--ghostty", default=os.environ.get("PORTAL_GHOSTTY_CLONE"),
                        help="a clone of Ghostty")
    parser.add_argument("--rex", default=os.environ.get("PORTAL_REX_SERVER"),
                        help="the Rex server's executable")
    # A checkout of Portal other than this one, for the tests.
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    # The platform whose Ghostty and server the report reads, for the tests.
    parser.add_argument("--platform", choices=["macos", "linux"], help=argparse.SUPPRESS,
                        default="linux" if sys.platform.startswith("linux") else "macos")
    args = parser.parse_args(argv)
    # Absolute, as Git runs some commands from elsewhere, such as a scratch repository.
    for name in ("package", "ghostty", "rex"):
        if getattr(args, name):
            setattr(args, name, os.path.abspath(getattr(args, name)))
    args.root = args.root.resolve()
    if args.command == "report":
        if args.version:
            parser.error("report takes no version")
        return report(args)
    return bump(args)


if __name__ == "__main__":
    sys.exit(main())
