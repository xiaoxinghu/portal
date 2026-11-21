#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/linux-gui.sh [SELECTOR]
# Portal's views, input and terminals on Linux, after ./build.sh: the suites
# of test/portal-linux-gui-tests.el, its terminals' and fed terminals', and
# test/portal-rex-gui-tests.el, Rex blocks shown against the fake server, in
# one fresh Emacs, through test/gui-ert.sh; then the themes of
# test/portal-linux-scheme-tests.el in another, on a session bus of its own
# that dbus-run-session starts; then an Emacs that quits with a view open. SELECTOR, an ERT regexp, narrows the suites. It runs on a desktop of its own, a second Hyprland with a
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
    -l "$root/test/portal-linux-terminal-tests.el" \
    -l "$root/test/portal-linux-fed-tests.el" \
    -l "$root/test/portal-rex-gui-tests.el" \
    --eval '(portal-gui-ert-start
             (list (quote and) "^portal-\\(linux\\|rex\\)-gui-"
                   (let ((focus (getenv "PORTAL_LINUX_SELECTOR")))
                     (if (equal focus "") t focus))))'
# A terminal with a pair of themes follows the desktop's light or dark, in
# an Emacs on a session bus of its own, where it plays the desktop portal
# (test/portal-linux-scheme-tests.el): yours is never asked to change.
case "$PORTAL_LINUX_SELECTOR" in
    "" | *scheme*)
        if command -v dbus-run-session >/dev/null 2>&1; then
            dbus-run-session -- sh "$root/test/gui-ert.sh" \
                -l "$root/test/portal-linux-gui-tests.el" \
                -l "$root/test/portal-linux-terminal-tests.el" \
                -l "$root/test/portal-linux-scheme-tests.el" \
                --eval '(portal-gui-ert-start
                         (list (quote and) "^portal-linux-scheme-"
                               (let ((focus (getenv "PORTAL_LINUX_SELECTOR")))
                                 (if (equal focus "") t focus))))'
        else
            echo "GUI checks: not run: a terminal following the desktop's light or dark, without dbus-run-session" >&2
        fi
        ;;
esac
# Emacs quits with a view open, shown and drawing, and the keyboard in it:
# the view ends in kill-emacs-hook, and Emacs exits as it was asked to. Once
# with the test pattern, and once with a terminal whose program is printing
# as fast as it can, so that its renderer and the presenter are busy.
[ -z "$PORTAL_LINUX_SELECTOR" ] || exit 0
for view in "(:directory \"/\" :test-pattern t)" "(:directory \"/\" :command \"yes\")"; do
    status=0
    "${EMACS:-emacs}" -Q --module-assertions -L "$root" -l "$root/portal.el" --eval "
(run-at-time
 1 nil
 (lambda ()
   (switch-to-buffer (get-buffer-create \"*quit*\"))
   (let ((target (portal-view-open 'terminal '$view))
         (deadline (+ (float-time) 10)))
     (while (and (not (plist-get (portal--inspect target) :showing)) (< (float-time) deadline))
       (accept-process-output nil 0.02)
       (redisplay t))
     (sit-for 0.5)
     (kill-emacs (if (and (portal--input target \"focus\")
                          (plist-get (portal--inspect target) :showing))
                     0
                   3)))))" || status=$?
    if [ "$status" != 0 ]; then
        echo "GUI checks failed: Emacs quitting with a view $view open exited $status" >&2
        exit 1
    fi
    echo "Emacs quit with a view $view open" >&2
done
