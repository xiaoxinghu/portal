#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run Portal's tests by category; see docs/testing.md or ./test.sh --help.
exec python3 -B "$(dirname "$0")/test/runner.py" "$@"
