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
[release skill](../.agents/skills/release/SKILL.md): ask it to release Portal,
or to make a dry run. It works in a fresh clone from GitHub, puts the release
commit on a branch `release/vX.Y.Z`, runs Checks on it without cached
downloads, composes the notes from the run's logs, and publishes the tag,
`stable` and `main` in one push only after you approve the notes. When Checks
fail, nothing is published.

The person releasing still:

- **reads the skipped tests** in the notes against the rules below;
- runs **the checks outside CI**, in the [VM](testing.md#graphical-checks-in-a-vm)
  or on a Mac, at the commit to release, or leaves them recorded as not run:
  - the [standalone AppKit checks](testing.md#standalone-appkit-checks);
  - physical-key delivery, by hand, which injected events cannot prove;
- runs **native acceptance** for each [platform row](platforms.md#acceptance-checks)
  the release claims beyond the runner's, macOS 27.0.1 with the pinned
  emacs-plus cask, and adds that evidence to the release's notes.

## A fix between releases

Fixes land on `main` first, always. When `main` is fit to release, release it,
as a PATCH when it holds only fixes. When it is not, release `stable` plus the
fix's commits alone: they are cherry-picked onto `stable`'s tip and released
from there, or, when they conflict, put on a branch made from `stable` by hand
and released from that branch. Nothing is merged into `stable`; the release
commit is merged into `main`, so `main` contains every release.

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

Name every skipped test and say why it skipped. Only
`portal-launcher-gui-minibuffer-panel-stays-on-its-display`, which needs a
second display, may skip. Any other skip, failure or check not run means the
release cannot claim what that check covers: fix it, or narrow the claim in
[supported platforms](platforms.md) first.

The workflow keeps its logs as the run's `logs` artifact for 14 days; the
release attaches them. Checks puts there CTest's own log, `ctest.log`, and
every suite prints its counts and the reasons for its skips.

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
