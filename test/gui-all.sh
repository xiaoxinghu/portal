#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/gui-all.sh
# Every graphical suite that CONTRIBUTING.md lists, each in its own fresh
# Emacs, one after another, after one build. In the VM the runner builds once;
# the suites, finding no Git metadata there, run on its desktop. A failing
# suite does not stop the others. Each logs to a directory of its own in
# PORTAL_TEST_LOGS, or build/gui-all, with its output in test.log and its
# exit-status: a suite's progress log never erases an earlier suite's.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# In the VM one stage runs every suite, package-gui.sh's own build included.
: "${PORTAL_TEST_TIMEOUT:=3600}"
export PORTAL_TEST_TIMEOUT
. "$root/test/gui-desktop.sh"
logs=${PORTAL_TEST_LOGS:-$root/build/gui-all}
summary= failed=0
for suite in views:views-gui input:input-gui launcher:launcher-gui \
    terminal-shell-startup:terminal-shell-startup package:package-gui; do
    name=${suite%%:*} script=test/${suite#*:}.sh
    dir=$logs/$name
    mkdir -p "$dir"
    rm -f "$dir/exit-status"
    echo "== $name: sh $script"
    started=$(date +%s)
    { status=0
      PORTAL_TEST_LOGS=$dir sh "$root/$script" 2>&1 || status=$?
      echo "$status" >"$dir/exit-status"; } | tee "$dir/test.log"
    status=$(cat "$dir/exit-status")
    if [ "$status" = 0 ]; then result=passed
    else result="failed ($status)"; failed=$((failed + 1)); fi
    summary="$summary$name: $result in $(($(date +%s) - started)) s
"
done
printf '== Graphical suites\n%s' "$summary"
[ "$failed" = 0 ]
