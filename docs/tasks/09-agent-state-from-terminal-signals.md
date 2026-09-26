# 09: Terminal views report agent signals, and Emacs tracks agent state

Type: AFK · Status: todo

## What to build

In-band agent signals reach Emacs over the notification pipe. Each terminal buffer that runs an agent carries an agent state (see [the agent state design](../agent-state-design.md#decisions)). This task has no UI. Tasks 10 and 11 build on the state change hook it adds.

**Swift: `native/Terminal.swift`**
- `HostedTerminal` adopts these delegates:
  - `TerminalSurfaceProgressReportDelegate`
  - `TerminalSurfaceDesktopNotificationDelegate`
  - `TerminalSurfaceBellDelegate`
  - `TerminalSurfaceCommandFinishedDelegate`

  Each callback adds an event to the session's queue. The queue holds at most 64 events and drops the oldest when full.
- When the queue goes from empty to non-empty, the session writes `agent TARGET\n` on the shared channel from task 04. If the write fails, it is retried the next time an event is queued.
- A new export, `portal--terminal-events TARGET`, returns the queued events as a list of plists, oldest first, and empties the queue:
  - `(:type progress :state indeterminate :percent nil)`, where `:state` is one of `remove`, `set`, `error`, `indeterminate` or `pause`;
  - `(:type notification :title "…" :body "…")`;
  - `(:type bell)`;
  - `(:type command-finished :exit 0)`.

  It returns nil for an unknown target.
- `terminalDidClose` adds `(:type closed)`, so the agent's row goes away when the shell ends.

**Elisp: new `portal-agent.el`**
- Registers a handler for `agent` in `portal-view-record-handlers`. The handler drains `portal--terminal-events` for the buffer and applies each event.
- Keeps the buffer-local `portal-agent-state`, a plist:
  - `:state`: `working`, `blocked`, `done` or `idle`;
  - `:message`: the last notification body;
  - `:since`: the time of the last transition;
  - `:source`: `terminal` for in-band signals, or `hook` from task 12.

  The buffer-local value is nil until the first agent signal.
- Provides `portal-agent-buffers`, which returns the live buffers whose state is non-nil.
- Runs the abnormal hook `portal-agent-state-change-functions` with `BUFFER OLD NEW` after each change. OLD and NEW are state symbols, or nil.
- Decides between done and idle. *turn ended* becomes `done` unless the buffer is shown in the selected window of a focused frame. A `done` buffer becomes `idle` when it is selected. The global window hooks are installed only while at least one agent buffer exists.
- Applying the same transition twice changes nothing, and runs no hook.

**Signals to transitions.** This is the starting mapping. Task 08 updates it from what it observed.

| Event | Transition |
|---|---|
| `progress` with `set`, `indeterminate` or `pause` | turn started (→ working) |
| `progress` with `remove` or `error` | turn ended (→ done or idle) |
| `notification` while working | blocked, with the body as the message |
| `notification` otherwise | turn ended, with the body as the message |
| `bell` | ignored unless task 08 shows an agent relies on it |
| `command-finished`, `closed` | agent gone (state becomes nil) |

**Agent setup**
- Document in the README what Codex needs: `tui.notifications = true`. Also document anything task 08 found Claude Code needs.

**Tests**
- The fake native adapter from task 02 implements `portal--terminal-events` with a queue that each test fills.
- Batch ERT tests cover:
  - every row of the mapping table;
  - done vs idle depending on whether the buffer is shown in the selected window;
  - a done buffer becoming idle when it is selected;
  - several events drained by one record;
  - a record whose queue is already empty, which does nothing;
  - the hook running once for each real change and not at all for a repeat;
  - killing the buffer, which removes it from `portal-agent-buffers`.

## Acceptance criteria

- [ ] In a GUI session, running Claude Code in a Portal terminal through task 08's scenarios 1, 2 and 7 moves `portal-agent-state` through working, then done or idle, then nil, as the mapping says
- [ ] Desktop notifications from agents are no longer silently dropped: they either reach `portal-agent.el` or are logged as unmapped
- [ ] The batch tests above pass under CTest
- [ ] ADR 0002's list of exports includes `portal--terminal-events`
- [ ] The README describes agent state and the setup each agent needs

## Blocked by

- [04: One notification pipe owned by portal-view.el](04-one-notification-pipe.md)
- [08: Spike: what coding agents signal inside a Portal terminal](08-agent-signal-spike.md)
