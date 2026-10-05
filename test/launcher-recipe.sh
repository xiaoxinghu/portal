#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Optional external smoke test of docs/launcher.md's launcher.el recipe: Portal
# does not need launcher.el. Set PORTAL_LAUNCHER_EL to a directory holding the
# package's launcher.el, such as a checkout of the tested revision. It uses
# disposable Emacs windows, briefly takes focus and activates the running Finder.
exec "$(dirname "$0")/../test.sh" external --suite launcher-recipe --allow-external --allow-gui "$@"
