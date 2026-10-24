# Implementation and native boundaries

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

Portal's single native module has C Emacs bindings and a C core over a Swift
macOS backend. Navigate by boundaries, not separate feature libraries:

- [`portal-view.el`](../portal-view.el) owns Lisp-side view lifetime, placement and
  notifications; [ADR 0001](adr/0001-one-portal-view-per-buffer.md) and
  [ADR 0002](adr/0002-portal-view-native-seam.md) define one view per buffer and
  the shared lifecycle.
- [`native/Core/include/portal.h`](../native/Core/include/portal.h) is the canonical
  platform interface for ownership, thread rules, primitives and callbacks;
  consult it rather than a copied API inventory.
  [ADR 0003](adr/0003-platform-interface-primitives.md) explains why the core owns
  policy and the platform supplies primitives.
- [`native/Backend.swift`](../native/Backend.swift) implements those primitives;
  [`native/Package.swift`](../native/Package.swift) defines the native library and
  pinned Ghostty dependency.
- The [input bridge](terminal-input-bridge.md), [hosted-app bridge](editor-bridge.md)
  and [launcher panel](launcher-native-panel.md) explain their protocols and platform-specific hazards.

## Shared native host

Each feature exposes its view and keyboard handler through `NativeSurface`.
`NativeHost` knows neither WebKit nor Ghostty: it attaches views to their frames,
remembers the original Emacs responder, and routes keys through one event monitor
to the focused surface or a pending Portal command. Key releases after a focus
change never reach the newly focused feature.

Features own their state and cleanup: closing a web view leaves terminals intact,
and vice versa.

## C bindings and platform interface

The C bindings register every Lisp function, convert arguments and results, and
route lifecycle functions to the core's view registry, input to its handoff,
and terminal and web functions to their respective core rules. The core owns Portal's rules; `portal.h` contains only platform
primitives and callbacks into the core
([ADR 0003](adr/0003-platform-interface-primitives.md)). `native/Backend.swift`
implements the macOS primitives. They use plain C types: borrowed UTF-8 arguments
with explicit lengths, `malloc` results freed by the core, and explicit errors
converted to Lisp `error`. Structured results, such as `portal--inspect`'s state,
cross as JSON parsed by the bindings with `json-parse-string`. The bindings
validate argument strings as UTF-8 because Emacs copies unibyte strings' raw
bytes unchanged.

## Notification pipe

