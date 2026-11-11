#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Snapshot locally installed, licensed tools; no private keys or passwords.
# Usage: bash tools/tart/stage.sh NEW_OUTPUT_DIRECTORY
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
. "$root/tools/tart/recipe.conf"
[[ $# == 1 && ! -e $1 ]] || { echo 'Pass a new output directory.' >&2; exit 1; }
[[ $(uname -m) == arm64 ]] || { echo 'Apple Silicon required.' >&2; exit 1; }
[[ $(/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -version) == "Xcode $XCODE_VERSION"$'\n'"Build version $XCODE_BUILD" ]]
[[ $(/Applications/Emacs.app/Contents/MacOS/Emacs --batch -Q --eval '(princ emacs-repository-version)') == "$EMACS_REVISION" ]]
paths=()
while IFS= read -r package; do
    [[ -d /opt/homebrew/Cellar/$package ]] || { echo "Missing pinned tool: $package" >&2; exit 1; }
    paths+=("Cellar/$package")
done < "$root/tools/tart/cellar.txt"
mkdir -p -- "$1"
out=$(cd -- "$1" && pwd)
cp "$root"/tools/tart/{recipe.conf,cellar.txt,provision.sh,verify.sh} "$out/"
cp "$root/tools/bun.manifest" "$out/"
# Preserve app symlinks, but omit quarantine and other host-specific xattrs.
tar --no-xattrs -cf "$out/apps.tar" -C /Applications Xcode.app Emacs.app
tar --no-xattrs -cf "$out/cellar.tar" -C /opt/homebrew "${paths[@]}"
read -r _ url digest < <(awk '$1 == "darwin-aarch64" { print }' "$out/bun.manifest")
curl --fail --location --retry 3 "$url" -o "$out/bun.zip"
printf '%s  %s\n' "$digest" "$out/bun.zip" | shasum -a 256 -c -
unzip -q "$out/bun.zip" -d "$out/bun-unpacked"
mv "$out/bun-unpacked/bun-darwin-aarch64/bun" "$out/bun"
rm -r "$out/bun-unpacked" "$out/bun.zip"
(cd "$out" && shasum -a 256 apps.tar cellar.tar bun bun.manifest recipe.conf cellar.txt provision.sh verify.sh > SHA256SUMS)
printf 'Toolchain staged at %s\nKeep this directory with the recipe commit; it contains the pinned app/tool binaries.\n' "$out"
