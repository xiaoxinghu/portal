# Contributing to Portal

Start with the [quickstart and prerequisites](README.md#build-and-run). Run all
commands below from the repository root, including commands linked from `docs/`.

## Workflow

Make code changes in a separate Git worktree on a new branch off `main`; leave
the main checkout on the user's branch. Commit the changes on that branch once
the project's checks pass, push it, and open a PR against `main` with
`gh pr create`. Describe the behavior changed and the checks actually run.

Project tasks live in `tasks/`, as [Markdown tasks](docs/tasks.md#writing-tasks).
`project.org` and its archive are historical references, not a second task store.
Agents creating, updating or completing tasks must use the
[author-tasks skill](.agents/skills/author-tasks/SKILL.md).

## Build and editor setup

`./build.sh` runs the `dev` CMake configure and build presets. For development,
configure once before opening native source files. Configuration generates editor
metadata without compiling the module; the second command builds it:

```sh
cmake --preset dev
cmake --build --preset dev
```

CMake locates Emacs, builds the Bun host, and invokes the native Swift package.
`native/Package.swift` links three targets into one module: `PortalCore`,
the portable C core; `PortalProcesses`, Darwin process collection in C; and
`Portal`, the Swift backend containing the host, web, terminal, input and toolbar code. There are no separate feature libraries
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

The single build command produces `build/portal.bundle` and
`build/portal-host`. The bundle contains the one native Emacs module at
`Contents/MacOS/portal.dylib` and Ghostty's resources. CMake recompiles the host when its TypeScript entry point
or HTML changes. CMake records the path of the `bun` found on `PATH` and
searches again if that file disappears. Set `-DBUN=/absolute/path/to/bun`
through `./build.sh` or CMake to select another Bun, or run
`cmake --fresh --preset dev` to rediscover every tool. Both binaries are built
for the current Mac.

To distribute this layout, include all `portal*.el` files at the package root,
`build/portal-host`, and the complete `build/portal.bundle`;
the host needs no adjacent web assets. Keep the bundle intact, including its terminfo
and shell integration resources. Restart Emacs when upgrading from the former
separate web and terminal modules, or after rebuilding a loaded native module.

For distribution alternatives and size measurements, see
[Bun distribution notes](docs/bun-distribution.md).

## Checks before a PR

Read [Testing Portal](docs/testing.md) before choosing or running tests: it
says which suites a change needs, which runs need permission to use the
desktop, and when earlier evidence can be cited instead of a rerun.

```sh
./build.sh
./test.sh                  # unit and headless integration suites
bun run --cwd host check
bun run --cwd host typecheck
git diff --check
```

`./test.sh` builds what its suites need and records each run in
`build/test-runs/`. Native view, keyboard, toolbar or launcher changes also need
the affected graphical suites, such as `./test.sh gui --suite launcher
--allow-gui`, and shared lifecycle, fixture or runner changes need
`./test.sh regression --allow-gui`. These open windows and take focus: agents
ask before running them. Credential-dependent and manual checks are
`./test.sh external` and `./test.sh manual`; report any not run.

Byte-compile changed Lisp files without leaving `.elc` files beside them, adding
`-L build/elpa/PACKAGE` for packages a test file requires:

```sh
emacs --batch -Q -L . -L test \
  --eval '(setq byte-compile-dest-file-function (lambda (_) (make-temp-file "portal-" nil ".elc")))' \
  -f batch-byte-compile CHANGED.el
```

The test commands do not replace formatting, type checking, Lisp compilation
or `git diff --check`. For a focused change to the C core, the
[standalone core build](docs/testing.md#c-core-checks) avoids Swift, Bun and
Ghostty.

## Where to make changes

- Read [the domain vocabulary](CONTEXT.md) and [native boundaries](docs/architecture.md)
  before changing view ownership, lifecycle or platform interfaces. The latter
  links to the architectural decisions and feature-specific design notes.
- Edit shared browser scripts in `native/Core/scripts/`; the C core embeds them.
  `build/` outputs, SwiftPM checkouts and bundled editor assets are generated.
  Keep dependency versions in their manifests and lockfiles.
- Launcher examples in [the launcher guide](docs/launcher.md) are executable test
  fixtures. Preserve their `<!-- example: NAME -->` markers and run
  `./test.sh unit --suite launcher` after editing them; tests load the actual
  blocks in both dynamic and lexical binding modes.
- Keep user instructions in `docs/`, contributor commands here and detailed
  test procedures in [Testing Portal](docs/testing.md). Link from the README
  rather than expanding it into a manual again. Preserve old README anchors
  when moving existing entry points.
