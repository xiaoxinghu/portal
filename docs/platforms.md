# Supported platforms

Portal claims support only where a recorded run proves it. A declared minimum,
such as a deployment target, says where binaries may load; it is not evidence
that Portal works there. Ordinary Portal views and the opt-in launcher have
separate claims.

## Matrix

| Emacs | macOS | CPU | Terminal and web views | Launcher |
| --- | --- | --- | --- | --- |
| GNU Emacs 31.1 NS, revision `a360712c` | 27.0.1, 27.2.1 | Apple Silicon | **Verified** | **Verified** |
| Other GNU Emacs 31.1 NS builds | 27.0.1, 27.2.1 | Apple Silicon | Unverified | Unsupported: refused |
| Later GNU Emacs NS releases | any | any | Unverified | Unsupported: refused |
| GNU Emacs 31.1 NS | 13.0–26 | any | Unverified | Unverified |
| GNU Emacs 31.1 NS | any | Intel | Unverified | Unverified |
| x86_64 Emacs under Rosetta | any | Apple Silicon | Unsupported | Unsupported |
| GNU Emacs 30 or earlier | any | any | Unsupported: refused | Unsupported: refused |
| GNU Emacs 31.1 pgtk on Linux, Wayland | — | any | Terminals, Rex connections and blocks' screens unverified, run on one machine; no web views yet. See [Linux](#linux) | Unsupported: refused |
| Text frames, terminal-only builds, non-NS builds on macOS, other systems | — | — | Unsupported: refused | Unsupported: refused |

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

## The downloaded runtime

