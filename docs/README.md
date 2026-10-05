# Portal documentation

Start with [build and run](../README.md#build-and-run).
Run shell examples from the repository root, not `docs/`.

## Use Portal

| I want to… | Guide |
| --- | --- |
| Move between Emacs and a native view | [Keyboard ownership and toolbars](keyboard.md) |
| Open HTML, URLs or a saved Markdown preview | [Web views and previews](web-views.md) |
| Draw and save offline | [Local Excalidraw drawings](excalidraw.md) |
| Run shells, switch terminals or use a quick terminal | [Terminals and optional Consult/Embark adapters](terminals.md) |
| Find running agents and understand their activity | [Agent dashboard](agents.md) |
| Present a command in a panel or set a global shortcut | [Launchers and global shortcuts](launcher.md) |
| Browse, author or complete Markdown tasks | [Markdown task browser and format](tasks.md) |
| Use the separate `project.org` integration | [Org task view](org-tasks.md) |
| Diagnose a blank hosted app or restart its process | [App host lifecycle and diagnostics](app-host.md) |

This repository stores tasks in `tasks/`; `project.org` and its archive are
historical references. Org integration remains available for projects using it,
not as a parallel task store here.

## Build and change Portal

- [Contributing](../CONTRIBUTING.md): build/editor setup, distribution, worktrees
  and checks before a PR.
- [Testing Portal](testing.md): batch coverage, graphical procedures, standalone
  native checks and opt-in smoke tests. Recorded results are not a new test run.
- [Domain vocabulary](../CONTEXT.md): view, terminal, hosted-app and Org task terms.
  See the [task format](tasks.md#writing-tasks) for Markdown identity and readiness.
- [Implementation and native boundaries](architecture.md): state ownership,
  lifetimes, platform interfaces and failure invariants.
- [Input bridge](terminal-input-bridge.md): key routing and the notification pipe.
- [Hosted-app bridge](editor-bridge.md): message transport and Excalidraw persistence.
- [Hosted app actions](hosted-actions.md): instances, task operations and process
  protocol version 3.
- [Launcher native panel](launcher-native-panel.md): Emacs NS compatibility,
  frame guards, geometry and command sessions.
- [Launcher daily-use validation](launcher-daily-use.md): fresh-session setup,
  M-x.app migration/rollback, automated checks and dated manual acceptance.
- [Application launcher integration](launcher-applications.md): launcher.el
  follow-ups, optional smoke test and the removed built-in adapter's evidence.
- [Terminal benchmarks](terminal-benchmark.md): latency/frame timing measurement
  and interpretation, not guaranteed parity with standalone Ghostty.

## Decisions, proposals and research

These records preserve rationale and evidence. Proposals and historical
measurements do not claim every described feature ships today; see the user
guides for current behavior.

### Architectural decisions

1. [One Portal view per buffer](adr/0001-one-portal-view-per-buffer.md)
2. [Shared view/native interface](adr/0002-portal-view-native-seam.md)
3. [Platform interface primitives](adr/0003-platform-interface-primitives.md)

### Design and research records

- [macOS GUI CI services](macos-gui-ci-research.md): provider comparison,
  desktop and Metal requirements, and a proposed Portal acceptance pilot.
- [Initial native-view research](../RESEARCH.md): original feasibility and
  proposed architecture, not current setup instructions.
- [Input design proposal](input-design.md): research on the superseded
  prefix/passthrough model.
- [Toolbar design](toolbar-design.md): implemented controls and later ownership
  updates, with historical alternatives and a dated [mockup](toolbar-mockup.html).
- [Markdown task browser specification](task-browser-spec.md): design contract
  and acceptance criteria; [the task guide](tasks.md) describes shipped usage.
- [Task dependency display research](task-dependency-display-research.md):
  alternatives and source comparisons.
- [Terminal session management research](terminal-session-management-research.md):
  package integration options and the original navigation proposal.
- [Agent discovery research](agent-discovery-research.md): recorded agent
  lifecycles, status-source limitations, fixtures and prototype artifacts.
- [Agent dashboard refresh research](emacs-agent-dashboard-research.md):
  Emacs precedents, refresh policy and measurements.
- [Launcher content sizing research](launcher-content-sizing-research.md):
  content-driven sizing investigation.
- [Bun distribution options](bun-distribution.md): current packaging, size
  measurements and alternatives to revisit.
