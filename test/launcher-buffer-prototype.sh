#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# GUI ONLY: bash test/vm.sh sh test/launcher-buffer-prototype.sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
include=$(head -n 1 "$root/build/emacs-include.txt")
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
    -I "$include" "$root/test/terminal-input.m" \
    -framework AppKit -framework WebKit -framework Carbon -framework IOSurface \
    -o "$root/build/test-terminal-input.dylib"
set -- -Q --module-assertions -L "$root" -L "$root/test"
for package in "$root"/build/elpa/*; do
    if [ -d "$package" ]; then set -- "$@" -L "$package"; fi
done
export PORTAL_LAUNCHER_TEST_ROOT="$root"
# Outside repo/: the VM runner removes successful runs' source/build trees.
export PORTAL_LAUNCHER_SCREENSHOTS="$root/../screenshots"
mkdir -p "$PORTAL_LAUNCHER_SCREENSHOTS"
"${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}" "$@" \
    -l "$root/portal.el" \
    --eval '(module-load (expand-file-name "build/test-terminal-input.dylib"
                                         (getenv "PORTAL_LAUNCHER_TEST_ROOT")))' \
    --eval '(load-theme (quote modus-vivendi) t)' \
    -l "$root/test/portal-launcher-buffer-prototype-gui-tests.el" \
    --eval '(run-at-time 1 nil
      (lambda ()
        (condition-case err
            (let ((stats (ert-run-tests-batch
                          (quote (or "^portal-launcher-buffer-prototype-gui-"
                                     portal-launcher-gui-minibuffer-panel-vertico
                                     portal-launcher-gui-persistent-buffer)))))
              (with-current-buffer "*Messages*"
                (princ (buffer-string) (quote external-debugging-output)))
              (kill-emacs (if (and (= (ert-stats-completed-unexpected stats) 0)
                                  (= (ert-stats-skipped stats) 0)
                                  (= (ert-stats-completed-expected stats) 7)) 0 1)))
          (error
           (princ (format "Prototype checks failed: %S\n" err)
                  (quote external-debugging-output))
           (kill-emacs 1)))))'
