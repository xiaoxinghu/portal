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

## The command

One command makes a release, with your own `git` and `gh` credentials, from
any checkout:

```sh
scripts/release.py                  # the next MINOR, from the tip of main on GitHub
scripts/release.py --patch          # the next PATCH: 0.2.0 to 0.2.1
scripts/release.py --major          # the next MAJOR: 0.4.2 to 1.0.0
scripts/release.py 0.5.0            # that version
scripts/release.py --from REF       # main as of an earlier commit, or a pushed branch
scripts/release.py --pick COMMIT…   # stable plus those commits alone, the next PATCH
scripts/release.py --dry-run        # everything but the publishing
scripts/release.py --appkit-passed --keys-passed  # the checks outside CI passed
```

The level and the base are separate. `--major`, `--patch` or a version say
what the version becomes, counting from the largest `vX.Y.Z` tag (or, before
the first release, from `Version:`); without them it is the next MINOR, or the
next PATCH with `--pick`. The base is the tip of `main` on GitHub, or what
`--from` or `--pick` names. `--from` takes any commit, tag or branch already
on GitHub; releasing `main` as of an earlier commit is the usual case when its
tip is not the commit wanted.

What it does:

1. **Clones** the repository from GitHub into a temporary directory. The
   checkout you run it from is never used: its `main` may hold merges not yet
   pushed.
2. **Refuses** before pushing anything when `gh` is not signed in; the version
   is not above every tag and `Version:`, or its tag exists; the last tag has
   no GitHub release; `stable` is not an ancestor of the base; the base adds
   nothing since the last release; or the base's own Checks run on `main`
   failed, unless `--ignore-base-checks`.
3. **Commits** the new `Version:` line on the base, checks that `git blame`
   of the line names that commit, and pushes it as the branch
   `release/vX.Y.Z`. No user is on that branch.
4. **Runs Checks** on it without cached downloads (`cache=false`) and waits,
   saying which step is running.
5. **Red**: names the failed steps and the run, and stops. No tag, `stable`
   and `main` unchanged; `release/vX.Y.Z` stays for reading, and the next run
   replaces it.
6. **Green**: composes the notes (below), then pushes the tag, `stable` moved
   to the commit and `main` in one atomic push. `main` fast-forwards to the
   commit when it has not moved past the base; otherwise the commit is merged
   into it, and a push refused because `main` moved meanwhile is merged and
   tried again. Nothing is ever force-pushed to `stable`, `main` or a tag. It
   then creates the GitHub release with the notes and the run's logs attached,
   and deletes `release/vX.Y.Z`.

A dry run stops after the notes, prints them and deletes `release/vX.Y.Z`. It
spends one Checks run.

Running it again after an interruption is safe. Before the push, the next run
continues the same candidate and the same Checks run, or replaces a candidate
made on another base. After the push, the tag stops it from publishing twice,
and when the GitHub release is missing it says so; the interrupted run printed
the `gh release create` command that finishes it.

## The notes

The notes live in the GitHub release only; they can be edited after
publishing.

- **What is new**: the first-parent subjects of the base since the previous
  tag, without their `portal/<task>: ` prefix, and a pull request's title for a
  bare "Merge pull request". The first release says it is the first and links
  the README.
- **What upgrading costs**: whether any file the native build reads
  (`portal-build--input-files`) changed since the previous tag, so whether the
  first native command after upgrading offers a rebuild and a restart.
- **Evidence**, read from the run's job log and its `logs` artifact: the
  commit, the run, what "Record the environment" printed with the Emacs, module
  header and Bun lines, every step with its result and counts, each CTest suite
  with its own counts, and every skipped test by name with its reason. A run
  that restored cached downloads is refused as evidence.
- **Checks outside CI**: the standalone AppKit checks and physical-key
  delivery, each "not run" unless its flag says it passed.

The logs zip attached to the release keeps them past the 14 days the workflow
keeps its artifact.

## What a person still does

- **Read the skipped tests** in the notes against the rules below, before
  publishing: a dry run shows them.
- **The checks outside CI**, in the [VM](testing.md#graphical-checks-in-a-vm)
  or on a Mac, at the commit to release, then `--appkit-passed` and
  `--keys-passed`; or leave them recorded as not run:
  - the [standalone AppKit checks](testing.md#standalone-appkit-checks);
  - physical-key delivery, by hand, which injected events cannot prove.
- **Native acceptance** for each [platform row](platforms.md#acceptance-checks)
  the release claims beyond the runner's, macOS 27.0.1 with the pinned
  emacs-plus cask: run that row's graphical scripts through the VM runner in a
  guest of that combination, or on a Mac of it, and add the evidence to the
  release's notes.

## A fix between releases

Fixes land on `main` first, always. Then, when `main` is fit to release,
release it: `scripts/release.py`, or `--patch` when it holds only fixes. When
it is not, `scripts/release.py --pick COMMIT…` with the fix's commits on
`main`, merge commits included: it cherry-picks them with `-x` onto the tip
of `stable`, puts the release commit on top and goes on as for any release. A
cherry-pick that conflicts stops it before anything is pushed: make the branch
by hand from `stable`, push it, and release it with
`scripts/release.py --patch --from BRANCH`.

Nothing is merged into `stable` either way, so it still only fast-forwards.
The release commit is merged into `main`, so that `main` contains every
release: its `Version:` names the patch, and the next release from `main`
fast-forwards `stable` again.

`--from` and `--pick` are easy to take for each other. With `main` at
A-B-C-D-E and `stable` at A, `--from C` releases B and C, everything up to a
point, and D and E wait for the next release; `--pick D` releases D's change
alone, without B and C.

## What versions promise

Until 1.0.0, a MINOR release may add, change and remove options, commands and
keys, and a PATCH release only fixes. `--major` makes 1.0.0, the first release
whose options, commands and keys Portal commits to keeping; after it, only a
MAJOR release may break them.

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

## Guard rails on GitHub

Two rulesets keep `stable` and the tags from being rewritten. Neither stops the
command, whose pushes only fast-forward `stable` and create tags. Create them
once, as the repository's owner:

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
