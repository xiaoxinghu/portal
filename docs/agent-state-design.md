# Agent state in Emacs

Coding agents such as Claude Code and Codex run inside Portal terminal views. This design shows each agent's state in Emacs as it changes: a live dashboard, plus Emacs-style alerts when the dashboard is closed. It works the way [herdr](https://herdr.dev/) does, but inside Emacs. The tasks are [08 to 12](tasks/README.md#agent-state).

## Decisions

- **Emacs owns agent state, the dashboard and alerts.** The native module only passes on what the terminal reports. There is no native dashboard and no multiplexer inside the terminal view. The Emacs path works, and a native one would go against ADR 0001 (one view per buffer) and Portal's premise that Emacs owns layout.
- **Agent states.** There are four, following herdr:
  - *working*: the agent is on a turn;
  - *blocked*: it waits for a decision, such as a permission prompt or a question;
  - *done*: its turn ended while you weren't looking;
  - *idle*: its turn ended and you have seen it.

  The agent only reports that a turn ended. Emacs decides between done and idle, because only Emacs knows whether the buffer is on screen. A turn that ends while the buffer isn't shown in the selected window of a focused frame is *done*. Selecting the buffer turns it *idle*.
- **A terminal becomes an agent when it sends an agent signal.** Portal doesn't look at process names or parse the screen.
- **Signals are transitions, and repeats are harmless.** Every source maps its signals onto the same few transitions: *turn started*, *blocked*, *turn ended*, *agent gone*. Applying a transition twice changes nothing. So when two sources report the same event, there are no precedence rules.
- **Signals reach Emacs in two ways:**
  1. **In-band, through Ghostty (task 09).** The agent writes escape sequences to its terminal. Ghostty parses them, and libghostty-spm calls a delegate on the `HostedTerminal`. Swift queues an event in the session and writes a short `agent TARGET` record on the notification pipe from task 04. The Emacs handler drains the queue with `portal--terminal-events TARGET`. The pipe carries notifications and the queue carries the payload, as `native/NativeEventChannel.swift` already requires. Payloads such as notification bodies can be longer than `PIPE_BUF`, which is 512 bytes on macOS. Draining also coalesces records, and it recovers from a record dropped when the pipe was full.
  2. **Out of band, through agent hooks (task 12, only if needed).** Each terminal's environment carries `PORTAL_TARGET` and `PORTAL_AGENT_SOCKET`, the same pattern as herdr's `HERDR_PANE_ID` and `HERDR_SOCKET_PATH`. A hook script sends the hook's JSON to a local socket that Emacs listens on.
- **In-band first.** It needs no agent configuration: Claude Code already sends Ghostty desktop notifications and progress reports. It also works for any agent that emits the standard sequences. Hooks are added only if the spike in task 08 shows in-band signals can't tell *blocked* apart, or that they leave gaps.

## Signal sources

| Source | Signals | Agents | Setup |
|---|---|---|---|
| OSC 9;4 progress report | `3` (indeterminate) when a turn starts, `0` (remove) when it ends | Claude Code (`terminalProgressBarEnabled`) | None, if it is on by default (task 08 checks) |
| OSC 9 / OSC 777 desktop notification | Turn complete, needs permission, needs input | Claude Code (by default in Ghostty); Codex (`tui.notifications`) | None for Claude Code; one line of Codex config |
| BEL | Attention | Codex's fallback, Claude Code's `terminal_bell` | None |
| OSC 133 command finished | The agent process exited | Any, if Ghostty shell integration runs in the embedded surface | None |
| Claude Code hooks | `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Notification`, `Stop`, `StopFailure`, `SessionStart`, `SessionEnd`, with `session_id` and `cwd` | Claude Code | A settings entry, or later a plugin |
| Codex `notify` | `agent-turn-complete` only | Codex | One line of config |

What exists in Portal today:
- libghostty-spm already routes every in-band signal to a delegate protocol:
  - `build/swift/checkouts/libghostty-spm/Sources/GhosttyTerminal/Surface/TerminalSurfaceViewDelegate.swift`: bell at line 36, progress at 133, command finished at 140, desktop notification at 147, pwd at 208;
  - the routing is in `…/InMemory/TerminalCallbackBridge.swift`, lines 50-104 and 144.
