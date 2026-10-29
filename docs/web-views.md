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

`l` or Command-[ (`portal-web-back`) and `r` or Command-] (`portal-web-forward`)
move through the view's history.

## Address bar

Command-L (`portal-web-load-url`) loads another page in the same buffer, as a
browser's address bar does; the buffer takes the new page's name and `g`
reloads it from then on. Command-T (`portal-open-url`) reads the same way and
opens the page in a new buffer, as a browser opens a tab. A hosted app's
buffer, such as a Markdown preview, opens the page in a new buffer for
Command-L too.

The minibuffer starts with the page's URL selected, in the `region` face:

- Typing replaces it, and yanking replaces it with what is yanked.
- Backspace, `C-d` or a kill clears it.
- Left and Right keep it, with the cursor at its start or end, and any other
  key, such as `C-a` or `TAB`, keeps it as text and does what it always does.
- `RET` with it still selected loads the page again. `M-n` brings it back.

`M-x portal-open-url` from a buffer that is not a web page starts empty.

As you type, [bookmarks](#bookmarks) are suggested, matching their name or
their URL; Vertico, Orderless and Marginalia apply as for any completion. On
`RET`, the address bar loads:

1. The chosen suggestion's page. Plain Emacs completes with `TAB`; Vertico
   chooses the first suggestion, and `M-RET` takes what was typed instead.
2. A URL with a scheme, as typed, such as `https://example.com/a` or
   `file:///tmp/index.html`.
3. A site: a host with a dot or a port, and maybe a path, gains `https://`,
   such as `example.com`, `192.168.1.1`, `myhost:8080` or
   `en.wikipedia.org/wiki/Free software`. `localhost`, with or without a port
   or path, gains `http://`.
4. Anything else, such as `emacs bookmarks`, searches the web through
   `portal-web-search-url`, Google by default. Its `%s` becomes the words,
   each percent-encoded and joined by `+`:

```elisp
(setopt portal-web-search-url "https://duckduckgo.com/?q=%s")
```

`(portal-web-read-url PROMPT CURRENT)` reads a URL this way for your own
commands. Suggestions come from `portal-web-omnibox-sources`, a list of
`(GROUP . FUNCTION)`, where FUNCTION returns `(STRING . URL)` pairs; completion
matches STRING.

## Bookmarks

A web page's bookmark is an ordinary Emacs bookmark of type Web, kept in your
bookmark file with the others: its name is the page's title, its location
the page's URL. So `C-x r m` (`bookmark-set`) bookmarks the page on screen,
and `C-x r b` (`bookmark-jump`), `C-x r l` (`bookmark-bmenu-list`),
`consult-bookmark` and Embark's bookmark actions open, rename and delete it as
any bookmark. Opening one always opens its page in a new web buffer, where
the command shows buffers: `bookmark-jump-other-window`, Embark's `o` and
Consult's other-window commands put it in another window.

In a web buffer:

- Command-D (`portal-web-bookmark-set`) bookmarks the page, reading a name
  that starts as the page's title, or its host without one. A bookmark of the
  same name is replaced.
- `b` or Command-B (`portal-web-bookmark-load`) loads a bookmarked page in this
  buffer.
- `B` or Command-Shift-B (`portal-web-bookmark-open`) opens one in a new
  buffer; `M-x portal-web-bookmark-open` does so from any buffer.

Both pick from web pages' bookmarks only, with their URLs beside them.
A hosted app, such as a Markdown preview, cannot be bookmarked, and opens a
bookmark in a new buffer.

Loading Portal and Consult, in either order, enables `portal-web-consult-mode`:
`consult-bookmark` then lists web pages with EWW's under Web, narrowed with
`w SPC`. Opt out with `portal-web-consult-auto-enable` set to nil before
loading them, or `M-x portal-web-consult-mode`.

## Find and zoom

`C-s` or Command-F (`portal-web-find`) reads text in the minibuffer and finds
it in the page, after the page's selection; `C-r` (`portal-web-find-backward`)
finds it before. WebKit selects and highlights the match, wrapping around the
page's ends. While the minibuffer reads, `C-s` and `C-r` move to the next and
previous match without leaving it, and `RET` stays on the match shown; empty
input finds the last text again. Afterwards Command-G and Command-Shift-G
(`portal-web-find-next` and `portal-web-find-previous`) move between matches.
Case matters as in isearch: when `case-fold-search` is off, or the text has an
upper-case letter. The page never takes the keyboard while finding; a page
without a match says so in the echo area.

`+` or Command-= (`portal-web-zoom-in`) and `-` or Command-- (`portal-web-zoom-out`)
step through `portal-web-zoom-steps`, and `0` or Command-0
(`portal-web-zoom-reset`) returns to 100%. The page lays itself out again at the
new size. A level belongs to the page's site, its host: every page from it
shows at that level, in every web view, including pages a view goes to later,
so the site reopens at its level. Local files and other pages without a host
share one level. `portal-web-zoom-levels` holds them; with `savehist-mode` on,
Emacs keeps them between sessions.

The Command keys work while the page has the keyboard too, unless the page
uses them itself.

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
`l` and `r` or Command-[ and Command-] in the buffer, `portal-web-back` and `portal-web-forward`, navigate previously shown
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
- A page can go fullscreen, as a video player's button does, and Escape
  leaves fullscreen; [fullscreen pages](keyboard.md#fullscreen-pages) says
  where the keyboard goes.
- The minibuffer is the [address bar](#address-bar): the page has no toolbar.
  Inspecting a view reports its `:zoom` in percent.
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

## Downloads

A web view downloads what it cannot show, such as a zip archive, anything
its server sends as an attachment (`Content-Disposition: attachment`), as
mail attachments are, and links with a `download` attribute. The file goes
to `portal-web-download-directory`, `~/Downloads/` by default, under the name
the site suggests; when that name is taken, it becomes `report (1).pdf` and
so on. The page stays as it was, and the echo area says when the download
starts, where it finished, or why it failed:

```elisp
(setopt portal-web-download-directory "~/Downloads/web/")
```

A change applies to downloads that start afterwards. Killing a web buffer
cancels its unfinished downloads. There is no download list or progress
display; `M-x dired` the directory to find files.

## Passwords and certificates

A site behind HTTP authentication, as many self-hosted and intranet sites
are, asks for a user name and password with a sheet on the page's frame,
such as "Log in to “wiki.example”", naming the area of the site it is for
and saying when the password would be sent unencrypted. The sheet follows
the page as its JavaScript dialogs do. Once logged in, WebKit sends them
without asking for the rest of the Emacs session, from every ordinary web
view, or from a hosted app's own view; a wrong one asks again with the user
name kept. Cancel, and the page shows what the site sends without them.
Basic, Digest and NTLM authentication ask; other kinds, such as Kerberos,
are left to the system.

Ticking "Remember this password" keeps it in the login keychain, from where
the site gets it without asking in later sessions, until it fails; logging
in again with the box clear forgets it. Hosted apps keep nothing, so their
sheet does not offer to remember.
`(portal-web-open-hosted "/sign-in")` opens a page that asks: any user name
with the password `portal` signs in.

A site that asks for a certificate of the user's gets one from the keychain:
the one chosen for that site before, or one chosen in the system's
certificate sheet from those the site accepts. The sheet keeps the choice in
the keychain for that site. Without one, or when cancelled, the page goes on
without a certificate. A site whose own certificate the system does not
trust fails to load, with no way to go on anyway.

## Camera and microphone

A page that asks to use the camera or microphone, as a video call does,
asks with a sheet on its frame, such as "Allow “meet.google.com” to use your
camera and microphone?". The sheet follows the page as its JavaScript
dialogs do: hiding the page takes it down, showing the page puts it back,
and closing the view refuses. A frame from another site names both, as in
"Allow “widget.example” in “example.com”".

Allowing lets that site, and that frame's site, use the devices again
without asking, in every web view, until Emacs quits; a request for a device
not yet allowed asks again. Refusing lasts for that one request: the page
may ask again. Hosted apps may not use either device, and are never asked.

macOS also asks, once, whether Emacs may use the camera and the microphone;
Emacs.app names them in its `NSCameraUsageDescription` and
`NSMicrophoneUsageDescription`. Change that answer in System Settings,
Privacy & Security, Camera or Microphone, then restart Emacs. Refused
there, the page gets an error. As in browsers, only secure pages can ask:
HTTPS, and `http://localhost` or `127.0.0.1`.
