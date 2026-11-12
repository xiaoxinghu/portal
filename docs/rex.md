# Connect to a Rex server

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

[Rex](https://www.superlogical.com/rex/docs) is a terminal multiplexer: its
server runs your terminals' programs, so they outlive the applications that
show them. Portal is becoming a client of that server. Today it can connect to
one, call its methods and receive its events from Lisp. It shows no Rex
terminal yet; see [what is not built](#what-is-not-built).

Rex is optional. Portal's own [terminals](terminals.md) run their shells
themselves and need no Rex installed.

- [Connect and disconnect](#connect-and-disconnect)
- [Call the server](#call-the-server)
- [Receive events](#receive-events)
- [When a connection is lost](#when-a-connection-is-lost)
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
several. Disconnecting, like quitting Emacs, ends nothing on the server: its
sessions and blocks carry on.

Portal speaks one revision of Rex's API, 12, and tells the server so. A newer
server translates to and from it, so updating Rex needs no change in Portal.
`(portal-rex-connection-welcome CONNECTION)` holds the server's welcome.

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

`(portal-rex-connection-sessions CONNECTION)` holds the sessions the server
had when the connection started receiving events, as `session.list` returns
them. The first event the hook sees is the first change after that list.
Nothing keeps the list current yet.

## When a connection is lost

When a server goes away or closes the connection, Emacs says so once in the
echo area, such as "Lost the Rex server at ~/Library/Application
Support/rex/server.sock: The server closed the connection". Calls still
waiting fail with `"portal_disconnected"`, and the connection takes no more.
Nothing reconnects by itself: run `portal-rex-connect` again.

## What is not built

Portal's Rex client is being built in steps. Not built yet:

- A buffer for each block, following blocks and sessions as they come and go.
- A block's screen in its buffer, and typing into it.
- Commands for sessions and for new terminals.
- Titles, directories and programs of Rex terminals.
- Ending a block by killing its buffer.
- Sharing a block's size with Rex's other clients.
- Reconnecting, and resuming a block's output after a dropped connection.
- Restoring the arrangement of Rex terminals with bookmarks or the desktop.
- Servers on other machines.
