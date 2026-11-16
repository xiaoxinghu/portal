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
  `release/vX.Y.Z`, and starts Checks on it without cached downloads. It
  refuses a version that is not above the current one, a base that `stable`
  could not fast-forward to or that has nothing new, and a previous release
  left unfinished.
- `notes` drafts the notes from the logs of that branch's green run: what is
  new, what upgrading costs, and the [evidence](#evidence).
- `publish` pushes the tag, `stable` and `main` in one push, creates the
  GitHub release with the logs attached, and deletes the branch.

The agent chooses the base, reads a red run, finishes the notes, and publishes
only after you approve them. Until then nothing is published, so a release you
do not approve was a dry run: the agent deletes the branch. `notes` and
`publish` refuse a run that failed or that restored cached downloads.

The person releasing still:

- **reads the skipped tests** in the notes against the rules below;
- runs **the checks outside CI**, in the [VM](testing.md#graphical-checks-in-a-vm)
  or on a Mac, at the commit to release, or leaves them recorded as not run:
  - the [standalone AppKit checks](testing.md#standalone-appkit-checks);
  - physical-key delivery, by hand, which injected events cannot prove;
  - the fullscreen input tests, `sh test/input-gui.sh fullscreen`, which
    skip on GitHub's runners;
  - the four Excalidraw slide tests, `sh test/views-gui.sh
    'excalidraw-gui-\(arrange\|presents\|slides-follow\)'`, which skip
    there too;
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
refuses fullscreen, the four `portal-input-gui-web-fullscreen-` tests, and the
four Excalidraw slide tests that
[skip themselves there](testing.md#view-graphical-checks); those eight are
checks not run until they pass in the VM. Any other skip, failure or check
not run means the release cannot claim what that check covers: fix it, or
narrow the claim in [supported platforms](platforms.md) first.

The evidence is the run's `logs` artifact, which the workflow keeps for 14
days and the release attaches: `environment.log`, with `USE_CACHE=false` when
the run restored no cached downloads, `build.log`, CTest's own log
`ctest.log`, `python.log`, and each graphical suite's `test.log` in a
directory of its own. Every suite prints its counts and the reasons for its
skips there, and the notes quote them.

## Guard rails on GitHub

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
