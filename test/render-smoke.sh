#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/render-smoke.sh [--fault blank|shift] [--adapter NAME] [RUNTIME-DIRECTORY]
# The rendering smoke test: does a terminal draw in its pane and take input,
# for the build in RUNTIME-DIRECTORY, a directory such as
# `portal-build-directory' names (by default the checkout's build/), in the
# graphical session this runs in?  test/portal-render-smoke.el is the test;
# this starts it in a fresh Emacs with Portal's Lisp from this checkout,
# bounds it in time and keeps its record.
#
# Exits 0 when every check passed, 1 when one failed or the test did not
# finish within PORTAL_SMOKE_TIMEOUT seconds (default 60), 77 when it could
# not run here: no graphical session, or no way to capture or type in it.
# A not-run is never a pass.  It never starts a desktop or compositor of its
# own.  The record, render-smoke.log, the captures and Emacs's output go to
# render-smoke/ in PORTAL_TEST_LOGS, or in build/; the record is printed at
# the end.  --fault breaks the pane after the token is typed, to check that
# the test finds it: blank hides the view, shift moves it a pixel right and down.
# --adapter names the place's adapter in place of the one the session says.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/test/gui-desktop.sh"
usage() {
    echo "Usage: sh test/render-smoke.sh [--fault blank|shift] [--adapter NAME] [RUNTIME-DIRECTORY]" >&2
    exit 2
}
fault= adapter=
while [ $# -gt 0 ]; do
    case $1 in
        --fault) [ $# -ge 2 ] || usage; fault=$2; shift 2 ;;
        --adapter) [ $# -ge 2 ] || usage; adapter=$2; shift 2 ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
    esac
done
case $fault in ''|blank|shift) ;; *) usage ;; esac
[ $# -le 1 ] || usage
runtime=
if [ $# = 1 ]; then
    [ -d "$1" ] || { echo "render-smoke: no directory $1" >&2; exit 2; }
    runtime=$(CDPATH= cd -- "$1" && pwd -P)
fi
build=${runtime:-$root/build}
out=${PORTAL_TEST_LOGS:-$root/build}/render-smoke
rm -rf "$out"
mkdir -p "$out"
record=$out/render-smoke.log
note() { printf 'smoke: %s\n' "$*" >>"$record"; }
finish() {
    cat "$record"
    exit "$1"
}
budget=${PORTAL_SMOKE_TIMEOUT:-60}

# What ran where, for the record.
note "$(date -u +%Y-%m-%dT%H:%M:%SZ) in $(hostname -s 2>/dev/null || hostname)"
note "checkout $root at $(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo 'no Git metadata')"
note "runtime $build"
if [ -f "$build/portal-build.eld" ]; then
    note "build record $(tr '\n' ' ' <"$build/portal-build.eld")"
else
    note "build record: none in $build"
fi
if [ "$(uname -s)" = Darwin ]; then
    module=$build/portal.bundle/Contents/MacOS/portal.dylib
    note "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)," \
        "$(sysctl -n hw.model), CPU $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores"
    note "GPU $(ioreg -rd1 -c IOAccelerator |
        sed -nE 's/^ *"(model|IOClass|gpu-core-count)" = "?([^"]*)"?$/\1 \2/p' |
        paste -sd ',' - | sed 's/,/, /g')"
    emacs=${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}
else
    module=$build/portal.so
    # An Arm CPU's cores have no model name in /proc/cpuinfo; lscpu names
    # each kind, and the device tree the machine.
    cpu=$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | paste -sd ',' - | sed 's/,/, /g')
    cpu=${cpu:-$(sed -n 's/^model name[^:]*: //p' /proc/cpuinfo | head -n 1)}
    machine=$(tr -d '\0' </proc/device-tree/model 2>/dev/null ||
        cat /sys/class/dmi/id/product_name 2>/dev/null || :)
    note "$(uname -srm), ${machine:+$machine, }CPU ${cpu:-unknown}, $(nproc) cores"
    note "desktop ${XDG_CURRENT_DESKTOP:-unnamed}, Wayland display ${WAYLAND_DISPLAY:-none}"
    # The compositor that draws the frame, and its version.
    if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        note "compositor $(hyprctl version 2>/dev/null | head -n 1 || echo 'Hyprland, hyprctl not answering')"
    else
        case $(printf %s "${XDG_CURRENT_DESKTOP:-}" | tr '[:upper:]' '[:lower:]') in
            *gnome*) note "compositor $(gnome-shell --version 2>/dev/null || echo 'GNOME Shell, version unknown')" ;;
            *kde*) note "compositor $(kwin_wayland --version 2>/dev/null || echo 'KWin, version unknown')," \
                "$(plasmashell --version 2>/dev/null || echo 'plasmashell version unknown')" ;;
        esac
    fi
    # The GPU: each render node's driver and device, and Mesa's renderer
    # when eglinfo is installed.  Ghostty's own report is in emacs.log.
    for node in /sys/class/drm/renderD*; do
        [ -e "$node/device/driver" ] || continue
        device=$(tr '\0' ' ' <"$node/device/of_node/compatible" 2>/dev/null ||
            cat "$node/device/vendor" "$node/device/device" 2>/dev/null | paste -sd: - || :)
        note "GPU ${node##*/}: driver $(basename "$(readlink -f "$node/device/driver")"), device ${device% }"
    done
    if command -v eglinfo >/dev/null 2>&1; then
        note "EGL $(eglinfo -B -p wayland 2>/dev/null |
            sed -nE 's/^OpenGL core profile (renderer|version): /\1 /p' | paste -sd ',' - | sed 's/,/, /g')"
    fi
    emacs=${EMACS:-emacs}
