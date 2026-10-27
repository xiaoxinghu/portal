# Working on Portal

When the `ws` CLI is on the system, tasks and notes live there: `ws help` explains it.

Before changing code, read [Contributing](CONTRIBUTING.md) for build setup,
required checks and generated-file boundaries. After rebuilding a loaded native
module, restart Emacs; it does not hot-reload.
Before verifying work, read [Testing Portal](docs/testing.md#verifying-work)
and run its checks, graphical ones included: the default loop while working,
the full set before merging. Start graphical Emacs only through the test
scripts: when the clone sets `git config portal.testVm`, they run in that VM
and keep windows off the desktop.

Before changing view ownership or platform interfaces, read
[the native boundaries](docs/architecture.md) and its linked ADRs. When editing
launcher examples, preserve the markers in [the launcher guide](docs/launcher.md):
tests execute those blocks directly.
