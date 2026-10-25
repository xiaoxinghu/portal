#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/views-gui.sh [SELECTOR]
# Ordinary terminal and web views in one fresh Emacs, through test/gui-ert.sh:
# WebKit loading, windows pages open, terminals, their coexistence, Markdown
# previews and Excalidraw. SELECTOR, an ERT regexp, narrows them. Terminal and
# integration tests run only here; the launcher and the input suite have their
# own runners.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/test/gui-desktop.sh"
export PORTAL_VIEWS_SELECTOR="${1:-}"
exec sh "$root/test/gui-ert.sh" \
    -l "$root/test/portal-tests.el" \
    -l "$root/test/portal-terminal-tests.el" \
    -l "$root/test/portal-integration-tests.el" \
    -l "$root/test/portal-markdown-gui-tests.el" \
    -l "$root/test/portal-excalidraw-gui-tests.el" \
    -l "$root/test/portal-web-gui-tests.el" \
    --eval '(portal-gui-ert-start
             (list (quote and)
                   "^portal-\\(web\\|terminal\\|integration\\|markdown-gui\\|excalidraw-gui\\)-"
                   (quote (not portal-terminal-start-uses-shell-startup))
                   (let ((focus (getenv "PORTAL_VIEWS_SELECTOR")))
                     (if (equal focus "") t focus))))'
