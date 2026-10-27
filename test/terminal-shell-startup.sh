#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Native regression: the shell supplies PATH and startup values, not Emacs.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/test/gui-desktop.sh"
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
env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/zsh ZDOTDIR="$fixture/dotfiles" \
    PORTAL_TEST_SHELL_DIRECTORY="$fixture" PORTAL_TEST_EXPENSIVE="${PORTAL_TEST_EXPENSIVE:-}" \
    "${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}" -Q --module-assertions \
    -L "$root" -l "$root/portal.el" -l "$root/test/portal-terminal-tests.el" \
    -l "$root/test/portal-test-tiers.el" \
    --eval '(run-at-time 1 nil
      (lambda ()
        (let ((stats (ert-run-tests-batch
                      (portal-test-tiers-selector
                       "^portal-terminal-start-\\(uses-shell-startup\\|missing-program\\)"))))
          (with-current-buffer "*Messages*" (princ (buffer-string) (quote external-debugging-output)))
          (kill-emacs (if (= (ert-stats-completed-unexpected stats) 0) 0 1)))))'
