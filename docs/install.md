# Install Portal

Portal is an Emacs package with a native part: a module that Emacs loads and a
standalone app host. Package managers install the Lisp and the sources; Portal
builds its native part from those sources the first time you need it.

The use-package examples marked `<!-- example: NAME -->` are test fixtures: the
package installation test runs them. Keep their markers when editing them.

## Prerequisites

- Graphical macOS Emacs 31.1 or newer, built with module support. See
  [supported platforms](platforms.md) for what has been verified.
- Xcode with Swift 6.2 or newer, CMake 3.29 or newer and Ninja. Install CMake
  and Ninja with `brew install cmake ninja` or your tool manager.
- Bun is optional. A build uses a compatible Bun where it finds its other tools;
  otherwise it downloads Portal's pinned Bun once (see [Bun](#bun)).

Graphical Emacs started from the Dock or Finder does not see your shell's `PATH`.
The build searches Emacs's `exec-path`, then the directories where Homebrew
(`/opt/homebrew/bin`, `/usr/local/bin`) and MacPorts (`/opt/local/bin`) install
tools, so tools from either need no setup. For tools installed elsewhere, such
as by a tool manager, add their directory to `exec-path`:

```elisp
(add-to-list 'exec-path (expand-file-name "~/.local/bin"))
```

