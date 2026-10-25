# Preview files and open web pages

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## HTML files and URLs

Run `M-x portal-render-html` in a `.html` or `.htm` buffer to preview saved
contents, including relative scripts, styles and images from its directory.
Other buffers prompt for a local path or URL. Relative paths use the buffer's
`default-directory`; `C-u M-x portal-render-html` always prompts. Unsaved edits
are excluded. Repreviewing a file reuses and reloads its buffer, such as
`*portal: index.html*`.

`M-x portal-open-url` opens any absolute URL in a new, page-named buffer each
time, such as `*portal: example.com*`.
Both commands accept HTTP, HTTPS, `file:`, `data:`, and `about:` URLs.
To open a local HTML file programmatically:

```elisp
(portal-render-html "/absolute/path/index.html")
```

In a web buffer, `g` reloads and `q` (`quit-window`) hides the still-running
page. Killing the buffer closes it.

## Markdown previews

Run `M-x portal-render-markdown` in a Markdown file buffer to preview it;
Markdown modes and common extensions are recognised. Other buffers prompt for
a saved local file. `C-u M-x
portal-render-markdown` explicitly chooses another file. Each file reuses one
preview buffer, such as `*portal: notes.md*`. The Bun server reads and renders
it with its [built-in Markdown API](https://bun.com/docs/runtime/markdown),
returning complete HTML with embedded light/dark CSS. Rendering is in memory:
no temporary HTML files or additional npm dependencies.

Previews follow system light/dark appearance, even when Emacs frames force a
title-bar appearance with `ns-appearance`. To fix preview appearance, set
`portal-web-appearance` or run `M-x portal-web-set-appearance`:

```elisp
(setopt portal-web-appearance 'light) ; or 'dark; nil follows the system
```

This affects every web view, including Excalidraw;
open previews change immediately without reloading.

Previews support headings, lists, fenced code, tables, strikethrough, task lists,
heading anchors and images. Local images, such as `![diagram](img/arch.png)`,
resolve like links below and show inline; HTTP(S) and `data:` images also work. Command-R rereads the displayed file from disk; from
Emacs, `g` (`portal-web-reload`) also starts a stopped host. Loaded previews
survive host stops or restarts. Missing or unreadable files show an error page.

The preview follows links like a browser:

| Link | Where it goes |
| --- | --- |
| `#anchor` | Scrolls within the page |
| A local Markdown file, such as `architecture.md` or `other.md#heading` | Opens in the same preview, at the heading if there is one |
| Any other local file, such as `src/server.ts#L42` | Opens in Emacs in another pane, at line 42 for `#L42` or `#L42-L50` |
| A local image or folder | Opens in Emacs, in `image-mode` or Dired |
| `https://…` and other sites | Opens in the default browser |

Relative links resolve from the displayed document's folder; local absolute
paths and `file:` URLs also work. Following a Markdown link renames the buffer
after that file: `g` rereads it, and `portal-render-markdown` on that file finds
this preview.
`l` and `r` in the buffer, `portal-web-back` and `portal-web-forward`, navigate previously shown
documents and restore reading positions. Following a new link after going back
discards forward pages, as in a browser; opening files in Emacs or websites does not.

One click opens a file in Emacs and selects its pane with editing focus. The
preview keeps its pane and reading position; the file reuses another pane or
splits the frame. `display-buffer-alist` still decides: if it uses the preview's
pane, the hidden preview keeps its page. `M-x portal-render-open-in-emacs`
does the same for the displayed Markdown file, including after going back or
forward.

To resume reading, click the preview to select and focus it, or select its pane
and press `RET`. From elsewhere, `M-x portal-render-return` shows, selects and
focuses the preview this frame last opened a file from, without reloading.
It has no global key; bind one if desired.

This version shows saved contents only, without automatic refresh, syntax
highlighting, Mermaid or math rendering. Going back past a host restart shows "Not found";
`g` reloads from the running host. Raw HTML appears as text; a page-specific
Content Security Policy blocks scripts. Bun currently marks its Markdown API unstable;
Portal tests it with the Bun version in the [build prerequisites](../README.md#build-and-run).

## Web view behaviour

Web views are Portal views of the web kind. Remote pages use
[WebKit URL request loading](https://developer.apple.com/documentation/webkit/wkwebview);
local pages use `loadFileURL` with containing-directory read access for relative
scripts, styles and images. JavaScript is enabled by default.

- Each web buffer has one view in its selected pane
  ([ADR 0001](adr/0001-one-portal-view-per-buffer.md)); other panes showing
  that buffer show only text. Use two buffers for side-by-side pages.
- Views belong to no frame: showing the buffer elsewhere moves its page.
  Deleting a frame only hides its views.
- Hiding with `q` or another buffer preserves the page's navigation, DOM, scroll
  position and form state. Cookies use WebKit's default store, except hosted
  apps keep no cookies or storage between Emacs sessions.
- Pages other than hosted apps send WebKit's user agent with Safari's suffix,
  such as `Version/26.0 Safari/605.1.15`, naming the installed Safari's
  version, because Google refuses to sign in to embedded web views without
  it. Google does not sanction this, so it may stop working. Hosted apps keep
  WebKit's plain user agent.
- Hosted pages never leave the app host: other navigation is cancelled and
  opened in the default browser. Local `file:` links instead give Emacs focus
  and send the URL in a `follow` message over the [bridge](editor-bridge.md).
  WebKit forbids hosted pages from loading local files, so a script in its own
  content world, beyond the page's reach, catches these clicks. Every hosted
  page commit, including Back/Forward, sends a `page` message. URLs use the
  bridge because long paths would not fit in notification records.
- CSS's `prefers-color-scheme` reflects system appearance, not a frame's forced
  `ns-appearance`. Setting `portal-web-appearance` to `light` or `dark`
  overrides every web view, open or new.
- With page focus, unused chords reach Emacs and the configured escape
  (Command-period by default) returns control to Emacs. Clicking
  to enter sends `select TARGET`; Emacs selects the view's pane.
- A page's `alert`, `confirm` and `prompt`, and the question a page with a
  `beforeunload` handler asks before it is left or reloaded, show as a sheet
  on the view's frame; the page waits for the answer. The sheet holds that
  frame until answered, as in any Mac app. Hiding the page takes its sheet
  down and showing it again puts it back, still waiting; closing the view
  dismisses it. WebKit asks before leaving only a page the user has
  interacted with, and closing the view never asks.
  `(portal-web-open-hosted "/dialogs")` opens a page that tries each one.
- This URL viewer has no address bar or downloads.
  Inspect failed loads through `:error` in
  `(portal--inspect (portal-view-target))`, or the page itself with
  [Web Inspector](#web-inspector).

## Windows pages open

A link to `target=_blank`, `window.open` and sign-in popups open a new web
buffer named after the page, such as `*portal: accounts.google.com*`, and
renamed as it goes to other pages, as sign-in popups that start blank do. It
appears in a pane beside the page that opened it, with the keyboard, as files
a Markdown preview opens do; `display-buffer-alist` still decides. The new
page shares the opener's cookies and storage, so signing in there signs the
opener in. `g` reloads the page it shows. When the page closes itself with
`window.close()`, as sign-in popups do once done, its buffer is killed and its
pane goes back to what it showed before. Killing the buffer closes the page,
and the opener's buffer is independent of it. Window sizes the page asks for
are ignored. Hosted apps open no windows: links to other sites still open in
the default browser.

WebKit has a known bug in which a popup's `window.opener` is null on some
macOS versions ([759487](https://developer.apple.com/forums/thread/759487),
[810417](https://developer.apple.com/forums/thread/810417)), which breaks
sign-in flows that report back to the opener. On macOS 27.0.1 (26A434), on
2026-10-25, a popup from `window.open` had its opener and could post to it,
as `test/portal-web-gui-tests.el` checks; macOS 26 was not checked. Links to
`target=_blank` get no opener, as browsers give them `rel=noopener` by
default.

Lisp can give any buffer a web view: `(portal-web-open URL)` opens and loads
URL in the current buffer. Loading the current page, ignoring its fragment,
reloads without adding history.
`(portal-web-open-hosted PATH)` instead opens immediately at `about:blank`
and loads hosted PATH, such as `"/hello"`, when the host is ready, starting it
if needed. Hosted apps exchange JSON objects with their buffers over the
[bridge](editor-bridge.md): `(portal-web-send PLIST)` sends to the app;
buffer-local `portal-web-bridge-function` receives app messages in order.
Other web views have no bridge.

## Web Inspector

Safari's Web Inspector can attach to any web view, hosted apps and Markdown
previews included, on macOS 13.3 or later. Turn on "Show features for web
developers" in Safari's Advanced settings once; then Safari's Develop menu
lists each open page under this Mac, in its Emacs entry, by title or URL.
Choosing one opens Web Inspector for that page: its elements, console,
network requests and storage.

`portal-web-inspectable`, on by default, only allows attaching; nothing opens
until the menu is used. It applies to web views opened afterwards:

```elisp
(setopt portal-web-inspectable nil) ; keep new pages out of the Develop menu
```

`(plist-get (portal--inspect (portal-view-target)) :inspectable)` tells whether
a page is listed; a window a page opens is listed when its opener is. Emacs
has no command to open Web Inspector itself: WebKit offers that only through
private interfaces.
