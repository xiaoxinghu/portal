#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/rex-server-gui.sh [SELECTOR]
# The real-server tier: Portal's Rex client against real Rex servers, in one
# fresh graphical Emacs, through test/gui-ert.sh. Each test starts a server
# of its own on its own socket and stops it; one still running afterwards
# fails the run. SELECTOR, an ERT regexp, narrows the tests.
# Rex is private beta software, so this runs only where a Rex Server is:
# PORTAL_TEST_REX names its rex program, or else the test VM's
# /Applications/Rex Server.app or the one Rex's Mac app keeps. Elsewhere it
# says it did not run and exits 77, which test/gui-all.sh reports as not run.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/test/gui-desktop.sh"
rex=${PORTAL_TEST_REX:-}
if [ -z "$rex" ]; then
    for candidate in "/Applications/Rex Server.app/Contents/MacOS/rex" \
        "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"; do
        if [ -x "$candidate" ]; then rex=$candidate; break; fi
    done
fi
if [ -z "$rex" ]; then
    echo "Real Rex server checks not run: no Rex Server here; set PORTAL_TEST_REX to its rex program." >&2
    exit 77
fi
[ -x "$rex" ] || { echo "PORTAL_TEST_REX is not a program: $rex" >&2; exit 2; }
echo "Rex Server: $rex, $(HOME=/var/empty "$rex" --autostart=false version | head -1)"
# The servers' directories: nothing else runs from here.
servers=$(mktemp -d /tmp/portal-rex.XXXXXX)
trap 'rm -rf "$servers"' EXIT
status=0
PORTAL_TEST_REX=$rex PORTAL_TEST_REX_DIRECTORY=$servers PORTAL_REX_SERVER_SELECTOR="${1:-}" \
    sh "$root/test/gui-ert.sh" \
    -l "$root/test/portal-rex-server-gui-tests.el" \
    --eval '(portal-gui-ert-start
             (list (quote and) "^portal-rex-server-gui-"
                   (let ((focus (getenv "PORTAL_REX_SERVER_SELECTOR")))
                     (if (equal focus "") t focus))))' || status=$?
left=$(pgrep -f "$servers/" || :)
if [ -n "$left" ]; then
    echo "Rex servers left running, now killed:" >&2
    ps -o pid=,command= -p "$(echo $left | tr ' ' ,)" >&2 || :
    kill -KILL $left 2>/dev/null || :
    status=1
fi
exit "$status"