- `HostedTerminal` (`native/Terminal.swift:7`) implements none of these. Notifications from agents in Portal are dropped today.
- Terminal environment variables are set at `native/Terminal.swift:26`.

## Rejected options

- **A native dashboard: a sidebar and multiplexer inside the terminal view.** It would need several sessions per view, and it would rebuild list UI and notifications that Emacs already has. It is only worth doing if Emacs could not receive the signals, and it can.
- **Parsing the screen, as herdr does without integrations.** herdr maintains detection rules for 22 agents, which break when an agent's UI changes. In Portal, reading text means `select_all` on every poll (`Terminals.text`).
- **Hooks that write custom OSC sequences to `/dev/tty`.** Ghostty drops unknown OSC codes before they reach the embedder, and reusing OSC 777 for a private payload is a hack.
- **Hooks that call `emacsclient --eval`.** This depends on the user's `server-start`, and it means quoting JSON into a Lisp string on every event. A socket that Portal owns needs neither.
- **Claude Code `http` hooks.** They only work for Claude Code, and Emacs would need an HTTP parser.

## Open questions for task 08

- Does Claude Code treat a Portal terminal as Ghostty? Ghostty's core should set `TERM_PROGRAM=ghostty`, but Portal also sets `INSIDE_EMACS=portal-ghostty`.
- Claude Code only notifies when "you appear to be away". Does a Portal terminal report focus out (DEC mode 1004) when its buffer is hidden, when Emacs selects another window, or when Emacs loses focus?
- Does the progress report stay indeterminate while Claude waits for permission? If it does, in-band signals cannot tell *blocked* from *working* without parsing the notification body.
- After a permission is approved, which signal first shows the turn is working again? No hook fires until `PostToolUse`.
- Does command finished fire in the embedded surface when the agent exits?

## References

**herdr**
- [herdr](https://herdr.dev/) · [repository](https://github.com/ogulcancelik/herdr)
- [Integrations](https://herdr.dev/docs/integrations/): the `HERDR_*` environment, `pane report-agent`, and the idle/working/blocked states
- [Socket API](https://herdr.dev/docs/socket-api/): newline-delimited JSON, `events.subscribe`, `pane.agent_status_changed`

**Claude Code**
- [Hooks reference](https://code.claude.com/docs/en/hooks): events, `Notification` matchers, `async` hooks, common input fields
- [Terminal configuration: notifications](https://code.claude.com/docs/en/terminal-config#get-a-terminal-bell-or-notification): desktop notifications by default in Ghostty, Kitty and iTerm2
- Settings reference: [`preferredNotifChannel`](https://code.claude.com/docs/en/settings-reference#preferrednotifchannel) · [`terminalProgressBarEnabled`](https://code.claude.com/docs/en/settings-reference#terminalprogressbarenabled)
- [anthropics/claude-code#57366](https://github.com/anthropics/claude-code/issues/57366): Claude Code's OSC 9;4 behaviour (indeterminate at turn start, removed at turn end)

**Codex**
- [Advanced configuration](https://developers.openai.com/codex/config-advanced): `notify`, and `tui.notifications` with OSC 9 or BEL
- [openai/codex#19921](https://github.com/openai/codex/issues/19921) and [#11808](https://github.com/openai/codex/issues/11808): `notify` only reports turn complete

**Terminal sequences**
- [OSC 9;4 progress sequences](https://learn.microsoft.com/en-us/windows/terminal/tutorials/progress-bar-sequences): states 0 to 4
- [Ghostty configuration reference](https://ghostty.org/docs/config/reference): desktop notifications, shell integration
- [andybarilla/jackdaw#18](https://github.com/andybarilla/jackdaw/issues/18): OSC 9;4 as a status channel shared by several agent harnesses

**Emacs**
- [Network processes](https://www.gnu.org/software/emacs/manual/html_node/elisp/Network-Processes.html): `make-network-process` with `:server t` and `:family 'local`
- [Tabulated List mode](https://www.gnu.org/software/emacs/manual/html_node/elisp/Tabulated-List-Mode.html)
- [Mode line variables](https://www.gnu.org/software/emacs/manual/html_node/elisp/Mode-Line-Variables.html): `global-mode-string`
- [Desktop notifications](https://www.gnu.org/software/emacs/manual/html_node/elisp/Desktop-Notifications.html): `notifications-notify` uses D-Bus, so the macOS build of Emacs can't use it
