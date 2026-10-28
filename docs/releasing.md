# Releasing Portal

A release is a commit on `main` that changes the `Version:` header in
`portal.el`, tagged `vVERSION`. use-package's `:vc` installs the newest such
commit by default. Portal has had no release yet, so the
[installation guide](install.md) asks for `:rev :newest` instead.

A release ships only with the evidence below, gathered at the release commit
itself. Results from an earlier commit are not evidence for it.

## Checklist

1. **Checks.** The [Checks workflow](../.github/workflows/checks.yml) passes on
   the release commit with every step green. Graphical steps count only from a
   run that executed them; a skipped step is not a pass.
2. **Uncached build.** Run the workflow on the release commit from the Actions
   tab with "Restore cached downloads" off. It must pass too, so that no cache
   hides a download that has gone missing or changed.
3. **Native acceptance.** The [acceptance checks](platforms.md#acceptance-checks)
   pass for each row the release claims as verified. The workflow's run covers
   the row its runner matches, macOS 27.0.1 with the pinned emacs-plus cask.
   Run other rows' graphical scripts through the [VM runner](testing.md#graphical-checks-in-a-vm)
   in a guest of that combination, or on a Mac of it.
4. **Checks outside CI.** Run these in the VM or on a Mac, or record them as not
   run:
   - the [standalone AppKit checks](testing.md#standalone-appkit-checks);
   - physical-key delivery, by hand, which injected events cannot prove.
5. **Record.** Write the evidence into the GitHub release's notes, then tag and
   publish.

## Evidence

For each row the release claims, record:

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

The workflow keeps its logs, the graphical suites' included, as the run's
`logs` artifact for 14 days. Copy what the notes need before then.
