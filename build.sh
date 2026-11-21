#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

# One build of these outputs at a time: a second one stops at once, with
# status 75.  macOS has lockf, which exits so; Linux has flock, which is told to.
if [ -z "${PORTAL_BUILD_LOCKED:-}" ]; then
    mkdir -p build
    status=0
    if [ "$(uname -s)" = Darwin ]; then
        PORTAL_BUILD_LOCKED=1 lockf -k -t 0 build/.build.lock /bin/sh "$here/build.sh" "$@" ||
            status=$?
    else
        PORTAL_BUILD_LOCKED=1 flock -n -E 75 build/.build.lock /bin/sh "$here/build.sh" "$@" ||
            status=$?
    fi
    if [ "$status" -eq 75 ]; then
        echo "build.sh: another Portal build is running in $here" >&2
    fi
    exit "$status"
fi

# --prune, first, builds only what Portal runs and then deletes everything else:
# the build tree and the host's packages, about 750 MB, and on Linux Ghostty's
# source and Zig's cache, over 1 GB more.  Installed packages use it; the next
# build starts afresh from SwiftPM's, Zig's and Bun's download caches.
prune=
if [ "${1:-}" = --prune ]; then
    prune=1
    shift
    set -- "$@" -DBUILD_TESTING=OFF
fi

# Emacs started from the Dock lacks the shell's PATH.  Like portal-build.el's
# portal-build--tool-directories, look where Homebrew and MacPorts install too.
for dir in /opt/homebrew/bin /usr/local/bin /opt/local/bin; do
    case ":$PATH:" in *":$dir:"*) ;; *) PATH=$PATH:$dir ;; esac
done
export PATH

# BUN, a compatible bun on PATH, Portal's cached Bun, or a verified download;
# see tools/resolve-bun.sh.  A -DBUN argument is an explicit choice, like BUN.
for argument in "$@"; do
    case $argument in -DBUN=*|-DBUN:*=*) BUN=${argument#*=}; export BUN ;; esac
done
bun=$(/bin/sh tools/resolve-bun.sh)
set -- "-DBUN=$bun" "$@"
# Preserve the existing environment overrides, including on later builds.
if [ -n "${EMACS:-}" ]; then set -- "$@" "-DEMACS=$EMACS"; fi
if [ -n "${EMACS_INCLUDE:-}" ]; then set -- "$@" "-DEMACS_INCLUDE=$EMACS_INCLUDE"; fi
cmake --preset dev "$@"
cmake --build --preset dev
if [ -n "$prune" ]; then
    # Keep the outputs, the build record and log, the lock, the Bun cache and
    # the record of the libghostty-spm copy the module was built from.
    find build -mindepth 1 -maxdepth 1 ! -name portal.bundle ! -name portal.so \
        ! -name ghostty-linux ! -name portal-host \
        ! -name licenses ! -name portal-build.eld ! -name portal-build.log \
        ! -name libghostty-spm.state \
        ! -name .build.lock ! -name tools -exec rm -rf {} +
    # Of Ghostty's install on Linux, what portal.so loads: the library, by its
    # file and its soname, and the resources.
    if [ -d build/ghostty-linux ]; then
        find build/ghostty-linux -mindepth 1 -maxdepth 1 ! -name lib ! -name share \
            -exec rm -rf {} +
        find build/ghostty-linux/lib -mindepth 1 -maxdepth 1 ! -name ghostty-internal.so \
            ! -name libghostty.so -exec rm -rf {} +
        find build/ghostty-linux/share -mindepth 1 -maxdepth 1 ! -name ghostty \
            ! -name terminfo -exec rm -rf {} +
    fi
    rm -rf host/node_modules host/.generated
    echo "Removed the intermediate files: the next build starts afresh"
fi
if [ "$(uname -s)" = Darwin ]; then module=portal.bundle; else module=portal.so; fi
echo "Built build/$module, build/portal-host and build/licenses"
