#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run as the desktop user, over SSH or inside the VM. No GUI Emacs is started.
set -euo pipefail
root=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
# shellcheck source=tools/tart/recipe.conf
. "$root/recipe.conf"
[[ $(sysctl -n kern.hv_vmm_present) == 1 ]]
[[ $(stat -f %Su /dev/console) == "$(id -un)" ]]
[[ $(sw_vers -productVersion) == "$MACOS_VERSION" && $(sw_vers -buildVersion) == "$MACOS_BUILD" ]]
export PATH=/opt/homebrew/bin:$PATH
export SDKROOT LIBRARY_PATH
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
LIBRARY_PATH="$(/usr/libexec/PlistBuddy -c Print:LSEnvironment:LIBRARY_PATH /Applications/Emacs.app/Contents/Info.plist)"
[[ $(xcodebuild -version) == "Xcode $XCODE_VERSION"$'\n'"Build version $XCODE_BUILD" ]]
xcodebuild -checkFirstLaunchStatus
emacs=/Applications/Emacs.app/Contents/MacOS/Emacs
[[ $("$emacs" --batch -Q --eval '(princ emacs-repository-version)') == "$EMACS_REVISION" ]]
[[ $("$emacs" --batch -Q --eval '(princ (funcall (native-compile (lambda (n) (+ n 1))) 41))') == 42 ]]
cmake_version=$(sed -n 's|^cmake/||p' "$root/cellar.txt")
ninja_version=$(sed -n 's|^ninja/||p' "$root/cellar.txt")
bun_manifest=$root/bun.manifest
[[ -f $bun_manifest ]] || bun_manifest=$root/../bun.manifest
bun_version=$(awk '$1 == "version" {print $2}' "$bun_manifest")
[[ $(cmake --version | head -1) == "cmake version $cmake_version" ]]
[[ $(ninja --version) == "$ninja_version" ]]
[[ $(bun --version) == "$bun_version" ]]
printf 'Guest toolchain and native compilation passed. Run the GUI suites before accepting this image.\n'