The notification pipe was Portal's first core rule, in `native/Core/channel.c`.
`portal--channel` supplies its descriptor; platform code sends records through
the core's `portal_notify`
([details](terminal-input-bridge.md#the-notification-pipe)). The platform supplies
one primitive: a timer calling back into the core. Calls into the core run on the module thread,
never reaching Emacs.

## View identity and failure rules

Terminal and web views run on the shared Portal view lifecycle
([ADR 0002](adr/0002-portal-view-native-seam.md)). `portal-view.el` makes
every native lifecycle call: `portal--open KIND OPTIONS` returns a target such as
`terminal:3` or `web:4`, and a window a page opens arrives with one
([below](#web-navigation-and-bridge)). `portal--place`, `portal--hide`,
`portal--close` and `portal--inspect` take that target.

The C core owns view identity in `native/Core/views.c`. Target IDs are global
across kinds and never reused, even after failed opens: stale targets cannot
reach newer views. The core holds platform views from creation to destruction,
checks their kind for kind-specific operations, and tracks attachment and edges.
The platform supplies five primitives: create a view of a kind, destroy it,
attach it at a rectangle in a frame with a given title, detach it, and describe
platform-only facts, such as page title or terminal grid. `portal--inspect`
combines that description with the core's `:id`, `:kind`, `:visible` and `:edges`.
Closing removes the target before platform destruction, ensuring exactly one
destruction and preventing intervening platform activity from reaching the view.
The core drops platform records for targets without open views. Failed primitives
change nothing: failed opens register nothing; failed placements, including into
deleted frames, leave the same views open at their previous location for Lisp to
retry placement or close.

## Terminal rules and metadata

The core owns terminal rules in `native/Core/terminals.c`. The platform supplies
five terminal or engine primitives: list themes, apply a named or default theme,
paste text, press Enter, and read all text. Before creation, the
core validates options: `:directory` must be a string; `:command`, `:argv` and
`:theme` a string or nil; `:command` and `:argv` mutually exclusive; and `:theme`
a platform-listed name. The adapter decodes `:argv` into literal arguments and
executes them through the user's interactive login shell. The core likewise
validates theme names before applying them to all open terminals, oldest first;
unknown names change none. If a terminal rejects a theme, it supplies the error:
earlier terminals keep the new theme; it and later terminals keep the old one.
`portal--terminal-themes` returns platform names sorted by code point.
`portal--terminal-paste` pastes and, with ENTER, presses Enter separately only
on success. Enter has its own primitive because input replays real native events
without synthetic keys. Reading text on macOS selects all, leaving the selection
active. The macOS platform owns Ghostty types, binding strings such as
`select_all`, and the system-appearance default theme.

Every platform reports a terminal's `:ready`, `:title`, `:pwd`, `:columns`,
`:rows` and `:exited`. `:title` and `:pwd` hold values last set and reported by the
running program, initially `""`; Ghostty forwards only percent-decoded working directories
reported from this host. Test diagnostics include `:layer`, the macOS renderer's
layer class, and input-owned `:focused`. Process exit leaves the view, last output
and buffer open until Lisp closes them; nothing restarts the shell. Closing
(destroying) the view ends the process. As with every kind, the core never passes
closed terminals to the platform: stale targets fail with "No Portal view TARGET",
and themes reach only open terminals.

The platform reports title, working-directory and exit changes through
`portal_terminal_changed`. The core sends one `terminal TARGET` record until
`portal--inspect` describes that view, preventing frequent retitling from flooding
the pipe. Texts of any length stay with the platform; `portal-terminal.el`
inspects and caches them in the buffer. Changes during opening have no target,
so the core drops their records; Lisp inspects each new terminal once. On macOS,
Ghostty immediately reports exit as a surface-close request because Portal disables
`wait-after-command` and counts no exit as a failed launch. Portal retains the
view; the first post-exit key returns the keyboard to Emacs.

## Web navigation and bridge

The core owns web rules in `native/Core/web.c`
([details](editor-bridge.md#transport)). It validates each Lisp-loaded URL, asking
the platform to load it or reload the document already displayed. For every
hosted-page navigation, the core decides: stay on the app host's origin, open
other sites in the default browser, or hand local files to Emacs. The core owns the bridge queue and its
single outstanding `bridge` record, accepting messages based on platform-observed
sender facts, never page claims.

The core also decides what downloads: a link the page asks to download, as
with a `download` attribute, and a response the platform cannot show or that
its server marks as an attachment. The platform runs each download and asks
the core where to save it once the file's name is known; the core picks a new
name in the directory Lisp set with `portal--web-download-directory`,
numbering it while a file or another download has that name, and queues
`download` messages for Emacs as each starts, finishes or fails. Every web
view has this queue; only a hosted app's page may post to it. Closing a view
cancels its downloads.

Platform primitives parse URLs into platform spelling and, per view, load a URL,
navigate history (back, forward or reload, as an enum), post messages and set
the appearance; `portal--web-go` steps the history by name. The core stores
URLs in platform/WebKit spelling: percent-encoded spaces and punycode Unicode
hosts. Byte-for-byte comparisons leave equivalence to one parser. Platform
callbacks report posted messages, navigation requests, page commits and
failures. They identify views by target, so post-close completions reach nothing.

A page may open a window, as `window.open` and links to `target=_blank` do.
WebKit asks for the new view at once and requires it to be made from the
configuration it passes, which carries the opener's data store and opener
relationship, so the platform reports the request with `portal_web_window`
from inside WebKit's callback. The core decides (hosted apps open none),
gives the view a target, and has the platform make it with
`portal_web_create_window`, before sending `opened NEW OPENER`. This is the
one view Lisp does not open: `portal-web.el` gives the target a buffer with
`portal-view-adopt`, after which it is like any other view. Each page a
window commits sends `web TARGET`, one record until Lisp inspects the view,
and Lisp renames the buffer after it. A window's page closing itself sends
`closed TARGET`, and Lisp kills its buffer, closing the view.

The core also owns zoom per site and finding's results. Lisp gives a host a
level with `portal--web-zoom HOST PERCENT`; the core keeps the levels, shows
every open page from that host at its level, and on each page commit applies
the new page's host's level, so navigation and new views follow the site.
Pages without a host share `""`. `portal--web-find` asks the platform to find
text its own way, with a token; only the latest find's result reaches Emacs,
as a `found TARGET 1` or `found TARGET 0` record. The platform supplies two
primitives for these: find text, and set a view's zoom factor.

The shared JavaScript for local links lives in `native/Core/scripts`, compiled
into the core with `#embed`; platforms need neither script files nor the app
host at runtime. The script is a function started in an isolated world with
platform-specific transport; only platform glue names WebKit. Hosted apps see only `window.portalBridge`, with `postMessage`
and `receive`.

## Keyboard ownership in the mode line

The core's `native/Core/input.c` sends a `focus TARGET 1` or `focus TARGET 0`
record on each change of whether a view has the keyboard, whatever made it:
RET or a click into the view, the escape key, a handoff to Emacs, a click
elsewhere, or hiding the view. `portal-input.el` keeps the answer in the
buffer and puts `portal-input-mode-line-process` in `mode-line-process`, the
slot Emacs reserves for a buffer's state after its mode name, so the default
mode line and packages that render that variable, such as doom-modeline, show
`Ghostty[app]` while the view has the keyboard and `Ghostty[emacs]` while Emacs
does, with the terminal's `:exited` after it, each in a state face. While the
view has the keyboard the buffer also remaps `mode-line-active` to
`portal-mode-line-app-line`, so the pane's whole mode line changes color under
every mode line package; `portal-view-close-hook` lets the input module drop
the remap when a view closes before a last record could reach its buffer.
Nothing native draws over Emacs: the view fills the pane's body, and the mode
line stays Emacs's.

## System-wide keys

The core's `native/Core/shortcuts.c` parses chord notation such as
`Control-Option-Command-P` and owns global shortcuts' IDs and held state. The
platform supplies three primitives: register a hot key, unregister it, and post
a chord. Registering takes a key by its position on a US keyboard and reports
presses and releases through `portal_hotkey_pressed` and
`portal_hotkey_released`; the core turns each press into one `shortcut ID`
record.

`portal_key_post`, behind `portal-post-key` in `portal-system.el`, presses and
releases a chord in the frontmost application, which may be Emacs. It takes the
same parsed key, except that a letter or digit names a character: the platform
finds the key that types it in the current layout, with Command held when the
chord has Command, and fails without posting when none does. On macOS, that is
`UCKeyTranslate` over the current layout, or the current ASCII-capable one for
input sources without layout data. It posts exactly the chord's modifiers, never
ones the user holds. Without Accessibility permission, macOS silently drops posted
events, so the primitive fails first when `AXIsProcessTrusted()` is false, and
asks for the permission then, through `AXIsProcessTrustedWithOptions`: macOS
shows its own alert and adds Emacs to the Device Control and Data Access list
(Accessibility before macOS 27) switched off, so the user only flips the
switch. Every failed post asks: each is the user's own request, macOS shows
one alert at a time, and an alert closes with the Emacs that asked. Only a
post asks; loading Portal or setting a global shortcut never does. A
grant applies to the running Emacs: the next post works without a restart.

## Status panel

`portal-status-show` and `portal-status-hide` in `portal-system.el` show a
line of text above every application, such as what a command bound to a
global shortcut is doing while another application is frontmost. Lisp
decides what the text says, validates the options, turns the default offset
into points and runs the `:timeout` timer.

The core's `native/Core/status.c` decides where the panel goes and how big it
is. It picks a screen: the one asked for, else the one under the pointer,
which stays the panel's screen while it is shown and still exists. It sizes
the panel: a fixed width, or the platform's measurement at the widest
allowed, then the minimum width, all within the screen's usable area. It
anchors the panel to one of nine positions, moves it by the offset, inward
from anchored edges, and keeps it inside that area.

The platform supplies four primitives: list the screens' usable areas on one
plane, with the primary first and which one has the pointer; measure a panel
for text, tone and line limit at a maximum width; show text with a tone in a
rectangle; and hide. On macOS, `native/StatusPanel.swift` makes one
borderless nonactivating `NSPanel` at status-bar level, on every Space and
over fullscreen apps, that never becomes key or main and ignores the mouse,
so showing it neither activates Emacs nor moves the keyboard. It draws the
HUD material with a hairline edge, rounded to at most 18 points, a spinner
an SF Symbol or a breathing red dot for the tone, and wrapped text; it fades in and out and asks
VoiceOver to announce new text.

## Geometry, attachment and lifetime

Rectangles use Emacs frame pixels from the content area's top left, as reported
by `window-inside-pixel-edges`. On macOS these are AppKit points; the platform
only flips y. On window changes, `portal-view.el` picks one window per view,
across frames: the selected window if it shows the buffer, then the view's current
window, then any other showing the buffer. Without one, it hides the view. Cached
geometry avoids seam calls when nothing moves. Each placement briefly renames
the frame so Swift can find its native window; frame information is never cached.
Cross-frame placement moves the view in one call.

Swift's `NativeView` attaches both kinds, each implementing `PortalView`.
Detached and new views occupy a never-shown offscreen window, keeping every view
in a window and its session or page running. Only a fullscreen web page leaves
these windows, for one of WebKit's that WebKit later returns it from:
`NativeInput` sees the view arrive in a window that is not its host's, and
keeps who had the keyboard from the core until the view is back, once WebKit
has hidden its window. Keys in that window are the page's, and `NativeHost`
drops WebKit's re-sends of those the page does not use, which would otherwise
reach Emacs. `NativeView` moves, hides or closes the view only once it is
back, as Emacs last asked; closing first asks WebKit to leave fullscreen. Frame deletion hides its views;
the next sync places them wherever their buffers remain visible. Killing a buffer
or changing its major mode closes its view. Kind-specific operations have separate
exports, such as `portal--web-load TARGET URL`. Batch tests substitute
`test/portal-fake-native.el` for the native module.

The frame-title trick and geometry cache eliminate polling timers. Native code
retains no Emacs values or environment pointers after module calls: C bindings
copy arguments, and the backend sees only copies. Native navigation callbacks
report to the core, never Lisp.
