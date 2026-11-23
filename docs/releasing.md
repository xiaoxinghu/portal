# Releasing Portal

A release is one commit that changes the `Version:` line of `portal.el` and
nothing else, named three ways: the annotated tag `vX.Y.Z` points at it, the
branch `stable` is moved to it, and `main` contains it. `main` is where
development happens; `stable` only ever fast-forwards from one release commit
to the next, so a checkout on it upgrades with `git pull`, which is all
`package-vc-upgrade` does. use-package's `:last-release` and the Emacs Lisp
package archives find a release the same way, as the last commit that changed
`Version:`.

So `Version:` never changes by hand, and never on `main` outside a release:
whatever commit changes it becomes the newest release to package-vc. Between
releases `main` says the version of the last one, and `git describe` says how
far past it a checkout is.

## Making a release

A release is made by a coding agent following the
[release skill](../.agents/skills/release/SKILL.md): ask it to release Portal.
The skill's script, `release.sh`, does the mechanical parts, each in a fresh
clone from GitHub:

```sh
sh .agents/skills/release/release.sh candidate [LEVEL|X.Y.Z] [BASE]
sh .agents/skills/release/release.sh notes X.Y.Z >NOTES
sh .agents/skills/release/release.sh publish X.Y.Z NOTES
```

- `candidate` works out the version, the next MINOR from `main` unless told a
  level, a version or a base, puts the release commit on a branch
  `release/vX.Y.Z`, and starts Checks on it without cached downloads, a run
  of the [full set](../CONTRIBUTING.md#full-set) as every run started by hand
  is. It
  refuses a version that is not above the current one, a base that `stable`
  could not fast-forward to or that has nothing new, and a previous release
  left unfinished.
- `notes` drafts the notes from the logs of that branch's green run: what is
  new, what upgrading costs, the [runtime](#the-runtime-archive) it attaches,
  and the [evidence](#evidence).
- `publish` attaches the logs and the run's tested runtime to an immutable
  release, then moves `stable` and `main`, and deletes the branch; see
  [publishing](#publishing).

The agent chooses the base, reads a red run, finishes the notes, and publishes
only after you approve them. Your yes is the approval of the release step:
the workflow's jobs only read the repository, and `publish`, run by the agent
with your credentials, is what writes the tag, the release and the branches.
Until then nothing is published, so a release you do not approve was a dry
run: the agent deletes the branch. `notes` and `publish` refuse a run that
failed, that restored cached downloads, or that left out the full set's
checks: a push to `main` runs only the essential set.

The person releasing still:

- **reads the skipped tests** in the notes against the rules below;
- runs **the checks outside CI**, in the [VM](testing.md#graphical-checks-in-a-vm)
  or on a Mac, at the commit to release, or leaves them recorded as not run:
  - the [standalone AppKit checks](testing.md#standalone-appkit-checks);
  - physical-key delivery, by hand, which injected events cannot prove;
  - the fullscreen input tests, `sh test/input-gui.sh fullscreen`, which
    skip on GitHub's runners;
- runs **native acceptance** for each [platform row](platforms.md#acceptance-checks)
  the release claims beyond the runner's, macOS 27.0.1 with the pinned
  emacs-plus cask, and adds that evidence to the release's notes.

## A fix between releases

Fixes land on `main` first, always. When `main` is fit to release, release it,
as a PATCH when it holds only fixes. When it is not, release `stable` plus the
fix's commits alone: make a branch at `stable`'s tip, cherry-pick them onto it
with `git cherry-pick -x`, push it, and release with that branch as the base.
Nothing is merged into `stable`; the release commit is merged into `main`, so
`main` contains every release.

Releasing `main` as of an earlier commit C releases everything up to C, and
the commits after it wait; picking a commit D releases D's change alone.

## What versions promise

Until 1.0.0, a MINOR release may add, change and remove options, commands and
keys, and a PATCH release only fixes. 1.0.0 is the first release whose
options, commands and keys Portal commits to keeping; after it, only a MAJOR
release may break them.

## Evidence

A release ships only with evidence gathered at the release commit itself.
Results from an earlier commit are not evidence for it. Graphical steps count
only from a run that executed them; a skipped step is not a pass. For each
platform row the release claims, record:

- the commit, and the workflow run or VM run directory;
- macOS, CPU, Emacs build and revision, module header, Xcode, Swift, CMake and
  Bun, as the workflow's "Record the environment" step and build log print
  them;
- for each suite: passed, skipped or not run, with counts.

Name every skipped test and say why it skipped. A graphical suite fails when
a test skips that its script does not allow, so a green run's graphical skips
are these: `portal-launcher-gui-minibuffer-panel-stays-on-its-display`, which
needs a second display and may skip, and on GitHub's runners, where WebKit
refuses fullscreen, the four `portal-input-gui-web-fullscreen-` tests; those
four are checks not run until they pass in the VM. Any other skip, failure or check
not run means the release cannot claim what that check covers: fix it, or
narrow the claim in [supported platforms](platforms.md) first.

The evidence is the run's `logs` artifact, which the workflow keeps for 14
days and the release attaches: `environment.log`, with `USE_CACHE=false` when
the run restored no cached downloads and `PORTAL_TEST_EXPENSIVE=1` when it ran
the full set, `build.log`, CTest's own log
`ctest.log`, `python.log`, and each graphical suite's `test.log` in a
directory of its own. Every suite prints its counts and the reasons for its
skips there, and the notes quote them.

## The runtime archive

A run whose checks all passed also packs the build they tested, never a
second one, as the Apple Silicon runtime archive: `portal.bundle`,
`portal-host`, `portal-build.eld` and `licenses`, as the build made them.
`scripts/runtime-archive.py pack` writes it beside its manifest, which names
the target, the oldest macOS, the release's tag, the version, the commit, the
native source identity, and the archive's name, size and SHA-256. On a
candidate's branch the tag is `vX.Y.Z` and the archive
`portal-runtime-vX.Y.Z-macos-arm64.tar.gz`; elsewhere there is no tag, and
the archive is named after the version and the commit.
[`test/fixtures/runtime-manifest.json`](../test/fixtures/runtime-manifest.json)
is an example manifest.

The run then moves its `build/` away, unpacks the archive into another
directory with `scripts/runtime-archive.py unpack`, and checks it there: the
archive against the manifest, its files, each binary's CPU, oldest macOS and
libraries, then the module loaded and the host started by a disposable
Emacs, `portal-build--probe-batch`, and a terminal drawn by the
[rendering smoke test](testing.md#rendering-smoke-test). Only then are the
archive and the manifest kept, as two artifacts for 14 days; their record is
`runtime/` in `logs`. Portal's repository is public, so any signed-in GitHub
user can download them: the archive's `licenses/` is the notice and the
pointer to the source. Every release attaches them, also one that changed
only Lisp: the run packs them anyway, and an install that already has the
runtime of the same native sources downloads nothing.
`M-x portal-download-runtime`, and the first native command when asked to
download, fetch them by the release's tag, under these names; see
[downloaded runtimes](install.md#downloaded-runtimes).

The same run has a Linux job for each CPU, `ubuntu-26.04` and
`ubuntu-26.04-arm`, equal in priority, which make
`portal-runtime-…-linux-x86_64-gnu.tar.gz` and
`portal-runtime-…-linux-aarch64-gnu.tar.gz` from the build of the checks
that run on Linux: CTest and the Python tests, no graphical suite. Each
holds `portal.so`, `portal-build.eld`, `licenses`, and of
`ghostty-linux` Ghostty's library with its soname link, its resources and
`terminfo`, and no host. An archive is chosen by the CPU and the C library,
glibc, never by distribution or desktop: its floor, in the manifest, is
glibc 2.43, Ubuntu 26.04's, on which it is built with the runner's own
compiler and libraries. Ghostty's library is built for that glibc and the
CPU's baseline, `-DPORTAL_GHOSTTY_TARGET=x86_64-linux-gnu.2.43` (or
`aarch64-…`) `-DPORTAL_GHOSTTY_CPU=baseline`, and the module for the same
CPU by name, `-march=x86-64` or `-march=armv8-a`: the x86-64 image's GCC
would otherwise assume x86-64-v3. Its glibc is built for that too, and
marks every executable linked there as needing it, so the jobs' Emacs 31.1
is built in a stock `ubuntu:26.04` container, with pgtk, and cached. Unpacking checks each ELF binary's machine, that it needs no glibc
symbol version newer than the floor, nor, on x86-64, a CPU level above the
baseline in the note GCC writes, that it loads only GTK 3, Wayland,
EGL and glibc from the system and Ghostty's library from the runtime
through the module's `$ORIGIN/ghostty-linux/lib` runpath, and asks the
system's loader where it finds each. A disposable Emacs then loads the
module and starts Ghostty there. It does that again in a stock
`ubuntu:26.04` container, with the libraries of Ubuntu's own pgtk Emacs,
and then on a CPU of the baseline that QEMU emulates there, `qemu64` or
`cortex-a53`, where an instruction beyond it would stop Emacs; the
emulated CPU must first refuse a program of one newer instruction. Not on
the runner's own system: the x86-64 image's glibc is built for x86-64-v3,
and its loader stops on an older CPU before any program starts. `readelf`'s own account of both
binaries is `runtime/abi.log` in the job's `logs-TARGET`. No terminal is
drawn: Linux renders are checked on desktops, not here.

A release attaches the Apple Silicon archive alone for now: an install on
Linux downloads as soon as its release holds a Linux manifest, so the Linux
archives stay out, though the run must still pass its Linux jobs, until their
[download on desktops](platforms.md#linux) is accepted. `targets` in
`release.sh` names what a release attaches.

## Publishing

`publish` releases the commit and the files that run tested, in an order
that never shows a release half done, and nothing it published is ever
changed again:

1. It refuses unless the repository has
   [immutable releases](#guard-rails-on-github) on.
2. It downloads the run's runtime archive and manifest, checks each against
   GitHub's digest of the artifact, and the manifest against the tag, the
   version, the release commit and the archive's size and SHA-256. No
   archive is ever built here.
3. It pushes the tag alone, creates the release as a draft, and uploads the
   logs, the archive and the manifest to it. A draft is visible only to the
   repository's writers, and `stable` has not moved, so no install sees it.
4. When the draft holds exactly those files, it publishes it. GitHub then
   locks the tag and the assets: they cannot be replaced, added to or
   deleted, and the tag of a deleted release cannot be used again. The
   title and notes can still be edited.
5. It checks that the release is immutable, holds exactly those files, and
   that each downloads by the tag, without signing in, as the bytes GitHub
   holds and the run tested, the runtime as its manifest says; and
   `gh release verify` checks GitHub's attestation of the release. The
   manifest must be the one the run packed, a copy of which its `logs` keep
   in `runtime/`: so even a release found published, whose artifacts are not
   fetched again, is tied to the archive that run tested.
6. Only then does it move `stable` and `main` in one push, and delete
   the candidate's branch.

When a step fails, `publish` says what it left, and run again it finishes
the release:

- **The run's archive has expired.** A run keeps its artifacts 14 days,
  after which GitHub no longer lists them. `publish` refuses before pushing
  anything. Start Checks again on the candidate's branch, uncached, with
  `gh workflow run checks.yml -R xiaoxinghu/portal --ref release/vX.Y.Z -f cache=false`,
  then draft the notes and publish from that run: the release commit stays,
  and its newest green run is the evidence.
- **An upload failed, or anything before publishing did.** The tag and a
  draft remain. Run `publish` again: it keeps what the draft holds that
  matches, removes the rest, a half-uploaded file among them, and uploads
  what is missing. A draft whose run has since expired needs a new run, as
  above.
- **Something after publishing failed**, a download, the push of `stable`
  and `main` (as when `main` moved). Run `publish` again: it finds the
  release published, uploads and removes nothing, checks it as in step 5
  and moves the branches. It needs the run that tested it, the newest green
  one of the release commit, with its `logs` still kept.
- **A published release is not what was tested**, short of a file, not
  immutable, or a download differs. `publish` refuses and `stable` stays.
  The release cannot be mended and its tag never reused: take it to the
  owner. To abandon it, the owner marks it a pre-release on GitHub, which an
  immutable release allows, and says why in its notes; then release the
  next PATCH version.

`candidate` refuses a new version while the last one is a draft or
`stable` is not at it: finish that release first. It passes over a
published pre-release as abandoned: the next version goes above it, and
`stable` must be at the last release before it. Older releases are never
touched, so a Portal pinned to a tag downloads that tag's runtime for as
long as GitHub keeps the release.

`test/test_release.py` rehearses each of these with a stand-in GitHub, and
most were rehearsed once on GitHub itself, in a test repository: see
[the rehearsal](#the-rehearsal).

GitHub lists a change a few seconds after making it: a new draft, a
release just published, the immutable-releases setting just turned on. So
`publish` asks again, 2 s apart, before calling something missing, and
tries a download again, as the first one of a release just published can
answer 404.

### The rehearsal

On 2026-11-23 Portal 0.3.0 was released, with this script, in a public copy
of the repository, `xiaoxinghu/portal-release-rehearsal`, with immutable
releases on and `stable`, `v0.2.0` and its release as in Portal:

| Case | How | What happened |
| --- | --- | --- |
| Missing archive | The run's Mac manifest artifact deleted, as GitHub lists an expired one | Refused, nothing pushed; Checks again on the branch was the cure |
| A draft GitHub did not list yet | Found by chance | Stopped after the tag, before uploading; now waited for |
| Upload cut off | The archive's upload killed after 2 s | The draft kept it as `starter`, with no digest; nothing public, `stable` unmoved |
| Publishing again | `publish` run again | Removed the cut archive, uploaded it, published; `stable` and `main` moved |
| Changing it after | Replace, add or delete an asset; delete or move the tag | GitHub refused each; editing the notes was allowed |
| The client | `portal-runtime-install` from a clone of `stable`, batch Emacs | Fetched the archive by the tag through GitHub's redirect, digest as the manifest, installed in 4.1 s |

Not rehearsed on GitHub, only with the stand-in: a push of `stable` refused
after publishing, a published release short of a file, not immutable or
downloading other bytes, a tag on another commit, and immutable releases off.

## Guard rails on GitHub

Immutable releases keep a published release's tag and assets from being
replaced, which is what makes a runtime's digest worth checking: nothing is
signed, and an install trusts GitHub over TLS, as it does for the Lisp. It
applies to releases published after it is turned on. `publish` refuses
without it. Turn it on once, as the repository's owner:

```sh
gh api -X PUT repos/xiaoxinghu/portal/immutable-releases
gh api repos/xiaoxinghu/portal/immutable-releases   # {"enabled":true,...}
```

Two rulesets keep `stable` and the tags from being rewritten, whoever pushes.
Neither stops a release, which only fast-forwards `stable` and creates tags.
Create them once, as the repository's owner:

```sh
gh api -X POST repos/xiaoxinghu/portal/rulesets --input - <<'EOF'
{"name": "stable", "target": "branch", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/heads/stable"], "exclude": []}},
 "rules": [{"type": "non_fast_forward"}, {"type": "deletion"}]}
EOF
gh api -X POST repos/xiaoxinghu/portal/rulesets --input - <<'EOF'
{"name": "release tags", "target": "tag", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
 "rules": [{"type": "update"}, {"type": "deletion"}]}
EOF
```

`gh api repos/xiaoxinghu/portal/rulesets` lists them.
