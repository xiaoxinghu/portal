#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/linux-gui.sh [SELECTOR]
# Portal's views, input, terminals and web views on Linux, after ./build.sh:
# the suites of test/portal-linux-gui-tests.el, its terminals', fed
# terminals' and pages', and test/portal-rex-gui-tests.el, Rex blocks shown
# against the fake server, in one fresh Emacs, through test/gui-ert.sh; then
# the themes of test/portal-linux-scheme-tests.el in another, on a session
# bus of its own that dbus-run-session starts; then a page drawn in memory
# and a web view where WPE WebKit is not installed, each in an Emacs of its
# own; then an Emacs that quits with a view open. SELECTOR, an ERT regexp,
# narrows the suites. It runs on a desktop of its own, a second Hyprland with a
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
    -l "$root/test/portal-linux-web-tests.el" \
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
# Pages' suite alone, in an Emacs of its own, for the tests named SELECTOR.
web() {
    sh "$root/test/gui-ert.sh" \
        -l "$root/test/portal-linux-gui-tests.el" \
        -l "$root/test/portal-linux-terminal-tests.el" \
        -l "$root/test/portal-linux-web-tests.el" \
        --eval "(portal-gui-ert-start \"$1\")"
}
# A page drawn in memory, as where the compositor takes no DMABUF or EGL
# names no GPU: only a process's first page decides.
case "$PORTAL_LINUX_SELECTOR" in
    "" | *memory*) PORTAL_TEST_WEB_MEMORY=1 web "^portal-linux-web-memory-" ;;
esac
# A web view where WPE WebKit is not installed says what to install, and
# terminals work: WPE WebKit's library is an empty file in that Emacs, which
# bwrap makes, as it makes WebKit's own sandbox. A build without web views
# says so the same way, with no bwrap.
case "$PORTAL_LINUX_SELECTOR" in
    "" | *without*)
        wpe=$({ ldconfig -p || /sbin/ldconfig -p; } 2>/dev/null |
            sed -n 's/.*libWPEWebKit-2\.0\.so\.1 .*=> //p' | head -1)
        if [ ! -f "$root/build/portal-web.so" ] || [ -z "$wpe" ]; then
            PORTAL_TEST_NO_WPE=1 web "^portal-linux-web-without-"
        elif command -v bwrap >/dev/null 2>&1; then
            PORTAL_TEST_NO_WPE=1 bwrap --dev-bind / / --ro-bind /dev/null "$(realpath "$wpe")" \
                sh "$root/test/gui-ert.sh" \
                -l "$root/test/portal-linux-gui-tests.el" \
                -l "$root/test/portal-linux-terminal-tests.el" \
                -l "$root/test/portal-linux-web-tests.el" \
                --eval '(portal-gui-ert-start "^portal-linux-web-without-")'
        else
            echo "GUI checks: not run: a web view without WPE WebKit, without bwrap" >&2
        fi
        ;;
esac
# Emacs quits with a view open, shown and drawing, and the keyboard in it:
# the view ends in kill-emacs-hook, and Emacs exits as it was asked to. Once
# with the test pattern, once with a terminal whose program is printing as
# fast as it can, so that its renderer and the presenter are busy, and once
# with a page drawing every frame, where the build has web views. Nothing
# Emacs started runs on after it, WebKit's processes among them, which
# have its environment.
[ -z "$PORTAL_LINUX_SELECTOR" ] || exit 0
page=$(mktemp "${TMPDIR:-/tmp}/portal-quit.XXXXXXXX")
trap 'rm -f "$page"' EXIT
printf '%s\n' '<!doctype html><style>html{background:#f98128}</style><script>' \
    'requestAnimationFrame(function frame(now) {' \
    '  document.title = now; requestAnimationFrame(frame); });</script>' >"$page"
views="terminal (:directory \"/\" :test-pattern t)
terminal (:directory \"/\" :command \"yes\")"
[ ! -f "$root/build/portal-web.so" ] || views="$views
web (:load \"file://$page\")"
echo "$views" | while IFS= read -r line; do
    kind=${line%% *} view=${line#* }
    mark=portal-quit-$$-$kind-$(date +%s%N)
    status=0
    PORTAL_QUIT_MARK=$mark "${EMACS:-emacs}" -Q --module-assertions -L "$root" \
        -l "$root/portal.el" --eval "
(run-at-time
 1 nil
 (lambda ()
   (condition-case failure
       (progn
         (switch-to-buffer (get-buffer-create \"*quit*\"))
         (let ((target (portal-view-open '$kind (unless (eq '$kind 'web) '$view)))
               (deadline (+ (float-time) 10)))
           (when (eq '$kind 'web)
             (portal--web-load target (plist-get '$view :load)))
           (while (and (not (plist-get (portal--inspect target) :showing))
                       (< (float-time) deadline))
             (accept-process-output nil 0.02)
             (redisplay t))
           (sit-for 0.5)
           (kill-emacs (if (and (portal--input target \"focus\")
                                (plist-get (portal--inspect target) :showing))
                           0
                         3))))
     ;; A web view where WPE WebKit is missing says so: not run, 4.
     (error (message \"%s\" (error-message-string failure))
            (kill-emacs (if (string-match-p \"WPE WebKit\" (error-message-string failure)) 4 5))))))" ||
        status=$?
    if [ "$status" = 4 ]; then
        echo "GUI checks: not run: Emacs quitting with a page open, without WPE WebKit" >&2
        continue
    fi
    if [ "$status" != 0 ]; then
        echo "GUI checks failed: Emacs quitting with a $kind view $view open exited $status" >&2
        exit 1
    fi
    sleep 2
    if grep -lsa "PORTAL_QUIT_MARK=$mark" /proc/[0-9]*/environ >/dev/null; then
        echo "GUI checks failed: a process of Emacs's ran on after it quit with a $kind view" >&2
        exit 1
    fi
    echo "Emacs quit with a $kind view $view open" >&2
done
