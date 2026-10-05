#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Native regression: the shell supplies PATH and startup values, not Emacs.
# CTest runs this as the terminal-startup-gui suite (docs/testing.md).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/dotfiles" "$fixture/tools"
cat > "$fixture/dotfiles/.zprofile" <<'PROFILE'
export PORTAL_SHELL_PROFILE=login-loaded
PROFILE
cat > "$fixture/dotfiles/.zshrc" <<'RC'
export PATH="$PORTAL_TEST_SHELL_DIRECTORY/tools:/usr/bin:/bin"
export PORTAL_SHELL_RC=interactive-loaded
cd "$PORTAL_TEST_SHELL_DIRECTORY"
RC
cat > "$fixture/tools/portal-startup-cli" <<'PY'
#!/usr/bin/python3
import json, os, sys
with open(sys.argv[1] + '.tmp', 'w') as f:
    json.dump(dict(args=sys.argv[2:], cwd=os.getcwd(),
                   profile=os.getenv('PORTAL_SHELL_PROFILE'), rc=os.getenv('PORTAL_SHELL_RC'),
                   lisp=os.getenv('PORTAL_LISP_ONLY'), term=os.getenv('TERM'),
                   inside=os.getenv('INSIDE_EMACS')), f)
os.replace(sys.argv[1] + '.tmp', sys.argv[1])
PY
chmod +x "$fixture/tools/portal-startup-cli"
cp "$fixture/tools/portal-startup-cli" "$fixture/tools/portal ' é\tool"
# The suite's result and build variables pass through; nothing else from this shell.
env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/zsh ZDOTDIR="$fixture/dotfiles" \
    PORTAL_TEST_SHELL_DIRECTORY="$fixture" \
    PORTAL_TEST_RESULTS_DIR="${PORTAL_TEST_RESULTS_DIR:-}" PORTAL_TEST_SUITE="${PORTAL_TEST_SUITE:-}" \
    PORTAL_TEST_BUILD="${PORTAL_TEST_BUILD:-$root/build}" \
    "${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}" -Q --module-assertions \
    -L "$root" -L "$root/test" -l "$root/portal.el" -l "$root/test/portal-suite.el" \
    -f portal-suite-graphical "$root/test/portal-terminal-startup-gui-tests.el"
