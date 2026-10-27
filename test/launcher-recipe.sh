#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Optional integration smoke test of docs/launcher.md's launcher.el recipe, outside
# CTest: Portal does not need launcher.el. Set PORTAL_LAUNCHER_EL to a
# directory holding the package's launcher.el, such as a checkout of the tested
# revision. Run after ./build.sh, in a desktop session; it uses disposable
# Emacs windows, briefly takes focus and activates the running Finder.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${PORTAL_LAUNCHER_EL:?Set PORTAL_LAUNCHER_EL to the directory of launcher.el}"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
    -I "$(cat "$root/build/emacs-include.txt")" "$root/test/terminal-input.m" \
    -framework AppKit -framework WebKit -framework Carbon -framework IOSurface \
    -o "$root/build/test-terminal-input.dylib"
set -- -Q --module-assertions -L "$root" -L "$root/test" -L "$PORTAL_LAUNCHER_EL"
for package in "$root"/build/elpa/*; do
    if [ -d "$package" ]; then set -- "$@" -L "$package"; fi
done
export PORTAL_LAUNCHER_TEST_ROOT="$root"
"${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}" "$@" -l "$root/portal.el" \
    --eval '(module-load (expand-file-name "build/test-terminal-input.dylib"
                                         (getenv "PORTAL_LAUNCHER_TEST_ROOT")))' \
    -l "$root/test/portal-launcher-recipe-tests.el" \
    -l "$root/test/portal-test-tiers.el" \
    --eval '(run-at-time 1 nil
      (lambda ()
        (condition-case err
            (let ((stats (ert-run-tests-batch
                          (portal-test-tiers-selector "^portal-launcher-recipe-"))))
              (with-current-buffer "*Messages*"
                (princ (buffer-string) (quote external-debugging-output)))
              (princ (format "launcher.el: %s\n" (locate-library "launcher"))
                     (quote external-debugging-output))
              (kill-emacs (if (and (= (ert-stats-completed-unexpected stats) 0)
                                  (= (ert-stats-skipped stats) 0)
                                  (= (ert-stats-completed-expected stats) 2)) 0 1)))
          (error
           (princ (format "Launcher recipe checks failed: %S\n" err)
                  (quote external-debugging-output))
           (kill-emacs 1)))))'
