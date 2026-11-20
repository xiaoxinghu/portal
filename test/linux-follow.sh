#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/linux-follow.sh [fill|terminal|fed]
# Record a view following its pane and check every frame of the recording:
# after ./build.sh, on the desktop of test/linux-desktop.sh. A fresh Emacs
# opens a test pattern in a pane and changes that pane, one command every
# PORTAL_FOLLOW_INTERVAL seconds (default 0.4), PORTAL_FOLLOW_ROUNDS times
# over (default 3): the steps of PORTAL_FOLLOW_STEPS, by default splits, a
# pane made larger, one pane again, the buffer switched away and back, a
# second frame that halves the first and goes again, and another program's
# window that does the same (test/portal-linux-follow.el names them all). wf-recorder records the
# output meanwhile, 60 frames a second and lossless, and
# test/linux-recording.py reads the recording: in every frame the view must
# be exactly over its pane, covering all of it and nothing else, but for
# the frames in which a window the compositor has resized shows its last
# frame at the new size, which are counted apart. With "fill", the pattern is a single pixel
# stretched over the pane. With "terminal", the view is a terminal whose shell
# prints blank lines all the while, so that its renderer makes frames as the
# pane changes, each one its theme's orange background. With "fed", a Rex
# block's terminal of the fake Rex server's, fed blank lines all the while:
# it holds the block's grid, which follows the pane a moment later, with the
# theme's background beside it, so the pane is that orange throughout too.
#
# It exits 0 when no frame is out of place, 1 when one is, naming each, and
# 77 where the desktop cannot start. The recording stays in
# PORTAL_TEST_LOGS, or build/linux-follow, as follow.mkv. Beside Hyprland it
# needs wf-recorder, ffmpeg and Python 3.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "${PORTAL_TEST_DESKTOP:-}" ]; then
    exec sh "$root/test/linux-desktop.sh" sh "$0" "$@"
fi
for tool in wf-recorder ffmpeg ffprobe python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "linux-follow.sh: needs $tool" >&2; exit 1; }
done
logs=${PORTAL_TEST_LOGS:-$root/build/linux-follow}
mkdir -p "$logs"
work=$(mktemp -d "${TMPDIR:-/tmp}/portal-follow.XXXXXXXX")
export PORTAL_FOLLOW_DIRECTORY="$work" PORTAL_FOLLOW_PATTERN="${1:-}"
: "${PORTAL_FOLLOW_STEPS:=split-below split-right taller wider one-pane away back second-frame first-frame-alone second-window wait wait wait first-window-alone wait}"
: "${PORTAL_FOLLOW_ROUNDS:=3}" "${PORTAL_FOLLOW_INTERVAL:=0.4}"
export PORTAL_FOLLOW_STEPS PORTAL_FOLLOW_ROUNDS PORTAL_FOLLOW_INTERVAL
emacs= recorder=
stop() {
    [ -z "$recorder" ] || kill -INT "$recorder" 2>/dev/null || :
    [ -z "$emacs" ] || kill -KILL "$emacs" 2>/dev/null || :
    rm -rf "$work"
}
trap stop EXIT
# Wait for Emacs to leave FILE in the work directory, for at most SECONDS.
await() {
    tries=0
    until [ -e "$work/$1" ]; do
        tries=$((tries + 1))
        if [ "$tries" -gt $(($2 * 10)) ] || ! kill -0 "$emacs" 2>/dev/null; then
            echo "linux-follow.sh: Emacs did not get to \"$1\"" >&2
            cat "$logs/emacs.log" >&2
            exit 1
        fi
        sleep 0.1
    done
}
"${EMACS:-emacs}" -Q --module-assertions -L "$root" -L "$root/test" -l "$root/portal.el" \
    -l "$root/test/portal-linux-follow.el" -f portal-linux-follow-start >"$logs/emacs.log" 2>&1 &
emacs=$!
await ready 30
# Every frame, changed or not, so that a frame's number is its time.
wf-recorder -o "$PORTAL_TEST_DESKTOP" -D -r 60 -c libx264rgb -p preset=ultrafast -p crf=0 \
    -f "$logs/follow.mkv" -y >"$logs/recorder.log" 2>&1 &
recorder=$!
sleep 1
: >"$work/go"
await done 300
echo "The view at the end: $(cat "$work/facts")"
sleep 0.5
kill -INT "$recorder"
wait "$recorder" 2>/dev/null || :
recorder=
kill -KILL "$emacs" 2>/dev/null || :
wait "$emacs" 2>/dev/null || :
emacs=
if [ "$PORTAL_FOLLOW_PATTERN" = terminal ] || [ "$PORTAL_FOLLOW_PATTERN" = fed ]; then
    # Great Pumpkin's background (test/portal-linux-follow.el).
    python3 -B "$root/test/linux-recording.py" "$logs/follow.mkv" f98128
else
    python3 -B "$root/test/linux-recording.py" "$logs/follow.mkv"
fi
