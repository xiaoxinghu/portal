# Contributing to Portal

Start with the [quickstart and prerequisites](README.md#build-and-run). Run all
commands below from the repository root, including commands linked from `docs/`.

## Workflow

Make code changes in a separate Git worktree on a new branch off `main`; leave
the main checkout on the user's branch. Commit the changes on that branch once
the project's checks pass, push it, and open a PR against `main` with
`gh pr create`. Describe the behavior changed and the checks actually run.

Besides the [build prerequisites](README.md#build-and-run), the
[checks](#checks) need Bun on `PATH` for the host checks
(the pinned version in `tools/bun.manifest` or newer) and Python 3, which Xcode
includes. Opening a PR from the command line uses the GitHub CLI, `gh`.

## Build and editor setup

`./build.sh` runs the `dev` CMake configure and build presets. For development,
configure once before opening native source files. Configuration generates editor
metadata without compiling the module; the second command builds it:

```sh
cmake --preset dev
cmake --build --preset dev
```

On macOS, CMake locates Emacs, builds the Bun host, and invokes the native Swift package;
[on Linux](#building-on-linux) it compiles a C module instead.
`native/Package.swift` links two targets into one module: `PortalCore`,
the portable C core, and `Portal`, the Swift backend containing the host, web, terminal and input code. There are no separate feature libraries
or plugin builds. Ghostty comes through its Swift wrapper, libghostty-spm, which
Portal patches; [the Ghostty dependency](#the-ghostty-dependency) says how it is
pinned. Configuration writes the discovered header path to
`build/emacs-include.txt`, which the package also reads for editor support.

Use SourceKit-LSP with Eglot for Swift and the C bindings, with `native/` as its
SwiftPM project root. Xcode provides the server. Reconnect Eglot after switching
from the former CMake compilation database. No project-specific header paths
belong in your Emacs configuration. Reconfigure after changing Emacs or SDKs.

### The Ghostty dependency

Portal draws terminals with [libghostty-spm](https://github.com/Lakr233/libghostty-spm),
a Swift package around a prebuilt Ghostty library. `native/libghostty-spm.json`
pins its release: the version tag and the revision that tag must name.
[The terminal guide](docs/terminals.md) says which Ghostty that release ships.
DisplayLink, the wrapper's own dependency, is pinned in `native/Package.resolved`.

Portal builds the wrapper's Swift with its own patches. Configuration runs
`tools/patch-libghostty-spm.sh`, which fetches the pinned release's source with
Git into `build/libghostty-spm`, checks the revision and applies
`native/patches/libghostty-spm/*.patch` in name order, one commit each. A patch
that does not apply fails the configuration, naming it. `native/Package.swift`
builds that copy with `.package(path:)`, and so does SourceKit-LSP; the copy's
own manifest still downloads the prebuilt library by URL and checksum. Changing
the pin, a patch or the script configures again and remakes the copy. The patches
today:

- `0001-suppress-terminal-responses.patch` adds `suppressesTerminalResponses` to
  `InMemoryTerminalSession`. With it on, the session parses its output through
  `ghostty_surface_write_buffer_replay`, so the surface answers no queries in
  it: the output of a Rex block, whose server has answered them already.

The `libghostty-spm` CTest suite runs the patched package's in-memory session
tests, on real Ghostty surfaces, including the tests the patches add.

To change a patch, edit the copy in `build/libghostty-spm` and build: while the
pin, the patches and the script stay the same, a build keeps the changes made
there and says so. Commit them in the copy, amending a patch's commit or adding
one on top, then write the whole set back, with REVISION from the pin:

```sh
rm native/patches/libghostty-spm/*.patch
git -C build/libghostty-spm format-patch --zero-commit --no-signature \
    -o "$PWD/native/patches/libghostty-spm" REVISION
```

The next configuration remakes the copy from the patch files. Keep each patch
small and in the package's style, so that it can be offered upstream.

A Rex server runs its terminals with its own Ghostty, and Portal draws a
block by feeding the same bytes to the Ghostty of its pinned release. When
the server's knows a sequence Portal's does not, the two screens differ;
[the Rex guide](docs/rex.md#ghostty-versions) says what that looks like. Run the report before working on the Rex client and after Rex updates:

```sh
tools/ghostty-version.py
```

It prints the pinned release, the newest release and the installed Rex
server's Ghostty, each with its commit and date (in UTC), how many commits of
the server's each release's Ghostty lacks, and a verdict: up to date, a newer
release exists, or the newest release is still behind the server. A release's
Ghostty is the one its `binaryTarget` downloads, the library Portal links; the
report notes when its `Ghostty.ref` names another. It changes nothing. It reads what is on disk first: the build's patched copy, and the
clones `PORTAL_LIBGHOSTTY_SPM_CLONE` and `PORTAL_GHOSTTY_CLONE` name (or
`--package` and `--ghostty`). It asks the network, Git and GitHub's API, only
for what those lack, and never with `--offline`, and it says what it could not
find out. The server's Ghostty is read from its executable, which nothing the
server answers reports; `PORTAL_REX_SERVER` or `--rex` names one that is not in
Rex's usual place. This report is the only check: Portal does not compare
versions when it connects to a server.

To move to a new release, bump the pin:

```sh
tools/ghostty-version.py bump                  # the newest release
tools/ghostty-version.py bump 2.2.2026110702   # a named one
```

It writes the release's tag and revision to `native/libghostty-spm.json`,
refreshes `native/Package.resolved`, and names each patch that no longer
applies to the release, exiting with status 1 when one does not. Then
`build/libghostty-spm-bump` holds the new release with the patches applied by
`git am` up to the first that fails, where it stopped: fix it there and
`git am --continue`, then write the set back with the `format-patch` command
above, run from that copy with the new revision. It commits nothing and runs
no checks, and ends by listing what to do next: those repairs, build, follow
[Licenses](docs/licenses.md#when-dependencies-change) for the new prebuilt
library, update the release and Ghostty versions in the terminal guide, and
run the checks. Run it again after fixing a patch or regaining the network:
with the pin already moved, it checks the patches and resolves again.

### Building on Linux

Portal has no native views on Linux yet, but its module builds and loads
there. `./build.sh` makes `build/portal.so` in place of `build/portal.bundle`,
with `build/ghostty-linux` beside it and `build/portal-host` and
`build/licenses` as on macOS. CMake compiles the module itself: the C
bindings and core with [`native/Linux/backend.c`](native/Linux/backend.c), the
backend for an Emacs built with pgtk, linked against GTK 3, `wayland-client`
and Ghostty's library, which [the next section](#ghostty-on-linux) says how
Portal builds. No Swift is involved. The backend's operations fail, each
saying what Linux lacks, so the module answers only what the core answers by
itself and what Ghostty's library says of itself; the file's first comment
lists what is real and what each missing piece waits for. The link fails when
the backend lacks a primitive of `portal.h`, or Ghostty's library a function
the backend calls, and `native/Linux/portal.map` keeps every symbol but
Emacs's two entry points inside the module.

A build needs:

- Emacs 31.1 built with pgtk and modules, and its `emacs-module.h`;
- GCC 15 or newer, or a Clang with C23's `#embed`, which the core uses, as
  `cc`; CMake 3.29 or newer, Ninja and `pkg-config`;
- the development files of GTK 3, `wayland-client` and EGL, as pkg-config's
  `gtk+-3.0`, `wayland-client` and `egl`;
- for Ghostty's library, Zig at the version `native/ghostty.json` names or a
  later patch release of it, as `zig` on `PATH` or in `ZIG`, ncurses' `tic`
  and Git;
- Bun, chosen [as on macOS](#build-outputs-and-distribution): the pinned
  release has glibc builds for aarch64 and x64. Only one build runs per
  checkout at a time there too, with `flock` for the lock.

`M-x portal-build` checks for each of them before it starts, and names what
is missing. A first build takes three to four minutes on ten cores, most of
it Zig building Ghostty.

Configuration writes `build/compile_commands.json` for clangd.

[The checks](#checks) that run on Linux are CTest, the host checks, the Python
tests and `git diff --check`, with `nproc` for the number of jobs. CTest
leaves out the suites of the macOS module, `rex` and `libghostty-spm`, and of
the macOS VM runner, and adds `linux-module`, which loads the built module in
batch Emacs. The Python tests skip those of Swift helpers and of the macOS
Ghostty wrapper. There are no graphical checks on Linux yet: those stay on
macOS.

### Ghostty on Linux

Portal's terminal on Linux will draw with Ghostty's own embedding library,
which no release ships for Linux, so Portal builds it from source with Zig and
its own patches: Ghostty's library has no Linux platform to embed.
`native/ghostty.json` pins the release: the version tag, the revision that tag
must name, and the Zig that the release's `build.zig.zon` asks for, so that a
build can check Zig before it fetches anything. `./build.sh` builds the
library with this script, which also runs alone:

```sh
tools/build-ghostty-linux.sh
```

It checks Zig and `tic`, fetches the pinned release's source with Git into
`build/ghostty`, checks the revision and the pin's Zig, applies
`native/patches/ghostty/*.patch` in name order, one commit each, and runs
`zig build -Dapp-runtime=none` there. A patch that does not apply fails the
build, naming it. A Zig of the pin's major and minor version at the same patch
release or a later one builds it, as Ghostty's build itself requires. Ghostty
builds everything else from source and links it in; Zig downloads those
sources on the first build into its own global cache. Zig's cache for the
build is `build/ghostty-cache`: about 1 GB after one build, more with each
mode and each changed patch, and safe to delete. The outputs are in
`build/ghostty-linux`:

- `lib/libghostty.so`, the library under its soname, and `include/ghostty.h`,
  its header. The library needs `libc`, `libm` and `libEGL` at run time.
- `share/ghostty`, the shell integration and themes. A host sets
  `GHOSTTY_RESOURCES_DIR` to it before `ghostty_init`; Ghostty finds the
  terminfo database in `share/terminfo` beside it.

CMake runs the script only when the pin, a patch, the set of patches or the
script has changed, or one of those outputs is gone: the script runs Zig each time, which takes
seconds even with nothing to build. `portal.so` links the library and finds it
by its rpath, `$ORIGIN/ghostty-linux/lib`, so `ghostty-linux` stays beside the
module wherever Portal is installed. The module works out the resources'
directory from its own place, sets `GHOSTTY_RESOURCES_DIR` to it in its own
process and starts Ghostty on first use: nothing of an installed Ghostty is
used. `portal--terminal-engine`, which only the Linux module has, starts it
and answers with its version, build mode and resources; the build's own check
calls it, and so does the `linux-module` suite.

`--optimize Debug` builds with Zig's safety checks in place of ReleaseFast, and
`--prefix DIR` installs somewhere else. A Debug build also checks every page of
a terminal after each change and takes a minute to print 2 MB: it is for
finding faults, not for use. ReleaseSafe is not offered, because Ghostty at this
pin does not compile in it here: glibc's fortified `ptsname_r` does not get
through Zig's translation of C. `PORTAL_GHOSTTY_CLONE` names a local clone of
Ghostty to fetch the tag from in place of the network.

The patches today:

- `0001-build-link-the-GL-and-EGL-loaders-into-an-OpenGL-lib.patch` compiles
  glad, the OpenGL and EGL loader, into the library. Ghostty's build compiles it
  into executables only, so the library as built cannot be linked. It is
  Ghostty's bug: drop the patch once a pinned release has fixed it.
- `0002-build-install-the-resources-with-the-Linux-library.patch` installs the
  resources, which Ghostty's build installs only with an executable, and
  leaves out the desktop file, services and icons of the application.
- `0003-embedded-a-Linux-platform-whose-host-presents-the-re.patch` adds
  `GHOSTTY_PLATFORM_LINUX`, a surface whose host shows the frames itself:
  `ghostty_surface_take_frame` hands over the renderer's latest frame, a DMABUF
  or pixels in memory, a callback given with the surface announces each frame
  on the render thread, and `ghostty_frame_free` gives the frame's texture
  back, which the renderer does not draw into before. The comments on these in
  `ghostty.h` are the contract a host is written to.
- `0004-build-export-only-the-C-API-from-the-Linux-library.patch` gives the
  shared library a version script that exports the `ghostty_` functions alone.
  Without it the library exports every symbol of what it links in statically,
  and in Emacs, which has loaded the system's FreeType, HarfBuzz, fontconfig,
  libxml2, libpng and zlib first, a thousand of its own calls went to those
  copies instead of its own.

To change a patch, edit the copy in `build/ghostty` and run the script again:
while the pin, the patches and the script stay the same, it builds the changes
made there and says so. Commit them in the copy, amending a patch's commit or
adding one on top, then write the whole set back, with REVISION from the pin:

```sh
rm native/patches/ghostty/*.patch
git -C build/ghostty format-patch --zero-commit --no-signature \
    -o "$PWD/native/patches/ghostty" REVISION
```

The next run remakes the copy from the patch files. `./build.sh` does not
run the script for changes made in the copy alone: run it yourself, and
`./build.sh` then builds the module against the library it made. To move the pin, apply the
patches to the new tag in a clone of Ghostty with `git am`, repair those that
stop, write them back the same way and change `native/ghostty.json`, its Zig
too; `tools/ghostty-version.py` knows only the macOS wrapper. Then follow
[Licenses](docs/licenses.md#when-dependencies-change) for what the library
now links in. The `test_build_ghostty_linux.py` tests run the script against a
stand-in for Ghostty and for Zig.

The pin is shaped so that a prebuilt library can join it: a download with
its checksum, for each architecture, in place of the build, once the patches
stop changing. The outputs would stay where they are.

For TypeScript editing, install the host's development dependencies and run its
checks:

```sh
bun install --cwd host --frozen-lockfile
bun run --cwd host check
bun run --cwd host typecheck
```

Biome checks host formatting, imports, and lint rules using `biome.json`.
Indentation uses tabs. Run `bun run --cwd host format` to format the host sources.
Generated assets and dependencies are excluded through Git's ignore rules.

`host/tsconfig.json` supplies strict TypeScript settings and Bun/Node API types.
The asset declarations describe HTML and CSS imports loaded as strings.
Bun types match the tested 1.3.14 runtime; TypeScript 6 retains `tsserver`
support for editors using `typescript-language-server`, including Eglot.
If an existing TypeScript session still shows old diagnostics, run
`M-x eglot-reconnect`. The type check also generates the browser assets.
CMake installs the locked dependencies, bundles the editor and fonts, and
compiles the standalone host. Runtime users need no npm packages.

Build against the Emacs installation that will load the module. Configuration
locates its header beside the app's resources or in system include directories.
Override the cached choices when needed:

```sh
cmake --preset dev -DEMACS=/path/to/emacs -DEMACS_INCLUDE=/path/to/include
```

`EMACS` and `EMACS_INCLUDE` environment overrides also work with `./build.sh`.
When changing Emacs installations, pass its include directory too, or run
`cmake --fresh --preset dev` to rediscover everything.

Restart Emacs after rebuilding a module it has already loaded. The build replaces
the library atomically, so rebuilding leaves the old loaded library intact; it
does not hot-reload that library.

## Build outputs and distribution

The single build command produces `build/portal.bundle`,
`build/portal-host` and `build/licenses`; a [Linux build](#building-on-linux)
has `build/portal.so` and `build/ghostty-linux` for the bundle. The bundle contains the one native Emacs module at
`Contents/MacOS/portal.dylib` and Ghostty's resources. CMake recompiles the host when its TypeScript entry point
or HTML changes. Both binaries are built for the current Mac's CPU
architecture and macOS 13 or later; see [supported platforms](docs/platforms.md)
for what has been verified. The build ends by
loading the new module and starting the new host in a disposable batch Emacs,
then writes `build/portal-build.eld`, the record that `portal-build.el` checks
before Emacs loads the module; see [what Portal checks](docs/install.md#what-portal-checks).
Only one `./build.sh` runs per checkout at a time.

`./build.sh --prune`, which `M-x portal-build` runs for installed packages,
builds without tests and then deletes everything else in `build/` except
`tools/`, the lock and the build log, as well as `host/node_modules` and
`host/.generated`: about 750 MB. On Linux it keeps, of `build/ghostty-linux`,
the library and the resources, and deletes Ghostty's source copy and Zig's
cache for it, over 1 GB more. Its next build starts afresh. Build without
`--prune` for development.

`./build.sh` chooses Bun with `tools/resolve-bun.sh`: the `BUN` environment
variable, then a compatible `bun` on `PATH`, then Portal's pinned Bun cached in
`build/tools/` (or `PORTAL_TOOLS_DIR`), downloaded and verified when missing.
`PORTAL_BUN_DOWNLOAD=0` disables the download. The manifest pins the release's
builds for macOS and for Linux with glibc. A `-DBUN=/absolute/path/to/bun`
argument is an explicit choice, like `BUN`. Plain `cmake` records the `bun` found on `PATH`
and searches again if that file disappears; run `cmake --fresh --preset dev`
to rediscover every tool. Update the pinned version, its asset URLs and
digests together in `tools/bun.manifest`, and test the build with it.

To distribute this layout, include `LICENSE` and all `portal*.el` files at the
package root, `build/portal-host`, the complete `build/portal.bundle` (on Linux,
`build/portal.so` and `build/ghostty-linux` as `--prune` leaves it),
`build/licenses` and `build/portal-build.eld`, or set `portal-build-directory`
to where the build outputs are; the host needs no adjacent web assets. Without
`native/`, Portal accepts only a record from the same `Version:` as `portal.el`. Keep the
bundle intact, including its terminfo and shell integration resources.
`build/licenses` holds Portal's license and the third-party notices for both
outputs, generated from `licenses/inventory.json` and the build's own records. A
binary release also needs the corresponding source and has open license
questions; see [Licenses and third-party notices](docs/licenses.md). Restart
Emacs when upgrading from the former separate web and terminal modules, or after
rebuilding a loaded native module.

Package managers compile every Lisp file at the package root, with or without
optional packages such as Consult and Embark; `.elpaignore` keeps them away from
`test/` and `build/`. Keep adapters loadable without their package, requiring
it only when their mode is enabled. The `package` CTest suite installs this
checkout through the [installation guide](docs/install.md)'s use-package
examples and fails on any compilation error or warning.

For distribution alternatives and size measurements, see
[Bun distribution notes](docs/bun-distribution.md).

## Checks

The checks come in two tiers. Run the default loop while working: about two
minutes after an incremental build. Run the full set once before merging; CI
runs it again on `main` after each merge.

### Default loop

```sh
./build.sh
ctest --test-dir build -j$(sysctl -n hw.ncpu) --output-on-failure
bun run --cwd host check
bun run --cwd host typecheck
python3 -B -m unittest discover -s test -p 'test_*.py'
git diff --check
sh test/views-gui.sh
sh test/input-gui.sh
```

The last two each run in a fresh graphical Emacs. They open windows and take
keyboard focus while they run. To keep working meanwhile,
[run them in a VM](docs/testing.md#graphical-checks-in-a-vm). Add the full
set's graphical check for what a change touches: `launcher-gui.sh` for the
launcher, `package-gui.sh` for installation and the build.

### Full set

The full set adds the tests tagged `:expensive`, long soaks and matrices, to
every ERT runner, and four more graphical checks. With
`PORTAL_TEST_EXPENSIVE=1` set, run the default loop's batch checks, then every
graphical suite:

```sh
sh test/gui-all.sh
```

It runs `test/views-gui.sh`, `test/input-gui.sh`, `test/launcher-gui.sh`,
`test/terminal-shell-startup.sh`, `test/rex-server-gui.sh` and
`test/package-gui.sh` in turn, after a failure too, and fails if any of them
did; run one of those to repeat a single suite. In a VM the wrapper builds
once for all of them. `rex-server-gui.sh` checks Portal against a
[real Rex server](docs/testing.md#against-a-real-rex-server); where none is
installed it reports itself not run.
[Test tiers](docs/testing.md#test-tiers) says how tests join a tier.

### What they cover

The build installs the locked host dependencies and CMake downloads hash-checked
Emacs packages for integration tests. The `licenses` suite fails when a
dependency change leaves a staged notice missing or the license inventory out of
date; [Licenses and third-party notices](docs/licenses.md#when-dependencies-change)
says what to update. CTest exercises the real C core with a fake
backend, Lisp behavior, and the compiled app host; it does not validate native
windows; the graphical checks do. For native view, keyboard or
launcher changes, also run the relevant [standalone checks](docs/testing.md#standalone-appkit-checks).
Physical-key and manual checks are opt-in; report any not run.

For a focused change to the C core, the [standalone core build](docs/testing.md#c-core-checks)
avoids Swift, Bun and Ghostty, on macOS and on Linux. CMake's registered tests are the source of truth
for the batch suite; use `ctest --test-dir build -N` to list them. `-j` runs
the suites side by side, in about a third of the time; the
[test-writing rules](docs/testing.md#writing-tests) say what that asks of a suite.

## Where to make changes

- Read [the domain vocabulary](CONTEXT.md) and [native boundaries](docs/architecture.md)
  before changing view ownership, lifecycle or platform interfaces. The latter
  links to the architectural decisions and feature-specific design notes.
- Edit shared browser scripts in `native/Core/scripts/`; the C core embeds them.
  `build/` outputs, SwiftPM checkouts and bundled editor assets are generated.
  Keep dependency versions in their manifests and lockfiles. After changing
  host dependencies, rerun `bun audit` and update
  [dependency security findings](docs/dependency-security.md).
- Record third-party code that ships in `licenses/inventory.json`. Files in
  `licenses/texts/` are verbatim upstream license texts; do not reformat them.
- Launcher examples in [the launcher guide](docs/launcher.md) are executable test
  fixtures. Preserve their `<!-- example: NAME -->` markers and run the `launcher`
  CTest suite after editing them; tests load the actual blocks in both dynamic
  and lexical binding modes.
- Keep user instructions in `docs/`, contributor commands here and detailed
  test procedures in [Testing Portal](docs/testing.md). Link from the README
  rather than expanding it into a manual again.
- Never edit the `Version:` line of `portal.el`: a release changes it, made by
  an agent with the release skill as [Releasing Portal](docs/releasing.md) describes.
