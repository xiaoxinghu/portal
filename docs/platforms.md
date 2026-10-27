# Supported platforms

Portal claims support only where a recorded run proves it. A declared minimum,
such as a deployment target, says where binaries may load; it is not evidence
that Portal works there. Ordinary Portal views and the opt-in launcher have
separate claims.

## Matrix

| Emacs | macOS | CPU | Terminal and web views | Launcher |
| --- | --- | --- | --- | --- |
| GNU Emacs 31.1 NS, revision `a360712c` | 27.0.1 | Apple Silicon | **Verified** | **Verified** |
| Other GNU Emacs 31.1 NS builds | 27.0.1 | Apple Silicon | Unverified | Unsupported: refused |
| Later GNU Emacs NS releases | any | any | Unverified | Unsupported: refused |
| GNU Emacs 31.1 NS | 13.0–26 | any | Unverified | Unverified |
| GNU Emacs 31.1 NS | any | Intel | Unverified | Unverified |
| x86_64 Emacs under Rosetta | any | Apple Silicon | Unsupported | Unsupported |
| GNU Emacs 30 or earlier | any | any | Unsupported: refused | Unsupported: refused |
| Text frames, terminal-only or non-NS builds, other systems | — | — | Unsupported: refused | Unsupported: refused |

Revision `a360712c9d272d950d8d8255ef74570f7e90b7d9` is the `emacs-31.1` release
tag. "Refused" means Portal stops with a message naming the requirement before
loading native code. Package metadata requires Emacs 31.1, so package managers
refuse older versions too; Lisp still byte-compiles on any Emacs.
[Evidence](#evidence) for the verified row is recorded below.

Each unverified row needs the [acceptance checks](#acceptance-checks) passing on
that combination before it is claimed:

- **Other Emacs 31.1 builds and later releases.** The verified build is the
  emacs-plus cask, which adds its own patches. Run the checks on each other
  build (official sources, other distributions) or release.
- **macOS 13–26.** A guest of the oldest version to claim, with matching Xcode.
- **Intel.** A physical Intel Mac: Apple Silicon cannot virtualize Intel macOS.
  Ghostty and Bun ship Intel binaries, but no Portal build has run on one.
- **Emacs 30.** A released Emacs 30 NS build, before lowering the minimum in
  `Package-Requires` and `portal-view--unsupported`.

The launcher keeps its narrower gate: GNU Emacs NS 31.1 at the revision above,
with native subroutine trampolines enabled. Builds whose
`emacs-repository-version` is not that revision are refused. Widening the gate needs
the launcher's native review in [its design notes](launcher-native-panel.md),
not only passing checks; see [launcher safety](launcher.md#set-up-safely).

## Requirements

Building Portal needs:

- the Emacs that will load the module, and its `emacs-module.h`;
- Xcode with Swift 6.2 or newer and Clang. The Ghostty wrapper's
  `swift-tools-version` sets the Swift minimum;
- CMake 3.29 or newer (`cmake_minimum_required`) and Ninja;
- Bun with `Bun.markdown.html`, which CMake checks;
- network access for the first build's locked downloads.

Running Portal needs only the Emacs it was built for and the build outputs.
Neither Bun, Node nor Swift is used at runtime.

Build against the Emacs that loads the module. The module refuses to initialize
in an Emacs whose module interface is older than the header it was built with,
so a module built for Emacs 31 does not load into Emacs 30. Both build outputs
contain only the building Mac's CPU architecture, which must match the Emacs
process: an Intel Emacs under Rosetta cannot load an Apple Silicon build.

`native/Package.swift` declares macOS 13 as the deployment target. The compiler
then rejects calls to APIs newer than macOS 13 that lack availability checks,
and the module and host record 13.0 as their minimum. The prebuilt Ghostty
library and Bun both require macOS 13 as well. This is the floor the binaries
are built for, not a tested support claim.

## Acceptance checks

A combination is verified when, at one Portal commit:

1. `./build.sh` and the [full set](../CONTRIBUTING.md#full-set) of checks
   pass;
2. `sh test/views-gui.sh` and `sh test/input-gui.sh` pass with no skips in a
   graphical session of that combination, on a Mac or in a VM guest, for
   terminal and web views and their keyboard handling;
3. `sh test/launcher-gui.sh` passes, for the launcher. Only the test that
   needs a second display may skip.

Physical keys, Accessibility and manual checks are outside these claims too.
Record each run below; older results are not evidence for later changes.

## Evidence

Recorded 2026-10-11 at the commit introducing this page, on top of `main` at
`1a21a1b`. The guest kept default macOS settings, including autocorrection.

| | Host | VM guest |
| --- | --- | --- |
| Machine | Apple M1 Pro, arm64 | UTM guest on that host, arm64 |
| macOS | 27.0.1 (26A434) | 27.0.1 (26A434) |
| Emacs | emacs-plus-app cask 31.1-349: GNU Emacs 31.1, revision `a360712c`, NS, modules, native compilation | same cask and revision |
| Module header | `/Applications/Emacs.app/Contents/Resources/include/emacs-module.h` (Emacs 31) | same |
| Xcode, Swift | Xcode 27.0 (27A266a), Swift 6.4 | same |
| Bun, CMake | Bun 1.4.2, CMake 4.4.4 | same |
| Results | build; 29 of 30 CTest suites, see below; Biome; TypeScript; 8 Python tests | see below |

On the host, `vm-runner`'s "unlaunchable commands record a failure" exceeds
Bun's 5-second test timeout; it fails the same way on `main` at `1a21a1b`.

In the guest:

- `views-gui.sh`: 40 of 40 passed, no skips.
- `input-gui.sh`: 39 of 39 passed, no skips.
- `launcher-gui.sh`: 41 passed; 1 skipped,
  `portal-launcher-gui-minibuffer-panel-stays-on-its-display`, which needs a
  second display.

Built artifacts: `portal.dylib` and `portal-host` are arm64 only, with minimum
macOS 13.0.
