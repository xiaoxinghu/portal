# Run and troubleshoot the app host

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Bun UI host

Loading the Lisp package or native module starts no server. The first
`portal-hello`, `portal-about`, `portal-render-markdown`, or drawing buffer
asynchronously starts one shared child process. Hello, About and Markdown
previews are hosted apps: their web views open immediately at `about:blank`
and load when the host sends its readiness message. External URLs need no server.

- Each Emacs process owns one host, shared by its web views, bound to
  `127.0.0.1` on an OS-assigned port.
- Each host generates a fresh access token and sends it through the readiness
  pipe. URLs have the form `http://127.0.0.1:PORT/TOKEN/hello`,
  `http://127.0.0.1:PORT/TOKEN/dialogs`, a page that tries the
  [JavaScript dialogs](web-views.md#web-view-behaviour),
  `http://127.0.0.1:PORT/TOKEN/about?portal=VERSION&emacs=VERSION` or
  `http://127.0.0.1:PORT/TOKEN/markdown?path=ENCODED_ABSOLUTE_PATH`. Previews
  load local images from `image?path=ENCODED_ABSOLUTE_PATH`, which serves
  only files with common image extensions. The host
  validates the token and Host header; responses suppress outgoing referrers.
- The About page shows the Portal and Emacs versions that `portal-about`
  passes, as text, with the host's Bun version. Its portal is drawn with
  WebGL and stops animating while the view is hidden. It draws one still
  frame when the system reduces motion, and shows the Companion Buffer image
  when WebGL is unavailable.
- Closing or hiding a view leaves the server running. `M-x portal-start-server`
  prewarms it; `M-x portal-stop-server` stops it;
  `M-x portal-restart-server` replaces it. Loaded hosted apps keep their pages
  through host stops or restarts. Press `g` in an app's buffer to reload,
  starting the host if needed.
- Startup is bounded by `portal-server-start-timeout` (five seconds by default).
  Failures leave diagnostics in `*portal-server*` and waiting apps at
  `about:blank`; press `g` in the buffer, or run `portal-hello`, to retry.
  There is no automatic restart loop.
- Emacs supervises the child through a pipe: stdout carries a versioned JSON
  readiness line; stderr carries diagnostics. Closing stdin requests shutdown,
  even on unexpected Emacs exit. Normal shutdown handles OS termination signals
  with a forced-termination fallback.
- `portal-server-program` selects the standalone executable, launched directly
  without a shell or Bun lookup on PATH. The compiled binary disables runtime
  loading of `.env` and `bunfig.toml`.

Control protocol version 3 announces readiness, port, and access token in one
`ready` record. Emacs sends nothing; stdin stays open for the host's lifetime.
Rebuilding publishes the executable atomically; running hosts keep their old
code until `portal-restart-server`.
