# Tasks

## Portal view lifecycle redesign

These tasks build the design recorded in [CONTEXT.md](../../CONTEXT.md), [ADR 0001](../adr/0001-one-portal-view-per-buffer.md) and [ADR 0002](../adr/0002-portal-view-native-seam.md). Each task is a thin vertical slice. It goes through Swift, Elisp and tests together, deletes the code it replaces, updates the docs it touches, and leaves Portal working.

| Task | Type | Blocked by |
|---|---|---|
| [01: Spike: a terminal view survives moving between frames and being parked](01-terminal-frame-spike.md) | AFK, escalate on failure | none |
| [02: Terminal views run on the shared Portal view lifecycle](02-terminal-views-shared-lifecycle.md) | AFK | none |
| [03: Portal views follow their buffer into any frame](03-views-follow-buffer-across-frames.md) | AFK | 01, 02 |
| [04: One notification pipe owned by portal-view.el](04-one-notification-pipe.md) | AFK | 02 |
| [05: Web views run on the shared Portal view lifecycle](05-web-views-shared-lifecycle.md) | AFK | 02 |
| [06: Hosted apps open immediately and load when the app host is ready](06-hosted-apps-open-immediately.md) | AFK | 05 |
| [07: Excalidraw talks to its buffer over the bridge](07-excalidraw-over-bridge.md) | AFK | 04, 06 |

Tasks 01 and 02 can start straight away. Once 02 is done, 04 and 05 can run in parallel, and so can 03 if 01 has also passed.

Out of scope: the input handoff redesign, the toolbar redesign, and the routing of hosted-app pages.

## Agent state

These tasks build [the agent state design](../agent-state-design.md): agents running in terminal views report their state to Emacs, which shows a live dashboard and raises alerts. They follow the same slice rules as the tasks above.

| Task | Type | Blocked by |
|---|---|---|
| [08: Spike: what coding agents signal inside a Portal terminal](08-agent-signal-spike.md) | AFK, escalate on failure | none |
| [09: Terminal views report agent signals, and Emacs tracks agent state](09-agent-state-from-terminal-signals.md) | AFK | 04, 08 |
| [10: The agent dashboard lists every agent live](10-agent-dashboard.md) | AFK | 09 |
| [11: Agents that need you raise alerts when the dashboard is closed](11-agent-alerts.md) | AFK | 09 |
| [12: Agent hooks report exact state over an Emacs socket](12-agent-hooks-socket.md) | AFK, conditional on 08 | 08, 09 |

Task 08 can start straight away. Task 09 also waits for 04, which is on the lifecycle track. Once 09 is done, 10 and 11 can run in parallel. Task 12 only happens if 08 finds gaps in the in-band signals.

Out of scope: a native dashboard, detecting agents by process name or by parsing the screen, and macOS notification-centre alerts built into Portal (task 11 leaves a hook for these).
