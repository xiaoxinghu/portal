#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/gui-all.sh
# Every graphical suite that CONTRIBUTING.md lists for this system, each in
# its own fresh Emacs, one after another, after one build. In the VM the runner builds once;
# the suites, finding no Git metadata there, run on its desktop. A failing
# suite does not stop the others. Each logs to a directory of its own in
# PORTAL_TEST_LOGS, or build/gui-all, with its output in test.log and its
# exit-status: a suite's progress log never erases an earlier suite's. A
# suite that exits 77 could not run here, as the real-server tier where no
# Rex Server is installed: it is reported as not run, and fails nothing.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# In the VM one stage runs every suite, package-gui.sh's own build included.
: "${PORTAL_TEST_TIMEOUT:=3600}"
export PORTAL_TEST_TIMEOUT
# The VM is a Mac: Linux's suites run here, on a desktop of their own.
if [ "$(uname -s)" = Darwin ]; then . "$root/test/gui-desktop.sh"; fi
logs=${PORTAL_TEST_LOGS:-$root/build/gui-all}
summary= failed=0
if [ "$(uname -s)" = Darwin ]; then
    suites="views:views-gui input:input-gui launcher:launcher-gui
        terminal-shell-startup:terminal-shell-startup rex-server:rex-server-gui
        package:package-gui"
else
    # Linux has the views and terminals: its suite, and the recordings of a
    # view, and of a terminal under output, following its pane. Each makes a
    # desktop of its own. A script's argument follows a plus.
    suites="linux:linux-gui linux-follow:linux-follow linux-follow-terminal:linux-follow+terminal"
fi
for suite in $suites; do
    run=${suite#*:}
    name=${suite%%:*} script=test/${run%%+*}.sh argument=
    case $run in *+*) argument=${run#*+} ;; esac
    dir=$logs/$name
    mkdir -p "$dir"
    rm -f "$dir/exit-status"
    echo "== $name: sh $script${argument:+ $argument}"
    started=$(date +%s)
    { status=0
      PORTAL_TEST_LOGS=$dir sh "$root/$script" ${argument:+"$argument"} 2>&1 || status=$?
      echo "$status" >"$dir/exit-status"; } | tee "$dir/test.log"
    status=$(cat "$dir/exit-status")
    if [ "$status" = 0 ]; then result=passed
    elif [ "$status" = 77 ]; then result="not run"
    else result="failed ($status)"; failed=$((failed + 1)); fi
    summary="$summary$name: $result in $(($(date +%s) - started)) s
"
done
printf '== Graphical suites\n%s' "$summary"
[ "$failed" = 0 ]
