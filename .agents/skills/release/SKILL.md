---
name: release
description: Release Portal - the Version: commit, tested uncached, tagged, with stable moved to it.
disable-model-invocation: true
---

# Release Portal

[Releasing Portal](../../../docs/releasing.md) says what a release is and what its evidence
must show; read it first. `release.sh`, beside this file, does the mechanical parts, each in
a fresh clone from GitHub, so the checkout you are in never matters. Yours are the parts
that need judgment: what to release, what a red run means, the notes, the owner's answer.

The owner says what to release. The default is the next MINOR from `main` on GitHub. They
may name a level (`major`, `minor`, `patch`) or a version X.Y.Z, and a base: a commit, tag or
branch on GitHub, for `main` as of an earlier commit or a fix branch made from `stable`.

1. **Base.** Read `gh run list -R xiaoxinghu/portal --workflow checks.yml --commit BASE`. A
   failed run goes to the owner before anything is pushed.
2. **Candidate.** `release.sh candidate [LEVEL|X.Y.Z] [BASE]` works out the version, makes
   the release commit, pushes it as `release/vX.Y.Z` and starts Checks on it without cached
   downloads. It prints the version and the run.
3. **Checks.** `gh run watch RUN -R xiaoxinghu/portal --exit-status`, about 15 minutes. Red:
   report the failed steps and the run's URL, leave the branch for reading, and stop.
4. **Notes.** `release.sh notes X.Y.Z >NOTES` drafts them from the run's logs. Replace a
   bare "Merge pull request #N" by that pull request's title, and under "Checks outside CI"
   say passed only for what the owner says passed at this commit. Leave the evidence as
   printed.
5. **Approval.** Show the owner the notes, and each skipped test against the
   [evidence rules](../../../docs/releasing.md#evidence). Without a yes the release ends:
   `gh api -X DELETE repos/xiaoxinghu/portal/git/refs/heads/release/vX.Y.Z`.
6. **Publish.** `release.sh publish X.Y.Z NOTES` pushes the tag, fills a draft release
   with the logs and the run's tested Mac runtime, publishes it, checks that anyone
   downloads each file by the tag unchanged, then moves `stable` and `main` and deletes the
   candidate. When it fails, it says what it left: run it again, which finishes a draft and
   never changes a published release. An expired archive needs Checks again on the
   candidate's branch, uncached; a published release it refuses goes to the owner.
   [Publishing](../../../docs/releasing.md#publishing) says what each failure leaves. Done
   when the release page shows the tag, immutable, with its three files, `stable` is at the
   release commit and `main` contains it.

When `release.sh` refuses, report what it said and that nothing was published. Never do by
hand what it refused: no tag, branch or release is made, moved or deleted outside it, but
for the candidate in step 5.
