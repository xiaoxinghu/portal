# Install Portal

Portal is an Emacs package with a native part: a module that Emacs loads and a
standalone app host. Package managers install the Lisp and the sources; the
first time you need the native part, Portal offers to download it from the
release of its version or to build it from those sources.

The use-package examples marked `<!-- example: NAME -->` are test fixtures: the
package installation test runs them. Keep their markers when editing them.

## Prerequisites

- Graphical macOS Emacs 31.1 or newer, built with module support. See
  [supported platforms](platforms.md) for what has been verified.
- To build Portal here: Xcode with Swift 6.2 or newer, CMake 3.29 or newer
  and Ninja. Install CMake and Ninja with `brew install cmake ninja` or your
  tool manager. A [downloaded runtime](#downloaded-runtimes) needs none of
  them.
- Bun is optional. A build compiles the app host with Portal's pinned Bun,
  which it downloads once, unless you name another (see [Bun](#bun)).

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
  :vc (:url "https://github.com/xiaoxinghu/portal" :rev "stable"))
```

Installing compiles Portal's Lisp only. The first native command, such as
`M-x portal-terminal` or `M-x portal-hello`, asks how to get the native part:

- **Download** (`d`) fetches the runtime of this Portal's release from
  GitHub, about 46 MB on Apple Silicon, and shows it in `*portal-runtime*`.
  It needs no Xcode, CMake or Bun. See [downloaded runtimes](#downloaded-runtimes).
- **Build here** (`b`) builds it from the sources and shows the build in
  `*portal-build*`. See [first build and first run](#first-build-and-first-run).
- **Not now** (`n`) does neither, and asks again next time.

Either runs in the background; when it finishes, run the command again. To
prepare Portal ahead of time, run `M-x portal-download-runtime` or
`M-x portal-build` yourself. To choose once for good, set
[`portal-build-on-first-use`](#choosing-ahead).

### Which revision

`:rev "stable"` installs the latest release and upgrades to each next one.
The branch `stable` moves only when Portal makes a release; development
happens on `main`. What else `:rev` can say, and what each does when you
upgrade:

| Specification | Installs | `package-vc-upgrade` |
| --- | --- | --- |
| `:rev "stable"` | the latest release | moves to the next release |
| `:rev :newest` | the newest commit on `main` | moves to the newest commit on `main` |
| `:rev "v0.2.0"` | that release | stays there |
| no `:rev` | the latest release | cannot upgrade it |

- **Following development**: `:rev :newest` gives every change as it merges,
  before any release, with the native rebuilds that come with them.
- **Pinning a version**: `:rev "v0.2.0"`, or any tag on the
  [releases page](https://github.com/xiaoxinghu/portal/releases), stays at
  that release; upgrading does nothing. To move to another version, run
  `git fetch --tags` and `git switch --detach v0.3.0` in the directory that
  `M-: portal-build-root` prints, then `M-x package-vc-rebuild RET portal` and
  restart Emacs. Or delete the package and install it again: use-package reads
  `:vc` only when Portal is not installed, so editing `:rev` later changes
  nothing.
- **Keep the `:rev`.** With
  `:vc (:url "https://github.com/xiaoxinghu/portal")` and no `:rev`,
  use-package installs the latest release as a commit, not on a branch, and
  `package-vc-upgrade` then fails without saying so: it leaves the error in a
  `*vc-git*` buffer. Portal's build tells you when its checkout is in that
  state. `:branch "stable"` without `:rev "stable"` does the same.

### Moving an install to stable

An install made with `:rev :newest`, or before Portal had releases, is on
`main` and stays there. To move it to releases, in the directory that
`M-: portal-build-root` prints, run

```sh
git fetch
git switch stable
```

then `M-x package-vc-rebuild RET portal`, which recompiles the Lisp, and
restart Emacs. The same commands move a checkout that is not on a branch.
`main` is ahead of the latest release, so this goes back to it; when the two
differ in native sources, the first native command asks again.

`M-x portal-version` says which Portal this is: its version, how many commits
it is past the release, and its branch, such as `Portal 0.2.0 (stable)`.

## First build and first run

The first build takes several minutes and needs the network. It downloads the
app host's locked dependencies, the pinned GhosttyKit binary (about 77 MB),
the source of its Swift wrapper, which it patches, and Portal's pinned Bun
unless it is cached or you name another (see [Bun](#bun)). Emacs stays usable while it builds.

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
(straight-use-package
 '(portal :host github :repo "xiaoxinghu/portal" :branch "stable"))
```

The equivalent Elpaca recipe, `(elpaca (portal :host github :repo
"xiaoxinghu/portal" :branch "stable"))`, follows the same layout but has not
been tested. Both follow the branch they name: `stable` for releases, as with
package-vc, or `main` without `:branch`.

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
       :rev "stable"
       :shell-command "./build.sh --prune"))
