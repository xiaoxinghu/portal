# Hosted app actions

Server-rendered hosted apps can invoke native operations through the app host. The first
client, task details' **Implement with Claude**, submits an HTML form; task
content still cannot execute scripts. **Complete**, **Reopen** and **Edit in
Emacs** use the same path from the task page script
(see [task operations](#task-operations)).

```text
Task form POST → Bun task handler → process stdout → Emacs command loop
                                                    ↓
                                              terminal.open
                                                    ↓
Task detail GET ← HTTP 303 ← process stdin ← terminal target / error
```

The hosted-page bridge handles page-local interactions with its buffer, such as
Excalidraw synchronization. App-host actions reuse parent/child process pipes,
not new sockets or WebSockets. Both reach Emacs, which owns buffers, native view
lifetime, placement and keyboard focus. Bun does not own terminal sessions.

## Registering an instance

Features call `portal-actions-enable` in their buffers with JSON properties and
an alist mapping explicit operation names to Elisp handlers. Handlers take an
arguments plist and return a result plist; unsupported operations are rejected.

Before loading a hosted page, `portal-web.el` registers its view's properties
with the app host and adds the native target as the URL's `context` parameter.
Pages treat it as an opaque handle to one live incarnation, independent of buffer
names, paths or selected panes. Navigation preserves it; reload after app-host
restart re-registers it before loading the new URL. Closing unregisters it.
Queued requests also check target liveness before acting.

New task views capture their project root: the task folder's project, or the
originating editing project for external task folders. Folders outside any known
project remain browsable but cannot launch Claude. Views also capture
`portal-tasks-claude-program` and `portal-tasks-claude-arguments` at opening.

## Process protocol, version 3

Records are UTF-8 JSON objects, one per line, at most 64 KiB per record. Both
readers handle partial and batched lines. stdout is exclusively protocol;
diagnostics use stderr. EOF on stdin retains its existing shutdown meaning.

Emacs sends:

- `context`: `id` and feature `properties`, registered before page loading.
- `forget`: `id`, when that view closes.
- `result`: request `id` plus either `value` or `error`.

The app host sends its existing `ready` record (now protocol 3), followed by
`request` records carrying `id`, `context`, `operation`, `arguments`, and an
absolute `deadline` in milliseconds. Requests time out after 15 seconds.

The process filter parses requests and queues `portal-action` input events.
Only the Emacs command loop invokes handlers, after checking the original host
process, deadline, live source view and registered operation. Handlers run in
the source buffer with its pane selected; it keeps the keyboard unless the
handler moves it, as `terminal.open` and `task.edit` do. Replaced processes'
requests cannot affect the new host. Repeated IDs are ignored within a host
lifetime.

Success means the native operation returned successfully. `terminal.open`
returns a terminal target, not proof Claude logged in, started responding or
completed the task.
Timeouts never retry launches. Before retrying an uncertain action, the UI asks
users to check for an existing result.

## Task implementation

Task details mint bounded, ten-minute form receipts tied to registered context
and task ID. POST accepts only same-origin URL-encoded forms.
`Referrer-Policy: same-origin` lets WebKit send a verifiable POST Origin while
withholding external referrers. POST retrieves server-owned values, never
browser-supplied programs, projects or operations. Duplicate POSTs share one
result, even during pending launches. GET, reload and Back never launch.
The host retains at most 1024 receipts; older pages may need reloading.

POST re-resolves the ID through the task index, using task details' resolver for
standalone/nested files, explicit IDs and folder `content.md` tasks. Missing,
conflicting, invalid or escaping sources fail before launch. Moved tasks launch
from their current paths.

`terminal.open` receives the project root as `directory`, the configured Claude
executable, arguments defaulting to `["--dangerously-skip-permissions"]`, and
initial prompt `implement @tasks/path/to/task.md`. Paths are project-relative,
including `../` for configured external task folders. Whitespace in references
is quoted within the prompt, independently of native command quoting. Launching
neither creates a worktree nor changes task status.

`portal-terminal-start` takes a directory, program, literal arguments and optional
buffer name. It sends a JSON `:argv` array to the native adapter and opens a
dedicated terminal through `pop-to-buffer` under Emacs display rules. The adapter
starts the user's interactive login shell, lets it load startup files, restores
the requested directory, then runs the program with `exec`. The shell's PATH
resolves programs; Emacs need not find them. Arguments are quoted literally,
including spaces, quotes, Unicode and shell metacharacters.

Like ordinary Ghostty terminals, the adapter chooses the native `SHELL`
environment value or user's login-shell record. Launches support POSIX-compatible
shells (`sh`, `bash`, `zsh`, `dash`, `ksh`) and fish. The shell owns its environment:
Lisp-side `setenv`, buffer-local `process-environment`, and `exec-path` cannot
affect launched programs. Ghostty supplies terminal metadata and shell integration;
Portal supplies appearance and bindings without importing standalone Ghostty's
configuration file.

Surface creation supplies the command without delayed paste or simulated typing.
The shell reports missing programs inside the terminal; last output remains
visible after exit. Hidden terminals keep running; closing their buffers ends
sessions. Closing the task browser leaves launched terminals open. Raw native
`:command` remains available to intentionally replace the normal shell.

POST redirects to task details with a receipt showing success or an escaped error,
preserving filter, execution/tree mode and source context. Form navigation may
reset reading position; a future fetch enhancement could preserve it without
changing native operations or the process protocol.

## Task operations

Task browsers register two more operations, affecting only one task file and
moving the keyboard only when asked:

- `task.status` with `file`, `start`, `end`, `text` and `before`: replace bytes
  `start` to `end` of `file` with `text`, if `file` still has the SHA-256
  `before`. The app host resolved the task and planned the edit; Emacs refuses
  unsaved buffers, files locked by another Emacs, read-only, changed or replaced
  files, and files outside the view's root. It replaces the whole file, rechecking
  the hash just before renaming, and reverts any unmodified visiting buffer.
  The page keeps the keyboard.
- `task.edit` with `file`: visit it in another pane with the local-file
  handoff, which gives Emacs the keyboard.

Pages post JSON to `/tasks/action` with `root`, `context`, task ID, `action`
(`status` or `edit`), and target `status` for status changes. Like forms, the route
requires same origin, bounded body, registered context and root. It runs requests
serially, returning `{}` after Emacs finishes or `{error}` for display. An
already-current status succeeds without asking Emacs; repeated or duplicate
requests never toggle back. After saving, Emacs requests a root-view refresh
over the [bridge](editor-bridge.md). See the
[task browser specification](task-browser-spec.md#task-operations) for patch
rules and refresh behavior.

## Verification

`./test.sh` includes app-host form/action tests
and the compiled-host → Emacs → fake-native launch flow. They cover ID-preserving
moves, duplicate delivery, errors, closed/expired sources, foreign origins,
root mismatch, reload/restart, literal shell arguments, and failed creation.
The `tasks-page` suite runs task pages' script in Playwright's headless WebKit:
in-place refreshes and their ordering, hidden and restored pages, kept folds,
history, scroll and focus, status and edit actions, and error recovery.

The same run sends status changes, a repeated change, refusal over unsaved edits,
and Edit in Emacs from the compiled host through the command loop. `bun test host`
covers the action route and status planning; task-browser graphical tests click
and key task buttons in WebKit.

`portal-tasks-gui-implement-post-starts-a-native-terminal` exercises a real WebKit
form click, process pipe, command-loop handoff and Ghostty PTY. A local probe
records cwd and argv with Unicode, whitespace and quotes. Checks cover terminal
focus, task-page retention and reload without relaunch. No Claude or model
request runs.

The pinned Ghostty [embedded surface implementation](https://github.com/ghostty-org/ghostty/blob/82938b633ba6/src/apprt/embedded.zig#L440) accepts a shell command. Its macOS process wrapper supplies `exec`; Portal passes only the quoted executable and arguments.
