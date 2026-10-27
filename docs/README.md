# Portal documentation

Start with [build and run](../README.md#build-and-run), then
[install Portal](install.md) in your Emacs.
Run shell examples from the repository root, not `docs/`.

## Use Portal

| I want to… | Guide |
| --- | --- |
| Install Portal, build its native part, upgrade it or fix installation problems | [Install Portal](install.md) |
| Move between Emacs and a native view | [Keyboard ownership](keyboard.md) |
| Open HTML, URLs or a saved Markdown preview | [Web views and previews](web-views.md) |
| Draw and save offline | [Local Excalidraw drawings](excalidraw.md) |
| Run shells, switch terminals or use a quick terminal | [Terminals and optional Consult/Embark adapters](terminals.md) |
| Present a command in a panel or set a global shortcut | [Launchers and global shortcuts](launcher.md) |
| Diagnose a blank hosted app or restart its process | [App host lifecycle and diagnostics](app-host.md) |

## Build and change Portal

- [Supported platforms](platforms.md): the Emacs, macOS and CPU matrix, build
  and runtime requirements, and the evidence behind each claim.
- [Contributing](../CONTRIBUTING.md): build/editor setup, distribution, worktrees
  and the two tiers of checks.
- [Testing Portal](testing.md): batch coverage, graphical procedures, standalone
  native checks and opt-in smoke tests. Recorded results are not a new test run.
- [Releasing Portal](releasing.md): the checklist and evidence a release needs.
- [Licenses and third-party notices](licenses.md): what the outputs ship, the
  staged notices, open questions before a binary release and inventory upkeep.
- [Domain vocabulary](../CONTEXT.md): view, terminal and hosted-app terms.
- [Implementation and native boundaries](architecture.md): state ownership,
  lifetimes, platform interfaces and failure invariants.
- [Input bridge](terminal-input-bridge.md): key routing and the notification pipe.
- [Hosted-app bridge](editor-bridge.md): message transport and Excalidraw persistence.
- [Launcher native panel](launcher-native-panel.md): Emacs NS compatibility,
  frame guards, geometry and command sessions.
- [Application launcher integration](launcher-applications.md): launcher.el
  follow-ups and an optional smoke test.
- [Dependency security findings](dependency-security.md): audit dispositions,
  overrides and accepted exceptions with review triggers.
- [Terminal benchmarks](terminal-benchmark.md): latency/frame timing measurement
  and interpretation, not guaranteed parity with standalone Ghostty.

## Decisions and design records

These records preserve rationale. Design records do not claim every described
feature ships today; see the user guides for current behavior.

### Architectural decisions

1. [One Portal view per buffer](adr/0001-one-portal-view-per-buffer.md)
2. [Shared view/native interface](adr/0002-portal-view-native-seam.md)
3. [Platform interface primitives](adr/0003-platform-interface-primitives.md)

### Design records

- [Bun distribution options](bun-distribution.md): the private Bun bootstrap,
  size measurements and alternatives to revisit.