```

This build blocks Emacs while it runs, and package-vc reports a failed build only
as a warning. Portal still checks the result on first use. straight.el's
`:pre-build` and Elpaca's `:build` steps can run the same command in the cloned
repository. Do not build from `:init` or `:config`: they run on every startup.

## Upgrade and rebuild

Upgrade Portal the way you installed it: `M-x package-vc-upgrade RET portal`,
`git pull` in a clone, or `M-x straight-pull-package RET portal`. Then restart
Emacs. On `stable`, an upgrade is the next release, and the release's notes on
the [releases page](https://github.com/xiaoxinghu/portal/releases) say whether
it needs a native rebuild. When the upgrade changed the native sources, the
first native command asks again, as on first use, to download the new
release's runtime or to rebuild; Lisp-only changes need neither, and reuse the
runtime or build you have.

To rebuild at any time, run `M-x portal-build`. Emacs cannot unload a module,
so after rebuilding a module that this Emacs has already loaded, restart Emacs
to use the new one; Portal says so rather than using a mismatched module. The
next section explains how Portal tells.

## What Portal checks

Each successful build loads the new module and, on macOS, starts the new app
host in a separate batch Emacs. It then records a hash of the native sources it was built
from in `build/portal-build.eld`. A build removes that record before replacing
anything, and records nothing if its sources changed while it ran, so a failed,
interrupted or overtaken build is never taken as ready.

Before loading its module, Portal compares the record with its sources once per
Emacs session; a [downloaded runtime](#downloaded-runtimes) carries the same
record. Startup never rebuilds, downloads or asks. After an upgrade that changes the native
sources, the first native command offers to rebuild. Lisp-only changes need no
rebuild. Emacs cannot unload a module: when the module that Emacs already loaded
came from another build, or from a Portal too old to record its build, Portal
asks you to restart Emacs before using the new one. Building never touches a module or host that is running.

Only one build of a checkout runs at a time; another one stops immediately.
`*portal-build*` shows the current build, and `build/portal-build.log` keeps the
last one started from Emacs.

## Downloaded runtimes

On Apple Silicon, Portal can download its native part instead of building it:
the runtime archive a release attaches, holding the module, the app host and
Ghostty's resources. Every release after 0.2.0 attaches one; for 0.2.0,
Download says the runtime is not released, and Build here remains. Choose **Download**
when the first native command asks, or run `M-x portal-download-runtime` at
any time. The install runs in the
background, shows its progress in `*portal-runtime*`, and ends by saying one
of:

- "Portal's runtime is installed: retry your command";
- "Portal's runtime is installed: restart Emacs to load its new native
  module", when this Emacs already loaded the module of another build. Portal
  never replaces a module Emacs has loaded: restart Emacs, then run the
  command;
- "Portal's runtime was not installed: …", with the reason, followed by "To
  build it here instead, run M-x portal-build" unless the reason already says
  so. See [troubleshooting](#troubleshooting). A failed download never builds
  by itself.

Which native part Portal uses, checked once per session:

1. With `portal-build-directory` set, that build, and nothing else: Portal
   neither downloads nor builds, and `M-x portal-download-runtime` refuses.
2. Otherwise its own build in `build/`, when it is complete and recorded from
   these native sources.
3. Otherwise the runtime downloaded for these native sources, if
   `portal-runtime-directory` holds one. An upgrade that changed only Lisp
   keeps using it, with no network.

So a build from source stays the alternative at any time: `M-x portal-build`
makes `build/`, which then comes first.

**On the Mac, Portal's own download is the only supported way to get a
runtime.** A file Emacs writes carries no quarantine attribute, as a file a
web browser saves does, so macOS's Gatekeeper loads the module and starts the
app host with no prompt and nothing for you to clear. This was tested on the
macOS versions [supported platforms](platforms.md#the-downloaded-runtime)
names, on a Mac with no developer tools. Portal's binaries are not signed
with a Developer ID or notarized. So a runtime archive downloaded by hand in
a browser, unpacked and named with `portal-build-directory`, is not a
supported route: Gatekeeper sees every file in it as quarantined. Use
`M-x portal-download-runtime` instead.

On Linux the same install takes one of two archives, for x86-64 and for
aarch64, each holding the module and Ghostty's library and resources, and no
app host: Linux has terminals and Rex blocks, not web views or the launcher.
No Linux release has published them yet. The Emacs process chooses, not the
distribution or the desktop: its CPU and C library, from
`system-configuration`, and the version of the glibc it runs with. Before
anything is downloaded, Portal refuses, saying why and offering
`M-x portal-build`:

- a CPU other than x86-64 and aarch64;
- musl, as on Alpine, or any C library other than glibc;
- a glibc older than 2.43, the archives' floor (Ubuntu 26.04, Fedora 44,
  current Arch).

An Emacs that cannot show Portal's views is refused whatever its runtime,
and no build is offered: one built without pgtk, a frame on X11 or
XWayland, a text terminal.

Portal reads the glibc version from the C library the Emacs process has
mapped, as `/proc/self/maps` names it, by the "release version" every glibc
carries: an Emacs from Nix, Guix, Flatpak or Snap may use a C library
other than the system's, which `ldd --version` would report. When the
version cannot be read, nothing is refused on that account. Either way the
check is there for a clear message: what protects a system it misjudges is
step 4 below, where the loader's own message, such as a glibc version not
found, stops the install, followed by what the runtime needs and the offer of
a build.

What an install does, in a batch Emacs of its own:

1. It looks in `portal-runtime-directory` (`~/.emacs.d/portal/runtime/` by
   default) for a runtime of this Portal's native source identity, the hash
   that [what Portal checks](#what-portal-checks) describes. If one is there,
   it uses it with no network. So a release that changed only Lisp downloads
   nothing.
2. Otherwise it fetches the manifest of the release tag of this Portal's
   version, never `latest`, from GitHub. It goes on only when that release
   was built from these native sources: a checkout past its release with
   native changes needs a build, and the install says so before fetching the
   archive.
3. It downloads the archive, checks its size and SHA-256 against the
   manifest, and unpacks it into a staging directory. It refuses an archive
   with a name or link that leads out of the runtime, or anything but files,
   directories and links, and checks the runtime's files and build record.
4. It loads the module and starts the host, on Linux Ghostty's library, in a
   disposable batch Emacs. Only then does the runtime take its place, in one
   rename.

A release whose runtime was built from other native sources, as on `main`
past a release that changed them, is refused before the archive is fetched:
build from source there. A failed or interrupted install leaves the runtimes
already there as they were. One install runs at a time; another one stops at once, saying so. A
successful install keeps the runtime it replaced, which a running Emacs may
have loaded, and deletes any older one.

**What the download trusts.** Portal trusts the runtime as it trusts its Lisp:
GitHub over TLS, pinned to a release tag. Nothing is signed. The manifest
comes from the same place as the archive, so its digest catches a truncated
or corrupted download, not an attacker. TLS is what protects it: the install
verifies GitHub's certificate and host name, and when they do not verify, it
stops. It never asks whether to continue, as Emacs's Network Security
Manager asks elsewhere, and a certificate you once accepted there for good
does not count. Every redirect must be HTTPS too. The install connects
directly, not through a proxy. It trusts the system's certificate
authorities and those in `gnutls-trustfiles`.

## Bun

Bun compiles the app host, and the built host includes that Bun as its
runtime. So a build uses Portal's pinned Bun, the version
[tools/bun.manifest](../tools/bun.manifest) names, and never a `bun` it finds
on `exec-path` or `PATH`, however new. In order:

1. The Bun you name: `portal-build-bun` in Emacs, or `BUN` for `./build.sh`.
   The build fails if this Bun is missing or incompatible.
2. Portal's pinned Bun, cached in `portal-build-tools-directory`
   (`~/.emacs.d/portal/tools/` by default; `PORTAL_TOOLS_DIR` or `build/tools/`
   for `./build.sh`). The cache is outside the package, so upgrades reuse it.
3. Portal's pinned Bun, downloaded from Bun's official release. Its SHA-256
   digest is checked against [tools/bun.manifest](../tools/bun.manifest)
   before it runs, and it reaches the cache in one atomic step.

A compatible Bun has `Bun.markdown.html` and is at least the pinned version.
Set `portal-build-download-bun` to nil, or `PORTAL_BUN_DOWNLOAD=0`, to never
download. Portal never changes your shell configuration or installed Bun.

On Linux, which has no web views yet, the build makes no app host and needs
no Bun: see [building on Linux](../CONTRIBUTING.md#building-on-linux).

## Disk use and removal

An installed Portal and the caches its build fills, measured on Apple Silicon:

| What | Where | Size |
| --- | --- | ---: |
| Portal and its build | The package directory, which `M-: portal-build-root` prints | 110 MB |
| The app host's packages, in Bun's cache | `~/.bun/install/cache/`, or `BUN_INSTALL_CACHE_DIR` | 330 MB |
| GhosttyKit, in SwiftPM's cache | `~/Library/Caches/org.swift.swiftpm/` | 80 MB |
| Portal's pinned Bun, if a build downloaded it | `portal-build-tools-directory` | 60 MB |
| Downloaded runtimes, at most two | `portal-runtime-directory` | 100 MB each |

The caches spare a rebuild after an upgrade most of its downloads. Removing
Portal's package leaves them. Other Bun and Swift projects share Bun's and
SwiftPM's caches: delete those only if nothing else uses them. A later build
downloads again what is missing.

## Supplied builds and read-only installations

Portal looks for its native part in `build/` beside its sources. To use one
built elsewhere, for example by a distribution, set `portal-build-directory` to
the directory holding `portal.bundle`, `portal-host` and `portal-build.eld`
(on Linux, `portal.so`, `ghostty-linux` and `portal-build.eld`).
Portal then reports a missing or stale build instead of offering to build.
Without the native sources beside the Lisp, Portal cannot hash them, so it
accepts only a build recorded by the same Portal version (the `Version:` in
`portal.el`): ship the Lisp and the build together. It
also reports a build directory that is not writable instead of starting a build
that cannot succeed.

| Option | Effect |
| --- | --- |
| `portal-build-on-first-use` | What the first native command does: `ask` (default), `download`, `build` or `never`; see [choosing ahead](#choosing-ahead) |
| `portal-build-directory` | Use a build supplied elsewhere |
| `portal-build-bun` | Use this Bun executable |
| `portal-build-download-bun` | Allow downloading Portal's pinned Bun |
| `portal-build-tools-directory` | Where downloaded tools are cached |
| `portal-runtime-directory` | Where downloaded runtimes are kept |

## Choosing ahead

`portal-build-on-first-use` says what the first native command does when the
native part is missing or older than the sources:

| Value | The first native command |
| --- | --- |
| `ask` (default) | asks: Download, Build here or Not now |
| `download` | downloads the release's runtime without asking. When it cannot, it says why and that `M-x portal-build` builds instead; it never builds by itself |
| `build` | builds here without asking, for unattended setups |
| `always` | the former name of `build`, and still the same: it builds and never downloads |
| `never` | only says what is missing; `M-x portal-download-runtime` and `M-x portal-build` remain |

For example, to always download:

```elisp
(setq portal-build-on-first-use 'download)
```

`always` was the only unattended value before downloads existed, and a
setup that names it keeps building from source as before: download only if you
choose `download`. `download`, `build` and `always` also act outside a command,
as from a timer; `ask` asks only in a command. Batch Emacs never asks,
downloads or builds, whatever the value, and neither does Portal when
`portal-build-directory` names a build made elsewhere. When a download cannot
be offered, `ask` says why and offers Build here or Not now; when a build
cannot start, it offers Download or Not now.

## Troubleshooting

Messages below are what Emacs or `*portal-build*` shows. For a failed build,
read the end of `*portal-build*` or `build/portal-build.log` first.

**"Portal's build needs cmake, ninja".** The build found them neither on
Emacs's `exec-path` nor in Homebrew's or MacPorts' directories. Install them,
or, if they are installed elsewhere, add that directory to `exec-path` as in
[prerequisites](#prerequisites). Emacs started from the Dock or Finder does not
read your shell's startup files. `M-: (executable-find "cmake")` shows what
Emacs finds on `exec-path`. Or [download](#downloaded-runtimes) the native
part, which needs none of them.

**"…needs xcrun", or Swift errors early in the build.** Install Xcode, open it
once to finish its setup, and select it with
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
`xcrun swift --version` must report Swift 6.2 or newer.

**"Portal native views need…" or "Portal needs Emacs with module support,
on macOS or Linux".** This Emacs cannot run Portal: it is older than 31.1, not built
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
set `portal-build-bun`: the host then contains that Bun. The first build still needs the other downloads.

**"Portal cannot build in … it is not writable".** Portal builds beside its
sources. Install it where you can write, or build it elsewhere and set
`portal-build-directory`. If the Bun cache cannot be created, set
`portal-build-tools-directory`.

**"Portal's native part is older than its sources".** The native sources
changed since your build or download: run `M-x portal-download-runtime` or
`M-x portal-build`.
**"…restart Emacs to use it"** or **"Restart Emacs to replace the old Portal
native modules"** means this Emacs already loaded another build; restart it.
"Portal is already building" and "another Portal build is running" mean one
build is in progress; wait for it. If builds fail after you changed Emacs,
Xcode or CMake, remove the `build` directory in `portal-build-root`, or run
`cmake --fresh --preset dev` in a clone, and build again.

**"Portal's runtime was not installed: …".** The end of `*portal-runtime*`
has the same reason. Portal tried nothing else: run `M-x portal-build` to
build from source instead, or fix the cause and run
`M-x portal-download-runtime` again.

- "…answered 404 for …: is it released?" This Portal's release has no runtime
  for this system: it predates downloads, or the release is not published.
- "Cannot reach github.com securely: …" The network is down, a proxy is
  required (the download connects directly), or the certificate did not
  verify. The download never asks whether to continue.
- "The runtime of vX.Y.Z was built from other native sources than these" This
  checkout's native sources are not the release's, as on `main` or a branch.
  Build from source.
- "The runtime failed its check in a separate Emacs" The runtime did not load
  in this Emacs, and nothing was replaced. Build from source.
- "Another Portal runtime install is running" Wait for it, then retry.

Some reasons come before any download, from the question or the command
itself, such as "Portal has no runtime to download for …" for an Intel Emacs
on a Mac: no release has a runtime for this Emacs. Build from source.

To start over, delete `portal-runtime-directory` (`~/.emacs.d/portal/runtime/`
by default) while no Emacs has loaded Portal's module from there, then
download again.

**A page stays blank, or a message says "(see \*portal-server\*)".** The app
host did not start or stopped. `*portal-server*` holds its diagnostics; press
`g` in the page's buffer to retry, or run `M-x portal-restart-server`. See
[app host lifecycle and diagnostics](app-host.md).

**The launcher refuses this Emacs.** It accepts only one Emacs build; see
[launcher setup](launcher.md#set-up-safely).

**"This Portal is not on a branch, so `package-vc-upgrade` cannot upgrade
it".** The checkout was installed without `:rev "stable"`, or at a tag.
`package-vc-upgrade` will not move it. If you did not pin it on purpose, move
it to `stable` as in [moving an install to stable](#moving-an-install-to-stable).

Still stuck? [Open an issue](https://github.com/xiaoxinghu/portal/issues) with
your Emacs version and revision, macOS version, what `M-x portal-version`
says and the log, removing credentials and private content.
