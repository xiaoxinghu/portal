# 10: The agent dashboard lists every agent live

Type: AFK · Status: todo

## What to build

`M-x portal-agents` shows the `*Portal Agents*` buffer: one row for each buffer in `portal-agent-buffers`, updated as agent state changes.

**Elisp: `portal-agent.el`**
- `portal-agents-mode` derives from `tabulated-list-mode` ([manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Tabulated-List-Mode.html)). Its columns are:
  - **State**, with a face for each state;
  - **Buffer**;
  - **Title**, the terminal title from `portal--inspect`;
  - **Directory**;
  - **Since**, the time of the last transition as `HH:MM`. It is an absolute time, so no timer has to keep it up to date;
  - **Message**.
- Rows sort by state (blocked, done, working, idle), then by oldest `:since`.
- Keys:
  - `RET` shows the agent's buffer with `pop-to-buffer`. Selecting it turns a done agent idle (task 09).
  - `g` redraws.
  - `q` runs `quit-window`.
- While a dashboard buffer exists, it listens to `portal-agent-state-change-functions` and schedules one redraw 0.1 s later, however many changes arrive in that time. The redraw keeps point on the same row. Killing the dashboard removes the hook.
- With no agents, the dashboard shows one line explaining how agents appear.

**Tests**
- Batch ERT tests use `portal-agent.el` state set directly or through the fake adapter. They cover:
  - which rows appear and in what order;
  - a burst of changes leading to a single redraw;
  - `RET` visiting the right buffer;
  - point staying on its row after a redraw;
  - a killed agent buffer's row going away.

## Acceptance criteria

- [ ] With three Claude Code terminals running, the dashboard shows each state change within half a second, without `g`
- [ ] `RET` on a done row shows that buffer, and the row turns idle
- [ ] The batch tests above pass under CTest
- [ ] The README documents `portal-agents`

## Blocked by

- [09: Terminal views report agent signals, and Emacs tracks agent state](09-agent-state-from-terminal-signals.md)
