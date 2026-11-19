#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run via: sh test/linux-desktop.sh COMMAND [ARGUMENT...]
# Run COMMAND on a desktop of its own: a second Hyprland, started inside
# this Wayland session, whose one output is headless. The windows COMMAND
# opens are on no screen of yours, and the keys and clicks a test sends
# there (wtype, test/linux-pointer.c) go to that Hyprland's own seat, never
# to the window you are typing in. COMMAND finds it as WAYLAND_DISPLAY and
# HYPRLAND_INSTANCE_SIGNATURE, with PORTAL_TEST_DESKTOP set to its output's
# name, for grim and wf-recorder, and PORTAL_TEST_DESKTOP_WIDTH, _HEIGHT and
# _SCALE to its size in its own pixels and how many device pixels each is.
# The output is 2560 by 1600 device pixels at scale 2 and 60 Hz, and a
# single window fills it, edge to edge, with nothing drawn around it: a
# pixel of the output is a pixel of the window.
#
# It is the compositor Portal's Linux views were written against, so a
# check here says what a user of it sees. It needs Hyprland 0.56 or newer,
# which reads the Lua configuration written below, and a Wayland session to
# start in. Exits 77, for "could not run here", without them.
set -eu
[ $# -gt 0 ] || { echo "usage: sh test/linux-desktop.sh COMMAND [ARGUMENT...]" >&2; exit 2; }
if [ -z "${WAYLAND_DISPLAY:-}" ] || ! command -v Hyprland >/dev/null 2>&1 ||
    ! command -v hyprctl >/dev/null 2>&1; then
    echo "linux-desktop.sh: needs Hyprland and a Wayland session to start it in" >&2
    exit 77
fi
output=PORTAL-TEST
work=$(mktemp -d "${TMPDIR:-/tmp}/portal-desktop.XXXXXXXX")
cat >"$work/hyprland.lua" <<EOF
hl.monitor({ output = "$output", mode = "2560x1600@60", position = "0x0", scale = 2 })
hl.monitor({ output = "", mode = "1280x800@60", position = "auto", scale = 1 })
hl.config({
    animations = { enabled = false },
    xwayland = { enabled = false },
    misc = { disable_hyprland_logo = true, force_default_wallpaper = 0, focus_on_activate = true,
             disable_splash_rendering = true, disable_watchdog_warning = true },
    decoration = { rounding = 0, shadow = { enabled = false }, blur = { enabled = false } },
    general = { gaps_in = 0, gaps_out = 0, border_size = 0 },
    input = { kb_layout = "us", follow_mouse = 1 },
})
EOF
cat >"$work/start.sh" <<EOF
#!/bin/sh
echo \$\$ >"$work/pid"
exec Hyprland -c "$work/hyprland.lua" >"$work/hyprland.log" 2>&1
EOF
chmod +x "$work/start.sh"
# Its window on this desktop, which it needs to start, goes where it is not
# seen when this desktop is Hyprland's too; it is closed a moment later.
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] &&
    hyprctl eval "hl.exec_cmd('$work/start.sh', { workspace = 'special:portal-test silent' })" \
        >/dev/null 2>&1; then
    :
else
    "$work/start.sh" &
fi
instance= socket= pid=
stop() {
    if [ -n "$instance" ]; then
        hyprctl -i "$instance" dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || :
    fi
    if [ -n "$pid" ]; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -KILL "$pid" 2>/dev/null || :
    fi
    rm -rf "$work"
}
trap stop EXIT
trap 'exit 130' INT TERM
# Its instance, by the process it runs as.
tries=0
while [ -z "$instance" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
        echo "linux-desktop.sh: Hyprland did not start" >&2
        cat "$work/hyprland.log" >&2 2>/dev/null || :
        exit 1
    fi
    sleep 0.1
    [ -s "$work/pid" ] || continue
    pid=$(cat "$work/pid")
    found=$(hyprctl instances 2>/dev/null | awk -v pid="$pid" '
        $1 == "instance" { instance = $2; sub(/:$/, "", instance) }
        $1 == "pid:" && $2 == pid { found = instance }
        $1 == "wl" && $2 == "socket:" && found == instance && found != "" { print found, $3; exit }')
    instance=${found%% *}
    socket=${found##* }
    [ -n "$found" ] || instance=
done
# The headless output alone: the window on this desktop goes with its output.
hyprctl -i "$instance" output create headless "$output" >/dev/null
for other in $(hyprctl -i "$instance" monitors | awk '$1 == "Monitor" { print $2 }'); do
    [ "$other" = "$output" ] || hyprctl -i "$instance" output remove "$other" >/dev/null
done
status=0
env -u DISPLAY WAYLAND_DISPLAY="$socket" HYPRLAND_INSTANCE_SIGNATURE="$instance" \
    GDK_BACKEND=wayland PORTAL_TEST_DESKTOP="$output" PORTAL_TEST_DESKTOP_WIDTH=1280 \
    PORTAL_TEST_DESKTOP_HEIGHT=800 PORTAL_TEST_DESKTOP_SCALE=2 "$@" || status=$?
exit "$status"
