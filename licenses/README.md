# Third-party notices

Portal is licensed under GPL-3.0-or-later; see `LICENSE` beside this file.

Portal's binaries contain code from other projects, under their own licenses.
Their license texts are in `texts/`.

- **The native module.** It contains Ghostty: through libghostty-spm on macOS,
  and through Portal's own build of it, in `ghostty-linux/`, on Linux. It also
  contains the libraries Ghostty links in, among them FreeType, HarfBuzz,
  fontconfig, libpng, zlib, Oniguruma, z2d, simdutf, Highway, Wuffs, stb and
  libxev. With them come the JetBrains Mono and Symbols Nerd Font fonts,
  iTerm2-Color-Schemes and bash-preexec.
- **The app host, `portal-host`, macOS only.** It contains Bun, which links
  JavaScriptCore from WebKit (LGPL-2.0) statically, and the npm packages that
  `host/bun.lock` pins, among them React, Excalidraw and Mermaid, with
  Excalidraw's fonts. Each npm package carries its own license.

## Source

Portal's source is at <https://github.com/xiaoxinghu/portal>. Use the tag this
build comes from. That tag pins the rest:

- on macOS, libghostty-spm's release, in `native/libghostty-spm.json`;
- on Linux, Ghostty's release, in `native/ghostty.json`, with Portal's patches
  in `native/patches/`;
- Bun's version, in `tools/bun.manifest`;
- the host's npm packages, in `host/bun.lock`.

z2d (MPL-2.0) has its source at <https://github.com/vancluever/z2d>.

To relink `portal-host` against a modified Bun or JavaScriptCore, build Portal
from the tag with your own Bun: `BUN=/path/to/bun ./build.sh`.
