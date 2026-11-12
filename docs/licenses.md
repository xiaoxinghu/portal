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
| `build/portal-host` | The standalone app host, with the Bun runtime inside |
| `build/licenses/` | A copy of Portal's license, the generated index and every third-party notice |

`build/licenses/` is generated; change `licenses/` instead. The files in
`licenses/texts/` are byte-for-byte copies of upstream license files from the
revision each inventory entry cites, and `.gitattributes` keeps Git from
normalizing them.

A binary release also needs the corresponding source described under
[unresolved before a binary release](#unresolved-before-a-binary-release).
A list of dependency names is not that source.

## What the build ships

The native module, `portal.bundle/Contents/MacOS/portal.dylib`, contains Portal's
C core and Swift backend, statically linked with:

- libghostty-spm, the Swift wrapper, and DisplayLink, from SwiftPM checkouts at
  the `native/Package.resolved` pins. The wrapper's GhosttyTheme module compiles
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

Both outputs link only macOS system frameworks and libraries, including the Swift
runtime and libc++, which Portal does not redistribute. A search of Portal's own
sources for license and copyright markers found no copied third-party code.

### Build-only dependencies

These build or test Portal but are not part of its outputs:

- Bun as package manager, bundler and compiler. Its runtime does ship inside
  `portal-host`.
- The host's development dependencies (Biome, TypeScript and type packages) and
  any installed npm package that the bundler records do not name.
- Apple's Swift and Clang toolchains and SDK, CMake and Ninja.
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

## Unresolved before a binary release

The generated index repeats the per-component items.

1. **Corresponding source.** A binary release conveys the object code of the
   whole module and host, so GPL-3.0 section 6 requires the corresponding source
   or a written offer; the LGPL and MPL-2.0 also require it for JavaScriptCore
   and z2d. That source is Portal at the release commit; libghostty-spm at its
   pinned revision, including its `Patches/` and build scripts that produce the
   prebuilt library; Ghostty at the revision that release names; the dependency archives Ghostty's `build.zig.zon` files pin; Bun at its
   release tag, with oven-sh/WebKit at the commit Bun pins and the libraries Bun's
   build scripts pin; and the npm packages at the lockfile versions. Statically
   linked LGPL code, such as JavaScriptCore in Bun, also needs a way to relink
   with a modified library; complete build sources and scripts provide that. No
   release mechanism provides any of this yet; task 5's release automation
   should attach it.
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
- **A new Swift pin or wrapper version.** Thin the new prebuilt library with
  `lipo`, list its members with `ar -t` and its symbols with `nm`, read the
  `build.zig.zon` files at the Ghostty revision its `Ghostty.ref` names, and
  update the Ghostty components and texts.
- **A new Bun version.** Add `licenses/texts/bun/VERSION/LICENSE.md` from that
  release's tag and a component for `bun@VERSION`.

Keep upstream license texts unedited. When a notice is only part of a file, such
as stb_image's license block, copy that part verbatim and say so in the
component's note.
