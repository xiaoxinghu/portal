---
name: release
description: Release Portal - the Version: commit, tested uncached, tagged, with stable moved to it.
disable-model-invocation: true
---

# Release Portal

[Releasing Portal](../../../docs/releasing.md) says what a release is and what its evidence
must show; read it first. This is how to make one. The owner says what to release; ask when
they did not:

- **next** (the default): MINOR from the tip of `main` on GitHub;
- **from** a commit, tag or branch on GitHub: `main` as of an earlier commit, or a fix branch
  made from `stable`;
- **pick** commits of `main`: `stable` plus those commits alone, PATCH;
- a level (MAJOR, MINOR, PATCH) or a version X.Y.Z;
- **dry run**: every step up to the notes, nothing published.

## Rules

- Work in a fresh clone of `https://github.com/xiaoxinghu/portal` in a temporary directory.
  The checkout you were started in may hold merges GitHub does not have.
- The release commit changes the `Version:` line of `portal.el` and nothing else.
- `stable` only fast-forwards. Every push is a plain push: tags, `stable` and `main` are
  never forced, deleted or moved back.
- Publish only from a green, uncached Checks run of the release commit itself, with
  evidence complete, and only after the owner approves the notes.
- When a step goes red or a check refuses, stop and report: what, the run's URL, and that
  nothing was published.

## Steps

1. **Base.** Clone; the base is `origin/main`, the commit named by **from**, or for **pick** a
   branch at `origin/stable` with each commit cherry-picked by `git cherry-pick -x` (`-m 1`
   for a merge). A conflict stops the release: the fix branch is the owner's to make, then
   released with **from**. Done when the base is one commit you can name.
2. **Version and refusals.** The current version is the largest `vX.Y.Z` tag, or before the
   first release the `Version:` line. The new one is the next at the level asked, or the
   version given. Stop when it is not above every tag; its tag exists; the largest tag has no
   GitHub release (`gh release view`); `stable` exists and is not an ancestor of the base; or
   the base adds no first-parent commit since the last tag. When the base is on `main`, read
   `gh run list --workflow checks.yml --commit BASE`: a failed run on `main` goes to the owner
   before anything is pushed. Done when every refusal is checked.
3. **Release commit.** On the base, set the `Version:` line and commit it alone as
   `release: Portal X.Y.Z`. Check `git diff --numstat HEAD^ HEAD` is `1 1 portal.el` and
   `git blame -L '/^;; Version:/,+1' HEAD -- portal.el` names HEAD. Push it as
   `release/vX.Y.Z`, replacing what an earlier attempt left there.
4. **Checks.** `gh workflow run checks.yml --ref release/vX.Y.Z -f cache=false`, find the run
   by its head commit in `gh run list --branch release/vX.Y.Z`, and wait with
   `gh run watch RUN --exit-status` (about 15 minutes). Red: name the failed steps, leave the
   branch for reading, stop.
5. **Notes.** Compose them as in [Notes](#notes), every section filled from the run's logs.
   Done when every suite's count and every skipped test is in them, or what is missing is
   reported and the release stops.
6. **Approval.** Show the owner the notes and the skipped tests against the evidence rules. A
   dry run ends here: delete `release/vX.Y.Z`.
7. **Publish.** `git tag -a vX.Y.Z -m "Portal X.Y.Z"` on the release commit. Fetch; `main`'s
   new tip is the release commit when `origin/main` is its ancestor, else a merge of it into
   `origin/main` titled `release: merge Portal X.Y.Z into main`. Then one push:
   `git push --atomic origin vX.Y.Z RELEASE:refs/heads/stable MAIN:refs/heads/main`. Refused
   because `main` moved: fetch, merge again, push again. Then
   `gh release create vX.Y.Z --verify-tag --title "Portal X.Y.Z" --notes-file NOTES LOGS.zip`
   with the run's logs zipped, and delete `release/vX.Y.Z`. Done when the release page shows
   the tag, `stable` is at the release commit and `main` contains it.

## Notes

- **What is new**: `git log --first-parent --format=%s PREVIOUS..BASE` as a list, each
  `portal/<task>: ` prefix dropped, `release:` subjects left out, a bare "Merge pull request
  #N" replaced by that pull request's title. The first release: one line saying so, linking
  the README.
- **What upgrading costs**: `git diff --name-only --no-renames PREVIOUS RELEASE`. Any of
  `CMakeLists.txt`, `CMakePresets.json`, `build.sh`, or a file under `host/`, `native/` or
  `tools/` (no dot-named part, nothing in `node_modules`), is what the native build hashes:
  "the first native command after upgrading offers a rebuild of several minutes, then restart
  Emacs". None: "Lisp only, no rebuild".
- **Evidence**: the commit, the run's URL, the environment, a table of every step with its
  result and counts, each CTest suite's own counts, and every skipped test with its reason.
- **Checks outside CI**: the standalone AppKit checks and physical-key delivery, "not run"
  unless the owner says they passed at this commit.

Where the evidence is:

- The job log: `gh api --allow-escape-sequences repos/xiaoxinghu/portal/actions/jobs/JOB/logs`,
  JOB from `gh run view RUN --json jobs`. Each step that ran starts at a `##[group]Run ` line,
  in order; `gh run view --log` names no steps. The run was uncached when the echoed
  environment says `USE_CACHE: false`; anything else is no evidence.
- "Record the environment" prints macOS, Xcode, Swift, CMake and the screen; "Install Emacs"
  the Emacs build and revision; "Build" `emacs-module.h from …`; `build.log` the Bun line.
- Counts: CTest's summary, `Ran N tests in` from Python's verbose run, ERT's `Ran N tests, …`
  with its `SKIPPED name reason` lines, and `N checks passed` from the package suite.
- `gh run download RUN -n logs`: `ctest.log` holds every CTest suite's own output, its counts
  and skips included; the C core's programs end with `N checks passed`.
