# Persistent terminal sessions

Research date: 2026-09-28.

Scope: investigate optional terminals that survive an Emacs exit, while retaining the ordinary buffer-owned `portal-terminal` model. This note evaluates designs; no runtime behavior was changed.

## Assessment

Optional persistent sessions are viable without replacing Portal's current terminal model or writing a terminal emulator. The strongest new finding is that Portal's **already pinned Ghostty wrapper supports host-managed I/O**. Existing tmux and Herdr services can own the workload while a Portal view becomes an attachment.

Start with an existing daemon: thin attach wrappers are the smallest addition; Herdr's documented terminal controller is a promising native-view experiment; tmux control mode offers the more established generic backend. A Portal-owned daemon is possible but adds the largest maintenance burden. Keeping tmux or Herdr as infrastructure replaces their everyday UI, not their executable dependency.

## What actually persists

The user's model is substantially right: tmux and Herdr separate the interface from the process that owns the terminals. Closing an interface does not close the terminal's PTY master. The server continues receiving output and maintains terminal state so a new client can redraw the screen. It is more than keeping a shell PID alive: a usable reconnect also needs screen state, terminal modes, scrollback, input routing, and resize ownership. Sources: [tmux manual](https://man.openbsd.org/tmux), [Herdr live persistence](https://herdr.dev/docs/session-state/).

```text
replaceable client                    persistent server
Emacs / terminal window  <-- socket -->  PTY master + terminal state
                                                |
                                          shell / agent / job
```

This persistence ends at the server's lifetime, unless another component explicitly preserves or reconstructs state. Neither product keeps ordinary OS processes running through a machine reboot. Herdr distinguishes live detach from saved layout restoration, optional screen-history replay, and starting a supported agent with its native resume command. Those are different promises. Its experimental live handoff can transfer live terminals between compatible server versions, but is not general crash or reboot recovery. Source: [Herdr session-state documentation](https://herdr.dev/docs/session-state/).

## tmux

### Ownership and lifecycle

The tmux manual specifies separate server and client processes, communicating over a socket. A server owns sessions, windows, panes, and their PTYs. `-L` selects a separate named server/socket; `-S` selects an explicit socket path. Detaching or an SSH disconnection leaves sessions running. `exit-empty` defaults to exiting when no sessions remain; `exit-unattached` can deliberately change the normal persistence behavior. Source: [tmux manual](https://man.openbsd.org/tmux).

The implementation confirms the topology: server startup calls `proc_fork_and_daemon`, which forks and daemonizes; pane creation uses `fdforkpty`; the server's pane-read callback parses output into terminal state. The display is therefore not needed to drain output. Source snapshot: tmux commit `94796f6b1182507efac8a272fc309a79e22e58a5`, [server startup](https://github.com/tmux/tmux/blob/94796f6b1182507efac8a272fc309a79e22e58a5/server.c#L179), [daemonization](https://github.com/tmux/tmux/blob/94796f6b1182507efac8a272fc309a79e22e58a5/proc.c#L374), [PTY creation](https://github.com/tmux/tmux/blob/94796f6b1182507efac8a272fc309a79e22e58a5/spawn.c#L478), [output parsing](https://github.com/tmux/tmux/blob/94796f6b1182507efac8a272fc309a79e22e58a5/window.c#L1586).

Screen and bounded pane history live in the server. `capture-pane -p -e` exposes screen text with attribute escapes; `-S -` includes retained history. Capturing the alternate screen and capturing a partial escape sequence are separate operations. This is a useful integration primitive, but a screen capture alone is not a complete serialization of every emulator mode. Sources: [capture-pane implementation](https://github.com/tmux/tmux/blob/94796f6b1182507efac8a272fc309a79e22e58a5/cmd-capture-pane.c), [manual capture/history definitions](https://github.com/tmux/tmux/blob/94796f6b1182507efac8a272fc309a79e22e58a5/tmux.1#L2797).

### Reuse from Portal

There are two distinct integration levels:

1. Run an ordinary `tmux attach-session` client inside `portal-terminal`. The existing terminal handles the tmux screen, and tmux handles persistence and redraw. This requires very little new terminal machinery, but keeps tmux's terminal UI and its interaction conventions.
2. Use tmux control mode. `tmux -C` accepts normal tmux commands, sends per-pane output and lifecycle notifications, and supports client sizing, input, and flow control. A Portal frontend could map panes to Emacs buffers and supply its own navigation. This is precisely the purpose of control mode, originally designed for iTerm2's native integration. Sources: [official control-mode guide](https://github.com/tmux/tmux/wiki/Control-Mode), [iTerm2 integration](https://iterm2.com/documentation-tmux-integration.html).

A control-mode adapter is real integration work: decode octal-escaped raw `%output` bytes; bootstrap existing screen/history and modes; avoid gaps or duplication between bootstrap and live output; route input and resize to stable pane IDs; handle alternate screens, reconnect, and backpressure. The guide explicitly says `%output` is the application's output, may contain escapes and non-UTF-8 bytes, and that a paused client's screen may need refreshing with `capture-pane`. Control mode does not send tmux's copy/choose-mode UI. These facts support a moderate adapter, not a transparent byte-pipe assumption. Sources: [control-mode guide](https://github.com/tmux/tmux/wiki/Control-Mode), [protocol in the tmux manual](https://github.com/tmux/tmux/blob/94796f6b1182507efac8a272fc309a79e22e58a5/tmux.1#L8933).

## Herdr

The old `ogulcancelik/herdr` repository redirects to [herdrdev/herdr](https://github.com/herdrdev/herdr). Source inspection below is pinned to commit `0d5d6f1f317e238c8297076bc6ab5c3a0cd56283`; the checked official documentation includes the 0.9.1 version. API availability must be checked against the installed binary, not assumed from older Herdr versions.

### Ownership and lifecycle

Launching Herdr discovers an existing server or spawns the same executable with `server`. On Unix it redirects standard streams to `/dev/null` and creates a new process session with `setsid`. Current macOS code also handles the durable user bootstrap context; this illustrates that reliable daemon lifecycle involves platform details beyond `&`. Sources: [autodetection and daemon startup](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/server/autodetect.rs#L184), [Unix detachment](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/platform/mod.rs#L197), [macOS context handling](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/platform/macos/bootstrap.rs).

The server owns the PTY master and child process, using `portable-pty`. It also owns a Ghostty virtual terminal: PTY output is parsed into that terminal, and terminal-generated query responses are returned to the PTY. A new client receives rendered state. This is a server-side terminal emulator, not just a daemon holding child processes. Sources: [PTY backend](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/pty/backend/unix.rs#L7), [Ghostty state and response callback](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/pane/terminal.rs#L1148), [output processing and responses](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/pane/terminal.rs#L1344).

Detach and disconnect remove the client and its input/resize ownership; they do not remove the terminal runtime. Explicit `herdr server stop` stops the session. Named Herdr sessions run independent servers. Sources: [client removal](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/server/headless.rs#L898), [detach/disconnect dispatch](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/server/headless.rs#L2566), [persistence documentation](https://herdr.dev/docs/persistence-remote/).

### Reusable interfaces

Herdr already exposes more suitable interfaces than embedding its whole workspace UI:

| Interface | What Portal would receive | Suitable use |
| --- | --- | --- |
| `herdr terminal attach <terminal_id>` | An interactive single-terminal client, without workspace chrome | Lowest-effort reuse inside an ordinary Portal terminal |
| `herdr terminal session control <target>` | NDJSON ANSI render frames; accepts input, resize, scroll, release | A custom native Portal view backed by Herdr |
| `herdr terminal session observe <target>` | Same render-frame stream, read-only | Previews and passive monitoring |
| CLI / JSON socket API | Session snapshots, lists, pane reads, input, agent status, event subscriptions | An Emacs session picker/dashboard and orchestration |

The controller/observer targets may be pane, terminal, or agent identifiers. Only one writable direct controller owns input and resize for a terminal; `--takeover` replaces it. Multiple observers do not acquire those rights. Sources: [CLI reference](https://herdr.dev/docs/cli-reference/#direct-terminal-attach), [persistence/direct attach guide](https://herdr.dev/docs/persistence-remote/#direct-terminal-attach), [socket API](https://herdr.dev/docs/socket-api/).

Example controller boundary:

```text
herdr terminal session control w1:p1 --cols 120 --rows 40

stdout: {"type":"terminal.frame","seq":1,"encoding":"ansi",
         "width":120,"height":40,"full":true,"bytes":"<base64>"}
stdin:  {"type":"terminal.input","text":"hello"}
stdin:  {"type":"terminal.resize","cols":100,"rows":30}
stdin:  {"type":"terminal.scroll","direction":"up","lines":10}
stdin:  {"type":"terminal.release"}
```

Input also accepts base64 bytes. EOF on controller stdin sends detach. The source additionally accepts `terminal.mouse`, although that command is not in the checked CLI documentation. Source: [complete controller implementation](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/client/terminal_sessions.rs).

### Frame semantics and limitations that matter

**Frames are rendered screen updates, not original application output.** The first frame repaints the screen; later frames usually contain ANSI cursor movement and changed cells. Size changes or requested repaints produce full frames. Sequence numbers are per client. A client must consume incremental frames in order; a fresh attachment establishes a new baseline. Sources: [ANSI frame encoder](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/protocol/render_ansi.rs#L1), [frame data definition](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/protocol/wire.rs#L1330).

**Scrollback stays with Herdr.** The stream paints the current viewport; it does not provide a complete historical output log for the receiving Ghostty surface. Portal would need to forward scrolling to `terminal.scroll`, or retrieve history for a separate read/search view. Herdr's scroll handler selects server scrollback, application mouse reporting, or alternate-screen scrolling as appropriate. Treating every repaint as terminal history would give the wrong history. Sources: [server viewport rendering](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/server/headless/render.rs#L690), [scroll routing](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/server/pane_input.rs#L106), [pane-read API](https://herdr.dev/docs/socket-api/#reading-panes).

**The small JSON controller is not yet a complete substitute for the native Herdr client.** Its output loop forwards terminal frames and shutdown, explicitly ignores separate graphics messages, and otherwise ignores messages. The native direct client separately handles clipboard, mouse-capture, and keyboard-protocol notifications. Thus a byte/resize prototype looks small, but parity for graphics, clipboard, extended keys, and paste needs testing and possibly upstream support. This is a source-based limitation, not an observed Portal failure. Sources: [controller output loop](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/client/terminal_sessions.rs#L120), [native client message handling](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/client/mod.rs#L1910), [server mode notifications](https://github.com/herdrdev/herdr/blob/0d5d6f1f317e238c8297076bc6ab5c3a0cd56283/src/server/headless/render.rs#L112).

**Do not implement Herdr's internal binary protocol first.** The public docs distinguish a negotiated stable endpoint generation for the full UI from numbered binary protocols used by direct attach and handoff. They recommend checking server compatibility for the latter. Running the installed Herdr CLI as the bridge delegates that compatibility work; it does not eliminate version checks or promise that every historical Herdr version supports controller mode. Source: [protocol stability](https://herdr.dev/docs/socket-api/#protocol-stability).

Architectural inference: Herdr's controller is a credible small prototype for replacing the Herdr interface with Emacs while retaining its runtime. It does not remove Herdr as a dependency. It avoids implementing PTY supervision and screen restoration, but requires Portal to distinguish a server-owned viewport from its ordinary locally owned terminal.

## Minimal detach tools

`dtach` intentionally omits terminal emulation and screen tracking. It is a small protected PTY relay and works best with applications that redraw themselves. Its master drains output and relays it to attached clients; it has no replayable screen model. It can preserve a process without giving a newly created Emacs terminal the screen or missed scrollback. Sources: [official dtach description](https://dtach.sourceforge.net/), [master implementation, commit b027c27](https://github.com/crigler/dtach/blob/b027c27b2439081064d07a86883c8e0b20a183c9/master.c#L249).

`abduco` makes the same small session-management tradeoff and recommends pairing with `dvtm` when redraws are incomplete. It provides listing, exit-status retention, read-only attach, and resize ownership. The source reads PTY bytes and sends them to connected clients, rather than keeping a terminal screen/history model. Sources: [upstream README](https://github.com/martanne/abduco/blob/8c32909a159aaa9484c82b71f05b7a73321eb491/README.md), [server loop](https://github.com/martanne/abduco/blob/8c32909a159aaa9484c82b71f05b7a73321eb491/server.c#L181).

Inference: these are useful for deliberately narrow “keep this job alive” requirements. They are a weak general replacement for tmux/Herdr if “they are there on reconnect” includes shells, TUIs, correct modes, and history. Adding a terminal-state layer largely removes their simplicity advantage.

## Portal's current architecture

Inspected Portal `d691db30d1f137149ae1482d00d10fbb43bdd19a` (the task branch's base on `main`). These are source findings, not a claim that a new backend has been tested.

```text
Emacs process
  terminal buffer → Portal view → Swift HostedTerminal
                                  Ghostty .exec backend
                                    PTY → shell / foreground program
```

- [`portal-terminal.el`](../portal-terminal.el), `portal-terminal--new`, creates a buffer and opens one terminal view. `portal-terminal-start` already accepts a program plus literal arguments, so launching an attach client requires no new renderer API.
- [`native/Terminal.swift`](../native/Terminal.swift), `HostedTerminal.init`, constructs `TerminalSurfaceOptions` without a backend override. The pinned wrapper defaults to `.exec`, so Ghostty owns the PTY, child process, terminal state, and rendering inside Emacs.
- [`native/Views.swift`](../native/Views.swift), `NativeView`, parks hidden views in an offscreen `NSWindow`, retaining their size and live terminal. This explains persistence across buffer switches and frame deletion: the owning Emacs process and Ghostty objects never went away.
- [`portal-view.el`](../portal-view.el) closes views on buffer kill, major-mode change, and `kill-emacs-hook`. Removing those hooks would not make the PTY and terminal state survive destruction of their owning process.
- [`portal-server.el`](../portal-server.el) and [`host/server.ts`](../host/server.ts) implement the hosted-app server, not terminal ownership. It intentionally stops at parent stdin EOF, including abrupt Emacs exit. Turning this existing app host into a persistent terminal service would change its responsibility and lifecycle; its being a separate process does not supply persistence today.
- The one-view-per-buffer rule in [ADR 0001](adr/0001-one-portal-view-per-buffer.md) need not change. A buffer could own a short-lived attachment to a longer-lived external session. The native view target (`terminal:N`) must not become the durable session identity.

### A useful capability already in the pinned dependency

Portal pins `libghostty-spm` **1.6.20260909**, revision `7e45d27160f9b34aca9ca5c9820e9207482f9f04`, in [`native/Package.resolved`](../native/Package.resolved). The resolved source and binary header were inspected locally, not inferred from the latest README.

That version already offers `TerminalSurfaceOptions(backend: .inMemory(session))`. `InMemoryTerminalSession` accepts `write(Data)` and resize callbacks, and its `receive(Data)` feeds externally supplied output to the existing native terminal. It also accepts process-exit reports. Consequently Portal can preserve Ghostty's renderer, selection, fonts, and existing view placement while replacing the process transport. This is a capability of the packaged, patched Ghostty wrapper; do not assume the same API exists in an arbitrary upstream Ghostty build. [Pinned options](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/Surface/TerminalSurfaceOptions.swift), [pinned host-managed session](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/InMemory/InMemoryTerminalSession.swift).

The name `InMemoryTerminalSession` does **not** mean persistent storage or a daemon. It is the I/O seam, and the external service must supply persistence. `receive` parses asynchronously and caps pre-surface buffering at 1 MiB. The pinned C binary exposes `ghostty_surface_write_buffer_replay`, which suppresses terminal replies during reconstructed output, but the Swift `receive` path uses ordinary `ghostty_surface_write_buffer`. A control-mode adapter therefore still needs an explicit protocol-response and replay policy. [Pinned session source](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Sources/GhosttyTerminal/InMemory/InMemoryTerminalSession.swift), [replay patch](https://github.com/Lakr233/libghostty-spm/blob/7e45d27160f9b34aca9ca5c9820e9207482f9f04/Patches/ghostty/0011-replay-response-suppression.patch).

## Options for Portal

The effort labels below are architectural estimates, not implementation schedules.

| Approach | Emacs fully exits? | What Portal would build | Assessment |
| --- | --- | --- | --- |
| Emacs daemon + client frames | Sessions last only while the Emacs daemon lives | Validate Portal's native views in this launch mode | Useful baseline, does not meet survival across Emacs process death |
| Run tmux / Herdr attach clients in current terminal views | Yes, while external server lives | Session selection, naming, attach and explicit stop commands | Smallest practical addition |
| Native tmux control-mode frontend | Yes | Byte transport, screen/history bootstrap, input routing, resize and reconnect policy | Best-established server choice; a bounded but substantial integration |
| Native Herdr terminal controller | Yes | NDJSON adapter, frame decoding, input/resize/scroll routing, session picker | Promising bounded prototype; verify protocol feature limits before adopting |
| dtach / abduco wrapper | Yes, while their keeper process lives | Launch/attach integration | Small for process survival; weaker screen/history restoration |
| Portal-owned terminal daemon | Yes, while its daemon lives | PTY supervision, terminal state, protocol, discovery, reconnect, packaging and upgrades | Technically possible, highest maintenance; not the first move |

### Smallest addition: a session manager around attach clients

Use the existing `portal-terminal-start` to launch a client attached to a named external session. For tmux, use a dedicated Portal socket namespace and one single-pane tmux window/session per independently sized Portal terminal. Emacs owns splits, switching, and naming; the tmux status bar and prefix can be disabled in that isolated server configuration. Buffer closure then destroys the attach client while the tmux server retains the workload. Provide a separate operation to terminate the external session.

This removes most tmux UI from everyday use without implementing control mode. However, tmux still renders into Ghostty, and tmux owns deep history. Hiding its UI does not automatically make the entire history available to Ghostty's native scrollback. Copy/history access, keys, colors, and terminal extensions need an explicit policy. Herdr's single-terminal attach offers a comparable first step while retaining its native attach client's extra protocol handling. These are proposed configurations, not changes made by this research.

### Native integration: preserve Portal's UI and renderer

```text
Emacs buffer → Portal terminal view → Ghostty host-managed I/O
                                      ↕ adapter / replaceable client
Independent tmux or Herdr server → terminal state + PTY → workload
```

For **tmux**, control mode sends pane output and asynchronous events. Portal would bootstrap existing screens/history, track terminal modes/cursor, and then consume live output. Snapshot-versus-stream ordering, backpressure, resize, and reconnect are real work. tmux remains the application's terminal and can already answer terminal queries, so blindly forwarding all replies produced by a second emulator risks duplicate input. Independently sized buffers are simpler if each maps to a one-pane tmux window instead of mirroring tmux's pane geometry. [Official control protocol](https://github.com/tmux/tmux/wiki/Control-Mode), [tmux-control response handling](https://github.com/csheaff/tmux-control/blob/ebe07f4caff0c1be21e1c92323de6d00744c2891/tmux-control.el#L6072).

For **Herdr**, the documented terminal controller sends already-rendered ANSI frames, accepts input and viewport changes, and exposes server-side scrolling. This avoids reconstructing the live screen from a raw-output log. It also means server history and rendering capabilities set the limits: feeding frames into Ghostty does not recreate its ordinary local scrollback or automatically expose all Ghostty protocols. The frame adapter is likely smaller than a complete tmux control frontend; making it feel indistinguishable from today's Portal terminal needs separate validation. See the Herdr source findings above for omitted auxiliary messages and input-mode limitations. [Herdr bridge API](https://herdr.dev/docs/persistence-remote/#direct-terminal-attach).

Both approaches replace the **user-facing multiplexer** with Emacs + Portal while retaining a multiplexer executable as infrastructure. If the requirement is to eliminate tmux and Herdr dependencies entirely, neither qualifies.

### Why a small PTY daemon is not the whole feature

Spawning a detached process, opening a Unix socket, and relaying bytes are manageable. Faithful reconnect also needs the current screen, cursor, terminal modes, scrollback, and correct output handling while no UI is present. A daemon must keep draining the PTY or apply a deliberate backpressure policy. A bounded tail of raw bytes can start halfway through an escape sequence or omit state changes; repainting visible characters alone does not restore alternate screens, input modes, or the application's terminal assumptions.

Reusing a headless terminal engine avoids writing a parser, but Portal would still own lifecycle, bounded history, snapshots and live-stream ordering, controller ownership, window sizing, process exit/reaping, socket discovery/permissions, protocol compatibility and daemon upgrades. A first version can exclude remote operation, multi-client editing, and reboot restore. That makes it a plausible separate project, not a small persistence flag on `portal-terminal`.

## Fit with Emacs

The workflow fits Emacs well: a durable external session can be presented as a buffer, selected with completion, associated with a `project.el` root, and displayed through normal Emacs windows. There is no requirement to import a second pane/workspace manager. Keep ordinary terminal buffers and quick terminals on today's buffer-owned lifecycle; offer persistent sessions explicitly. Killing an attachment buffer should detach, while stopping its session should be a distinct command. Persist backend/socket/session identifiers, not native view objects or only a buffer name. This is a proposed design judgment based on Portal's current lifecycle.

There is concrete precedent: **tmux-control** renders persistent tmux panes in Emacs using Eat; **iTerm2** maps tmux sessions into native terminal UI. The Emacs package demonstrates the interaction model but is not a ready-made Ghostty transport: the inspected implementation is closely tied to Eat, including terminal setup, history, mode tracking, and input handling. Its existence supports feasibility, not a promise that substituting the renderer is trivial. [tmux-control](https://github.com/csheaff/tmux-control), [iTerm2 integration](https://iterm2.com/documentation-tmux-integration.html).

Emacs daemon mode already separates frame lifetime from the Emacs process. It is enough if the real need is closing every visible editor window. It cannot protect terminals from restarting or crashing that Emacs process. Portal currently requires an `ns` graphical frame when loading its module and creates AppKit/Metal views; compatibility with daemon startup and first/last graphical-frame transitions needs testing, not an assumption that the native module works before a GUI frame exists. [Emacs server manual source](https://github.com/emacs-mirror/emacs/blob/master/doc/emacs/misc.texi), [`portal-view--load`](../portal-view.el).

The persistent terminal layer also does not replace all Herdr features: agent state detection, orchestration, notifications, and workspace management are separate product choices. Existing tmux/Herdr runtimes preserve the option of attaching from another terminal or SSH when Emacs is unavailable. A Portal-only macOS daemon would need a separate client story to retain that benefit.

## Recommendation and a bounded experiment

**Proceed with optional persistent sessions backed by an existing runtime; keep ordinary Portal terminals unchanged.** For the conservative route, start with a dedicated tmux server and thin attach wrappers. For testing a truly native Portal frontend, Herdr's terminal controller is especially worth a small experiment because both ends of the adapter already exist. Native tmux control remains attractive if protocol maturity and terminal/SSH interoperability matter more than minimizing adapter work. Do not begin by implementing a Portal daemon.

A useful next experiment has one existing external session, one Ghostty host-managed view, and explicit attach/detach/stop operations. Accept it only after:

1. A shell or agent continues producing output after a normal Emacs exit and an abrupt client death, and a fresh Emacs attaches to the same running process.
2. Reattachment restores a prompt and a full-screen TUI at different sizes, including after output was produced with no client.
3. History remains usable, UTF-8 and large pastes work, and mouse/scroll/keyboard behavior matches the chosen backend's documented limits.
4. Disconnect is distinguishable from process exit, and buffer closure cannot accidentally terminate the workload.

Treat multiple writers, automatic layout restoration, reboot resume, remote-machine management, and agent orchestration as later decisions. The first experiment should settle whether persistence and input/history fidelity fit Portal's interaction model.

## Local verification during this investigation

- Inspected the resolved Ghostty wrapper and its actual macOS C header at Portal's pinned revision; external I/O is present in the dependency already used by this checkout.
- Installed `herdr 0.9.1` exposes `terminal session control` and `terminal attach` in CLI help. No existing Herdr session was attached to or modified; a live Portal–Herdr controller integration was not tested.
- Ran an isolated tmux 3.7c experiment on a unique socket: killed its control client with `SIGKILL`, observed zero attached clients, saw output advance from `tick 0` to `tick 5`, and reattached with the same pane process ID. The test-owned server was then stopped. This verifies the backend persistence mechanism, not a Portal implementation.
- `./build.sh` passed. All 19 CTest suites passed across the initial run and the targeted rerun: the two initial failures were Emacs native compiler link errors for the installed `libemutls_w`; rerunning those two with `LIBRARY_PATH=/opt/homebrew/Cellar/gcc/15.2.0/lib/gcc/current/gcc/aarch64-apple-darwin25/15` passed. No source fix or test bypass was needed.
