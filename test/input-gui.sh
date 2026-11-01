#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/input-gui.sh [SELECTOR]
# Keyboard input checks in one fresh Emacs, through
# test/gui-ert.sh. SELECTOR, an ERT regexp, narrows them. The terminal and
# integration suites load for their helpers; views-gui.sh runs their tests.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/test/gui-desktop.sh"
export PORTAL_INPUT_SELECTOR="${1:-}"
exec sh "$root/test/gui-ert.sh" \
    -l "$root/test/portal-tests.el" \
    -l "$root/test/portal-terminal-tests.el" \
    -l "$root/test/portal-integration-tests.el" \
    -l "$root/test/portal-input-gui-tests.el" \
    --eval '(portal-gui-ert-start
             (list (quote and)
                   "^portal-input-gui-"
                   (let ((focus (getenv "PORTAL_INPUT_SELECTOR")))
                     (if (equal focus "") t focus)))
             (quote (portal-input-gui-web-fullscreen-keeps-the-keyboard-and-escape-leaves-it
                     portal-input-gui-web-fullscreen-page-closes-with-its-buffer
                     portal-input-gui-web-fullscreen-page-keeps-the-keyboard-in-another-frame
                     portal-input-gui-web-fullscreen-returns-to-where-emacs-put-the-page)))'
