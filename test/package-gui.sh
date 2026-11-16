#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs this copy of Portal through docs/install.md's use-package-vc example,
# from the branch stable of a Git copy of it, into an empty HOME, then checks
# first use in graphical Emacs: the first native command offers one build, and
# a fresh Emacs then opens a terminal and a web view.  The installation and its
# build are deleted afterwards.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# In the VM, the runner's build comes before the package's own.
: "${PORTAL_TEST_TIMEOUT:=2400}"
export PORTAL_TEST_TIMEOUT
. "$root/test/gui-desktop.sh"
emacs=${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}
work=$(mktemp -d "${TMPDIR:-/tmp}/portal-package-gui.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The runner copies files without Git metadata; installing needs a repository.
[ -d "$root/.git" ] || git -C "$root" init -q
"$emacs" --batch -Q -l "$root/test/portal-package-tests.el" \
    --eval "(portal-package-test--install \"$work\" \"$work/home/\" \"\")"

for phase in setup use; do
    echo "Graphical Emacs: $phase"
    (cd "$work/home" &&
        HOME="$work/home" PORTAL_PACKAGE_GUI_PHASE=$phase \
        "$emacs" -Q -l "$root/test/portal-package-gui.el")
done
