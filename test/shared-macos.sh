#!/bin/sh
# Every C file of native/Shared compiles for macOS, on Apple silicon and on
# Intel, with the project's warnings as errors, by Zig's cross-compile: the
# Linux build's Zig, ZIG, and the checkout, ROOT.  Compiling is all it
# says; nothing here runs the code on a Mac.
set -eu
zig=$1
root=$2
for target in aarch64-macos x86_64-macos; do
    for source in "$root"/native/Shared/*.c; do
        "$zig" cc -target "$target" -std=c11 -Wall -Wextra -Werror \
            -I "$root/native/Core/include" -I "$root/native/Shared" \
            -c "$source" -o /dev/null
        echo "$target: ${source#"$root"/}"
    done
done
