#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: build-ghostty-linux.sh [--optimize MODE] [--prefix DIR]
#                               [--pin FILE] [--patches DIR] [--source DIR]
#
# Build Ghostty's embedding library for Linux with Portal's patches, with Zig.
# Run with no arguments from a clean checkout, it leaves in build/ghostty-linux:
#
#   lib/libghostty.so      the library, by its soname (a link to ghostty-internal.so)
#   include/ghostty.h      its header, with the Linux platform the patches add
#   share/ghostty          the resources, for GHOSTTY_RESOURCES_DIR
#   share/terminfo         found by Ghostty beside them
#
# --pin names a JSON file holding Ghostty's url, the version tag and that tag's
# revision (native/ghostty.json).  --source (build/ghostty) becomes a copy of
# that source with every --patches/*.patch (native/patches/ghostty) applied in
# name order, one commit each.  A copy made from the same pin, patches and
# script is kept, with any changes made in it since, so a patch can be developed
# there; anything else is replaced.  A patch that does not apply fails the build.
# This is the shape of patch-libghostty-spm.sh, which reads its pin with macOS's
# plutil and so cannot be this script's first half.
#
# --optimize is Zig's mode: ReleaseFast (the default) or Debug, which checks
# every page of a terminal after each change and is too slow for real output.
# ReleaseSafe is not offered: at this pin glibc's fortified ptsname_r does not
# get through Zig's translation of C.  --prefix is where the build is
# installed.  Zig's cache is beside the source copy, in SOURCE-cache, and
# outlives it.
#
# $ZIG names the Zig to use when it is not `zig` on PATH: the version the
# source's build.zig.zon asks for.  $PORTAL_GHOSTTY_CLONE names a local clone
# of Ghostty to fetch the tag from in place of the pin's url.
set -eu

me=build-ghostty-linux
root=$(cd "$(dirname "$0")/.." && pwd)
pin=$root/native/ghostty.json
patches=$root/native/patches/ghostty
dest=$root/build/ghostty
prefix=$root/build/ghostty-linux
optimize=ReleaseFast

while [ "$#" -gt 0 ]; do
    case $1 in
    --pin | --patches | --source | --prefix | --optimize)
        if [ "$#" -lt 2 ]; then
            echo "$me: $1 needs a value" >&2
            exit 2
        fi
        case $1 in
        --pin) pin=$2 ;;
        --patches) patches=$2 ;;
        --source) dest=$2 ;;
        --prefix) prefix=$2 ;;
        --optimize) optimize=$2 ;;
        esac
        shift 2
        ;;
    *)
        echo "usage: $0 [--optimize MODE] [--prefix DIR] [--pin FILE] [--patches DIR] [--source DIR]" >&2
        exit 2
        ;;
    esac
done

case $optimize in
Debug | ReleaseFast) ;;
*)
    echo "$me: --optimize is Debug or ReleaseFast, not $optimize" >&2
    exit 2
    ;;
esac

# Zig runs in the source copy: a relative path must not start there.
absolute() {
    case $1 in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}
dest=$(absolute "$dest")
prefix=$(absolute "$prefix")

if [ "$(uname -s)" != Linux ]; then
    echo "$me: builds Ghostty's library for Linux, on Linux; on macOS Portal uses libghostty-spm" >&2
    exit 1
fi

# The pin is one "name": "value" pair a line.
field() {
    value=$(sed -n 's/^[[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pin")
    if [ -z "$value" ]; then
        echo "$me: $pin has no $1" >&2
        exit 1
    fi
    printf '%s\n' "$value"
}
url=$(field url)
version=$(field version)
revision=$(field revision)

# Name order, whatever the locale.
LC_ALL=C
export LC_ALL

# What the copy is made from: the pin, each patch and this script.
source_of() {
    printf '%s %s %s\n' "$url" "$version" "$revision"
    for patch in "$patches"/*.patch; do
        [ -f "$patch" ] || continue
        printf '%s %s\n' "${patch##*/}" "$(sha256sum <"$patch" | cut -d' ' -f1)"
    done
    printf '%s %s\n' "$me" "$(sha256sum <"$0" | cut -d' ' -f1)"
}
wanted=$(source_of)
record=.git/portal-source

