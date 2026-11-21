# Licenses and third-party notices

Recorded: 2026-10-11, against the locked dependencies of this commit.

Portal is licensed under [GPL-3.0-or-later](../LICENSE). Its build outputs also
contain third-party code, fonts and data under their own licenses. `./build.sh`
stages Portal's license and every required notice in `build/licenses/`, and the
`licenses` CTest suite fails when a notice is missing, stale or no longer matches
what the build ships. This page records what ships, what remains unresolved
before a binary release, and how to keep the inventory current.

The inventory lives in [licenses/inventory.json](../licenses/inventory.json):
each component's version, source, license, where it ships and its notice files.
`build/licenses/README.md` is the generated index of the same data plus every
bundled npm package. This page does not repeat the versions.

## Release layout

Distribute these together; the notices are part of the release:

| Path | Contents |
| --- | --- |
| `LICENSE`, `portal*.el` | Portal's license and Lisp |
| `build/portal.bundle` | The native module and the terminal resources it loads |
| `build/portal.so`, `build/ghostty-linux` | On Linux, the native module and, beside it, Ghostty's library and resources, as `build.sh --prune` leaves them |
| `build/portal-host` | The standalone app host, with the Bun runtime inside |
| `build/licenses/` | A copy of Portal's license, the generated index and every third-party notice |
| `SOURCE.md`, `source.json` | On macOS, where to get the module's [corresponding source](#corresponding-source), staged by `bun licenses/source.ts stage` |

`build/licenses/` is generated; change `licenses/` instead. The files in
`licenses/texts/` are byte-for-byte copies of upstream license files from the
revision each inventory entry cites, and `.gitattributes` keeps Git from
normalizing them.

