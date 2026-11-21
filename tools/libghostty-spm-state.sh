#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: libghostty-spm-state.sh SOURCE OUT
#
# Record in OUT what the build compiles of libghostty-spm: the copy SOURCE
# that patch-libghostty-spm.sh made, which keeps changes made in it since.
# OUT holds the copy's record of what it was made from (the pin, each patch
# and the script, with their SHA-256), the commit its patches made, its
# HEAD and any uncommitted changes, so that licenses/source.ts can tell a
# build of the pin plus Portal's patches from one of an edited copy.  A
# pruned build keeps OUT.
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 SOURCE OUT" >&2
    exit 2
fi
source=$1 out=$2

{
    sed 's/^/made /' "$source/.git/portal-source"
    printf 'patched %s\n' "$(git -C "$source" rev-parse refs/portal/patched)"
    printf 'head %s\n' "$(git -C "$source" rev-parse HEAD)"
    git -C "$source" status --porcelain | sed 's/^/changed /'
} >"$out.new"
mv "$out.new" "$out"
