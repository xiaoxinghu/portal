# Portal

Portal shows native macOS views inside Emacs panes, so an Emacs buffer can present a web page or a terminal as if it were ordinary buffer content.

## Views

**Portal view**:
A native view that an Emacs buffer presents in a pane. A buffer has at most one Portal view, and it appears in the selected pane that shows the buffer, in any frame. The view lives as long as its buffer and is hidden, not ended, while the buffer is not shown.
_Avoid_: native pane, surface (in Elisp), widget

**View kind**:
The native technology that renders a Portal view. There are two: **web** and **terminal**. Every view kind shares the same lifecycle and behaves the same way in panes and frames.
_Avoid_: using a feature name (Excalidraw, Markdown preview, quick terminal) as a view kind

**Web view**:
A Portal view of the web kind. It can show any web content, including a hosted app.
_Avoid_: editor view, preview view, browser

**Terminal view**:
A Portal view of the terminal kind. It runs a terminal session.
_Avoid_: shell view

**Quick terminal**:
A project's scratch terminal view, summoned into a panel at the bottom of the current frame. Each project has one.
_Avoid_: scratch shell, quick shell

## Web content

**Hosted app**:
Web content served by Portal's app host, such as Hello, the Markdown preview, or Excalidraw.
_Avoid_: hosted page, editor, UI

**App host**:
Portal's own local server for hosted apps.
_Avoid_: UI host, Bun host, server, host (unqualified)

**Bridge**:
The message channel between a hosted app and the buffer that presents it. Only hosted apps get a bridge; other web content never does.
_Avoid_: editor channel, event pipe

## Agents

**Coding agent**:
A program such as Claude Code or Codex that runs in a terminal view and works in turns. A terminal view counts as running one once it sends an agent signal.
_Avoid_: bot, assistant

**Agent signal**:
Something a coding agent reports that changes its agent state. It arrives in-band as a terminal escape sequence, or out of band from an agent hook.

**Agent state**:
Where a coding agent is in its turn: *working*, *blocked* (waiting for a decision from you), *done* (its turn ended while you weren't looking) or *idle* (its turn ended and you have seen it). The agent only reports that a turn ended. Emacs decides between done and idle.
_Avoid_: agent status

**Agent dashboard**:
The Emacs buffer that lists every coding agent and its agent state, updated as they change.
_Avoid_: sidebar
