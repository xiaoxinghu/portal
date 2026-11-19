#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Print the absolute file name of the Bun that builds Portal's app host.
#
# Tried in order:
#   1. BUN, an explicit choice: if it is unusable, fail instead of replacing it.
#   2. bun on PATH, when it is compatible.
#   3. Portal's pinned Bun (bun.manifest), cached in PORTAL_TOOLS_DIR.
#   4. The pinned Bun downloaded from its official release, verified against
#      the manifest's digest before it runs, then cached.  PORTAL_BUN_DOWNLOAD=0
#      turns downloads off.
# A compatible Bun has Bun.markdown.html and is at least the pinned version.
# Nothing global changes: no shell configuration, no installed Bun.  The
# choice and any fallback are reported on standard error.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
manifest=${PORTAL_BUN_MANIFEST:-$here/bun.manifest}
tools=${PORTAL_TOOLS_DIR:-$here/../build/tools}

say() { printf 'resolve-bun: %s\n' "$*" >&2; }
fail() { say "$*"; exit 1; }

version=$(awk '$1 == "version" { print $2 }' "$manifest")
[ -n "$version" ] || fail "no Bun version in $manifest"

compatible() {
    "$1" -e "if (typeof Bun.markdown?.html !== 'function'
        || !Bun.semver.satisfies(Bun.version, '>=$version')) process.exit(1)" \
        >/dev/null 2>&1
}

describe() { "$1" --version 2>/dev/null || echo "unknown version"; }

use() {
    say "using Bun $(describe "$1") at $1 ($2)"
    printf '%s\n' "$1"
    exit 0
}

if [ -n "${BUN:-}" ]; then
    case $BUN in /*) ;; *) fail "BUN must be an absolute file name: $BUN" ;; esac
    [ -f "$BUN" ] && [ -x "$BUN" ] || fail "BUN is not an executable file: $BUN"
    compatible "$BUN" ||
        fail "BUN=$BUN ($(describe "$BUN")) needs Bun.markdown.html and Bun $version or newer"
    use "$BUN" "BUN"
fi

if found=$(command -v bun 2>/dev/null) && [ -f "$found" ]; then
    if compatible "$found"; then use "$found" "found on PATH"; fi
    say "ignoring $found ($(describe "$found")): Portal needs Bun.markdown.html and Bun $version or newer"
fi

case $(uname -s) in
Darwin)
    # The hardware's architecture, even when this shell runs under Rosetta.
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then
        platform=darwin-aarch64
    elif [ "$(sysctl -n hw.optional.avx2_0 2>/dev/null)" = 1 ]; then
        platform=darwin-x64
    else
        platform=darwin-x64-baseline
    fi
    ;;
Linux)
    # Bun's builds for glibc; its x64 build needs AVX2, the baseline one does not.
    case $(uname -m) in
    aarch64 | arm64) platform=linux-aarch64 ;;
    x86_64 | amd64)
        if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then
            platform=linux-x64
        else
            platform=linux-x64-baseline
        fi
        ;;
    *) fail "Portal's pinned Bun has no download for $(uname -m): install Bun $version or newer, or set BUN" ;;
    esac
    ;;
*) fail "Portal builds only on macOS and Linux" ;;
esac

directory=$tools/bun/$version/$platform
cached=$directory/bun
if [ -x "$cached" ] && compatible "$cached"; then use "$cached" "Portal's cache"; fi

[ "${PORTAL_BUN_DOWNLOAD:-1}" != 0 ] ||
    fail "no compatible Bun, and downloads are off: install Bun $version or newer, or set BUN"
entry=$(awk -v platform="$platform" '$1 == platform { print $2, $3 }' "$manifest")
[ -n "$entry" ] || fail "no Bun download for $platform in $manifest"
url=${entry% *}
digest=${entry#* }

mkdir -p "$directory" || fail "cannot create $directory"
# Work beside the cache entry, so publishing it is an atomic rename.
work=$(mktemp -d "$directory/.download.XXXXXX")
trap 'rm -rf "$work"' EXIT
say "downloading Bun $version for $platform from $url"
curl -fsSL --proto '=https,file' --retry 2 -o "$work/bun.zip" "$url" ||
    fail "could not download $url"
# macOS has shasum, and Linux sha256sum without it more often than not.
if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$work/bun.zip" | awk '{ print $1 }')
else
    actual=$(sha256sum "$work/bun.zip" | awk '{ print $1 }')
fi
[ "$actual" = "$digest" ] ||
    fail "$url has SHA-256 $actual, not the expected $digest; nothing was cached"
unzip -q "$work/bun.zip" -d "$work/unpacked" || fail "could not unpack $url"
bun=$(find "$work/unpacked" -type f -name bun | head -n 1)
[ -n "$bun" ] || fail "$url contains no bun executable"
chmod +x "$bun"
compatible "$bun" || fail "the Bun from $url does not run on this machine"
mv -f "$bun" "$cached"
use "$cached" "downloaded"