or copy your shell's `PATH` with
[exec-path-from-shell](https://github.com/purcell/exec-path-from-shell). Portal
does not read your shell's startup files.

The first build downloads locked host dependencies and the pinned GhosttyKit
binary (about 77 MB) and takes several minutes.

## With use-package and package-vc

Emacs can install Portal straight from its Git repository:

<!-- example: use-package-vc -->
```elisp
(use-package portal
  :vc (:url "https://github.com/xiaoxinghu/portal" :rev :newest))
```

Installing compiles Portal's Lisp only. The first native command, such as
`M-x portal-terminal` or `M-x portal-hello`, offers to build the native part and
shows the build in `*portal-build*`. When it finishes, run the command again.
To prepare Portal ahead of time, run `M-x portal-build` yourself.

`:rev :newest` follows the newest commit. Portal has no releases yet.

## First build and first run

The first build takes several minutes and needs the network. It downloads the
app host's locked dependencies, the pinned GhosttyKit binary (about 77 MB),
the source of its Swift wrapper, which it patches, and Portal's pinned Bun if Emacs finds no compatible one
(see [Bun](#bun)). Emacs stays usable while it builds.

When it succeeds, the build keeps only what Portal runs, about 100 MB, and
deletes its intermediate files and the app host's packages, about 750 MB more.
So a later build, after an upgrade that changes the native sources, starts
afresh. It is faster than the first: SwiftPM and Bun keep their downloads in
their own caches, and Portal's pinned Bun stays in
`portal-build-tools-directory` (see [disk use](#disk-use-and-removal)). A
failed build keeps its files for diagnosis and continues from them.

A finished build says "Portal is ready: retry your command". Then
`M-x portal-hello` shows **Hello World in a native web view**, and
`M-x portal-terminal` a shell in the selected window. If the build fails,
Emacs says "Portal's build failed: see \*portal-build\*"; the same log stays in
`build/portal-build.log` in Portal's source directory, which
`M-: portal-build-root` prints. See [troubleshooting](#troubleshooting).

## From a clone

Clone the repository anywhere and load it from there:

```sh
git clone https://github.com/xiaoxinghu/portal ~/src/portal
```

<!-- example: use-package-load-path -->
```elisp
(use-package portal
  :load-path "~/src/portal")
```

Without use-package, `(add-to-list 'load-path "~/src/portal")` and
`(require 'portal)` do the same. Build from Emacs with `M-x portal-build`, or
from the clone with `./build.sh --prune`. Both use the same script and the same
[Bun selection](#bun), and keep only what Portal runs. Without `--prune`, the
[contributor build](../CONTRIBUTING.md#build-and-editor-setup) also builds
tests and keeps its intermediate files for incremental builds.

## With straight.el or Elpaca

Both link the Lisp files into a separate build directory. Portal follows those
links back to the cloned repository, where it builds and keeps its native part.
With straight.el:

```elisp
(straight-use-package '(portal :host github :repo "xiaoxinghu/portal"))
```

The equivalent Elpaca recipe, `(elpaca (portal :host github :repo
"xiaoxinghu/portal"))`, follows the same layout but has not been tested.

## Building when the package installs

Building on first use needs no package-manager configuration. A package manager
can also run the build as it installs or upgrades Portal, for example with
package-vc:

<!-- example: use-package-vc-build -->
```elisp
(require 'package-vc)
(unless (eq package-vc-allow-build-commands t)
  (add-to-list 'package-vc-allow-build-commands 'portal))

(use-package portal
  :vc (:url "https://github.com/xiaoxinghu/portal"
       :rev :newest
       :shell-command "./build.sh --prune"))
```

This build blocks Emacs while it runs, and package-vc reports a failed build only
as a warning. Portal still checks the result on first use. straight.el's
`:pre-build` and Elpaca's `:build` steps can run the same command in the cloned
repository. Do not build from `:init` or `:config`: they run on every startup.

## Upgrade and rebuild

Upgrade Portal the way you installed it: `M-x package-vc-upgrade RET portal`,
`git pull` in a clone, or `M-x straight-pull-package RET portal`. Then restart
Emacs. When the upgrade changed the native sources, the first native command
offers to rebuild, as on first use; Lisp-only changes need no rebuild.

To rebuild at any time, run `M-x portal-build`. Emacs cannot unload a module,
so after rebuilding a module that this Emacs has already loaded, restart Emacs
to use the new one; Portal says so rather than using a mismatched module. The
next section explains how Portal tells.

## What Portal checks

Each successful build loads the new module and starts the new app host in a
separate batch Emacs. It then records a hash of the native sources it was built
from in `build/portal-build.eld`. A build removes that record before replacing
anything, and records nothing if its sources changed while it ran, so a failed,
interrupted or overtaken build is never taken as ready.

Before loading its module, Portal compares the record with its sources once per
Emacs session. Startup never rebuilds. After an upgrade that changes the native
sources, the first native command offers to rebuild. Lisp-only changes need no
rebuild. Emacs cannot unload a module: when the module that Emacs already loaded
came from another build, or from a Portal too old to record its build, Portal
asks you to restart Emacs before using the new one. Building never touches a module or host that is running.

Only one build of a checkout runs at a time; another one stops immediately.
`*portal-build*` shows the current build, and `build/portal-build.log` keeps the
last one started from Emacs.

## Bun

Bun compiles the app host; the built host includes its own runtime. A build
uses, in order:

1. The Bun you name: `portal-build-bun` in Emacs, or `BUN` for `./build.sh`.
   The build fails if this Bun is missing or incompatible.
2. A compatible `bun` where the build finds CMake and Ninja (the shell's `PATH`
   for `./build.sh`).
   An incompatible one is reported and skipped.
3. Portal's pinned Bun, cached in `portal-build-tools-directory`
   (`~/.emacs.d/portal/tools/` by default; `PORTAL_TOOLS_DIR` or `build/tools/`
   for `./build.sh`). The cache is outside the package, so upgrades reuse it.
4. Portal's pinned Bun, downloaded from Bun's official release. Its SHA-256
   digest is checked against [tools/bun.manifest](../tools/bun.manifest)
   before it runs, and it reaches the cache in one atomic step.

A compatible Bun has `Bun.markdown.html` and is at least the pinned version.
Set `portal-build-download-bun` to nil, or `PORTAL_BUN_DOWNLOAD=0`, to never
download. Portal never changes your shell configuration or installed Bun.

## Disk use and removal

An installed Portal and the caches its build fills, measured on Apple Silicon:

| What | Where | Size |
| --- | --- | ---: |
| Portal and its build | The package directory, which `M-: portal-build-root` prints | 110 MB |
| The app host's packages, in Bun's cache | `~/.bun/install/cache/`, or `BUN_INSTALL_CACHE_DIR` | 330 MB |
| GhosttyKit, in SwiftPM's cache | `~/Library/Caches/org.swift.swiftpm/` | 80 MB |
| Portal's pinned Bun, if a build downloaded it | `portal-build-tools-directory` | 60 MB |

The caches spare a rebuild after an upgrade most of its downloads. Removing
Portal's package leaves them. Other Bun and Swift projects share Bun's and
SwiftPM's caches: delete those only if nothing else uses them. A later build
downloads again what is missing.

## Supplied builds and read-only installations

Portal looks for its native part in `build/` beside its sources. To use one
built elsewhere, for example by a distribution, set `portal-build-directory` to
the directory holding `portal.bundle`, `portal-host` and `portal-build.eld`.
Portal then reports a missing or stale build instead of offering to build.
Without the native sources beside the Lisp, Portal cannot hash them, so it
accepts only a build recorded by the same Portal version (the `Version:` in
`portal.el`): ship the Lisp and the build together. It
also reports a build directory that is not writable instead of starting a build
that cannot succeed.

| Option | Effect |
| --- | --- |
| `portal-build-on-first-use` | `ask` (default), `always` for unattended setups, or `never` |
| `portal-build-directory` | Use a build supplied elsewhere |
| `portal-build-bun` | Use this Bun executable |
| `portal-build-download-bun` | Allow downloading Portal's pinned Bun |
| `portal-build-tools-directory` | Where downloaded tools are cached |

## Troubleshooting

Messages below are what Emacs or `*portal-build*` shows. For a failed build,
read the end of `*portal-build*` or `build/portal-build.log` first.

**"Portal's build needs cmake, ninja".** The build found them neither on
Emacs's `exec-path` nor in Homebrew's or MacPorts' directories. Install them,
or, if they are installed elsewhere, add that directory to `exec-path` as in
[prerequisites](#prerequisites). Emacs started from the Dock or Finder does not
read your shell's startup files. `M-: (executable-find "cmake")` shows what
Emacs finds on `exec-path`.

**"…needs xcrun", or Swift errors early in the build.** Install Xcode, open it
once to finish its setup, and select it with
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
`xcrun swift --version` must report Swift 6.2 or newer.

**"Portal native views need…" or "Portal needs macOS Emacs with module
support".** This Emacs cannot run Portal: it is older than 31.1, not built
for macOS's graphical interface with modules, or the selected frame is a text
terminal. On Apple Silicon, an Intel Emacs under Rosetta cannot load the
build either; `M-: system-configuration` names the CPU. See
[supported platforms](platforms.md).

**"Module initialization failed".** The module was built with the header of a
newer Emacs than the one loading it, typically by `./build.sh` finding another
`emacs` on `PATH`. Run `M-x portal-build` from the Emacs that will use Portal:
it builds with that Emacs and its header. From a shell, set `EMACS` and
`EMACS_INCLUDE` as in [build and editor setup](../CONTRIBUTING.md#build-and-editor-setup).
CMake's "Set -DEMACS_INCLUDE=/path/to/include containing emacs-module.h" means
it found no header for the chosen Emacs.

**A download fails.** `*portal-build*` names the URL. "resolve-bun: could not
download" and SHA-256 mismatches concern Bun; failures fetching Ghostty or
packages come from SwiftPM or `bun install`. Check the network or proxy and run
`M-x portal-build` again. Without network access to Bun's releases, install
Bun (the version in [tools/bun.manifest](../tools/bun.manifest) or newer) and
set `portal-build-bun`. The first build still needs the other downloads.

**"Portal cannot build in … it is not writable".** Portal builds beside its
sources. Install it where you can write, or build it elsewhere and set
`portal-build-directory`. If the Bun cache cannot be created, set
`portal-build-tools-directory`.

**"Portal's native build is older than its sources".** Run `M-x portal-build`.
**"…restart Emacs to use it"** or **"Restart Emacs to replace the old Portal
native modules"** means this Emacs already loaded another build; restart it.
"Portal is already building" and "another Portal build is running" mean one
build is in progress; wait for it. If builds fail after you changed Emacs,
Xcode or CMake, remove the `build` directory in `portal-build-root`, or run
`cmake --fresh --preset dev` in a clone, and build again.

**A page stays blank, or a message says "(see \*portal-server\*)".** The app
host did not start or stopped. `*portal-server*` holds its diagnostics; press
`g` in the page's buffer to retry, or run `M-x portal-restart-server`. See
[app host lifecycle and diagnostics](app-host.md).

**The launcher refuses this Emacs.** It accepts only one Emacs build; see
[launcher setup](launcher.md#set-up-safely).

Still stuck? [Open an issue](https://github.com/xiaoxinghu/portal/issues) with
your Emacs version and revision, macOS version, Portal commit and the log,
removing credentials and private content.
