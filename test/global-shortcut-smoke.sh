#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# A person's smoke test of global shortcuts with physical keys, which the
# automated tests only inject. Run after ./build.sh, in a desktop session. It
# starts a disposable Emacs that sets two shortcuts, a command and a lambda,
# and records each call with the app in front. Override the chords with
# PORTAL_SMOKE_FIRST and PORTAL_SMOKE_SECOND if another app has them, and the
# two minutes allowed with PORTAL_SMOKE_SECONDS. ./test.sh manual runs this.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# The build to use, and its configured Emacs, which ./test.sh manual passes.
build=${PORTAL_TEST_BUILD:-$root/build}
if [ -z "${EMACS:-}" ]; then
    EMACS=$(sed -n 's/^EMACS:FILEPATH=//p' "$build/CMakeCache.txt" 2>/dev/null)
fi
# The CMake target rebuilds the test-only event injector only when it changed.
cmake --build "$build" --target portal-test-injector
first=${PORTAL_SMOKE_FIRST:-Control-Option-Command-8}
second=${PORTAL_SMOKE_SECOND:-Control-Option-Command-9}
seconds=${PORTAL_SMOKE_SECONDS:-120}
log=$(mktemp -t portal-global-shortcut-smoke)
echo "Switch to another app, then press $first and $second once each."
echo "Emacs quits once both have run; it gives up after $seconds seconds."
export PORTAL_TEST_BUILD="$build" PORTAL_SMOKE_LOG="$log" PORTAL_SMOKE_SECONDS="$seconds" \
    PORTAL_SMOKE_FIRST="$first" PORTAL_SMOKE_SECOND="$second"
status=0
"${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}" -Q -L "$root" -L "$root/test" -l "$root/portal.el" \
    -l "$root/test/portal-suite.el" \
    --eval '(module-load (portal-suite-use-build (getenv "PORTAL_TEST_BUILD")))' \
    --eval '(let* ((log (getenv "PORTAL_SMOKE_LOG"))
                   (ran nil)
                   (record
                    (lambda (name)
                      (let* ((pid (portal-test-frontmost))
                             (app (cdr (assq (quote comm) (process-attributes pid))))
                             (line (format "%s ran at %s with %s (pid %s) in front; Emacs in front: %s\n"
                                           name (format-time-string "%T") app pid
                                           (eql pid (emacs-pid)))))
                        (write-region line nil log t (quote silent))
                        (message "%s" line)
                        (unless (assq name ran) (push (cons name (not (eql pid (emacs-pid)))) ran))
                        (when (= (length ran) 2)
                          (kill-emacs (if (and (cdar ran) (cdadr ran)) 0 1)))))))
              (defalias (quote portal-smoke-command)
                (lambda () (interactive) (funcall record (quote command))))
              (portal-global-shortcut-set (quote smoke-command) (getenv "PORTAL_SMOKE_FIRST")
                                          (quote portal-smoke-command))
              (portal-global-shortcut-set (quote smoke-lambda) (getenv "PORTAL_SMOKE_SECOND")
                                          (lambda () (funcall record (quote lambda))))
              (run-at-time (string-to-number (getenv "PORTAL_SMOKE_SECONDS")) nil
                           (lambda ()
                             (write-region "Timed out\n" nil log t (quote silent))
                             (kill-emacs 2)))
              (with-current-buffer "*scratch*"
                (erase-buffer)
                (insert (format "Switch to another app, then press %s and %s.\n"
                                (getenv "PORTAL_SMOKE_FIRST") (getenv "PORTAL_SMOKE_SECOND")))))' \
    || status=$?
cat "$log"
rm -f "$log"
exit "$status"
