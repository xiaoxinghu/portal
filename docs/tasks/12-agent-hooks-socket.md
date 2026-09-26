# 12: Agent hooks report exact state over an Emacs socket

Type: AFK · Status: todo (conditional: task 08 decides whether this is needed)

## What to build

Agent hooks send exact states to Emacs, around Ghostty, as herdr's integrations do ([herdr integrations](https://herdr.dev/docs/integrations/)). Only build this if task 08 finds gaps in the in-band signals. Close only the gaps it lists.

**Swift: `native/Terminal.swift`**
- The terminal's environment (`native/Terminal.swift:26`) gains `PORTAL_TARGET=terminal:N`.
- Terminal open options accept `:environment`, an alist of extra variables that is merged into `envVars`.

**Elisp: `portal-agent.el`**
- On the first terminal open, start a local server with `make-network-process :server t :family 'local` ([manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Network-Processes.html)). Its socket is `portal-agent.sock`, in a directory under `temporary-file-directory` that only the user can access (mode 0700). Pass `PORTAL_AGENT_SOCKET` through `:environment`.
- Each connection sends a single line, `TARGET JSON`. The filter:
  - parses the JSON with `json-parse-string`;
  - finds the buffer in `portal-view-buffers` whose `portal-view-target` matches;
  - applies the mapped transition with `:source hook`;
  - closes the connection.

  Lines for unknown targets, and lines that don't parse, are dropped.
- The hook's `session_id` is stored as `:session` in `portal-agent-state`. The dashboard shows it on hover.

**Hook script: `bin/portal-agent-hook`**
- It exits 0 at once unless both variables are set, so it is harmless outside Portal. Otherwise it removes newlines from stdin (JSON strings cannot contain a raw newline) and sends `$PORTAL_TARGET JSON` with `nc -U -w 1 "$PORTAL_AGENT_SOCKET"`.
- The README gives the Claude Code settings entry. It registers the script with `"async": true` for each event in the mapping below.

**Hook events to transitions.** This is the starting mapping. Use task 08's findings to keep only the events that close a gap.

| Claude Code hook | Transition |
|---|---|
| `UserPromptSubmit` | turn started |
| `PermissionRequest` | blocked, with the tool name as the message |
| `Notification` with `elicitation_dialog` or `agent_needs_input` | blocked |
| `PostToolUse` | turn started (covers the gap after an approval) |
| `Stop` | turn ended |
| `StopFailure` | turn ended, with the error as the message |
| `SessionEnd` | agent gone |

Codex's `notify` only reports `agent-turn-complete` ([openai/codex#19921](https://github.com/openai/codex/issues/19921)), which the in-band OSC 9 already covers. So Codex gets no hook.

## Acceptance criteria

- [ ] Each gap that task 08 listed is closed in the GUI with Claude Code
- [ ] Batch ERT tests connect a client to the server and cover:
  - [ ] a mapped event changing the right buffer's state;
  - [ ] an unknown target being dropped;
  - [ ] bad JSON being dropped;
  - [ ] two connections at once
- [ ] The socket's directory has mode 0700, and the socket is deleted when Emacs exits
- [ ] The script exits 0 without output outside Portal
- [ ] The README documents the hook setup, and the design doc records which gaps this task closed

## Blocked by

- [08: Spike: what coding agents signal inside a Portal terminal](08-agent-signal-spike.md)
- [09: Terminal views report agent signals, and Emacs tracks agent state](09-agent-state-from-terminal-signals.md)
