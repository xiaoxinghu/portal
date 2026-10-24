# Portal

Portal shows native macOS views inside Emacs panes, so an Emacs buffer can present a web page or a terminal as if it were ordinary buffer content.

## Views

**Portal view**:
A native view that an Emacs buffer presents in a pane. A buffer has at most one Portal view, and it appears in the selected pane that shows the buffer, in any frame; while the minibuffer is selected, that is the pane it returns to. The view lives as long as its buffer and is hidden, not ended, while the buffer is not shown.
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

**Terminal project**:
The project a terminal view's buffer belongs to, by its canonical root: the project it started in, until explicitly reassigned. The shell changing directory never changes it.
_Avoid_: inferring a terminal's project from its current directory or buffer name

**Quick terminal**:
A project's scratch terminal view, summoned into a panel at the bottom of the current frame. Each project has one.
_Avoid_: scratch shell, quick shell

## System-wide

**Global shortcut**:
A chord, named by a symbol, that calls a Lisp function when pressed in any application, from Emacs's command loop and without activating Emacs. Setting the name again replaces its chord and function; a press from before that, or from before its removal, is ignored. Portal sets none itself; a user's configuration sets one for each launcher command that should open from any application.
_Avoid_: hotkey (the platform's primitive that registers a chord), launcher shortcut

**Status panel**:
The one small panel, floating above every application, that shows a line of text set from Lisp, such as what dictation is doing. It never takes the keyboard or the mouse.
_Avoid_: HUD, toast, notification, overlay

## Web content

**Hosted app**:
Web content served by Portal's app host, such as Hello, the Markdown preview, or Excalidraw.
_Avoid_: hosted page, editor, UI

**App host**:
Portal's own local server for hosted apps.
_Avoid_: UI host, Bun host, server, host (unqualified)

**Bridge**:
The message channel between a hosted app and the buffer that presents it. Only hosted apps get a bridge; other web content never does. The core's own messages to any web buffer, such as how a download went, wait in the same queue, but no page can post them.
_Avoid_: editor channel, event pipe
