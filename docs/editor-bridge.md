# The bridge, and Excalidraw drawings over it

The bridge connects a hosted app to its buffer (see [CONTEXT.md](../CONTEXT.md));
only hosted web views have one. Its first client, `portal-excalidraw.el`,
synchronizes a drawing buffer with its Excalidraw page.

## Transport

The C core owns the bridge (`native/Core/web.c`); the platform (WebKit on macOS)
only delivers messages and reports observations. Views opened with `:hosted`
receive a bridge. For other views, `portal--web-send` signals an error, pages
have no `window.portalBridge`, and the core drops all posts; their queue holds
only the core's `download` messages, below.

- **The app's interface.** On every load and reload, before hosted-page scripts
  run, Portal defines `window.portalBridge` in the main frame. Apps post JSON
  objects through `portalBridge.postMessage(object)` and set `portalBridge.receive`
  to an async Emacs-message handler (`host/bridge.d.ts`). Hosted source never
  names WebKit: only bootstrap glue in `native/WebView.swift` connects
  `postMessage` to `window.webkit.messageHandlers.portal`.
- **App to Emacs.** The platform validates posts as JSON objects, passing JSON
  text, `type`, and WebKit-observed sender facts to the core: main-frame status
  and document URL. The core accepts only main-frame messages from the app-host
  URL Emacs last loaded, never trusting page claims. It drops subframe messages,
  other pages' messages and core-reserved types. Accepted messages wait outside
  the notification pipe, so large payloads such as images never cross it. New
  `change` messages replace unreceived ones; all others retain their order.
