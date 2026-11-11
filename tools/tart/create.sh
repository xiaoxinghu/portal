#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: bash tools/tart/create.sh NEW_VM_NAME LOCAL_IPSW
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=tools/tart/recipe.conf
. "$root/recipe.conf"
[[ $# == 2 && -f $2 ]] || { echo 'Usage: create.sh NEW_VM_NAME LOCAL_IPSW' >&2; exit 1; }
[[ $(tart --version) == "$TART_VERSION" ]] || { echo "Expected Tart $TART_VERSION" >&2; exit 1; }
printf '%s  %s\n' "$IPSW_SHA256" "$2" | shasum -a 256 -c -
# Tart rejects an existing name. No existing VM is deleted or replaced.
TART_NO_AUTO_PRUNE=1 tart create "$1" --from-ipsw "$2" --disk-size "$DISK_SIZE" --disk-format asif
tart set "$1" --cpu "$CPU" --memory "$MEMORY" --display "$DISPLAY" --no-display-refit
shasum -a 256 "$2"
printf 'Created %s. Boot with --dir=setup:/absolute/staged/directory:ro and complete guest setup.\n' "$1"
