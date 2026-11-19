#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/linux-gui.sh [SELECTOR]
# Portal's views and input on Linux, after ./build.sh: the suite of
# test/portal-linux-gui-tests.el in one fresh Emacs, through test/gui-ert.sh,
# then an Emacs that quits with a view open. SELECTOR, an ERT regexp, narrows
# the suite. It runs on a desktop of its own, a second Hyprland with a
# headless output (test/linux-desktop.sh), so its windows are on no screen of
# yours and its keys and clicks go nowhere else. Beside Hyprland it needs
# grim, which reads that output's pixels, and wtype, which types. Exits 77,
# for "could not run here", where the desktop cannot start.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "${PORTAL_TEST_DESKTOP:-}" ]; then
    exec sh "$root/test/linux-desktop.sh" sh "$0" "$@"
fi
export PORTAL_LINUX_SELECTOR="${1:-}"
# glibc fills freed memory with this byte, so that reading a frame or a view
# that has been freed, as when a frame is deleted with views in it, crashes
# Emacs here and does not pass by luck.
export MALLOC_PERTURB_=165
sh "$root/test/gui-ert.sh" \
    -l "$root/test/portal-linux-gui-tests.el" \
    --eval '(portal-gui-ert-start
             (list (quote and) "^portal-linux-gui-"
                   (let ((focus (getenv "PORTAL_LINUX_SELECTOR")))
                     (if (equal focus "") t focus))))'
# Emacs quits with a view open, shown and drawing, and the keyboard in it:
# the view ends in kill-emacs-hook, and Emacs exits as it was asked to.
[ -z "$PORTAL_LINUX_SELECTOR" ] || exit 0
status=0
"${EMACS:-emacs}" -Q --module-assertions -L "$root" -l "$root/portal.el" --eval '
(run-at-time
 1 nil
 (lambda ()
   (switch-to-buffer (get-buffer-create "*quit*"))
   (let ((target (portal-view-open (quote terminal) (quote (:directory "/" :test-pattern t))))
         (deadline (+ (float-time) 10)))
     (while (and (not (plist-get (portal--inspect target) :showing)) (< (float-time) deadline))
       (accept-process-output nil 0.02)
       (redisplay t))
     (kill-emacs (if (and (portal--input target "focus")
                          (plist-get (portal--inspect target) :showing))
                     0
                   3)))))' || status=$?
if [ "$status" != 0 ]; then
    echo "GUI checks failed: Emacs quitting with a view open exited $status" >&2
    exit 1
fi
echo "Emacs quit with a view open" >&2
