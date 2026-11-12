#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run INSIDE the guest: install the staged Rex Server as /Applications/Rex Server.app,
# replacing the one there. provision.sh runs it as root; to move Rex's pin in
# a prepared guest, its admin test user runs it on a `stage.sh --rex-only`
# directory copied in. Rex's Mac app is never installed: nothing updates the
# server, and the real-server tests start their own.
# Usage: bash install-rex.sh STAGED_DIRECTORY
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: bash install-rex.sh STAGED_DIRECTORY' >&2; exit 1; }
[[ $(sysctl -n kern.hv_vmm_present) == 1 ]] || { echo 'Refusing to install Rex on a physical Mac.' >&2; exit 1; }
share=$(cd -- "$1" && pwd)
# shellcheck source=tools/tart/recipe.conf
. "$share/recipe.conf"
(cd "$share" && grep -E '  (rex\.tar|recipe\.conf)$' SHA256SUMS | shasum -a 256 -c -)
app="/Applications/Rex Server.app"
stage=$(mktemp -d /Applications/.portal-rex.XXXXXX)
trap 'rm -rf "$stage"' EXIT
tar --no-xattrs -xpf "$share/rex.tar" -C "$stage"
codesign --verify --deep --strict \
    -R="anchor apple generic and certificate leaf[subject.OU] = \"$REX_TEAM_ID\"" "$stage/Rex Server.app"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$stage/Rex Server.app/Contents/Info.plist") == "$REX_BUILD" ]]
[[ $(shasum -a 256 "$stage/Rex Server.app/Contents/MacOS/rex" | awk '{print $1}') == "$REX_SHA256" ]]
if [[ -e $app ]]; then
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") == com.superlogical.rex.server ]] ||
        { echo "$app is not Rex Server; leaving it." >&2; exit 1; }
    rm -rf "$app"
fi
mv "$stage/Rex Server.app" "$app"
printf 'Installed Rex Server %s (build %s) at %s\n' "$REX_VERSION" "$REX_BUILD" "$app"
