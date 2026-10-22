# Portal: native views in Emacs

<p align="center">
  <img src="assets/portal.png" alt="Portal Companion Buffer: a cube with Emacs, terminal and web emblems" width="320" height="320">
</p>

Portal puts native WebKit pages and Ghostty terminals inside macOS Emacs panes.
For Emacs users who want a real terminal or a local document preview alongside
editing, each buffer has one native view that follows it across splits, resizing
and frames. Hidden pages and terminal sessions keep running.

The bundled app host provides Markdown previews and an offline Excalidraw
editor. Optional launchers present your own Emacs commands in
a native panel, invoked by global shortcuts you configure.

![Portals in action](docs/images/portal-panes.png)

## Scope

Portal requires **GNU Emacs 31.1 or newer, built for macOS's graphical NS
interface with dynamic modules**; it is not a cross-platform package or a
replacement for Emacs's text rendering. It is verified on Apple Silicon with
macOS 27; Intel Macs and older macOS versions are unverified. See
[supported platforms](docs/platforms.md) for the matrix, its evidence and
known issues.
The native module runs inside Emacs: a defect can crash that process. Start in
a disposable `emacs -Q`, and restart Emacs after rebuilding a module it has
already loaded.

The opt-in launcher has a stricter compatibility gate: **GNU Emacs NS 31.1,
revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`** (the `emacs-31.1` tag),
with native subroutine trampolines enabled. Other builds are rejected for this
feature. Read [launcher safety and setup](docs/launcher.md#set-up-safely) before
enabling it.

## Build and run

You need graphical macOS Emacs 31.1 or newer with module support and its
matching `emacs-module.h`, Apple's Swift 6.2 or newer and Clang (Xcode), CMake
3.29 or newer, and Ninja. Install CMake and Ninja with `brew install cmake ninja`
or your tool manager. Bun is optional: without a compatible one, the build
downloads and verifies Portal's pinned Bun (1.3.14). The first build downloads
the app host's locked dependencies, the pinned GhosttyKit binary (about 77 MB)
and its Swift wrapper; a build with tests, as from a clone, also downloads Emacs
packages for them. Bun and SwiftPM keep about 400 MB of these downloads in
their caches, outside Portal: see [disk use](docs/install.md#disk-use-and-removal).
No Zig installation is needed.

Graphical Emacs started from the Dock does not see your shell's `PATH`. Portal's
build looks for CMake and Ninja on Emacs's `exec-path`, then where Homebrew and
MacPorts install them, so a Homebrew installation needs no setup. For tools
installed elsewhere, add their directory to `exec-path` in your configuration,
for example `(add-to-list 'exec-path (expand-file-name "~/.local/bin"))`, or use
[exec-path-from-shell](https://github.com/purcell/exec-path-from-shell).

To install Portal, add it to your Emacs configuration:

```elisp
(use-package portal
  :vc (:url "https://github.com/xiaoxinghu/portal" :rev :newest))
```

Then run `M-x portal-hello`. Portal offers to build its native part and shows
the build in `*portal-build*`. When Emacs says "Portal is ready: retry your
command", run `M-x portal-hello` again. [Install Portal](docs/install.md)
covers installing from a clone or with straight.el, the first build's downloads,
upgrades and [troubleshooting](docs/install.md#troubleshooting).

To try Portal without changing your configuration, build a clone with the
graphical Emacs executable that matches the build's header. For a non-default
installation, select it using
[build and editor setup](CONTRIBUTING.md#build-and-editor-setup) before
building. From a clone of this repository, run:

```sh
./build.sh
emacs -Q -l "$PWD/portal.el" --eval '(portal-hello)'
```

The build produces `build/portal.bundle` and the standalone `build/portal-host`.
Either way, Emacs should then show **Hello World in a native web view**; its app host
starts automatically. Click the page or press `RET` to enter it, and press
Command-period (`⌘.`) to return to Emacs. The mode line says who has the
keyboard: `Portal Web[app]` while the page does, `Portal Web[emacs]` after;
`RET` re-enters it. Customize `portal-input-escape-key` to change the escape chord,
or `portal-input-double-escape` to leave with Escape typed twice.
`q` hides the view; killing its buffer closes it.

Try `M-x portal-terminal` for a shell, `M-x portal-render-markdown` for a saved
Markdown file, or `M-x portal-excalidraw` for a local drawing. Loading Portal registers no global
shortcuts. Runtime use needs neither Bun nor Node nor adjacent web assets; see
[distribution layout](CONTRIBUTING.md#build-outputs-and-distribution).

## Documentation and contributing

Start with the [documentation index](docs/README.md) for user guides and design
notes. [Contributing](CONTRIBUTING.md) covers the worktree workflow,
editor setup, generated files and checks before a PR. [Testing Portal](docs/testing.md)
contains graphical procedures and detailed coverage; [AGENTS.md](AGENTS.md)
adds agent-specific working instructions.

For help or reproducible bug reports, use the repository's
[GitHub issues](https://github.com/xiaoxinghu/portal/issues). Include the Emacs
version/revision, macOS version, Portal commit and relevant diagnostics (for app
host failures, `*portal-server*`), removing credentials or private content.
Implementation files are licensed under [GPL-3.0-or-later](LICENSE). Builds
include third-party components under their own licenses; see
[Licenses and third-party notices](docs/licenses.md).
