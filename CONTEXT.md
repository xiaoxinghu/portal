# Portal

Portal shows native macOS views inside Emacs panes, so an Emacs buffer can present a web page or a terminal as if it were ordinary buffer content.

## Views

**Portal view**:
A native view that an Emacs buffer presents in a pane. A buffer has at most one Portal view, which stays in the pane it is in while that pane shows the buffer, in any frame; it moves when that pane goes, when the buffer is switched into the selected pane, or when RET or a click in another pane showing the buffer takes it there. Those other panes show a **placard**, the buffer's text saying where the view is. The view lives as long as its buffer and is hidden, not ended, while the buffer is not shown.
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

## Rex

Rex is a terminal multiplexer: a server that runs terminals' programs so they outlive the applications that show them. Portal is becoming one of its clients; [the Rex guide](docs/rex.md) says how far that has got. Portal's own terminal views need no Rex.

**Rex server**:
The program that runs blocks' programs and keeps their screens, on this Mac or another machine. It, not Portal, owns sessions and blocks: Emacs asks it to change them and hears from it when anything does.
_Avoid_: Rex (for the server alone), daemon, backend, host (unqualified)

**Connection**:
Emacs's link to one Rex server, from `portal-rex-connect` until it is disconnected or lost. Calls go out on it and the server's events come in on it, in order. Emacs can hold several at once, one per server; ending one ends nothing on the server.
_Avoid_: session (a Rex term for something else), client, socket (the platform's primitive that carries it)

**Session**:
A named group of blocks on a Rex server, with an ID and a label, which another session may share. It exists on the server whether or not Emacs is connected, and may be empty. In Emacs it is an attribute of its blocks' buffers, as a directory is, never a buffer or a container of its own.
_Avoid_: project, workspace; calling a connection a session. The "terminal session" a terminal view runs, its own shell, is not one.

**Block**:
One program on a Rex server with its screen, such as a shell: what one terminal shows. It belongs to one session for its whole life, and its ID never changes and is never reused. While Emacs is connected to its server it has exactly one buffer, named from its session's label and its own, which comes and goes with the block. Once a window shows that buffer, a terminal view in it shows the block's screen, and keeps it current until the buffer goes, shown or not.
_Avoid_: pane, tab, window (Rex's own layout terms), terminal (the view kind that shows it)

**Fed terminal**:
A terminal view that runs no program of its own: what it shows is the output of a block on a Rex server, fed to it by Portal, and what is typed in it goes to that block.
_Avoid_: remote terminal, Rex view (it is a terminal view like any other)

## System-wide

**Global shortcut**:
A chord, named by a symbol, that calls a Lisp function when pressed in any application, from Emacs's command loop and without activating Emacs. Setting the name again replaces its chord and function; a press from before that, or from before its removal, is ignored. Portal sets none itself; a user's configuration sets one for each launcher command that should open from any application.
_Avoid_: hotkey (the platform's primitive that registers a chord), launcher shortcut

**Status panel**:
The one small panel, floating above every application, that shows a line of text set from Lisp, such as what a command running from a global shortcut is doing. It never takes the keyboard or the mouse.
_Avoid_: HUD, toast, notification, overlay

## Web content

**Page**:
One document a web view shows, from the commit that loads it to the next; a reload makes a new page with the same URL. Its selection, find highlights, scroll position and typing belong to it, and moving the keyboard or the view never changes them.
_Avoid_: tab, URL (as identity)

**Hosted app**:
Web content served by Portal's app host, such as Hello, the Markdown preview, or Excalidraw.
_Avoid_: hosted page, editor, UI

**App host**:
Portal's own local server for hosted apps.
_Avoid_: UI host, Bun host, server, host (unqualified)

**Bridge**:
The message channel between a hosted app and the buffer that presents it. Only hosted apps get a bridge; other web content never does. The core's own messages to any web buffer, such as how a download went, wait in the same queue, but no page can post them.
_Avoid_: editor channel, event pipe
