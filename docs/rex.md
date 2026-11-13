# Connect to a Rex server

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

[Rex](https://www.superlogical.com/rex/docs) is a terminal multiplexer: its
server runs your terminals' programs, so they outlive the applications that
show them. Portal is becoming a client of that server. Today it can connect to
one, give each of its blocks a buffer that follows the server and shows the
block's screen, a terminal you type in with its title, directory and
program, make, rename and destroy sessions, start new terminals in them, end
a block by killing its buffer, and call its methods and receive its events
from Lisp; see
[what is not built](#what-is-not-built).

Rex is optional. Portal's own [terminals](terminals.md) run their shells
themselves and need no Rex installed.

- [Connect and disconnect](#connect-and-disconnect)
- [A buffer for every block](#a-buffer-for-every-block)
- [A block's screen](#a-blocks-screen)
- [Sessions and new terminals](#sessions-and-new-terminals)
- [End a block](#end-a-block)
- [A block's details](#a-blocks-details)
- [Portal's terminal commands](#portals-terminal-commands)
- [Appearance](#appearance)
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

Killing one of these buffers yourself ends its block, asking first while
the block may be busy: see [End a block](#end-a-block). To put a terminal
out of the way and keep it running, bury its buffer instead.

Two things to know about names:

- The server does not say when a detached block is relabelled. Its buffer
  takes the new name at the next change to its session that the server
  does report, such as a block made or a window changed.
- A name you give one of these buffers with `rename-buffer` lasts until its
  block or session is next relabelled; `portal-terminal-rename` relabels the
  block instead, as [below](#sessions-and-new-terminals).

### What a buffer knows

Each buffer holds three buffer-local variables, which no change of major
mode clears:

| Variable | Holds |
| --- | --- |
| `portal-rex-block-connection` | The connection to the block's server. It is nil in every other buffer. |
| `portal-rex-block-id` | The block's ID, such as `"block:01a1…"`, which never changes and is never reused. |
| `portal-rex-session-id` | The ID of the block's session. A block stays in one session for its whole life. |
| `portal-rex-block-directory` | The block's directory on its server's machine, as [its details](#a-blocks-details) give it, or nil until a window has shown the buffer. |

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
frame's text size and [`portal-terminal-theme`](#appearance), and other
panes showing the buffer show where it is.

From then on the view keeps up with the block while Emacs is connected,
whether a window shows the buffer or not, so a buffer you bury and show
again shows the screen as it is now, at once.

`C-c C-k` closes the view and leaves the block running; the view opens
again, with a fresh screen, the next time a window starts to show the
buffer. Killing the buffer closes it too.

### Size

A block has one size, that of the Rex client last used with it, and the
other clients draw it at that size as well as they can. Emacs uses a block
when you select the pane that shows it, come back to Emacs with that pane
selected, or type into it, and the block then takes the pane's size;
leaving the pane, burying the buffer or switching to another app gives
nothing up, so the block keeps Emacs's size until another client is used.
A block another client sizes is drawn at that size from the pane's
bottom-left corner, never scaled: clipped at the top and the right where it
is larger than the pane, with the terminal's background above it and to
its right where it is smaller, so a shell's prompt stays in view.

While another client sizes a block, its buffer's mode line says so after
the mode's name: `:sized by Rex.app`, by the name that client gives
itself, or `:sized elsewhere` when the server cannot say, as for a client
that has gone. The mouse over the mark shows the size. Selecting the pane
takes the block back, and the mark goes.

A pane that shows a block without being in use only asks for it: the
block is Emacs's if no other client has it, and stays another's
otherwise. So blocks in several panes keep Rex's app's sizes while you
work there, and a narrower or wider pane is drawn without resizing
anything. Emacs still sends the server each new size of the pane, which
the server keeps and applies the moment Emacs takes the block. Hiding a
block's view, or burying its buffer, never gives the block up: the server
passes a block whose client goes away to the client that claimed it last.

### What the first paint loses

The server sends a block's screen as the escape sequences that redraw it:
text, history, colours, styles, hyperlinks and the modes a program set,
such as mouse reporting or the keyboard protocol. Lines the terminal
wrapped come as the program wrote them, so they wrap again at the next
size as they do on the server. Portal leaves out the
server's palette, as [Appearance](#appearance) says. Three more things do
not come through:

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

## Sessions and new terminals

Portal gives the commands, and decides nothing about what a session is for:
one user option says which session a new terminal joins, and your
configuration can map sessions to projects, or to anything else.

| Command | Does |
| --- | --- |
| `portal-rex-new-terminal` | Starts a shell in a new terminal, in the directory of the current buffer, and shows its buffer in the selected window. The session is the one `portal-rex-session-function` returns. |
| `portal-rex-session-create` | Makes an empty session, reading its label; an empty label lets the server choose one, such as `quiet-meadow`. |
| `portal-rex-session-rename` | Gives a session a new label; its buffers are renamed. |
| `portal-rex-session-destroy` | Destroys a session, after asking, with how many blocks will end. Every program in it ends, as when a terminal window closes, and its buffers are killed. |
| `portal-rex-block-rename` | Gives the current buffer's block a new label. `portal-terminal-rename` does the same in a block's buffer. |

A command works on the server of the current buffer's block, or on the only
server Emacs is connected to, and asks which when there are several. The
session commands read the session, the current buffer's being the default.
Each command returns once the server has made the change and Emacs has
followed it: a new session is among the connection's sessions, a new
terminal has its buffer, a renamed block's buffer has its new name.

A new terminal gets a window of its own in its session, a tab in Rex's app,
without becoming the session's active one, so starting terminals from Emacs
does not change the tab another client is looking at. Its buffer comes as
any new block's does, and its `default-directory` is the directory it
started in. When the server refuses, such as when the session has as many
windows as it allows, the command says so in the server's words, and nothing
is made.

A block's label is its buffer's name: renaming a block's buffer with
`portal-terminal-rename` relabels the block, on the server, and the buffer
takes the name `*rex: SESSION/LABEL*`. A name given with `rename-buffer`
instead lasts only until a label next changes. An empty label gives a block
a default made from its ID, and a session back the label the server chose
when it made it.

From Lisp, the commands take the connection, nil for the only one, and the
session's ID, and return what they made:

```elisp
(let ((session (portal-rex-session-create nil "work")))
  (portal-rex-new-terminal nil session "~/src/api/")    ; ⇒ its buffer
  (portal-rex-session-rename nil session "api")
  (portal-rex-session-destroy nil session))              ; asks nothing
```

`(portal-rex-find-session CONNECTION LABEL)` returns the ID of the first
session with that label, or nil. Two sessions may share a label.

### Which session a new terminal joins

`portal-rex-session-function` holds a function that is called with the
connection, in the buffer the command started from, and returns the ID of
the session for the new terminal. It may make the session, and may ask.

The default, `portal-rex-session-default`, takes the current buffer's
session when that buffer is a block's, so a terminal started from a terminal
joins its session. Elsewhere it asks, completing over the server's sessions;
a name that no session has makes a session with it. A label that several
sessions share is offered once for each, with its ID.

To give each project a session named after it, made the first time a
terminal starts there, set the option to a function of your own:

<!-- example: rex-project-session -->
```elisp
(defun my-rex-project-session (connection)
  "Return the session named after the current project, making it if missing."
  (if-let* ((project (project-current)))
      (let ((name (project-name project)))
        (or (portal-rex-find-session connection name)
            (portal-rex-session-create connection name)))
    (portal-rex-session-default connection)))

(setq portal-rex-session-function #'my-rex-project-session)
```

A terminal started in a project then joins that project's session, and one
started outside any project asks as the default does. A Rex terminal's
buffer is in the directory it started in, so one started from it joins the
same project's session. Portal's tests run this example as written here.

## End a block

Every block is a buffer, so killing a block's buffer ends the block, with
Rex's `block.close`, as closing its tab in Rex's app would: its program
ends, and its tab goes from the app. There is no "keep it running" answer.
To put a terminal out of the way without ending it, bury its buffer:
`bury-buffer`, `quit-window`, or switch to another. Its block runs on, and
its buffer is there in `C-x b` and Ibuffer.

A kill must not cost a long-running job by accident, so it asks first when
the block may be busy:

| When it is killed, the block | Killing its buffer |
| --- | --- |
| Is at its shell's prompt | Ends it at once, without a question. |
| Runs a program, an editor, an agent, `ssh` or a pager included | Asks first, naming the program: `Rex block work/api is running sleep; end it?` No keeps the buffer and the block. |
| Cannot be told: no answer within a quarter of a second, an error, a block still starting | Asks first, as for a busy one, saying why. |
| Has a program that has exited | Ends it, without a question. |

Portal keeps no record of which blocks are busy: it asks the server at kill
time, with two calls sent together, and waits a quarter of a second at most,
so a server that has stopped answering costs that and a question, never a
hang. A block is idle when its foreground is its own shell (under `login`,
as every shell block on macOS is, its direct child) and the shell's line
editor is reading. Anything deeper, such as a subshell, a nested shell or
a pager under `git`, is busy, and so is a block started with a command
rather than a shell. Two things read as idle that are not quite: a shell
with jobs in the background or stopped, a `^Z`'d editor among them, which
end with the block without a question; and a program reading through the
shell's line editor, such as zsh's `vared`.

`portal-terminal-confirm-kill`, the option of Portal's own terminals, says
when to ask:

| Value | Asks |
| --- | --- |
| `t`, the default | When the block may be busy, as above. |
| `always` | For every block whose program runs, an idle one too: `End Rex block work/api, zsh at its prompt?` |
| `nil` | Never, and the server is not asked whether it is busy. |

The same rule holds however the buffer is killed: `C-x k`, Ibuffer, Embark,
`portal-terminal-kill-pane`, and `portal-terminal-close` (`C-c C-k`), which
in a block's buffer ends the block. `portal-terminal-close-all` ends every
terminal whose view is open, the blocks shown in Emacs among them, and
leaves blocks never shown alone. Killing several at once, as Ibuffer kills
its marked buffers, ends the idle ones and asks about each busy one by
name.

Nothing else ends a block:

- Quitting Emacs, disconnecting and a lost connection kill the buffers and
  end nothing: connect again, and every block has its buffer again.
- The buffers Portal kills because the server says a block closed or a
  session was destroyed ask nothing and call nothing.
- A server that goes while a kill asks it, or while the question waits for
  you, takes its buffers with it, and the kill ends nothing.
- A kill that runs no question, as when a program binds
  `kill-buffer-query-functions` to nil, cannot know the block is idle, so it
  kills only the buffer and says so; the block gets a buffer again when
  Emacs next connects.

Once the kill goes ahead, the buffer goes at once, and the server is asked
to close the block without Emacs waiting for it. A server that refuses says
why in the echo area, and the block runs on.

## A block's details

A block's buffer knows what its terminal reports, as a local terminal's
buffer does: its title, its directory, the program in its foreground, and
whether that program has exited. `portal-terminal-metadata` returns them,
[choosing a terminal](terminals.md#choosing-terminals) shows them, and the
directory becomes the buffer's `default-directory`, so `C-x C-f`, Dired and
a new terminal start where the block's shell is. They come from the
server, which watches the block's program, not from Emacs:

| Detail | What it is |
| --- | --- |
| `:title` | The title a program set last. |
| `:directory` | The directory the block's program last reported from this Mac, as a shell with Ghostty's integration does at each prompt (OSC 7). Until it reports one, the working directory of the program in the foreground, which follows a plain `cd` too. A directory reported from another machine, such as by a shell reached with ssh inside the block, changes nothing. |
| `:program` | The program in the foreground, named as Rex names one: the script an interpreter runs, else the name it was started under, else its executable's, a login shell's without its leading `-`. So it is `zsh`, `vim` or `/opt/tool/cli.js`, not always a path as for a local terminal. |
| `:exited` | Whether the block's program has ended and the block stayed. |

A block whose program ends usually ends with it: `exit` at its shell
closes the block, and Emacs kills its buffer, with nothing shown on the
way. A block made to stay after its program ends, such as one started with
`rex run --keep-open`, keeps its buffer, and its mode line shows
`:exited` a quarter of a second later, as a local terminal's does.

Until a window first shows a block's buffer, Portal knows none of these:
the buffer is listed by its name and project alone, and its directory is
the one a terminal started from Emacs started in, or unknown, with your
home as its `default-directory`, for a block made elsewhere. Emacs hears of a block's details only
from the sessions it has attached to, which it does as it shows their
blocks; asking every block when Emacs connects would cost three questions
per block for answers that would then go stale. When a window first shows
the buffer, Portal asks the block for each detail once, and follows its
changes from then on, whether a window shows it or not. Closing the view
with `C-c C-k` forgets the title, program and exit until the view opens
again; the directory stays.

`portal-rex-block-directory` holds the block's directory as a path on its
server's machine. Every server Portal connects to is on this Mac, so it is
also the buffer's `default-directory`. Portal never makes a TRAMP
directory of it.

## Portal's terminal commands

A block's buffer is a terminal to Portal's own terminal commands, from the
moment Emacs connects:

| Command | On a block's buffer |
| --- | --- |
| `portal-terminal-choose`, `portal-terminal-select`, the Consult source | Listed with the other terminals, whether shown yet or not, and annotated with its program. Choosing one shows it, which opens its view; so does previewing one in Consult, which claims the block. |
| `portal-terminal-choose-project` | Lists it when it belongs to the project: a block started with `portal-rex-new-terminal` belongs to the project it started in, and one made elsewhere to none, until `portal-terminal-set-project` assigns it. |
| `portal-terminal-next`, `-previous`, `-last`, `-select-index` | Go to it in turn: terminals with views in the order they opened, then the buffers of blocks not yet shown, in the order they were made. |
| `portal-terminal` | Returns to the first terminal, which may be a block's. |
| `portal-terminal-set-project` | Assigns it to a project, or to none. |
| `portal-terminal-rename` | Relabels the block on its server, and the buffer takes its new name, as [above](#sessions-and-new-terminals). |
| `portal-terminal-new`, `-split-below`, `-split-right`, `portal-terminal-start` | Start one of Portal's own terminals, in the block's directory. `portal-rex-new-terminal` starts a block instead. |
| `portal-terminal-focus` (`RET`) | Gives the view the keyboard, opening it first if a window shows the buffer. |
| `portal-terminal-zoom` | Zooms the pane, as for any buffer. |
| `portal-terminal-close` (`C-c C-k`), `portal-terminal-kill-pane`, `kill-buffer` | End the block, which kills the buffer, asking first while it may be busy, as [above](#end-a-block). |
| `portal-terminal-close-all` | Ends every terminal whose view is open, a block shown in Emacs as `portal-terminal-close` does; blocks never shown are left alone. |
| Embark's terminal actions | Select, rename, set the project and kill as above; Dired and copying the directory need the block's directory, known once it has been shown; "another shell" starts one of Portal's own terminals there. |
| `portal-terminal-toggle`, the quick terminal | Never a block's buffer: a project's quick terminal is always one of Portal's own. Toggled from a block's buffer, it goes by the project being edited, as from any other. |

## Appearance

A block's view is drawn with Portal's terminal theme and the frame's text
size, as any terminal view is: `portal-terminal-theme` and
`text-scale-adjust` apply to it, and change it at once.

Portal's theme wins over the server's. The server's first paint carries its
terminal's whole palette, which would give a block Rex's sixteen colours on
Portal's background and text colours, so Portal asks for the paint without
it, and leaves out the default colours the server sends on the stream. What
you see is a block in the same colours as every other terminal in Emacs,
whatever theme Rex's app uses. A palette a program sets while the view is
open still applies; one it set before the view opened is not repainted.

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
title. Once a window has shown one of a session's blocks, Emacs is
attached to that session too, and its blocks' own events, such as
`block_event` with `title_changed`, reach the hook as well.
[Rex's event reference](https://www.superlogical.com/rex/docs/reference/events)
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

- Reconnecting, and resuming a block's output after a dropped connection.
- Restoring the arrangement of Rex terminals with bookmarks or the desktop.
- Servers on other machines.
