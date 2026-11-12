#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Snapshot locally installed, licensed tools; no private keys or passwords.
# Usage: bash tools/tart/stage.sh [--rex-only] NEW_OUTPUT_DIRECTORY
# --rex-only stages the recipe and Rex Server alone, to move Rex's pin in a
# prepared guest with install-rex.sh.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
. "$root/tools/tart/recipe.conf"
rex_only=
if [[ ${1:-} == --rex-only ]]; then rex_only=1; shift; fi
[[ $# == 1 && ! -e $1 ]] || { echo 'Pass a new output directory.' >&2; exit 1; }
[[ $(uname -m) == arm64 ]] || { echo 'Apple Silicon required.' >&2; exit 1; }

# Rex Server is private beta software: it comes only from Rex's Mac app on
# this Mac, which keeps each build it installs and carries its own inside.
rex_build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null; }
rex_sha_of() { shasum -a 256 "$1/Contents/MacOS/rex" | awk '{print $1}'; }
rex_candidates=("$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/$REX_BUILD/Rex Server.app")
for app in /Applications/Rex*.app; do
    [[ -d "$app/Contents/Helpers/Rex Server.rex" ]] && rex_candidates+=("$app/Contents/Helpers/Rex Server.rex")
done
rex_server=
for candidate in "${rex_candidates[@]}"; do
    if [[ -d $candidate && $(rex_build_of "$candidate") == "$REX_BUILD" ]]; then rex_server=$candidate; break; fi
done
if [[ -z $rex_server ]]; then
    printf 'Rex Server build %s, which tools/tart/recipe.conf pins, is not on this Mac.\n' "$REX_BUILD" >&2
    current="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app"
    for candidate in "$current" "${rex_candidates[@]:1}"; do
        [[ -d $candidate ]] || continue
        printf 'This Mac has build %s at %s. To pin it instead, set in recipe.conf:\n' \
            "$(rex_build_of "$candidate")" "$candidate" >&2
        printf 'REX_VERSION=%s\nREX_BUILD=%s\nREX_SHA256=%s\n' \
            "$(HOME=/var/empty "$candidate/Contents/MacOS/rex" --autostart=false version | sed -n 's/^rex //p')" \
            "$(rex_build_of "$candidate")" "$(rex_sha_of "$candidate")" >&2
        break
    done
    exit 1
fi
[[ $(rex_sha_of "$rex_server") == "$REX_SHA256" ]] || {
    echo "$rex_server is build $REX_BUILD, but its rex differs from REX_SHA256." >&2; exit 1;
}
codesign --verify --deep --strict \
    -R="anchor apple generic and certificate leaf[subject.OU] = \"$REX_TEAM_ID\"" "$rex_server"

if [[ -z $rex_only ]]; then
    [[ $(/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -version) == "Xcode $XCODE_VERSION"$'\n'"Build version $XCODE_BUILD" ]]
    [[ $(/Applications/Emacs.app/Contents/MacOS/Emacs --batch -Q --eval '(princ emacs-repository-version)') == "$EMACS_REVISION" ]]
    paths=()
    while IFS= read -r package; do
        [[ -d /opt/homebrew/Cellar/$package ]] || { echo "Missing pinned tool: $package" >&2; exit 1; }
        paths+=("Cellar/$package")
    done < "$root/tools/tart/cellar.txt"
fi
mkdir -p -- "$1"
out=$(cd -- "$1" && pwd)
files=(recipe.conf cellar.txt provision.sh install-rex.sh verify.sh bun.manifest rex.tar)
cp "$root"/tools/tart/{recipe.conf,cellar.txt,provision.sh,install-rex.sh,verify.sh} "$out/"
cp "$root/tools/bun.manifest" "$out/"
# The archive holds the bundle as Rex Server.app, whichever copy it came from.
tar --no-xattrs -cf "$out/rex.tar" -s ",^${rex_server##*/},Rex Server.app," \
    -C "${rex_server%/*}" "${rex_server##*/}"
if [[ -z $rex_only ]]; then
    files+=(apps.tar cellar.tar bun)
    # Preserve app symlinks, but omit quarantine and other host-specific xattrs.
    tar --no-xattrs -cf "$out/apps.tar" -C /Applications Xcode.app Emacs.app
    tar --no-xattrs -cf "$out/cellar.tar" -C /opt/homebrew "${paths[@]}"
    read -r _ url digest < <(awk '$1 == "darwin-aarch64" { print }' "$out/bun.manifest")
    curl --fail --location --retry 3 "$url" -o "$out/bun.zip"
    printf '%s  %s\n' "$digest" "$out/bun.zip" | shasum -a 256 -c -
    unzip -q "$out/bun.zip" -d "$out/bun-unpacked"
    mv "$out/bun-unpacked/bun-darwin-aarch64/bun" "$out/bun"
    rm -r "$out/bun-unpacked" "$out/bun.zip"
fi
(cd "$out" && shasum -a 256 "${files[@]}" > SHA256SUMS)
printf 'Staged at %s, with Rex Server %s (build %s) from %s\n' "$out" "$REX_VERSION" "$REX_BUILD" "$rex_server"
printf 'Keep this directory out of Git and private: it holds the pinned binaries, Rex among them.\n'
