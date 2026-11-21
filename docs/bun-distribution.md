# Bun build and distribution options

Recorded: 2026-09-17. Updated: 2026-11-21. Status: Mac builds compile the host
with the pinned Bun, downloaded when needed; Linux builds no host; prebuilt
hosts remain deferred.

## Current behaviour

On macOS, `./build.sh` uses CMake to build the native Emacs module and compile
the TypeScript server into `build/portal-host`. It selects Bun with
`tools/resolve-bun.sh`: an explicit `BUN`, a cached copy of the pinned Bun in
`tools/bun.manifest`, or that Bun downloaded from its official release and
checked against the manifest's digest. A `bun` on `PATH` is never used, however
new: the host contains the Bun that compiled it, so the one a release ships is
the one its tag's manifest names. `M-x portal-build` runs the same script with
a cache under `user-emacs-directory`, so package upgrades reuse it. See
[Bun in the installation guide](install.md#bun).

On Linux, which has no web views yet, the build makes no host and needs no
Bun. CMake runs the host's Bun tests with `BUN` or a `bun` on `PATH`, and
reports them skipped without one.
This follows the native package installation research, which preferred an
Emacs-owned persistent cache to a per-checkout directory.

Bun is a **build dependency**, not a runtime installation requirement: the host
contains the Bun runtime, server code, and Hello World assets. See
[Bun's standalone executable documentation](https://bun.com/docs/bundler/executables).

Source builds on macOS still require graphical macOS Emacs and its module
header, Apple's Swift/Clang toolchain, CMake, and Ninja, even without a Bun
installation step.

## Options

| Approach | User experience | Tradeoffs |
| --- | --- | --- |
| Require installed Bun (former behaviour) | Install Bun, then run `./build.sh`. | Simplest setup; source users manage Bun. |
| Automatically download Bun during the build (current) | Run `./build.sh`; it obtains Bun. | No manual installation; first build needs a download or supplied executable. |
| Distribute a prebuilt host | Install a release with matching `portal-host`, or download it during build. | No local Bun compiler; requires release artifacts per supported architecture. |

### Automatically download Bun

Implemented by `tools/resolve-bun.sh`:

- Pin a Bun version and archive checksum per supported Mac architecture, and
  for Linux with glibc, which only the host's tests could use today.
- Download and extract into a private cache: `build/tools/` for `./build.sh`,
  `~/.emacs.d/portal/tools/` for `M-x portal-build`.
- Verify the checksum before extraction and execution.
- Invoke the executable directly; leave `PATH`, shell configuration, and global
  Bun installations unchanged.
- Cache for subsequent builds; retain the explicit `BUN` path override for
  development and offline builds. Take no `bun` from `PATH`: what is compiled
  into the host is the pinned Bun, unless someone names another.

Bun offers direct macOS Apple Silicon and Intel downloads; see the
[installation documentation](https://bun.com/docs/installation).
CMake provides [download, hash verification, and archive extraction](https://cmake.org/cmake/help/latest/command/file.html).

This preserves single-command source builds with project-managed Bun. A clean
offline build needs a supplied executable or populated cache.

### Distribute a prebuilt host

Proposed implementation:

- Build and test `portal-host` in CI for macOS Apple Silicon and Intel.
- Publish versioned, checksummed artifacts paired with the matching Lisp package
  and control protocol.
- Bundle the host in releases or download the matching artifact at install/build.
- Make CMake's Bun requirement conditional: prebuilt hosts skip server compilation;
  development retains source compilation.

Bun compiles for both Mac architectures; test each artifact on its target.
Shipping only the host still requires locally building the native Emacs module.
Distributing that module needs a separate compatibility/release plan.

## Size measurements

Measured locally on Apple Silicon with Bun 1.3.14: uncompressed file sizes,
not download sizes or runtime memory.

| Artifact | Bytes | MB (decimal) | MiB |
| --- | ---: | ---: | ---: |
| Bun executable | 63,096,576 | 63.1 | 60.2 |
| Compiled Hello World host, including Bun | 63,446,114 | 63.4 | 60.5 |

The runtime accounts for almost all host size. Distributed hosts include Bun;
no separate executable is needed. Automatic-download source builds retain both
cached compiler and compiled host. Sizes vary by Bun version and architecture.

## Recommendation to revisit

Automatically download pinned Bun for source builds; add prebuilt host artifacts
when establishing releases. Both can coexist: contributors build from source,
release users receive compiled hosts.

Automatic download is implemented for source builds; prebuilt distribution
remains a proposal. The runtime downloads' Mac archive will carry the compiled
host as the build makes it, and the Linux archive none, until Linux has web
views.
