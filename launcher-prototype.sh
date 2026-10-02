#!/bin/bash
# THROWAWAY: isolated native launcher experiment, no user init or working server.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
EMACS_BIN="${EMACS:-/Applications/Emacs.app/Contents/MacOS/Emacs}"
EMACS_HEADER="${EMACS_INCLUDE:-/Applications/Emacs.app/Contents/Resources/include}"
xcrun clang -bundle -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -I "$EMACS_HEADER" -framework AppKit -framework Carbon \
    experiments/launcher-prototype.m -o build/launcher-prototype.tmp.dylib
mv build/launcher-prototype.tmp.dylib build/launcher-prototype.dylib
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
if [[ "${1:-}" == "--workflows" ]]; then
    set -- -l "$PWD/experiments/launcher-workflows.el"
else
    set --
fi
exec "$EMACS_BIN" -Q -l "$PWD/portal-launcher-prototype.el" \
    --eval '(condition-case err (portal-prototype-start) (error (message "%s" (error-message-string err)) (kill-emacs 1)))' \
    "$@" \
    >build/launcher-prototype.log 2>&1
