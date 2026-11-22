#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/launcher-gui.sh [SELECTOR]
# The launcher's graphical suite, daily-use checks included, in one fresh
# Emacs, through test/gui-ert.sh. SELECTOR, an ERT regexp, defaults to every
# launcher test but the daily-use check of a configured completion stack,
# which launcher-daily-use.sh runs with the configuration it is given: with
# none, as here, picker-selection-without-typing covers it. Only the test
# that needs a second display may skip. Set PORTAL_LAUNCHER_SCREENSHOTS to a
# directory to save the panel's drawing there.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/test/gui-desktop.sh"
export PORTAL_LAUNCHER_SELECTOR="${1:-^portal-launcher-}"
exec sh "$root/test/gui-ert.sh" \
    -l "$root/test/portal-launcher-daily-use-tests.el" \
    --eval '(portal-gui-ert-start
             (list (quote and) (getenv "PORTAL_LAUNCHER_SELECTOR")
                   (quote (not portal-launcher-daily-use-configured-completion)))
             (quote (portal-launcher-gui-minibuffer-panel-stays-on-its-display)))'