A binary release also needs the corresponding source. A list of dependency
names is not that source. The macOS module's is
[given as pointers](#corresponding-source); the rest is still
[unresolved](#unresolved-before-a-binary-release).

## What the build ships

The native module, `portal.bundle/Contents/MacOS/portal.dylib`, contains Portal's
C core and Swift backend, statically linked with:

- libghostty-spm, the Swift wrapper, at the release `native/libghostty-spm.json`
  pins with Portal's patches applied, and DisplayLink, from a SwiftPM checkout at
  its `native/Package.resolved` pin. The wrapper's GhosttyTheme module compiles
  in iTerm2-Color-Schemes data; SwiftPM drops that data's license from the build,
  so the staged copy is the only one that ships.
- Ghostty, as the wrapper's prebuilt `libghostty.a`. The library's object members
  and symbols show what it contains: FreeType, libpng, zlib, Oniguruma, Wuffs,
  Highway, simdutf, stb_image, libxev, libvaxis, z2d, zig-objc, uucode, the Zig
  standard library and compiler-rt, plus the embedded JetBrains Mono and Symbols
  Nerd Font fonts. Versions come from the `build.zig.zon` files at the Ghostty
  revision the release names. Ghostty's other optional packages, such as
  HarfBuzz, fontconfig and glslang, are absent from this macOS library. So are
  zigimg, which only libvaxis's image loading uses and Ghostty never calls, and
  GNU libintl, which the wrapper's `0021-no-libintl.sh` patch leaves unlinked.

The bundle's resources hold Ghostty's compiled terminfo and the wrapper's bash
and zsh integration. That integration is the wrapper's own MIT rewrite, not
Ghostty's GPL-3.0 scripts; its vendored bash-preexec keeps its license file in
the bundle, and the check verifies that file is still there.

The app host, `portal-host`, contains the Bun runtime, Portal's host code and
icons, and the Excalidraw editor bundle. Bun's bundler records name every bundled
file: about 135 npm packages, including React, Excalidraw, Mermaid, Radix UI,
D3 and Cytoscape, and nine Excalidraw font families. Some prebuilt packages
contain other projects' code: Mermaid's parser compiles in Langium, Chevrotain,
the VS Code language server libraries, lodash-es and path-browserify; Mermaid
compiles in js-yaml; Excalidraw compiles in fonteditor-core, with Google's woff2
and Brotli as WebAssembly, and harfbuzzjs with HarfBuzz; Cytoscape contains
Thenable.

A Linux build's module, `build/portal.so`, contains Portal's C core and C
backend and nothing of another project: it loads GTK 3 and `wayland-client`
from the system, and Ghostty's library from `build/ghostty-linux` beside it.
That library is Portal's own build of the Ghostty release
`native/ghostty.json` pins, with Portal's patches, so its notices are
required by that pin (`ghostty@VERSION` in the inventory), not by a Swift
package. Two of those patches, the host-managed backend and replay without
replies, are libghostty-spm's, under its MIT license, and have a component of
their own with the package's license text. Zig's build links into `lib/ghostty-internal.so` FreeType, HarfBuzz,
fontconfig with libxml2, libpng, zlib, Oniguruma, glslang, SPIRV-Cross, Dear
ImGui with Dear Bindings and its ProggyClean font, glad, Wuffs, Highway,
simdutf, stb_image and stb_image_resize, libxev, libvaxis, z2d, zf, uucode,
X11's `rgb.txt`, the Zig standard library and compiler-rt, and the LLVM
libc++, libc++abi and libunwind that Zig bundles, plus the embedded JetBrains
Mono and Symbols Nerd Font fonts. It loads only libc, libm and libEGL from the
system, and exports Ghostty's C API alone. The evidence for each is in the
component's entry. zigimg is absent: libvaxis's image loading is not reached.

The resources ship as Ghostty has them, not as libghostty-spm rewrote them for
macOS: `share/ghostty/shell-integration` holds Ghostty's bash and zsh
integration, which is GPL-3.0-or-later (derived from Kitty's), its elvish,
fish and nushell integration under Ghostty's MIT license, and bash-preexec;
`share/ghostty/themes` holds the iTerm2-Color-Schemes themes; `share/terminfo`
holds Ghostty's terminfo entry.

Several of these versions are not the ones Ghostty's `build.zig.zon` files
name: their labels are stale (fontconfig is 2.18.3, simdutf 9.0.0), and the
inventory records what the archives contain. The Zig and LLVM runtime
components describe the Zig that builds the library, any patch release of the
one the pin names.

Both outputs link only macOS system frameworks and libraries, including the Swift
runtime and libc++, which Portal does not redistribute. A search of Portal's own
sources for license and copyright markers found no copied third-party code.

### Build-only dependencies

These build or test Portal but are not part of its outputs:

- Bun as package manager, bundler and compiler. Its runtime does ship inside
  `portal-host`.
- The host's development dependencies (Biome, TypeScript and type packages) and
  any installed npm package that the bundler records do not name.
- Apple's Swift and Clang toolchains and SDK, CMake and Ninja; on Linux, GCC,
  CMake, Ninja, pkg-config, Zig and ncurses' `tic`, which compiles Ghostty's
  terminfo.
- Emacs's `emacs-module.h` (GPL-3.0-or-later), read at compile time.
- The GNU ELPA packages downloaded for tests: Consult, Embark, Vertico, Orderless
  and Marginalia.
- The wrapper's other products and platform slices, such as ShellCraftKit.

## License compatibility

The staged texts back these findings; they are not legal advice. Most components
use licenses that GPL-3.0 accepts: MIT, BSD, ISC, Zlib, libpng-2.0, Apache-2.0,
0BSD, CC0-1.0 and Unicode-3.0. Others need specific handling:

- FreeType is offered under the FreeType License or GPL-2.0-or-later. Its own
  LICENSE.TXT says the FTL is compatible with GPL-3.0; the FTL requires the
  credit that the generated index prints.
- z2d is MPL-2.0 without the "Incompatible With Secondary Licenses" notice; it
  may combine with GPL-3.0 code but carries a source obligation.
- DOMPurify is offered under MPL-2.0 or Apache-2.0.
- The OFL-1.1 and MIT fonts may ship with software when their copyright and
  license accompany them, which the staged notices do. Two fonts remain open.

## Corresponding source

The macOS module's corresponding source is given as **pointers**: where to
fetch each input and the revision or digest that identifies it, with the steps
to rebuild. Portal hosts no copies. The owner chose this on 2026-11-21 over
attaching the inputs to each release (roughly 100–250 MB). The reasons:

- Nearly all of Portal's code is the owner's, so its GPL-3.0 source requirement
  is the owner's own to meet.
- In the module, only z2d (MPL-2.0) is third-party code whose license requires
  its source to be available. Its file-level terms cover z2d's own files, and
  its pinned archive is a public GitHub download.
- z2d cannot be removed with reasonable effort. Ghostty's sprite renderer draws
  every cursor, underline and box-drawing glyph with it. Removing it would mean
  patching Ghostty and building its library for macOS in Portal.

Pointers depend on the upstreams staying available: GitHub for Portal,
libghostty-spm, DisplayLink, Ghostty and z2d; ziglang.org for Zig; and
`deps.files.ghostty.org`, Ghostty's mirror, for most of its archives. Whether a
link to z2d's upstream archive meets MPL-2.0 is the owner's judgement, not
settled by this page. If an upstream disappears, a release must attach that
input instead.

The inputs are:

- Portal at the release commit, which holds its patches to libghostty-spm.
- libghostty-spm at its pin, whose `Patches/` and `Script/` build Ghostty's
  library. The prebuilt `GhosttyKit.xcframework` that the pin downloads was
  built by libghostty-spm's own release workflow, at a commit whose
  `Patches/`, `Script/` and `Ghostty.ref` are the pin's. So the pin's source is
  the library's source.
- DisplayLink at its `native/Package.resolved` pin.
- Ghostty at the pin's `Ghostty.ref`.
- Zig at the version that workflow builds with: its source, whose standard
  library and compiler-rt are in the library, and its Apple Silicon compiler.
- Every archive that Ghostty's `build.zig.zon` files pin at that revision, by
  URL and Zig package hash.

[licenses/source.json](../licenses/source.json) records what Portal's own files
do not: the commit that built the library, Ghostty's revision, the prebuilt
library's URL and digest, Zig's downloads and digests, the archives, and which
components ship from inside another input (`vendored`). It is written by
`bun licenses/source.ts refresh`, which fetches only what is missing from
`PORTAL_LIBGHOSTTY_SPM_CLONE` and `PORTAL_GHOSTTY_CLONE` when they are set. The
refresh fails when the library's build commit has different patches or scripts
from the pin.

A release stages the pointers beside its archive, from the build it archives:

```sh
bun licenses/source.ts stage build dist/source
```

This writes `SOURCE.md`, which lists the inputs and the rebuild steps with the
release's values filled in, and `source.json`, the same in JSON, mapping each
component to the input that holds its source. It works on a pruned build. It
fails, and writes nothing, in any of these cases:

- The module is not Apple Silicon.
- The checkout has changes that no commit holds.
- `licenses/source.json` was read from another libghostty-spm pin.
- An input has no revision or digest.
- A component that the build's `licenses/README.md` lists in the module has no
  input that holds its source.
- That index lacks a component the pins require.

The `corresponding-source` CTest suite checks each of these failures, and
checks the build's own notices against the inputs.

The Linux module's corresponding source is
`tasks/portal/runtime-linux-notices-source.md`'s to settle; nothing here
covers Portal's own Ghostty build.

## Unresolved before a binary release

The generated index repeats the per-component items.

1. **Corresponding source.** A binary release conveys the object code of the
   whole module and host, so GPL-3.0 section 6 requires the corresponding source
   or a written offer; the LGPL and MPL-2.0 also require it for JavaScriptCore
   and z2d. That source is Portal at the release commit, which holds its patches
   to libghostty-spm; libghostty-spm at its pinned revision, including its `Patches/` and build scripts that produce the
   prebuilt library; Ghostty at the revision that release names, or on Linux
   at the revision `native/ghostty.json` pins, with Portal's patches and
   `tools/build-ghostty-linux.sh`; the dependency archives Ghostty's `build.zig.zon` files pin; Bun at its
   release tag, with oven-sh/WebKit at the commit Bun pins and the libraries Bun's
   build scripts pin; and the npm packages at the lockfile versions. Statically
   linked LGPL code, such as JavaScriptCore in Bun, also needs a way to relink
   with a modified library; complete build sources and scripts provide that.
   The macOS module's part is settled: see
   [corresponding source](#corresponding-source). Linux's Ghostty build, Bun
   and the npm packages still have no release mechanism.
2. **Bun's notices.** Only Bun's LICENSE.md is staged. Bun publishes no license
   texts for the roughly 25 libraries it links statically, the Rust crates behind
   lol-html and argon2, or WebKit's per-file notices. Portal does not pin Bun yet
   (task 1), so the check accepts only the Bun versions the inventory lists.
3. **Liberation Sans.** Excalidraw ships Liberation Sans 1.05, which is under
   GPL-2.0 with font exceptions and Red Hat's license agreement, not the OFL of
   Liberation 2.x. The agreement requires renaming modified versions, and this
   WOFF2 conversion keeps the name. Decide whether it may ship inside the
   GPL-3.0 host, or replace or drop it.
4. **Cascadia Code.** The shipped 2005.150 file's license metadata opens with
   Microsoft "supplied font" terms that prohibit other use, before an OFL-based
   grant. The upstream release is OFL-1.1. Confirm which terms govern this file,
   or ship a release with plain OFL metadata.
5. **Unrecorded versions.** No upstream record gives the exact versions of
   woff2 and Brotli inside fonteditor-core's WebAssembly, path-browserify inside
   Mermaid's parser, or bash-preexec in the wrapper. Their texts come from the
   cited revisions.
6. **Portal artwork.** `assets/portal.png` and `host/icons/` are assumed to be
   project-owned under Portal's license; record their provenance.

## When dependencies change

Rebuild, then run `ctest --test-dir build -R licenses --output-on-failure`. Each
failure names the file to update:

- **Bundled npm packages changed.** For each new package, look for code from
  other projects in its bundled files: search for `@license`, `Copyright` and
  `/*!` banners, and read any source maps. The check already reports packages that
  source maps reveal. Add a component for anything found, then update
  `licenses/npm-reviewed.txt` to the printed list.
- **A package ships no license file.** Copy the license from upstream at that
  version into `licenses/texts/packages/` and add a component whose `when` lists
  the package version.
- **A component's version is no longer shipped.** A dependency upgrade made it
  stale, including any code or fonts recorded under it. Review the new version
  and update the component and its texts.
- **A new Swift pin or wrapper version.** The wrapper's version is in
  `native/libghostty-spm.json`, the other Swift pins in `native/Package.resolved`. Thin the new prebuilt library with
  `lipo`, list its members with `ar -t` and its symbols with `nm`, read the
  `build.zig.zon` files at the Ghostty revision its `Ghostty.ref` names, and
  update the Ghostty components and texts. Then run
  `bun licenses/source.ts refresh` and commit `licenses/source.json`. Check
  that each component in `vendored` still ships from the input it names.
- **A new Ghostty pin on Linux, or new patches there.** The pin is in
  `native/ghostty.json`. Read the `build.zig.zon` files and
  `src/build/SharedDeps.zig` at the new revision, check the library with
  `readelf -d` and `strings` (it exports only `ghostty_` symbols, so `nm`
  shows little), and update the components whose `when` names
  `ghostty@VERSION`, with their texts.
- **A new Bun version.** Add `licenses/texts/bun/VERSION/LICENSE.md` from that
  release's tag and a component for `bun@VERSION`.

Keep upstream license texts unedited. When a notice is only part of a file, such
as stb_image's license block, copy that part verbatim and say so in the
component's note.