fi
if [ -f "$module" ]; then
    note "module $(shasum -a 256 "$module" 2>/dev/null || sha256sum "$module")"
else
    note "module: none at $module"
fi

# A session to draw in, or not run.
if [ "$(uname -s)" = Darwin ]; then
    if ! launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
        note "NOT RUN: no graphical session for $(id -un): log in at the desktop"
        finish 77
    fi
    # Typing and capturing are in process, with the test-only injector and
    # the window capture beside it.
    include=${EMACS_INCLUDE:-}
    if [ -z "$include" ] && [ -f "$root/build/emacs-include.txt" ]; then
        include=$(cat "$root/build/emacs-include.txt")
    fi
    include=${include:-$(dirname "$emacs")/../Resources/include}
    set -- --eval "(module-load \"$out/test-terminal-input.dylib\")" \
        --eval "(module-load \"$out/test-window-capture.dylib\")"
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle -I "$include" \
        "$root/test/terminal-input.m" \
        -framework AppKit -framework WebKit -framework Carbon -framework IOSurface \
        -o "$out/test-terminal-input.dylib"
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle -I "$include" \
        "$root/test/window-capture.m" -framework AppKit -framework ScreenCaptureKit \
        -o "$out/test-window-capture.dylib"
else
    if [ -z "${WAYLAND_DISPLAY:-}" ]; then
        note "NOT RUN: no Wayland session: WAYLAND_DISPLAY is not set"
        finish 77
    fi
    # On Plasma the test types through KWin's EIS with a libei client of
    # its own, built here; the Lisp says why not when it is missing.
    place=$adapter
    if [ -z "$place" ] && [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        case $(printf %s "${XDG_CURRENT_DESKTOP:-}" | tr '[:upper:]' '[:lower:]') in
            *kde*) place=plasma ;;
        esac
    fi
    if [ "$place" = plasma ]; then
        if flags=$(pkg-config --cflags --libs libei-1.0 dbus-1 2>&1) &&
            why=$(${CC:-cc} -std=c11 -Wall -Wextra -Werror -o "$out/linux-ei-type" \
                "$root/test/linux-ei-type.c" $flags 2>&1); then
            export PORTAL_SMOKE_EI_TYPE="$out/linux-ei-type"
        else
            export PORTAL_SMOKE_EI_WHY="${why:-$flags}"
        fi
    fi
    set --
fi

started=$(date +%s)
PORTAL_SMOKE_OUT=$out PORTAL_SMOKE_RUNTIME=$runtime PORTAL_SMOKE_FAULT=$fault \
PORTAL_SMOKE_ADAPTER=$adapter \
    "$emacs" -Q -L "$root" -L "$root/test" \
    --eval '(let ((runtime (getenv "PORTAL_SMOKE_RUNTIME")))
              (unless (equal runtime "")
                (setq portal-build-directory (file-name-as-directory runtime))))' \
    -l "$root/portal.el" "$@" -l "$root/test/portal-render-smoke.el" \
    --eval '(run-at-time 0.5 nil (function portal-render-smoke))' \
    >"$out/emacs.log" 2>&1 &
pid=$!
# Emacs starts each subprocess in a process group of its own, which would
# outlive it.
stop() {
    children=$(pgrep -P "$pid" || :)
    kill -KILL "$pid" 2>/dev/null || :
    for child in $children; do kill -KILL -- "-$child" "$child" 2>/dev/null || :; done
}
trap stop EXIT
while kill -0 "$pid" 2>/dev/null && [ $(($(date +%s) - started)) -lt "$budget" ]; do
    sleep 0.2
done
if kill -0 "$pid" 2>/dev/null; then
    if command -v sample >/dev/null 2>&1; then
        sample "$pid" 2 -file "$out/emacs-sample.log" >/dev/null 2>&1 || :
    fi
    stop
    wait "$pid" 2>/dev/null || :
    note "FAIL the test did not finish within ${budget}s; Emacs sampled to emacs-sample.log"
    finish 1
fi
status=0
wait "$pid" || status=$?
trap - EXIT
note "Emacs exited $status after $(($(date +%s) - started))s"
case $status in
    0|1|77) ;;
    *)
        if grep -q 'WindowServer' "$out/emacs.log" 2>/dev/null; then
            note "NOT RUN: Emacs could not reach the window server; see emacs.log"
            status=77
        else
            note "FAIL Emacs ended with status $status; its output is in emacs.log"
            status=1
        fi
        ;;
esac
finish "$status"
