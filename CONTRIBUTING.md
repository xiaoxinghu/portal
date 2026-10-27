# Contributing to Portal

Start with the [quickstart and prerequisites](README.md#build-and-run). Run all
commands below from the repository root, including commands linked from `docs/`.

## Workflow

Make code changes in a separate Git worktree on a new branch off `main`; leave
the main checkout on the user's branch. Commit the changes on that branch once
the project's checks pass, push it, and open a PR against `main` with
`gh pr create`. Describe the behavior changed and the checks actually run.

Besides the [build prerequisites](README.md#build-and-run), the
[checks before a PR](#checks-before-a-pr) need Bun on `PATH` for the host checks
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

CMake locates Emacs, builds the Bun host, and invokes the native Swift package.
`native/Package.swift` links two targets into one module: `PortalCore`,
the portable C core, and `Portal`, the Swift backend containing the host, web, terminal and input code. There are no separate feature libraries
or plugin builds. Ghostty dependency versions and the binary checksum are pinned
through `native/Package.swift` and `native/Package.resolved`. Configuration writes
the discovered header path to `build/emacs-include.txt`, which the package also
reads for editor support.

Use SourceKit-LSP with Eglot for Swift and the C bindings, with `native/` as its
SwiftPM project root. Xcode provides the server. Reconnect Eglot after switching
from the former CMake compilation database. No project-specific header paths
belong in your Emacs configuration. Reconfigure after changing Emacs or SDKs.

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
`build/portal-host` and `build/licenses`. The bundle contains the one native Emacs module at
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
`host/.generated`: about 750 MB. Its next build starts afresh. Build without
`--prune` for development.

`./build.sh` chooses Bun with `tools/resolve-bun.sh`: the `BUN` environment
variable, then a compatible `bun` on `PATH`, then Portal's pinned Bun cached in
`build/tools/` (or `PORTAL_TOOLS_DIR`), downloaded and verified when missing.
`PORTAL_BUN_DOWNLOAD=0` disables the download. A `-DBUN=/absolute/path/to/bun`
argument is an explicit choice, like `BUN`. Plain `cmake` records the `bun` found on `PATH`
and searches again if that file disappears; run `cmake --fresh --preset dev`
to rediscover every tool. Update the pinned version, its asset URLs and
digests together in `tools/bun.manifest`, and test the build with it.

To distribute this layout, include `LICENSE` and all `portal*.el` files at the
package root, `build/portal-host`, the complete `build/portal.bundle`,
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

## Checks before a PR

```sh
./build.sh
ctest --test-dir build --output-on-failure
bun run --cwd host check
bun run --cwd host typecheck
python3 -B -m unittest discover -s test -p 'test_*.py'
git diff --check
```

Then the graphical checks, each suite in a fresh graphical Emacs:

```sh
sh test/gui-all.sh
```

It runs `test/views-gui.sh`, `test/input-gui.sh`, `test/launcher-gui.sh`,
`test/terminal-shell-startup.sh` and `test/package-gui.sh` in turn, after a
failure too, and fails if any of them did; run one of those to repeat a single
suite. They open windows and take keyboard focus while they run. To keep
working meanwhile, [run them in a VM](docs/testing.md#graphical-checks-in-a-vm),
where the wrapper builds once for all of them.

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
avoids Swift, Bun and Ghostty. CMake's registered tests are the source of truth
for the batch suite; use `ctest --test-dir build -N` to list them.

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