- **Notification.** The first waiting message sends one `bridge TARGET` record
  through the shared pipe owned by `portal-view.el`
  ([terminal input bridge](terminal-input-bridge.md#the-notification-pipe)).
  No further record goes out until Emacs receives the messages. Delivery preserves
  order with all other records, waiting when the pipe is full.
- **Receiving.** `portal-web.el` handles `bridge` records by calling
  `portal--web-receive TARGET`. The core returns all waiting messages as a JSON
  array, allowing the next message to send a new record. The handler calls the
  buffer's `portal-web-bridge-function` with each message as a plist, in order.
  Running inside the process filter, this function never prompts; it queues
  commands as Emacs input events.
- **Emacs to app.** `(portal-web-send PLIST)` calls `portal--web-send TARGET
  JSON`. The core asks the platform to deliver the object to `portalBridge.receive`
  as data, not script text. Failed delivery, including an unset `receive`, queues
  an `error` message for Emacs unless the page has changed. Each message identifies
  its destination page; late failures from old pages are dropped.

Core-only messages include `page` with each committed hosted page's URL
(including Back/Forward), and `error` for failed loads or a stopped web process.
Local `file:` clicks send `follow` with the URL, after first returning the
keyboard to Emacs, ending any key sequence it is reading, so `escape` precedes
`bridge`.
Every web view, hosted or not, queues `download` messages: the `state` of a
download (`started`, `finished` or `failed`, with a `message`), its `url` and
the `file` it saves to, empty when the core refused it a file.
`portal-web.el` handles `page` and `follow` for all hosted apps, and `download`
for every web view, tracking the displayed page, visiting linked files and
saying how downloads go, without calling the buffer's bridge function. URLs use messages because long paths would not fit in records.
Asynchronous AppKit/WebKit callbacks never retain an `emacs_env` or call Lisp;
post-close callbacks find no core target and do nothing.

WebKit blocks app-host pages from loading local files and never consults the
navigation delegate. The core's shared links script (`native/Core/scripts/links.js`)
catches these clicks in an isolated content world beyond the page's reach.
The platform consults the core as for any hosted-page navigation: stay on the
app host's origin, open other sites in the default browser, or hand local files
to Emacs.

Hosted pages retain no cookies or storage between sessions and never leave the
app host. Excalidraw's CSP allows local scripts, fonts and embedded images but
blocks external requests. File inputs, including image insertion, use the native
picker; Emacs owns opening and saving drawings.

## Drawing sessions

`portal-excalidraw-mode` calls `(portal-web-open-hosted "/excalidraw/")`:
the view appears immediately and loads when the app host is ready. Like every
Portal view, it stays in its pane, and `RET` or a click in another pane
showing the buffer brings it there. Hiding preserves page state
and undo history; killing the buffer or changing major mode closes the view.

The page reports `ready`, then Emacs sends `load` with the buffer's JSON.
`loaded` sets the normalized baseline. Later `dirty` and `change` messages
update the buffer and its modified flag. Selection, viewport and other state
outside the document do not modify it. Image data is included using
Excalidraw's `serializeAsJSON(..., "local")`.

## Slides

The page has three screens, the editor, Arrange and the console
([slides](excalidraw.md#slides), [presenting](excalidraw.md#presenting)).
Arrange and the console cover the editor, which stays mounted, sized and
`inert` under them, so its scene stays the only copy of the drawing and keeps
its undo history. Emacs sends `mode` with `mode` `draw`, `arrange` or
`present` to switch; the page sends `mode` back whenever its screen changed,
whoever changed it, and `portal-excalidraw.el` keeps that in
`portal-excalidraw--mode` for the mode line. A page that loads, or reloads,
starts in the editor. `snapshot`, `save` and `saved` work on every screen.
The page sends `notice`, with a `message`, for what Emacs should say without
the drawing having failed, such as Present asked of a drawing without slides.
Arrange and the console share the current slide, so each starts where the
other left off.

`host/slides.ts` is the deck, kept apart from the page and React: the frames
in slide order, and slide images kept per frame. A frame's image is made again
only when the frame, an element in it by `frameId`, or an element in no frame
reaching into it changed version, or when the drawing's files or background
changed. Images come from Excalidraw's `exportToSvg` with `exportingFrame`,
when Arrange is entered and 150 ms after each scene change while it is shown.
While Arrange or the console is shown, a capture listener on the window,
registered before the editor mounts, stops every key before the editor's own
listeners.

## Presenting

Entering Present opens the slide window first, with
`window.open("./audience", name)` under a name new to each Present: a page of
the last one can outlive its buffer for a moment, and a reused name would load
the new one there, with no new window. Without a window, Present does not
start, and the page sends a `notice`. The page keeps the window's reference;
the two pages talk directly, and nothing about presenting crosses the bridge
but `mode`:

- `/excalidraw/audience` is the slide window's page, with its own bundle,
  `host/audience.ts`, built beside the editor's and sharing none of it. Its
  policy lets it run only that script and show `blob:` and `data:` images.
- The drawing's page sends it `{type: "show", svg, index, count}`, the current
  slide's SVG, index from 0, when it says `{type: "ready"}`, when the current
  slide changes, and when that slide's image changes. It decodes each slide
  before showing it.
- It sends `{type: "key", key}`, `key` one of `next`, `previous`, `first`,
  `last` and `stop`, for the presenting keys (`host/present.ts`) pressed while
  it has the keyboard; the console moves as for its own keys.

The core lets a hosted app open a window only on its own origin, and that
window has no bridge ([web views](web-views.md#windows-pages-open)). The
drawing's buffer-local `portal-web-window-action` shows it with
`portal-excalidraw--display-slides`: `display-buffer-pop-up-frame` with
`portal-excalidraw-slides-frame-parameters` and the window parameters
`mode-line-format`, `header-line-format` and `tab-line-format` `none`. The
drawing keeps the slide window's buffer and frame. Opening gives the slide view
the keyboard and selects its frame; the display action queues a command
that gives it back to the console, with `select-frame-set-input-focus` and
`portal-view-focus`, once the window is shown. As the page leaves Present,
the drawing drops the windows its page opened whose `portal-web-opened`
events still wait, and closes their views: they belong to a Present that is
over. Closing the drawing's view does the same. While any slide window is open,
`frame-resize-pixelwise` is `t`, and afterwards as it was.

No ending cleans up after itself: killing the slide window's buffer, or the
page's `close()`, leaves its frame, showing another buffer; deleting the frame
leaves the buffer and a live, hidden page, of which the drawing's page sees
only a `blur`. So each ending deletes the frame and kills the buffer that are
left. The page leaving Present, `portal-excalidraw-stop-presenting`, the slide
window's buffer killed (its `kill-buffer-hook`) and its frame deleted
(`delete-frame-functions`) each close the slide window; the last two also send
`mode` `arrange`. Killing the drawing, changing its major mode, reopening and
reverting it close the slide window too.

Arrange's edits need no message of their own. Each is one
`api.updateScene({elements, captureUpdate: CaptureUpdateAction.IMMEDIATELY})`
replacing the frames it changes with `newElementWith(frame, {name})` or
`{customData}`, which keeps the frame's other `customData` keys. That is one
step of the editor's undo history, and the editor reports it as any change, so
`dirty` and `change` carry it to the buffer. `moveSlide` in `host/slides.ts`
says which frames a move renumbers. Arrange hands Command-Z and
Shift-Command-Z to the editor by dispatching a copy of the key on its
container, where Excalidraw's own key handler listens; the capture listener
lets that copy pass. In the notes box or a name field, Arrange runs them as
`document.execCommand("undo")` and `"redo"` instead: WebKit leaves those keys
unhandled in a field, so they would reach Emacs, where the drawing's buffer
has no undo.

## Saving and input

Before saving, Emacs sends `snapshot` with a monotonically increasing request ID.
The page commits any active text editor and returns the latest scene. Only a
matching ID completes the save barrier; errors or timeouts abort writing.
A `write-contents-functions` guard also covers normal `save-buffer` and save-all;
`before-save-hook` cannot, because Emacs may catch its errors and keep writing.
Normal Emacs save machinery writes the file, sending `saved` only from
`after-save-hook`. Failed writes leave the buffer modified.

The page's Save button and Command-S send `save`, queuing an Emacs save for the
drawing buffer. The page still owns the keyboard, so saving first focuses Emacs
for any filename prompt, then refocuses the page. The drawing leaves Control-X
unused, so `C-x C-s` reaches Emacs, runs its normal save command with mode
remapping, and restores focus after saving and any filename prompt.
The configured escape (Command-period by default) leaves Emacs in control;
Escape and drawing-used chords stay
with the page.

The buffer retains the latest synchronized JSON even if WebKit stops.
`portal-excalidraw-reopen` rebuilds from it, never silently overwriting unsaved
work with a saved file. `revert-buffer` reads the file and reopens the view.
Auto-save and backups follow Emacs configuration. Changes synchronize after
150 ms; web-process crashes can lose edits not yet received by Emacs. App-host restarts do not reload
drawings; reopen them if old asset URLs are gone.

## Verification

`./build.sh` compiles the browser assets and fonts into the relocatable host
and builds the native module. `bun run --cwd host typecheck` builds the
Excalidraw assets and checks TypeScript.

`ctest --test-dir build --output-on-failure` runs batch tests. Against the fake
native module, `test/portal-web-tests.el` checks ordered `bridge` delivery to the
buffer's bridge function. `test/portal-excalidraw-tests.el` covers opening the
Excalidraw hosted app, bridge loading, scene persistence, save failures, stale
replies, revert, switching screens, and presenting: the slide window's bare
frame, the keyboard given back, and each way presenting ends.
`host/slides.test.ts` covers slide order and which images a change makes
stale; `host/audience.test.ts` the slide window's page, served offline and
apart from the editor's bundle, and the presenting keys.

`ctest --test-dir build -R web-core` runs `test/portal-web-tests.c`, the core's bridge and
web rules against the fake platform: message order and coalescing, draining
and re-arming, invalid senders and reserved types, ordinary pages, navigation
decisions, a hosted app's windows only on its own origin, handoffs after an
escape, closed views and stale deliveries.

The [standalone AppKit check](testing.md#standalone-appkit-checks) in `test/native-focus.swift`
verifies a real WebKit bridge: ordered main-frame-only messages under one record
until received, operation after reload, failed delivery reaching Emacs, and no
bridge for non-hosted views.

Graphical tests require a disposable graphical Emacs with the
[test event injector](testing.md#input-graphical-checks) loaded.
Load `test/portal-excalidraw-gui-tests.el`; run `M-x ert` with selector
`^portal-excalidraw-gui-`. Coverage includes real WKWebView, paste,
image round trips, several drawings, revert, hidden-state retention, rapid
`C-x C-s` delivery to Emacs, Arrange: slides in order, keys, editing a
slide and saving from it, and presenting: the slide window shows the slide,
next from the console and from the slide window, and stopping, which takes
the slide window and its frame. In the full set, a covered slide window still
draws, and fullscreen fills the display. The test-only JavaScript evaluator is absent from
the production module. That the editor works offline, loading its modules and
fonts only from the app host, is an [app host check](testing.md#app-host-checks).