The Apple Silicon [runtime download](install.md#downloaded-runtimes) is
claimed only on the macOS versions it has run on:

| macOS | Emacs | CPU | Download, terminal, web views and preview |
| --- | --- | --- | --- |
| 27.2.1 (26B131) | GNU Emacs 31.1 NS, revision `a360712c` | Apple Silicon | **Verified**, on a Mac with no developer tools |
| Any other, 13.0 or newer | GNU Emacs 31.1 NS | Apple Silicon | Unverified |

Its binaries are built for macOS 13, as a build's are, but no download has run
on any other version, and no Ventura guest is set up to run one. A version is
added here once the [download's acceptance](#the-download) passes on it. The
rows of the [matrix](#matrix) above are about Portal built from source.

## Linux

On Linux Portal has terminals and no web views yet. Its native module
builds there and loads into an Emacs 31.1 built with pgtk, and a terminal
runs your login shell in a pane of a frame on Wayland, drawn by
[Portal's own build of Ghostty](../CONTRIBUTING.md#ghostty-on-linux).
Emacs [connects to a Rex server](rex.md#on-linux) there, and a window that
shows a block's buffer shows the block's screen. Opening a page fails with
"Portal has no web views on Linux yet", so the build makes no app host and
needs no Bun.
Other frames are refused before any native code loads, with the reason: an
Emacs built without pgtk, a text terminal, or a pgtk frame that GDK put on
X11. [Building on Linux](../CONTRIBUTING.md#building-on-linux) says what a
build needs and which checks run.

The [runtime download](install.md#downloaded-runtimes) has an archive for
x86-64 and one for aarch64, for glibc 2.43 or newer, and refuses musl, other
CPUs and older glibc before downloading, offering a build. Which archive an
install takes, and each refusal, is tested on fixtures only: no Linux release
has published an archive, and no download has run on a desktop.

**Untested: Emacs from Nix, Guix, Flatpak or Snap.** None has been tried,
with a build or a download. Such an Emacs may not use the system's C library
or library paths, and Portal does not special-case it: the download reads
the glibc of the Emacs process itself, and the module load in a disposable
Emacs decides. When that load fails, the install says what the runtime needs
and offers the local build.

The view machinery was run on 2026-11-20 on one machine, with a test pattern
for content: Arch Linux on aarch64 (an M1 Pro under Asahi), Hyprland 0.56.2,
Arch's `emacs-wayland` 31.1, GTK 3.24.52, GCC 16.1, CMake 4.5, Zig 0.17.1 and
Bun 1.3.14, Portal's pin, at scale 2. `sh test/linux-gui.sh` passed, 18 tests,
and `sh test/linux-follow.sh` found no frame out of place in recordings of
3,719 frames and, with the stretched pattern, 3,715. They ran on the
[test desktop](testing.md#linux-graphical-checks), a headless output of a
second Hyprland with no animations. No other compositor, no other scale, no
screen a person looks at and no x64 machine has run it.

Terminals were run on 2026-11-20 on the same machine and test desktop, with
Mesa's `asahi` driver: `sh test/linux-gui.sh` passed, 23 tests, among them a
shell typed into, two terminals with one closed beside a flood of output
with no torn frame, and Emacs quitting with a terminal printing; and
`sh test/linux-follow.sh terminal` found no frame out of place in a
recording of 1,198 frames of a terminal under output. No other GPU driver
has drawn one.

Rex blocks' screens were run on 2026-11-20 on the same machine and test
desktop, against the fake server and against Arch's `rex`
0.0.1795116584: `sh test/linux-gui.sh` passed, 50 tests, among them the
fake server's 21 and a held grid read from the screen to the pixel;
`sh test/rex-server-gui.sh` passed all 12 tests against the real server,
none skipped; and `sh test/linux-follow.sh fed` found no frame out of place
in recordings of a block fed all the while, about 1,195 frames each.

## Requirements

Building Portal on macOS needs:

- the Emacs that will load the module, and its `emacs-module.h`;
- Xcode with Swift 6.2 or newer and Clang. The Ghostty wrapper's
  `swift-tools-version` sets the Swift minimum;
- CMake 3.29 or newer (`cmake_minimum_required`) and Ninja;
- Bun, to compile the app host: Portal's pinned Bun, which the build
  downloads, or one named with `BUN` or `portal-build-bun` that has
  `Bun.markdown.html` and is the pinned version or newer. A `bun` on `PATH`
  is not used. See [Bun](install.md#bun);
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

### The download

A macOS version is verified for [the downloaded runtime](#the-downloaded-runtime)
when, on a Mac or guest of that version with graphical Emacs and no build
of Portal on it, the Lisp installed as
[the install guide](install.md#with-use-package-and-package-vc) says, and then
none of Xcode, the Command Line Tools, CMake, Ninja, Zig or Bun left on it
(installing needs Git, which a Mac has only with Xcode or the Command Line
Tools):

1. the first native command offers Download, and the install fetches a green
   Checks run's runtime archive and manifest, the files a release attaches,
   served at a release's address;
2. the retried command opens a terminal; an ordinary page opens without
   starting the app host; a Markdown preview starts the runtime's host;
3. `sh test/render-smoke.sh` passes on the downloaded runtime, with
   `PORTAL_SMOKE_HELPERS`;
4. no file of the runtime carries `com.apple.quarantine`, and nothing asks
   about it or about developer tools;
5. a fresh Emacs with no release reachable uses the cached runtime without
   asking;
6. with the developer tools back and no runtime cached, Build here builds
   from the sources and the retried command uses that build.

## Evidence

Recorded 2026-11-23, [the download's acceptance](#the-download), the first
download of a runtime on a Mac that never built Portal: a fresh clone of the
VM recipe's base image, never used by the test runner.

| | VM guest |
| --- | --- |
| Machine | Tart guest, Apple M1 Pro (Virtual), 4 cores, AppleParavirtGPU, scale 1 |
| macOS | 27.2.1 (26B131), Gatekeeper on |
| Emacs | GNU Emacs 31.1, revision `a360712c`, NS, the recipe's emacs-plus app, started with `open -a Emacs` |
| Tools | none of Xcode, the Command Line Tools, CMake, Ninja, Zig or Bun once the Lisp was installed (Xcode was there for Git and native compilation, then moved away) |
| Lisp | the install guide's use-package form with `:rev :newest`: `main` at `16f31d1` |
| Runtime | Checks run 45102309512's archive of `16f31d1`, 45,804,467 bytes, SHA-256 `e5afad28403840a573a48bbb5883d54476e6fb8d94a6dbfbef23f0ea0e8fa775`, identity `abe1ac93…`, served under the v0.2.0 release's names from 127.0.0.1 with a test certificate authority |

- Download: offered with Not now and no Build here, installed in 2.4 s with
  two requests; the retried command opened a terminal from the runtime; an
  ordinary page opened with no app host; a Markdown preview started the
  runtime's `portal-host`.
- `sh test/render-smoke.sh` on the runtime: every check passed, done 4.2 s
  from Emacs's start.
- No file of the runtime had any extended attribute. Gatekeeper's exec check
  evaluated the module, as it does a local build's, and nothing asked. No
  dialog about developer tools opened.
- Offline, with nothing serving: no question, no install; terminal, a local
  page and a Markdown preview from the cache.
- Build here, with the tools back and no runtime: `build.sh --prune` built
  in 71 s, and the retried command loaded `build/`'s module.

`codesign --verify` fails the archive's `portal-host` ("invalid signature")
and `portal.bundle` ("code has no resources"), as it does a local build's;
both are ad-hoc and linker-signed. Loading them needs no more; a Developer
ID signature would need both fixed.

Recorded 2026-11-20, the first run on a Mac since Linux gained views,
terminals, Rex connections and blocks' screens, which changed Lisp, tests and
CMake that the Mac shares. The full set ran with `PORTAL_TEST_EXPENSIVE=1`,
at the commit that records it, on `main` at `26ab316`.

| | Host | VM guest |
| --- | --- | --- |
| Machine | Apple M1 Pro, arm64 | Tart guest on that host, arm64 |
| macOS | 27.2.1 (26B131) | 27.2.1 (26B131) |
| Emacs | emacs-plus-app cask 31.1-406: GNU Emacs 31.1, revision `a360712c`, NS, modules, native compilation | same revision |
| Xcode, Swift | Xcode 27.2 (27B52), Swift 6.4.2 | Xcode 27.2 (27B52) |
| Bun, CMake | Bun 1.4.2, CMake 4.4.4 | Bun 1.3.14, CMake 4.0.3 |
| Results | build; 35 of 35 CTest suites; Biome; TypeScript; 72 Python tests, 16 of them skipped: Ghostty's Linux build | see below |

In the guest, through `sh test/gui-all.sh`:

- `views-gui.sh`: 90 of 90 passed, no skips.
- `input-gui.sh`: 17 of 17 passed, no skips.
- `launcher-gui.sh`: 41 passed; 1 skipped,
  `portal-launcher-gui-minibuffer-panel-stays-on-its-display`, which needs a
  second display.
- `terminal-shell-startup.sh`: 2 of 2 passed.
- `rex-server-gui.sh`: 12 of 12 passed against Rex Server
  0.1.0-preview.14, the VM recipe's pin.
- `package-gui.sh`: passed.

Built artifacts: `portal.dylib` and `portal-host` are arm64 only.

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
