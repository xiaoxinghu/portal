# 11: Agents that need you raise alerts when the dashboard is closed

Type: AFK · Status: todo

## What to build

You hear about blocked and done agents without keeping the dashboard open, the way Emacs usually tells you things: through the mode line and the echo area. There is also a hook for anything louder.

**Elisp: `portal-agent.el`**
- **Indicator.** The mode line construct `portal-agent-mode-line` is added to `global-mode-string` ([manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Mode-Line-Variables.html)) while any agent is blocked or done.
  - It shows counts, for example `⚑1 ✓2`, and is empty otherwise.
  - Clicking it runs `portal-agents`.
  - It is added and removed from `portal-agent-state-change-functions`, so nothing stays in the mode line while no agents exist.
- **Alert hook.** `portal-agent-alert-functions` is an abnormal hook that runs with `BUFFER STATE MESSAGE` when a buffer's state becomes `blocked` or `done`. It does not run when the agent's buffer is shown in the selected frame. It also does not run for `done` while the dashboard is shown in the selected frame, because the dashboard already makes that visible.
- **Default alert.** `portal-agent-alert-message` is the default member of the hook. It shows `BUFFER is blocked: MESSAGE` or `BUFFER is done` in the echo area. It uses `message` and never prompts, because it runs inside the process filter.
- **User option.** `portal-agent-indicator` (boolean, default t) turns the indicator off.
- **README example.** A two-line function added to `portal-agent-alert-functions` that sends a macOS notification with `osascript`. `notifications-notify` needs D-Bus, so the macOS build of Emacs can't use it ([manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Desktop-Notifications.html)).

## Acceptance criteria

- [ ] While you work in another buffer, a Claude Code turn that ends shows `✓1` in the mode line and a message in the echo area. Showing that buffer clears both.
- [ ] A permission prompt in a hidden terminal shows `⚑1` and the prompt's text
- [ ] Nothing alerts for an agent whose buffer is in the selected window
- [ ] Batch ERT tests cover:
  - [ ] the indicator's text for each mix of states, and its removal when the last agent goes;
  - [ ] which transitions run the alert hook, and which don't because the buffer or the dashboard is visible
- [ ] The README documents the indicator, the hook and the `osascript` example

## Blocked by

- [09: Terminal views report agent signals, and Emacs tracks agent state](09-agent-state-from-terminal-signals.md)
