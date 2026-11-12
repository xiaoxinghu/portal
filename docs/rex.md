# Connect to a Rex server

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

[Rex](https://www.superlogical.com/rex/docs) is a terminal multiplexer: its
server runs your terminals' programs, so they outlive the applications that
show them. Portal is becoming a client of that server. Today it can connect to
one, give each of its blocks a buffer that follows the server and shows the
block's screen, a terminal you type in, and call its methods and receive its
events from Lisp; see [what is not built](#what-is-not-built).

Rex is optional. Portal's own [terminals](terminals.md) run their shells
themselves and need no Rex installed.

- [Connect and disconnect](#connect-and-disconnect)
- [A buffer for every block](#a-buffer-for-every-block)
- [A block's screen](#a-blocks-screen)
- [Call the server](#call-the-server)
- [Receive events](#receive-events)
- [When a connection is lost](#when-a-connection-is-lost)
- [Ghostty versions](#ghostty-versions)
- [What is not built](#what-is-not-built)

For the words used here, see [the domain vocabulary](../CONTEXT.md#rex); for
where the code sits, [Rex connections](architecture.md#rex-connections).

## Connect and disconnect

`M-x portal-rex-connect` connects to the Rex server on this Mac, through its
Unix socket, `~/Library/Application Support/rex/server.sock`. That is where
Rex's Mac application starts its server; set `portal-rex-socket` if yours
listens elsewhere. With a prefix argument the command reads a socket's path
instead, and from Lisp it takes one:

```elisp
(portal-rex-connect)                        ; this Mac's server
(portal-rex-connect "~/elsewhere/server.sock")
```

It returns the connection once the server has taken it, and says why when it
cannot: no socket at that path, nothing listening on it, a server that is not
Rex's, or one that does not answer within `portal-rex-timeout` seconds
(default 5). Emacs can be connected to several servers at once, each with its
own connection. Connecting again to a server Emacs is connected to returns
the connection it has. `(portal-rex-connections)` lists them.

`M-x portal-rex-disconnect` ends a connection, asking which when there are
several. Disconnecting, like quitting Emacs, kills the buffers of that
server's blocks and ends nothing on the server: its sessions and blocks
carry on.

Portal speaks one revision of Rex's API, 12, and tells the server so. A newer
server translates to and from it, so updating Rex needs no change in Portal.
`(portal-rex-connection-welcome CONNECTION)` holds the server's welcome.

## A buffer for every block

While Emacs is connected to a server, each block on it has exactly one
buffer, and each such buffer has one block. Connecting makes them, for the
blocks of every session, detached blocks and those made by other clients
included. Portal keeps no list of its own: `C-x b` and Ibuffer are the list.

A buffer is named `*rex: SESSION/BLOCK*` from the two labels, such as
`*rex: work/api*`. Two blocks with the same labels are told apart as Emacs
tells any two buffers apart, `*rex: work/shell*` and `*rex: work/shell*<2>`.

The buffers follow the server, with Emacs idle:

| On the server | In Emacs |
| --- | --- |
| A block is made, in Rex's app, by `rex run` or by any other client | It gets a buffer. |
| A block closes, or its program ends | Its buffer is killed. |
| A session is destroyed | Its blocks' buffers are killed. |
| A block or a session is relabelled | The buffers it names are renamed. |
| Emacs disconnects, or the connection is lost | That server's buffers are killed. |

These kills never ask, and none of them ends anything on the server.

A buffer is in `portal-terminal-mode`, the mode of Portal's
[terminals](terminals.md). Until a window shows it, it has no terminal view
and its text says which block it is; once one does, it shows
[the block's screen](#a-blocks-screen).

Killing one of these buffers yourself kills only the buffer, and Emacs says
so, without asking first, whatever `portal-terminal-confirm-kill` says: the
block still runs, and gets no other buffer until Emacs next connects to its
server. Ending a block from Emacs is [not built](#what-is-not-built).

Two things to know about names:

- The server does not say when a detached block is relabelled. Its buffer
  takes the new name at the next change to its session that the server
  does report, such as a block made or a window changed.
- A name you give one of these buffers lasts until its block or session is
  next relabelled.

### What a buffer knows

Each buffer holds three buffer-local variables, which no change of major
mode clears:

| Variable | Holds |
| --- | --- |
| `portal-rex-block-connection` | The connection to the block's server. It is nil in every other buffer. |
| `portal-rex-block-id` | The block's ID, such as `"block:01a1…"`, which never changes and is never reused. |
| `portal-rex-session-id` | The ID of the block's session. A block stays in one session for its whole life. |

A session is an attribute of a buffer, as a directory is: it has no buffer of
its own, and every grouping is yours to build from these.
`(portal-rex-session-label BUFFER)` returns what the buffer's session is
called now, or nil for a buffer that is no block's.
`(portal-rex-buffers CONNECTION SESSION-ID)` returns the buffers of a
session's blocks, of a whole server's without the session, and of every
connected server's without either.
`(portal-rex-block-buffer CONNECTION BLOCK-ID)` returns one block's buffer.

`(portal-rex-connection-sessions CONNECTION)` holds the server's sessions as
`session.list` returns them, a vector of plists with `:session_id` and
`:label`, in the server's order. The server's events keep it current. Two
sessions may have the same label.

### Ibuffer

In Ibuffer, `M-x ibuffer-filter-by-portal-rex-session` limits the list to
the blocks of the sessions with one label, completing over the connected
servers' sessions. The filter is `portal-rex-session`, for a saved filter
or a filter group:

```elisp
(setq ibuffer-saved-filter-groups
      '(("default"
         ("work" (portal-rex-session . "work"))
         ("play" (portal-rex-session . "play")))))
```

It goes by what a session is called now, so a renamed session's buffers
move with its label. Portal groups nothing else.

## A block's screen

The first time a window shows a block's buffer, the buffer gets a
terminal view, as one of Portal's [terminals](terminals.md) has, and the
view shows the block's screen: what it shows on the server, with its
history above it. Typing in the view types into the block's program,
which runs on the server, so a shell, vim or an agent behaves as in any
terminal. The view is an ordinary terminal view in every other way: it
stays in its pane, takes the keyboard with RET or a click, follows the
frame's text size and `portal-terminal-theme`, and other panes showing the
buffer show where it is.

From then on the view keeps up with the block while Emacs is connected,
whether a window shows the buffer or not, so a buffer you bury and show
again shows the screen as it is now, at once.

`C-c C-k` closes the view and leaves the block running; the view opens
again, with a fresh screen, the next time a window starts to show the
buffer. Killing the buffer closes it too.

### Size

While Emacs is the only client showing a block, the block takes the size
of the pane that shows it, and resizing the pane reflows the screen as it
does in any terminal. When a block is shown in a pane, Emacs claims it,
taking it from Rex's app or any other client that had it. How Emacs and
Rex's other clients should share a block's size is
[not built](#what-is-not-built): until it is, a block that another client
resizes or takes back is drawn in Emacs at Emacs's size, wrongly, until
the program next draws its whole screen.

### What the first paint loses

The server sends a block's screen as the escape sequences that redraw it:
text, history, colours, styles, hyperlinks and the modes a program set,
such as mouse reporting or the keyboard protocol. Three things do not come
through:

- **The cursor's shape.** A program that set a bar or an underline cursor
  shows a block until it sets it again.
- **The primary screen under an alternate one.** Shown while a full-screen
  program such as vim runs, the screen is vim's; when vim exits, the shell's
  screen and history are blank in Emacs, though not on the server.
- **What a program prints while the view opens.** The screen is taken a
  moment after the block's output starts to arrive, so output in between is
  drawn twice; a program that moves its cursor relative to where it is,
  such as a shell redrawing its prompt, can then draw over a line. Emacs
  waits for the pane's size to settle before it starts, which avoids the
  common case, a program redrawing for a new size.

Each happens only when a view opens on a block, once per block while Emacs
stays connected.

### Typing, focus and queries

Keys, mouse clicks and pastes are encoded by the view as for any terminal,
and typed into the block in order. A click past column 95 in a program
using the oldest mouse protocol (X10, without SGR) reaches the program
wrong, as that protocol writes such a column as a byte the server's API
cannot carry; programs using SGR mouse reporting, as most do, are not
affected.

The server's terminal answers a program's queries, such as which terminal
it is or where the cursor is, so the view answers none of them: a program
gets one answer, the server's. Likewise, whether the view has the keyboard
goes to the server, which reports focus to a program that asked, and the
view's own focus, size and colour-scheme reports are dropped.

### When it goes wrong

A block whose screen cannot be shown, because the server refused part of
it, loses its view, and its buffer says why; showing the buffer again tries
again. A block whose output stops, such as when its server drops the
stream, keeps its last screen, and Emacs says so in the echo area; from
then on nothing typed there reaches the block, so a screen that no longer
changes never runs a command unseen.

## Call the server

`portal-rex-call` calls one of the server's methods and returns its result:

```elisp
(portal-rex-call nil "session.list")
;; ⇒ (:sessions [(:session_id "session:01a1…" :label "work") …])

(portal-rex-call connection "session.set_label"
                 '(:session_id "session:01a1…" :label "api"))
```

Its first argument is a connection, or nil for the only one. The method's
arguments are a plist, or nil for none; [Rex's reference](https://www.superlogical.com/rex/docs/reference/api)
lists every method with what it takes and returns. JSON crosses as
`json-serialize` and `json-parse-string` have it, with objects as plists: an
array is a vector, and null and false are `:null` and `:false`.

The call waits for the answer, at most `portal-rex-timeout` seconds or the
timeout given as its fourth argument, and Emacs does nothing else meanwhile;
`C-g` ends the wait.
A call that fails signals `portal-rex-error`, whose data is a sentence and the
error as a plist:

| `:code` | What happened |
| --- | --- |
| One of the server's, such as `"method_not_found"`, `"bad_request"` or `"conflict"` | The server refused the call. `:message` and `:status` are the server's. |
| `"portal_timeout"` | No answer came in time. |
| `"portal_disconnected"` | The connection ended first, or had ended. |

```elisp
(condition-case failure
    (portal-rex-call nil "no.such_method")
  (portal-rex-error (plist-get (nth 2 failure) :code)))
;; ⇒ "method_not_found"
```

`portal-rex-call-async` takes the same connection, method and arguments, and
a function, and returns at once. The function is called with the result and
nil, or with nil and the error plist. It runs from a process filter, so it
must not prompt.

```elisp
(portal-rex-call-async nil "session.list" nil
                       (lambda (result failure)
                         (message "%S" (or failure (plist-get result :sessions)))))
```

## Receive events

A connection receives the events of the server and of every session on it:
sessions created, renamed and destroyed, blocks created and closed, windows
changing. It asks for them with `session.attach_all` and the scope `session`,
which leaves out what a block reports about its own terminal, such as its
title. [Rex's event reference](https://www.superlogical.com/rex/docs/reference/events)
lists them.

Each event runs `portal-rex-event-functions` with the connection and the
event as the server sent it, parsed like a result:

```elisp
(add-hook 'portal-rex-event-functions
          (lambda (_connection event)
            (message "Rex: %s" (plist-get (plist-get event :payload) :type))))
```

```elisp
(:type "event" :seq 7
 :payload (:type "session_created"
           :payload (:session (:session_id "session:01a1…" :label "work"))))
```

An event of one session comes wrapped once more, as a `session_event` whose
payload has the `:session_id` and the `:event`. Events of one connection
arrive in order, with `:seq` rising by one, and every function on the hook
sees one event before any sees the next. The functions run from a process
filter, or inside a `portal-rex-call` that was waiting when the event came,
in both cases with quitting inhibited, so they must not prompt. A function
may call `portal-rex-call` itself: it gets its answer, and the events that
arrive while it waits run after it returns; `C-g` cannot cut that wait
short, so give it a short timeout.

Portal has followed an event before the hook runs for it: the connection's
sessions have the change, and a closed block's buffer is gone. A new block's
buffer comes a moment later, as its event carries only the block's ID and
Portal asks the server for the label. The first event the hook sees is the
first change after the sessions the connection started with.

## When a connection is lost

When a server goes away or closes the connection, Emacs says so once in the
echo area, such as "Lost the Rex server at ~/Library/Application
Support/rex/server.sock: The server closed the connection". Its blocks'
buffers are killed, calls still waiting fail with `"portal_disconnected"`,
and the connection takes no more. Nothing reconnects by itself: run
`portal-rex-connect` again, which makes the buffers again.

## Ghostty versions

A Rex server runs each block's program in a terminal of its own Ghostty.
Portal is to draw a block's screen by feeding the same output to its own
Ghostty, the one in the [libghostty-spm](terminals.md#native-ghostty-terminal)
release Portal pins. The two are seldom the same Ghostty, and nothing checks
them: Portal connects to any server whose API it speaks, whatever its Ghostty.

While they agree on every sequence a program sends, the screens match. When
the server's Ghostty knows a sequence Portal's does not, the screens differ,
silently, until the program draws that part again: a program that inserted a
column with DECIC, say, leaves `ab  cdefgh` on the server and `abcdefgh` in
Emacs. Portal's Ghostty is usually the older, as Rex updates itself and Portal
moves only when its pin does.

To see how far apart they are, run the report from a checkout of Portal:

```sh
tools/ghostty-version.py
```

It prints Portal's Ghostty, that of the newest libghostty-spm release and that
of the Rex server installed on this Mac, how many of the server's commits each
lacks, and whether a newer release would help. It is the only check there is;
[Contributing](../CONTRIBUTING.md#the-ghostty-dependency) says how to bump the
pin when it would.

## What is not built

Portal's Rex client is being built in steps. Not built yet:

- Commands for sessions and for new terminals.
- Titles, directories and programs of Rex terminals, from the server.
- Ending a block by killing its buffer.
- Sharing a block's size with Rex's other clients: see [Size](#size).
- Reconnecting, and resuming a block's output after a dropped connection.
- Restoring the arrangement of Rex terminals with bookmarks or the desktop.
- Servers on other machines.
