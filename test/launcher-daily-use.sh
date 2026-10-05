#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The launcher daily-use suite, kept as an entry point for
# docs/launcher-daily-use.md. It opens disposable Emacs windows; run it in a
# desktop session. PORTAL_LAUNCHER_CONFIG optionally names a file with only the
# completion/theme setup to validate.
exec "$(dirname "$0")/../test.sh" gui --suite launcher-daily-use-gui --allow-gui "$@"
