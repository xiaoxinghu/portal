# A page owns its state

A web view's **page** is one document, from the commit that loads it to the next commit. Its identity is the view and the core's generation; its URL is an attribute, which `pushState` or a fragment changes without a new page, and a reload keeps while making one. Its state, the selection, the find highlights, the scroll position, what is typed into it, belongs to the page and lives only in WebKit; Portal keeps no copy.

Only four things change it: the page's own scripts, the user's input in the page, a command Emacs addresses to that page, such as a find, and the page ending. Moving the keyboard between Emacs and the page, moving the view between panes, hiding or parking it, and window or application focus never do: leaving a page and coming back finds it as it was, as point is in a buffer.

Every request to a page carries its generation and every report names the page it is about; one for a page that has gone is dropped. Derived facts, such as a find's match number, are kept under the page and query they came from, and Portal shows only what it can derive.

This came from finding. With the page holding the keyboard, Command-G goes through the input handoff: the page gives the keyboard to Emacs, Emacs sends the find, and the page takes the keyboard back. WebKit clears a page's selection when the page gives up the keyboard, and a find starts after the selection, so every Command-G found the first match again. The keyboard moving had changed the page.

## Considered Options

- **Keeping state per URL.** A reload would keep a selection the new document does not have; `pushState` would drop one it does.
- **Mirroring the selection in Portal.** A second source of truth that drifts, as WebKit's own match counter does.

## Consequences

WebKit's own policy of clearing the selection when the view gives up the keyboard is turned off on every page: on macOS, `WKPageSetMaintainsInactiveSelection` is set at each commit, since it does not survive navigation. A find's result is dropped once its page has committed another, and the match number is shown only when the platform can locate the selected match among the page's matches.