count=0
for patch in "$patches"/*.patch; do
    [ -f "$patch" ] && count=$((count + 1))
done

if [ -f "$dest/$record" ] && [ "$(cat "$dest/$record")" = "$wanted" ]; then
    if [ -n "$(git -C "$dest" status --porcelain)" ] ||
        [ "$(git -C "$dest" rev-parse HEAD)" != "$(git -C "$dest" rev-parse refs/portal/patched)" ]; then
        echo "$me: building $dest with the changes made in it since it was patched" >&2
    fi
else
    work=$dest.new
    rm -rf "$work"
    mkdir -p "$(dirname "$dest")"
    git init -q "$work"
    from=${PORTAL_GHOSTTY_CLONE:-$url}
    git -C "$work" fetch -q --depth 1 "$from" "refs/tags/$version" || {
        echo "$me: cannot fetch Ghostty $version from $from" >&2
        exit 1
    }
    fetched=$(git -C "$work" rev-parse 'FETCH_HEAD^{commit}')
    if [ "$fetched" != "$revision" ]; then
        echo "$me: Ghostty's tag $version is $fetched, not the revision $pin pins, $revision" >&2
        rm -rf "$work"
        exit 1
    fi
    git -C "$work" checkout -q --detach "$fetched"

    # Each patch becomes a commit, so `git -C SOURCE format-patch` gives them back.
    for patch in "$patches"/*.patch; do
        [ -f "$patch" ] || continue
        if ! git -C "$work" -c user.name=Portal -c user.email=portal@invalid \
            -c commit.gpgsign=false -c core.hooksPath=/dev/null \
            am -q --committer-date-is-author-date "$patch" >&2; then
            echo "$me: ${patch##*/} does not apply to Ghostty $version" >&2
            rm -rf "$work"
            exit 1
        fi
    done
    git -C "$work" update-ref refs/portal/patched HEAD
    printf '%s\n' "$wanted" >"$work/$record"

    rm -rf "$dest"
    mv "$work" "$dest"
    echo "Patched Ghostty $version with $count patches in $dest"
fi

zig=${ZIG:-zig}
needs=$(sed -n 's/.*minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$dest/build.zig.zon")
if ! command -v "$zig" >/dev/null 2>&1; then
    echo "$me: no $zig: Ghostty $version builds with Zig ${needs:-as its build.zig.zon says}; name one with \$ZIG" >&2
    exit 1
fi
# Ghostty's build runs tic to compile its terminfo, and hides what tic says.
if ! command -v tic >/dev/null 2>&1; then
    echo "$me: no tic, which compiles Ghostty's terminfo: install ncurses" >&2
    exit 1
fi

# The version is given: Ghostty's build would ask Git, and the copy has no tags.
# No documentation: it is built only where pandoc is found.
(cd "$dest" && "$zig" build \
    -Dapp-runtime=none \
    -Doptimize="$optimize" \
    -Dversion-string="${version#v}" \
    -Demit-docs=false \
    --prefix "$prefix" \
    --cache-dir "$dest-cache") || {
    echo "$me: zig build failed; Ghostty $version asks for Zig ${needs:-as its build.zig.zon says}, and $zig is $("$zig" version 2>/dev/null || echo unknown)" >&2
    exit 1
}

library=$prefix/lib/ghostty-internal.so
if [ ! -f "$library" ]; then
    echo "$me: zig build left no $library" >&2
    exit 1
fi
# The library's soname is libghostty.so, whatever Ghostty's build calls the file.
ln -sfn ghostty-internal.so "$prefix/lib/libghostty.so"

echo "Built Ghostty $version ($optimize) with $count patches:"
echo "  library    $prefix/lib/libghostty.so"
echo "  header     $prefix/include/ghostty.h"
echo "  resources  $prefix/share/ghostty"
