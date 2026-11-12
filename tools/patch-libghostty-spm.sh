#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: patch-libghostty-spm.sh PIN PATCHES DEST
#
# Make DEST a copy of libghostty-spm's source at the release PIN names, with
# every PATCHES/*.patch applied in name order; native/Package.swift builds that
# copy.  PIN is a JSON file holding the repository's url, the release's version
# tag and that tag's revision.  The prebuilt Ghostty library is not fetched
# here: the copy's own Package.swift downloads it by URL and checksum.
#
# A copy made from the same pin, patches and script is kept, with any changes
# made in it since, so a patch can be developed there; anything else is
# replaced.  A patch that does not apply fails the build.
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 PIN PATCHES DEST" >&2
    exit 2
fi
pin=$1 patches=$2 dest=$3
me=patch-libghostty-spm

field() {
    plutil -extract "$1" raw -o - "$pin" || {
        echo "$me: $pin has no $1" >&2
        exit 1
    }
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
        printf '%s %s\n' "${patch##*/}" "$(shasum -a 256 <"$patch" | cut -d' ' -f1)"
    done
    printf '%s %s\n' "$me" "$(shasum -a 256 <"$0" | cut -d' ' -f1)"
}
wanted=$(source_of)
record=.git/portal-source

if [ -f "$dest/$record" ] && [ "$(cat "$dest/$record")" = "$wanted" ]; then
    if [ -n "$(git -C "$dest" status --porcelain)" ] ||
        [ "$(git -C "$dest" rev-parse HEAD)" != "$(git -C "$dest" rev-parse refs/portal/patched)" ]; then
        echo "$me: building $dest with the changes made in it since it was patched" >&2
    fi
    exit 0
fi

work=$dest.new
rm -rf "$work"
git init -q "$work"
git -C "$work" fetch -q --depth 1 "$url" "refs/tags/$version" || {
    echo "$me: cannot fetch libghostty-spm $version from $url" >&2
    exit 1
}
fetched=$(git -C "$work" rev-parse 'FETCH_HEAD^{commit}')
if [ "$fetched" != "$revision" ]; then
    echo "$me: libghostty-spm's tag $version is $fetched, not the revision $pin pins, $revision" >&2
    exit 1
fi
git -C "$work" checkout -q --detach "$fetched"

# Each patch becomes a commit, so `git -C DEST format-patch` gives them back.
count=0
for patch in "$patches"/*.patch; do
    [ -f "$patch" ] || continue
    if ! git -C "$work" -c user.name=Portal -c user.email=portal@invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null \
        am -q --committer-date-is-author-date "$patch" >&2; then
        echo "$me: ${patch##*/} does not apply to libghostty-spm $version" >&2
        exit 1
    fi
    count=$((count + 1))
done
git -C "$work" update-ref refs/portal/patched HEAD
printf '%s\n' "$wanted" >"$work/$record"

rm -rf "$dest"
mv "$work" "$dest"
echo "Patched libghostty-spm $version with $count patches in $dest"
