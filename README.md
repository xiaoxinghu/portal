# Portal: native views in Emacs

Native WebKit pages and Ghostty terminals inside macOS Emacs panes, backed by
one native dynamic module: C Emacs bindings over a Swift backend. A bundled Bun server hosts Hello World, local
Markdown previews, a task browser and an offline Excalidraw editor. Each buffer has one native view,
which follows its buffer across splits, resizing and frames; hidden pages and
terminal sessions keep running.

## Build and run

Requires graphical macOS Emacs with dynamic modules, its `emacs-module.h`,
Apple's Swift 6/Clang toolchain (Xcode), CMake 3.29 or newer, Ninja, and Bun
(tested with Bun 1.3.14). Install CMake and Ninja with `brew install cmake ninja`
or your tool manager, and install Bun for building.
The build checks that Bun provides `Bun.markdown.html`.
The resulting host executable includes Bun and its page assets: users do not
need Bun, Node, npm packages, or server source files at runtime.
The native module uses SwiftPM to download a pinned GhosttyKit binary
(about 77 MB on the first build) and its native Swift wrapper. No Zig installation
is needed. The versions and binary checksum are pinned by
`native/Package.swift` and `native/Package.resolved`.

```sh
./build.sh
emacs -Q -l "$PWD/portal.el" \
  --eval '(portal-hello)'
```

The single build command produces `build/portal.bundle` and
`build/portal-host`. The bundle contains the one native Emacs module at
`Contents/MacOS/portal.dylib` and Ghostty's resources. CMake recompiles the host when its TypeScript entry point
or HTML changes. CMake records the path of the `bun` found on `PATH` and
searches again if that file disappears. Set `-DBUN=/absolute/path/to/bun`
through `./build.sh` or CMake to select another Bun, or run
`cmake --fresh --preset dev` to rediscover every tool. Both binaries are built
for the current Mac.

Or load `portal.el` in graphical Emacs and run `M-x portal-hello`.
Run `M-x portal-preview-markdown` to preview the current Markdown file or
select another local file, and `M-x portal-tasks` to list the project's
actionable [tasks](#task-view).
To distribute this layout, include all `portal*.el` files at the package root,
`build/portal-host`, and the complete `build/portal.bundle`;
the host needs no adjacent web assets. Keep the bundle intact, including its terminfo
and shell integration resources. Restart Emacs when upgrading from the former
separate web and terminal modules, or after rebuilding a loaded native module.

Run `M-x portal-preview-html` in a `.html` or `.htm` file buffer to open its
saved contents in a web view, including relative scripts, styles,
and images from its directory. From other buffers, it prompts for a local
path or URL. Relative paths use the current buffer's `default-directory`;
`C-u M-x portal-preview-html` always prompts. Unsaved edits are not included.
Previewing the same file again reuses its buffer, such as `*portal: index.html*`,
and reloads it.

`M-x portal-open-url` opens an arbitrary absolute URL in a new buffer each time,
named after the page, such as `*portal: example.com*`.
Both commands accept HTTP, HTTPS, `file:`, `data:`, and `about:` URLs.
To open a local HTML file programmatically:

```elisp
(portal-preview-html "/absolute/path/index.html")
```

In a web buffer, `g` loads the page again and `q` (`quit-window`) hides the
view while the page keeps running. Killing the buffer closes the page.

## Global shortcuts

A global shortcut calls a Lisp function when its chord is pressed in any
application. It does not activate Emacs, select a frame or show a panel, so the
function decides what appears. Loading Portal registers nothing. Name each
shortcut with a symbol:

```elisp
(defun my/play-pause ()
  (interactive)
  (call-process "osascript" nil 0 nil "-e" "tell application \"Music\" to playpause"))

(portal-global-shortcut-set 'play-pause "Control-Option-Command-M" #'my/play-pause)
(portal-global-shortcut-set 'time "Control-Option-Command-T"
                            (let ((pattern "%H:%M"))
                              (lambda () (message "%s" (format-time-string pattern)))))
(portal-global-shortcut-remove 'time)    ; t, or nil when TIME was not set
```

Setting a name again replaces its chord and function and releases the old
chord, so evaluating a configuration again leaves one registration per name.
An interactive command runs with `call-interactively`; any other function of no
arguments runs with `funcall`, so a lambda can capture what it needs.
`portal-global-shortcut-set` returns the name. It signals an error and changes
nothing for a name that is not a non-nil symbol, a function that needs
arguments, invalid notation, a chord another name has (the message names it), or
a chord that macOS refuses because the system or another application has it.
`portal-global-shortcut-remove` returns t when the name was set and nil
otherwise; it signals only if macOS cannot release the chord, and then keeps it.

The notation is case-insensitive, hyphen-separated modifier names (`Control`,
`Option`, `Command`, `Shift`) followed by `A`–`Z`, `0`–`9`, `Space`, or `F1`–`F20`.
At least one of Control, Option or Command is required, with no duplicate
modifiers. Letters and digits refer to **US physical key positions**, independent
of the input layout and Emacs's `ns-*-modifier` settings. Shift must be explicit;
capital letters in the notation do not imply it. Fn, Caps Lock, punctuation,
left/right modifier distinctions and multi-key sequences are unsupported.
Function keys require the keyboard to send the function key rather than its
media action. Two spellings of one chord, such as `command-control-option-p`,
are the same chord. System-reserved shortcuts and other hotkey utilities can
still intercept keys; choose another chord if one registers but is not
delivered.

The native module registers each chord with Carbon. A press sends a record
through Portal's notification pipe, even with no Portal view open; it needs
neither a subprocess nor an Accessibility event tap. The pipe's filter only
queues an input event, and the command loop calls the function, as for a key
bound to it, during a minibuffer prompt too. Emacs must be running, and busy
Lisp delays the call; there is no responsiveness guarantee. Holding a chord
calls the function once. A press while an earlier press of the same shortcut
still waits is dropped, and so is a press from before its name was last set or
removed. A press that arrives in the middle of a key sequence, or while a
prompt reads a single key, is read there instead and calls nothing.

An error in the function is shown as a message naming the shortcut. Every
shortcut stays set, and unlike other commands' errors it discards no waiting
input, such as another shortcut's press; with `debug-on-error`, the debugger
shows it. Unloading `portal-global-shortcut` or exiting Emacs releases every
chord; if one cannot be released, unloading fails and the feature stays loaded. Removing one shortcut, or disabling or deleting the launcher panel,
leaves the others.

## Native launcher panel (opt-in)

The launcher passed the user's daily-use checklist on 2026-10-04. See the
[setup and validation guide](docs/launcher-daily-use.md) for the tested versions,
fresh-session procedure and manual input/accessibility results.

`portal-launcher.el` presents a real Emacs buffer in one reusable, borderless,
nonactivating macOS panel. It uses Portal's existing module. Loading the feature
does not create a frame or register a shortcut. Enable the mode to register
Control–Option–Command–P; it opens the application picker from any application.
Install the optional [launcher.el](https://github.com/xiaoxinghu/launcher.el)
package first; this is the tested revision:

```elisp
(use-package launcher
  :vc (:url "https://github.com/xiaoxinghu/launcher.el"
       :rev "731146d95d7d1ff16f48e7a200da873c8d8b375c")
  :commands (launcher launcher-refresh))
```

After building and loading Portal:

```elisp
(require 'portal-launcher)
(portal-launcher-mode 1)        ; register shortcut, create the frame on first press
(portal-launcher-present)      ; same app picker, without the global shortcut
;; C-u M-x portal-launcher-present refreshes before prompting.
;; M-x launcher-refresh refreshes separately.
(portal-launcher-mode -1)       ; delete frame and release shortcut
```

For a persistent setup, install the pinned dependency above, build Portal, then
add the following to your init file (replace the directory):

```elisp
(load "/absolute/path/to/portal/portal.el" nil t)
(require 'portal-launcher)
(setopt portal-launcher-shortcut "Control-Option-Command-P"
        portal-launcher-command #'portal-launcher-applications
        portal-launcher-size '(720 420)
        portal-launcher-offset '(0 0))
(portal-launcher-mode 1)
```

First try this in a fresh disposable Emacs with your completion/theme setup.
After that passes, explicitly evaluate the setup in a fresh normal session.
The launcher runs inside Emacs; it needs neither the app host, a separate
launcher application nor a per-invocation `emacsclient`. Emacs must already be
running, and long Lisp work delays invocation.

To migrate from M-x.app, start with a different Portal chord. Record the old
M-x launcher row's trigger and expression, then remove only that shortcut row
in M-x Settings before assigning its chord to Portal. Keep M-x running for its
other shortcuts, `emacs://` and `org-protocol://` bindings. Modifier double-taps
remain M-x features. See the guide for the migration and rollback checks.

To roll back, run `(portal-launcher-mode -1)` and remove the enable call from
your init file. This deletes the dedicated panel, releases its global shortcut
and removes its frame guards. Existing ordinary frames and Portal views remain
usable. Restore the saved M-x launcher row if you migrated it. The shared native
module stays loaded for other Portal features; restart Emacs to change its
binary. Rebuilding or unloading Lisp does not replace a loaded native module.

Type an application name, select it with your completion setup, then Return to
launch or activate it. `launcher.el` owns the Spotlight index, directory list,
duplicate-name labels, path annotations and `open -a` calls. Warm invocations
reuse its cache; use explicit refresh after installing or removing an app.
Its `launcher-app-directories`, `launcher-fallback-search-url` and
`launcher-bangs` remain customizable. Unmatched text searches the web; `!g`,
`!yt` and `!gh` followed by a space and query select a search engine.

The default `portal-launcher-command` is `portal-launcher-applications`, a thin
adapter around `launcher`. Return accepts the highlighted app, including the
first candidate or one selected with arrow keys, without requiring typed text.
An empty/whitespace completion result or a bang without a query cancels. In stock
completion, Space inserts a space in this prompt and Tab completes; explicitly
customized Space bindings are kept. Ordinary `M-x launcher` is unchanged.
The package loads only when this command runs; missing installation produces a
setup error, and other Portal features and custom commands do not require it.
Discovery, missing-bundle and open errors close the panel and can be retried;
refresh a stale index before trying a moved app. An empty Spotlight index reports
an error and is retried on the next invocation. See
[integration checks and timings](docs/launcher-applications.md).

The explicit buffer API remains available:

```elisp
(portal-launcher-show (get-buffer-create "*Launcher*"))
(portal-launcher-resize 713 407)
(portal-launcher-hide)
(portal-launcher-show)          ; same frame and content
(portal-launcher-mode -1)       ; delete frame and release shortcut
```

`M-x portal-launcher-toggle` uses the same command as the shortcut. To run
another interactive command, configure `portal-launcher-command`:

```elisp
(defun my/launcher-example ()
  (interactive)
  (message "Selected %s" (completing-read "Choose: " '("Apple" "Orange") nil t)))
(setopt portal-launcher-command #'my/launcher-example)
(portal-launcher-present)      ; run the configured command directly
;; Or supply a command for just this invocation:
(portal-launcher-present #'my/launcher-example)
```

Each call chooses how the panel looks, without registering a shortcut or
changing the completion setup:

```elisp
;; Only the prompt and an inline completion UI, such as Vertico:
(portal-launcher-present #'my/launcher-example :kind 'minibuffer)
;; Any function of no arguments; its value is returned:
(portal-launcher-present (lambda () (read-string "Name: ")) :kind 'minibuffer)
;; A buffer window without mode lines:
(portal-launcher-present #'my/buffer-command :kind 'buffer :mode-line nil)
```

`:kind 'buffer`, the default, shows a buffer window above the panel's own
minibuffer, as before. Buffers the function displays appear in the panel, and
windows it creates there are deleted when the panel hides. `:kind 'minibuffer`
makes the whole panel a minibuffer: the prompt is its first line, an inline
completion UI follows directly below, and unused lines stay empty at the
bottom. Buffers the function displays appear nowhere, so stock completion's
`*Completions*` list is not shown, though Tab still completes and Return
accepts; Vertico, Icomplete's vertical mode or Fido show candidates in the
panel. Commands that display or preview buffers, split windows or otherwise
need a buffer window require `buffer`.

Both kinds have `portal-launcher-size`, and Emacs does not fit the panel to its
content. A completion UI that asks for more lines than the panel holds is
clipped at the bottom; the default 420 points hold Vertico's default 10
candidates. Lower the count or raise the height. Changing kind replaces the
dedicated frame; presenting the same kind again reuses it.

`:mode-line nil` hides the mode lines of the panel's windows, including windows
created and buffers switched during the call; the default, t, shows each
buffer's own. It sets the `mode-line-format` window parameter, so the same
buffers keep their mode lines in other frames, and restores each window's
earlier parameter when the panel hides. A minibuffer panel has none.

The function is an interactive command, called with `call-interactively` so it
sees a prefix argument, or any function of no arguments, called with `funcall`.
It runs with the buffer `*Portal Launcher*` current, in the panel's own
minibuffer and with the user's completion setup, including Vertico, Orderless
and Marginalia. Nested prompts stay in the panel. An invalid function or option
signals an error before anything is shown.

Success hides the panel; Escape, C-g, another invocation, `portal-launcher-hide`,
or losing keyboard focus cancels the entire session. Errors propagate after
cleanup. Frame deletion and disabling unwind prompts before releasing the frame.
Cancellation returns focus to the previous app while the panel still owns the
keyboard; a successful external action or click-away preserves the destination
app's focus. Emacs's original window selection is restored without activating
its application. Display rules, presentation options and cancellation keys last
only for the session.

Functions must be synchronous. Invoke after any existing minibuffer has
finished. Functions that deliberately use other frames or catch arbitrary
throws need explicit wrappers. Set `portal-launcher-command` back to nil for
the plain reusable buffer, reusing any content supplied to
`portal-launcher-show`.

The mode's chord is the [global shortcut](#global-shortcuts) named
`portal-launcher`, which calls `portal-launcher-toggle`; its notation and
delivery are those of every global shortcut. Change the chord with Customize or
`setopt`; changes take effect immediately while enabled. For example:

```elisp
(setopt portal-launcher-shortcut "Control-Option-Command-L")
```

The default does not claim Command-Space. A chord that macOS reports as
unavailable raises an error and retains the previous registration; failed
`setopt` also retains the previous option value. Repeated enable keeps one
registration, successful rebind releases the old chord, and
`portal-launcher-mode -1`, unloading, or exiting releases it, leaving other
global shortcuts set. After changing the option with `setq`, enable the mode
again to apply it. A press that waits while the panel is shown some other way,
such as with `portal-launcher-show`, still toggles it.

Start in a disposable graphical Emacs. This feature depends on internal Emacs
NS behavior, and a native defect can crash the hosting Emacs. Initially it accepts
only GNU Emacs NS **31.1**, revision
`a360712c9d272d950d8d8255ef74570f7e90b7d9`. Rebuild Portal and restart Emacs before
using the new bindings. Native-compiled Emacs also needs a working
`modify-frame-parameters` and `delete-frame` trampolines so native callers cannot
bypass the frame guard or delete a frame with live session prompts.
Leave `native-comp-enable-subr-trampolines` enabled; if the trampoline is missing
and Emacs cannot compile it, enabling the launcher fails before creating a frame.

Customize `portal-launcher-size` (default `(720 420)`), `portal-launcher-offset`
(`(0 0)`, positive right/down), `portal-launcher-screen` (nil uses the pointer's
monitor), `portal-launcher-font`, `portal-launcher-shadow`, and
`portal-launcher-corner-radius`. Show again to apply them. Size and offsets use
AppKit logical points, independent of Retina scale. The panel centers within the
monitor's usable area, clamps onscreen, and repositions when displays change.
`portal-launcher-frame-parameters` supplies initial colors, fringes and borders.

Fonts, buffers and appearance remain ordinary Emacs customization. The frame's
native role is fixed: changing decorations, fullscreen, parentage, toolbars or
focus policy is rejected. Deleting the launcher frame is supported; the next
show creates a new one. Hide preserves the launcher's content and returns Emacs
selection to the previous ordinary window without changing that window's buffer.

For plain buffer presentation outside a command session, finish or cancel an
active launcher minibuffer before hiding it. Outbound native drag-and-drop is
cancelled. The [daily-use guide](docs/launcher-daily-use.md) records the user's
IME and VoiceOver validation.
See [implementation and measured geometry](docs/launcher-native-panel.md).

## Shared keyboard controls

Emacs is the system, and each native view an app running in it, as a page runs
in a browser. Terminal, Excalidraw, and HTML/Markdown views behave as their apps
do outside Emacs, and a chord the app does not use reaches Emacs:

| Keys in a view | Where they go |
| --- | --- |
| Typing: plain and Shift keys, arrows, Return, Tab, Escape | The app, always |
| A chord (Control, Option or Command with a key that types a character) the app uses | The app |
| Command-C, Command-V | Copy and paste, in every view |
| Command-F, Command-R | Find and reload, in a web view with a toolbar |
| Any other chord | Emacs, as if typed in the view's buffer; Emacs reads the rest of its key sequence |
| Command-Escape | Return to Emacs and stay there |
| `RET`, or a click, while Emacs owns a Portal buffer | Enter the app |

So `s-x`, or any Emacs binding of yours on Command, works inside a terminal
without leaving it, and `C-x b` works on a page that does not use Control-X.
A terminal's program gets every Control and Option chord: tmux keeps `C-b`.
A page gets each chord first, as it would in a browser, and keeps those it uses.
Plain keys never reach Emacs, since Emacs binds single keys too; for an Evil
Space leader, bind a chord to it as well, such as `(evil-set-leader 'normal
(kbd "s-'"))`. Splits, buffers and switching stay Emacs's job: views have no
tab or split keys.

Commands finish their minibuffer interaction before returning to the selected
native view; explicit unfocus, errors, and selecting an ordinary buffer leave
Emacs in control. `C-g` cancels a key sequence Emacs is reading. The native
toolbar's ownership dot is hollow when Emacs owns the keyboard, green when the
view owns it, and blue while Emacs reads a command. Click the dot to enter or
return to Emacs. No global physical keybinding is installed in ordinary buffers.

The 28 pixel toolbar reserves space above the content. Web pages have back,
forward, find, zoom, and reload; Markdown and HTML previews also have a table of
contents, and Markdown previews an **Open in Emacs** button. Terminals have text
size controls. Excalidraw and quick
terminals have no toolbar. The command that opens a web view chooses its toolbar.
`(setq portal-toolbar nil)` hides toolbars live, and `t` restores them. Colors
follow Emacs faces and update after theme changes.

`portal-zoom-in`, `portal-zoom-out`, `portal-zoom-reset`, `portal-toggle-toc`,
`portal-find`, `portal-web-back` (`l`), and `portal-web-forward` (`r`) use the
same state as the buttons. Terminal equivalents are
`portal-terminal-text-size-increase`, `portal-terminal-text-size-decrease`, and
`portal-terminal-text-size-reset`, and in a terminal Command-Plus, Command-Minus
and Command-0 do the same, with or without a toolbar. Command-F runs `portal-find` in a web view
with a toolbar, and Command-R reloads the page as the Reload button does, unless
the page uses those chords itself; in Portal's own web buffers, `s-f` and `s-r`
(`portal-web-reload`) also work while Emacs owns the keyboard. Find opens a field inside the strip; Return
and Shift-Return navigate matches, and Escape closes it. State survives hiding
and redisplaying a pane; reload preserves zoom and the TOC. Killing the buffer
releases it.

A terminal's native bindings can claim a chord its program would otherwise
get, such as a Control chord (see [the input bridge](docs/terminal-input-bridge.md)).
macOS's own shortcuts, such as Command-Space, still come first.

Click inside a page or press `RET` to interact. A click that enters a view also
selects the Emacs pane showing it, so the selected pane and the keyboard always
agree. After returning to Emacs, `q` hides the web view and `g` loads its page
again. The mode line and minibuffer remain available.

Restart Emacs after rebuilding the native module to try these controls.

## Local Excalidraw drawings

Run `M-x portal-excalidraw` for a new drawing, then Command-S or `C-x C-s` to
choose its filename and save. Open existing `.excalidraw` files normally with `C-x C-f`
or Dired; they enter `portal-excalidraw-mode` automatically. A prefix argument
to `portal-excalidraw` prompts for an existing or new file.

- Draw, type, paste text/images, and use the normal Excalidraw editing tools.
- Command-S, `C-x C-s` and the drawing's **Save** button save through Emacs.
  The drawing does not use `C-x`, so `C-x C-s` reaches Emacs even while the
  drawing has the keyboard. `C-c C-r` in the buffer reopens the drawing.
- Command-Escape returns keyboard focus to Emacs; `RET` re-enters the drawing.
  Bare Escape remains available for drawing/text editing.
- Each drawing buffer has one web view running the Excalidraw hosted app. It
  opens at once and loads the drawing when the app host is ready. Switching
  buffers hides it without losing its contents, selection, or undo history. In
  splits, the view follows the selected window showing that buffer. Independent
  drawings can be displayed together.
- Drawings use standard Excalidraw JSON, including embedded image data. Emacs owns
  file saving, modified indicators, backup settings, auto-save, and overwrite
  checks. Untitled modified drawings also participate in save/close prompts.
- `M-x revert-buffer` reloads the file from disk. `C-c C-r` reopens a failed
  view using the buffered drawing, preserving unsaved buffered changes but
  resetting undo history. Use it after restarting the app host if more
  Excalidraw assets need loading. A stopped host does not unload an already
  open drawing.

Excalidraw 0.18.1, React, CSS, lazy modules and fonts are bundled into
`portal-host`. The build installs pinned npm dependencies with Bun; runtime use
needs no npm packages or internet connection. The page blocks external asset
requests, CDN font fallbacks and remote embeds. Document persistence uses neither
localStorage nor IndexedDB. The current integration focuses on local documents;
cloud collaboration, online library installation, persistent personal libraries,
and image export are not integrated.

Restart Emacs after rebuilding the native module. See
[the bridge](docs/editor-bridge.md) for implementation and tests.

## Quick project terminal

Run `M-x portal-terminal-toggle` to summon a scratch terminal in the bottom half
of the frame. Run it again to dismiss the panel and return to your editing
window, even if the terminal no longer has keyboard focus. No global shortcut
is installed. Call `(portal-terminal-toggle)` from Lisp or bind the command to
whatever Emacs key sequence you prefer. For example, in your own configuration:

```elisp
(keymap-global-set "s-`" #'portal-terminal-toggle)
```

A Command chord reaches Emacs from a terminal, so the same key dismisses the
panel while Ghostty has keyboard focus. See [the input
bridge](docs/terminal-input-bridge.md) for how native events reach Elisp, and
for native bindings, which claim a chord such as a Control chord that the
terminal's program would otherwise get.

Each project has one quick shell, which you can summon from any Emacs frame.
The panel and its remembered height belong to each frame, but summoning the
shell in another frame brings the same shell into that frame's panel. A new
shell starts at the project root of the current file or Dired buffer, which
`portal-project-function` finds, with `project.el` by default. Help
and other auxiliary buffers use the most recently selected file/Dired directory
in that frame.
Outside a project, the file's directory is used; with no editing context,
`portal-terminal-quick-directory` defaults to home. Remote contexts are rejected.

Dismissal only hides the panel: the shell, current directory, environment,
partially typed input, scrollback, and foreground programs remain intact.
Reopening never sends `cd` or starts a replacement shell. A command such as
`npm run dev` keeps running while hidden; reopen and use `C-c` to interrupt it.
Switching files or projects does not automatically change an already visible
panel. Dismiss it, then summon again to select the new project's quick shell.

Quick terminals have these commands, which you can bind to Command chords:
`portal-terminal-quick-dismiss` dismisses without ending the shell,
`portal-terminal-quick-reset` confirms and resets to a fresh shell at this
project's root, and `portal-terminal-quick-forget` confirms and forgets this
project's quick shell. Reset/forget target the visible panel when there is
one, otherwise the current editing project. Escape, `q`, and `C-g` remain
terminal input. Clicking into the
editor leaves the panel visible. Its initial height is controlled by
`portal-terminal-quick-height` (default `0.5`); dismissal remembers manual resizing.

Quick terminals are excluded from ordinary Portal terminal selection, numbering,
and cycling. They have no naming or multiple-instance workflow. A busy quick
shell remains busy until its command finishes or you interrupt/reset it.
Deleting a frame only hides its panel's shell. Quitting Emacs ends the session;
this does not provide persistence across Emacs restarts. A shell that exits is
not silently restarted: use reset when you want a new one.

Run the buffer/window/project tests with `ctest --test-dir build -R quick-terminal`.
`ctest --test-dir build -R terminal-metadata` checks terminal names, projects and
directory reports with the fake native module: names that tell projects named alike
apart, lookups by root after renames, reports while hidden, changes made while a
terminal opens, ignored directory reports, reassignment, exits and kills, completion over every field with Emacs's own
styles, and quick terminals keeping their names and projects.
The graphical terminal suite also tests a Command chord toggling the panel from inside
it, and a real foreground process continuing while the quick panel is hidden.

## Native Ghostty terminal

To compare terminal performance, run `./benchmark.sh --label portal` inside the
embedded shell and `./benchmark.sh --label ghostty` in standalone Ghostty.
See [benchmark methodology and FPS research](docs/terminal-benchmark.md) for
latency, frame timing, optional Instruments captures and interpretation limits.

After `./build.sh`, load `portal.el` and run `M-x portal-terminal`, or launch a
fresh graphical Emacs:

```sh
emacs -Q -L "$PWD" -l "$PWD/portal.el" --eval '(portal-terminal)'
```

This embeds a real Ghostty Metal terminal surface inside the pane. Ghostty owns
the PTY, shell, terminal state, fonts, rendering, selection and scrollback.
It starts your normal shell in the current local `default-directory`; interactive
commands, Vim and other TUIs use the real terminal protocol engine. It does not
convert output to Emacs text or use WebKit or the Bun server.

- Click the terminal or press `RET` in its buffer to give it keyboard focus.
- The shell gets typing and every Control and Option chord, including Escape,
  `C-g`, `C-c` and tmux's `C-b`. A Command chord reaches Emacs, which runs it in
  the terminal's buffer, then gives the terminal the keyboard back.
- `Command-Escape`, or clicking **Return to Emacs**, leaves keyboard control
  with Emacs. Use normal Emacs bindings, then `RET` to re-enter Ghostty.
- Select with the mouse and use `Command-C` / `Command-V` for the macOS clipboard.
  Scroll with the trackpad or mouse wheel. Non-Latin IME composition has not
  been manually verified.
- Hidden buffers keep their shells running: `quit-window` or switching buffers
  hides the terminal, and showing the buffer again brings the same shell back.
  Deleting the frame showing a terminal also only hides it. Killing a terminal
  buffer or running `portal-terminal-close` in it ends that shell.
  `portal-terminal-close-all` ends all embedded shells.

Terminals come with these commands, and no keys: bind the ones you use in
Emacs, on Command chords to reach them from inside a terminal too.

| Command | Action |
| --- | --- |
| `portal-terminal-new` | New independent terminal buffer |
| `portal-terminal-split-below` / `-split-right` | Split below / right with a new shell |
| `portal-terminal-next` / `-previous` / `-last` | Next / previous / last terminal buffer |
| `portal-terminal-select-index` | Select a terminal by the digit of its key, such as `s-1` |
| `portal-terminal-choose` | Choose a terminal by name, project, directory or title |
| `portal-terminal-rename` | Rename the terminal buffer |
| `portal-terminal-zoom` | Zoom the pane; repeat to restore the layout |
| `portal-terminal-kill-pane` | End the shell, asking first while it runs, and close its pane |

```elisp
(keymap-global-set "s-n" #'portal-terminal-new)
(keymap-global-set "s-]" #'portal-terminal-next)
(keymap-global-set "s-[" #'portal-terminal-previous)
(keymap-global-set "s-w" #'portal-terminal-choose)
```

These are Emacs operations: terminal buffers stand in for tmux windows and Emacs
windows stand in for panes. Splits, buffers and switching stay Emacs's job, and
a terminal has no tab or split keys of its own. For tmux itself, run it inside
a terminal: it gets its `C-b`. There are no saved per-terminal pane layouts or
tmux copy mode. Each terminal buffer has one Portal view,
which appears in the selected pane showing the buffer; other panes showing the
same buffer display only its text ([ADR 0001](docs/adr/0001-one-portal-view-per-buffer.md)).
Terminals belong to no frame: show a terminal buffer in another frame and its
view moves there, with the same shell and scrollback. Selection, numbering and
cycling cover every terminal. Different terminal buffers can display and run
simultaneously.

### Names, projects and directories

Portal names a terminal buffer once, when it starts: `*terminal: portal*` for a
shell in project `portal`, `*claude: portal*` for `portal-terminal-start`
running `claude`, and Emacs adds `<2>` to repeats. Projects whose roots end the
same way, such as two worktrees both called `portal`, read `research/portal`;
outside a project, the abbreviated start directory stands in. Rename a
terminal with `portal-terminal-rename` or `rename-buffer`: Portal never renames it again,
whatever title its programs set.

A terminal belongs to the project of the directory it started in, which
`portal-project-function` finds. The default uses `project.el`; Projectile
users can set it to `projectile-project-root`. Changing directory in the shell
leaves the project alone. `M-x portal-terminal-set-project` assigns another
project, or none with a prefix argument. Quick terminals always belong to the
project they were opened for.

When the shell reports its directory, the buffer follows it. Its
`default-directory` changes, so `C-x C-f`, Dired and new terminals start there,
and so does `list-buffers-directory`, which Ibuffer and `list-buffers` show.
Ghostty's bundled shell integration reports the directory at every zsh or bash
prompt, and any program can report one with OSC 7. Ghostty accepts reports only
from this host. Portal also ignores one that is not an existing local directory,
such as a path inside a container, and never lets a report reach TRAMP. Until
a report arrives, the buffer keeps the directory the terminal started in.

The mode line shows `:exited` once a terminal's program ends; the buffer and its
last output stay until you kill it.

Other packages can use the same facts. `(portal-terminal-buffers PROJECT QUICK)`
lists terminals in creation order: with PROJECT, a root, only that project's,
wherever their shells are now, and with QUICK, quick terminals too.
`(portal-terminal-metadata BUFFER)` returns a terminal's `:name`, `:project`,
`:directory`, `:title`, `:exited` and `:quick`. Portal caches these as the
native terminal reports changes, including while it is hidden. They are only
facts: a title is whatever a program set, not a process name, and a live shell
may be busy or idle.

### Choosing terminals

`M-x portal-terminal-choose` lists every terminal.
`M-x portal-terminal-choose-project` lists the current project's: run from a
terminal, the project it belongs to, and otherwise the project of the file or
Dired buffer you are editing, however far its shells have moved. `M-a` switches
between the two lists and keeps what you typed. Each candidate shows the
terminal's name, project, directory and title, and completion matches any of
them, out of the box: its category, `portal-terminal`, tries the `basic` and
`substring` styles before your own, as Emacs does for buffers, and
`completion-category-overrides` can change that. With Orderless,
`portal api npm` finds a terminal titled `npm run dev` in project `portal`'s
`api/` directory. Exited and quick terminals are annotated.

The terminals you selected most recently come first, and `RET` on empty input
takes the first; the current terminal comes last. The order is fixed when the
list opens, and previews never count as selecting. Cycling with
`portal-terminal-next`, `-previous` and `-select-index` keeps creation order.

The New group starts a terminal at the project's root, or outside a project in
the current directory; "New named terminal…" asks for a name first, and
`server` gives `*server: portal*`. Completion requires a listed entry, so typing
alone never starts a shell. Quick terminals are left out unless
`portal-terminal-choose-quick` is set, and a chosen one opens in its panel. From
a quick panel, the choice opens in the editing window behind the panel, which
stays; cancelling returns to the panel.

Killing a terminal buffer whose program is still running asks first, however it
is killed: `C-x k`, Ibuffer, Embark or `portal-terminal-kill-pane`. Ghostty's program is not an
Emacs process, so Emacs's own question for a running process never comes up.
Set `portal-terminal-confirm-kill` to nil to kill without asking. A terminal
whose program exited goes without asking, and quick reset and forget keep their
own question. `M-x portal-terminal-select` selects a terminal by name, where
terminals of its kind show.

### Agent dashboard

Run `claude`, `codex` or `pi` in an ordinary Portal shell, then open `M-x portal-agents`.
The agent appears automatically, even before its first prompt or while waiting
at a trust dialog. Discovery also finds sessions started before the dashboard
opened, while it was hidden, or before discovery was enabled. No agent setup
or per-session tracking is needed. This is tested with Claude Code 2.1.288 and
Codex CLI 0.155.1 and Pi 0.87.0. Pi activity needs the extension setup below;
its identity is discovered without setup.
Rebuild and restart Emacs to give new terminals the discovery marker.

Each row shows its terminal name, agent, assigned project, terminal process
state, agent activity, current directory and reported title. Claude activity comes
from [`claude agents --json`](https://code.claude.com/docs/en/agent-view#list-sessions-as-json):
`busy` becomes `working`, and `waiting` and `idle` keep their names. **Idle does
not mean success.** At startup, at a trust dialog, on an unsupported status, or
when the status command fails, activity is `unknown`; hover it for the reason.
A process-discovery failure also makes Process `unknown` until recovery.
Set `portal-agents-claude-program` to an absolute path if Claude is not on Emacs's
`exec-path`.

Codex rows are labelled **Codex (title)**: activity is inferred from its default
terminal title. A leading braille spinner means `working`, `Action Required`
means `waiting`, another nonempty title means `idle`, and a missing or blank
title means `unknown`. Hover activity for its source and limitations. Startup
can read as working before the first prompt; non-approval menus and model errors
can read as idle. Custom title settings can invalidate the mapping. Titles are
terminal-wide and carry no process ID, so this is a best-effort inference from
the current cache, not proof that a particular run emitted it. Keep Codex's
default title settings for this source. Notifications and progress do not affect
Codex activity; focus and notification suppression do not imply idle.

Pi rows are labelled **Pi (progress)**. Install the bundled lifecycle extension
once (from the Portal repository root):

```sh
mkdir -p ~/.pi/agent/extensions
cp -i extensions/portal-pi.ts ~/.pi/agent/extensions/portal-pi.ts
```

Keep Pi's `terminal.showTerminalProgress` off (its default), and disable other
extensions that write OSC 9;4 progress. Portal does not change Pi settings.
Then enable this source in Emacs:

```elisp
(setopt portal-agents-pi-progress t)
```

Later plain `pi` launches load the extension automatically. In an existing Pi
session, `/reload` loads it without relaunching. Only Portal TUI sessions emit
reports; RPC, print mode and terminals outside Portal do not. The extension
reports working at `agent_start`, waiting during blocking extension UI prompts,
and idle only when `ctx.isIdle()` agrees, using `agent_settled` after work.
`agent_end` does not settle retries, automatic compaction or queued continuation.
Failures and cancellations can settle to idle; idle does not mean success.

Only native progress reports received **after discovery** count. Until then,
activity is `unknown`, even if an earlier startup report is cached. Opening the
dashboard and using `/reload` or `/new` provides fresh evidence; a later turn
also does. A hidden dashboard preserves evidence for a previously discovered
run and checks its process identity on redisplay. Runs first discovered on
redisplay wait for new evidence. Reports carry native receipt times so delayed
metadata and repeated states cannot reuse a report from before discovery.

This is a configured source, not a sender-authenticated protocol: OSC progress
has no PID. Competing writers or output received late from another process can
mislead it. Keep the extension as the sole progress writer. Unsupported states,
missing reports and extension shutdown become unknown. There is no heartbeat:
silence alone cannot distinguish an unchanged state from a broken extension.
In Pi 0.87.0, manual compaction success precedes the idle flag clearing and has
no subsequent settlement event, so it becomes unknown until another lifecycle
report. Built-in menus are not covered by extension UI prompt events. Hover
activity to see its source or why evidence is missing.

The dashboard is an ordinary Tabulated List buffer with no native view, web
page or app host. Move, isearch, or press `S` to sort; `RET` visits the correct
terminal and gives it the keyboard, including hidden terminals, quick panels,
and terminals in another frame. This also works in Evil's normal state with
evil-collection's Tabulated List bindings. Renaming a buffer or changing
directory does not change its identity. Two agents in the same directory remain
distinct.

Discovery uses foreground processes tied to the exact terminal, never titles,
progress bars or project paths. Exiting an agent removes its automatic row even
while the shell keeps running; relaunching creates a new agent session. A
suspended (Ctrl-Z) agent disappears until foregrounded. Remote agents, agents
inside tmux, or launches that remove `PORTAL_TERMINAL` are not discovered.
The marker must agree with OS ancestry on the same controlling TTY back to
Emacs; inheriting it inside a nested PTY is insufficient. Native agent binaries
and known runtime script launches are recognized. The executable must match the
runtime whose argument grammar is parsed, allowing supported aliases. Runtime
options are parsed by their documented arity; unknown options, inline code and
ambiguous package tasks are not guessed. Such terminals can still be tracked
manually.

Optional `M-x portal-agents-track` (`t`) tracks any terminal; a prefix argument
also asks for a label, and `(portal-agents-track BUFFER LABEL)` works from Lisp.
An explicit label overrides the agent label without creating a second row. Manually
tracked terminals remain after program exit, marked `exited`, until closed or
untracked. Other harnesses have unknown activity. `portal-agents-untrack` (`u`)
leaves the program running and hides a discovered run until it leaves the
foreground or is explicitly tracked again; later runs are discovered normally.

While shown, one two-second timer scans processes and reads cached metadata.
Opening or showing the dashboard scans immediately. Codex activity is read from
cached titles after a successful scan, and Pi reads cached progress without a
status subprocess. Title glyph-class and
progress changes trigger asynchronous Claude status queries; spinner animation
within a class does not. Queries never overlap, time out after five seconds,
and retry after a transition, every four seconds for unknown status, or at a
30-second safety poll. A transition during a query schedules a fresh query;
results cannot attach to a replaced terminal or process. Leading activity
markers are omitted from agent titles so spinner frames do not redraw rows.
Hidden dashboards do no discovery or status collection, and cancel pending
queries. Existing native metadata records continue for hidden terminals.

Rows are rewritten only when displayed facts change, preserving sorting,
selection, each window's position and keyboard focus. `g` refreshes and `q`
hides the dashboard. `portal-agents-toggle-live-update` or
`(setq portal-agents-live-update nil)` leaves collection manual: open, show, or
`g`. Set `portal-agents-live-update-interval` to change the interval the next
time updates start. Set `portal-agents-discover-claude` or
`portal-agents-discover-codex` or `portal-agents-discover-pi` to nil to disable
that agent's automatic discovery; disable all three to retain only manual tracking. Minimized/invisible frames stop
collection at the next tick.

With 100 tracked terminals, a refresh with nothing changed took under 1 ms in
graphical Emacs and redrew nothing. When every title changed, it took about
7 ms plus the redisplay. See the
[measurements](docs/emacs-agent-dashboard-research.md#measurements).

### Consult and Embark

Loading `portal.el` automatically enables `portal-terminal-consult-mode` when
Consult is loaded, in either load order. No extra configuration is needed:
`consult-buffer` then accepts `t SPC` to show only Portal terminals, and the
terminal pickers use Consult with your existing completion UI. Portal does
not load Consult itself or require it to be installed. Vertico, Orderless and
Marginalia work through ordinary completion.

To opt out, set `portal-terminal-consult-auto-enable` to nil before loading
Portal and Consult. You can also disable the active integration with
`M-x portal-terminal-consult-mode`.

The optional Embark adapter and a project picker binding can be enabled in
your configuration:

```elisp
(with-eval-after-load 'embark
  (require 'portal-terminal-embark)
  (portal-terminal-embark-mode))
(keymap-set project-prefix-map "t" #'portal-terminal-choose-project) ; C-x p t
```

With `portal-terminal-consult-mode`, the pickers read with Consult, which adds
preview and narrowing: `t` narrows to terminals and `n` to the New group.
`consult-buffer` and `consult-project-buffer` gain a Terminal group, hidden
until you narrow with `t` (type `t SPC`, or your `consult-narrow-key` then
`t`). There it holds every terminal, or the terminals assigned to Consult's
project, and the default list still shows each terminal once, as a buffer.

`M-.` previews the terminal at point in the window you started from, or in the
editing window behind a quick panel. Its live view moves there, even from
another frame, and goes back when you move on or cancel; nothing counts as
selected until you accept. The program sees the preview window's size
meanwhile, which is why preview waits for `M-.` by default. A preview never
takes the keyboard: typing stays in the minibuffer. Quick terminals are not
previewed. To preview as you move, or change the narrowing key:

```elisp
(consult-customize portal-terminal-consult-source portal-terminal-consult-project-source
                   :preview-key '(:debounce 0.3 any) :narrow ?T)
```

`consult-buffer`'s own Buffer group previews terminals as it does any buffer,
following `consult-preview-key`. Marginalia annotates terminal candidates as
buffers, with their mode and directory, in place of Portal's exited and quick
notes.

With `portal-terminal-embark-mode`, terminal candidates stay buffer candidates,
so Embark's buffer actions work, and `E` exports them to Ibuffer. A target that
is a live terminal, in any prompt, Ibuffer or Embark Collect, also has these
actions; any other buffer keeps Embark's buffer map:

| Key | Action |
| --- | --- |
| `RET` | Select it where terminals of its kind show |
| `r` | Rename it |
| `d` | Open Dired in its directory |
| `c` | Start another shell in its directory: a new shell, not a copy |
| `W` | Copy its directory |
| `p` | Assign it to another project, or with `C-u` to none |
| `k` | End it, asking as killing it asks |

Actions reach the session itself, even after a rename in the same prompt.
Candidates mixed with the New group export to Embark Collect, as mixed Consult
lists do; narrow with `t` first for Ibuffer.

Projectile users set both project functions. Consult's current hook is
`consult-project-function`, which takes MAY-PROMPT; the older
`consult-project-root-function` no longer exists.

```elisp
(setq portal-project-function #'projectile-project-root
      consult-project-function (lambda (_may-prompt) (projectile-project-root)))
```

While a terminal has the keyboard, your Command bindings for these commands
reach Emacs, in quick terminals too:

```elisp
(keymap-global-set "s-b" #'consult-buffer)
(keymap-global-set "s-t" #'portal-terminal-choose-project)
```

The chosen terminal gets the keyboard once the minibuffer closes, and cancelling
returns it to the terminal you came from.

The adapters are tested with GNU ELPA Consult 3.10, Embark 1.2, Vertico 2.15
and Orderless 1.8, and with MELPA Consult 20260829.1558 and Embark
20260610.302. They use Consult's source helpers, such as `consult--multi` and
`consult--buffer-preview`, and Embark's `embark--targets`: internal API,
confined to `portal-terminal-consult.el` and `portal-terminal-embark.el`.

`ctest --test-dir build -R terminal-choose` checks the pickers with Emacs's own
completion and the fake native module: recent-use order and creation-order
cycling, projects by assignment, `M-a`, the New group, quick panels, closed
terminals and the question before killing. `-R 'terminal-(consult|embark)'`
checks the adapters against the releases above, which CMake downloads into
`build/elpa` and verifies by hash. A keyboard macro types into a real
minibuffer, so Consult's narrowing, preview and lookup, and Embark's targets,
actions and export to Ibuffer, run as they do for you.

Configure in Lisp after loading `portal.el` (changes apply to running terminals):

```elisp
(setq portal-terminal-theme "Dracula") ; nil follows system light/dark appearance
```

`portal-terminal-theme` accepts an exact, case-sensitive name from
`(portal-terminal-themes)`. Set it with `setq` or Customize, including in your
init file before loading Portal. Changes recolor all running terminals, including
hidden ones, and apply to new terminals without restarting existing shells.
Set it to `nil` to restore Alabaster in light mode and Afterglow in dark mode.
Named themes stay fixed across system appearance changes.

A Command chord from a terminal runs in its buffer, with its keymaps. Commands
finish their minibuffer interaction before focus returns to the selected
terminal. Switching to an ordinary buffer keeps Emacs in control. A custom
command can call `portal-terminal-unfocus` to stay in Emacs even when a terminal
is selected. Errors also leave focus in Emacs.

`portal-terminal-native-map` adds opt-in standalone or nested shortcuts to all
terminals, claiming chords their programs would otherwise get, such as Control
chords; `portal-terminal-quick-native-map` overlays it for quick terminals.
Use `portal-terminal-bind-key` / `portal-terminal-unbind-key` for live changes,
or call `portal-terminal-refresh-bindings` after direct keymap edits. These maps
start empty and do not install global shortcuts. First chords are one modified
ASCII key in `kbd` notation, where Meta means Option and Super means Command;
the rest of a sequence uses normal Emacs keys.

The module's C core catches Command chords and registered first chords, and notifies Emacs through the
notification pipe that every Portal view shares
([details](docs/terminal-input-bridge.md#the-notification-pipe)). It holds fast follow-up keys until Lisp is ready, and Lisp reads the keymap and runs the
command. Ordinary terminal input and output stay native; there is no polling timer
or terminal redraw through Lisp.

The terminal uses the pinned [GhosttyTerminal Swift wrapper](https://github.com/Lakr233/libghostty-spm/tree/1.6.20260909)
and its Ghostty build. Themes come from the wrapper's bundled catalog; standalone
Ghostty preferences are not loaded. Ghostty's
app-level window/tab commands are not implemented here, and its own Command-key
bindings never apply: the core gives Command chords to Portal's shortcuts or Emacs. The Emacs buffer contains
instructions, not live terminal text, so ordinary Emacs search and movement do not
operate on the terminal. The native view still shares Emacs's main thread for
input and presentation; this is not a guarantee of latency parity during Emacs GC
or long-running Lisp.

`(portal--inspect (portal-view-target))` reports the selected terminal's actual
native surface, grid, bounds, focus and title. `(portal--terminal-text TARGET)`
selects all native scrollback and returns its text for inspection; it leaves
that selection active. Neither is polled during normal use. Restart Emacs after
rebuilding a module it has already loaded.

The graphical terminal tests exercise a real shell, alternate-screen output,
native keyboard and clipboard input, focus return, resizing, hidden-session
continuity, shell termination, and editing/saving a file in Vim. A real shell's
directory reports, percent-encoded and from Ghostty's zsh or bash integration,
reach the buffer's metadata and `default-directory`; a hidden terminal's title
arrives without renaming it; and an exit is reported when it happens, keeping the
buffer, its output and the keyboard until the next key. They also exercise
Command chords running Emacs commands with rapid follow-up keys, `C-b` and `C-a`
reaching the shell, multiple sessions and splits, runtime binding
registration/unbinding, quick-only shortcuts, shifted characters, literal
binding bytes, cancellation, and minibuffer focus.
Batch binding tests run with `ctest --test-dir build -R terminal-bindings`, and
batch tests of the view lifecycle (opening, splits, selection, `quit-window`,
showing the buffer elsewhere, moving between frames, deleting a frame and
killing the buffer) run with `ctest --test-dir build -R view`. Batch Emacs has
one frame, so these tests open a second, suspended terminal frame on a
pseudo-terminal.
Build the test-only AppKit event injector (no Accessibility permission required):

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -bundle \
  -I "$(cat build/emacs-include.txt)" test/terminal-input.m \
  -framework AppKit -framework WebKit -framework Carbon -framework IOSurface \
  -o build/test-terminal-input.dylib
emacs -Q --module-assertions -L "$PWD" -l "$PWD/portal.el" \
  --eval "(module-load \"$PWD/build/test-terminal-input.dylib\")" \
  -l "$PWD/test/portal-terminal-tests.el" \
  --eval '(ert-run-tests-interactively "^portal-terminal-")'
```

To check program launches with a controlled shell environment, run
`sh test/terminal-shell-startup.sh` after building. It starts a disposable graphical
Emacs with a minimal PATH and temporary zsh dotfiles, then verifies shell-side
program lookup, login and interactive startup, literal arguments, terminal
metadata, and missing-program errors. Set `EMACS` to choose its executable.

`./build.sh` runs the `dev` CMake configure and build presets. For development,
configure once before opening native source files; this generates editor metadata
without compiling the module:

```sh
cmake --preset dev
cmake --build --preset dev
```

CMake locates Emacs, builds the Bun host, and invokes the native Swift package.
`native/Package.swift` links three targets into one module: `PortalCore`,
the portable C core; `PortalProcesses`, Darwin process collection in C; and
`Portal`, the Swift backend containing the host, web, terminal, input and toolbar code. There are no separate feature libraries
or plugin builds. Configuration writes the discovered header
path to `build/emacs-include.txt`, which the package also reads for editor support.

Use SourceKit-LSP with Eglot for Swift and the C bindings, with `native/` as its
SwiftPM project root. Xcode provides the server. Reconnect Eglot after switching
from the former CMake compilation database. No project-specific header paths
belong in your Emacs configuration. Reconfigure after changing Emacs or SDKs.

For TypeScript editing, install the host's development dependencies and run its
checks:

```sh
bun install --cwd host --frozen-lockfile
bun run --cwd host check
bun run --cwd host typecheck
```

Biome checks host formatting, imports, and lint rules using `biome.json`.
Indentation uses tabs. Run `bun run --cwd host format` to format the host sources.
Generated assets and dependencies are excluded through Git's ignore rules.

`host/tsconfig.json` supplies strict TypeScript settings and Bun/Node API types.
The asset declarations describe HTML and CSS imports loaded as strings.
Bun types match the tested 1.3.14 runtime; TypeScript 6 retains `tsserver`
support for editors using `typescript-language-server`, including Eglot.
If an existing TypeScript session still shows old diagnostics, run
`M-x eglot-reconnect`. The type check also generates the browser assets.
CMake installs the locked dependencies, bundles the editor and fonts, and
compiles the standalone host. Runtime users need no npm packages.

Build against the Emacs installation that will load the module. Configuration
locates its header beside the app's resources or in system include directories.
Override the cached choices when needed:

```sh
cmake --preset dev -DEMACS=/path/to/emacs -DEMACS_INCLUDE=/path/to/include
```

`EMACS` and `EMACS_INCLUDE` environment overrides also work with `./build.sh`.
When changing Emacs installations, pass its include directory too, or run
`cmake --fresh --preset dev` to rediscover everything.

Restart Emacs after rebuilding a module it has already loaded. The build replaces
the library atomically, so rebuilding leaves the old loaded library intact; it
does not hot-reload that library.

## Bun UI host

Loading the Lisp package or native module does not start a server. The first
`portal-hello`, `portal-preview-markdown`, `portal-tasks-browser`, or drawing buffer starts one shared
child process asynchronously. Hello, the Markdown preview and the task browser are hosted apps: each opens its
web view at once, at `about:blank`, and loads its page as soon as the host sends
its readiness message. Opening external URLs does not require the server.

- The host binds to `127.0.0.1` on an OS-assigned port. Each Emacs process owns
  its own host; all its web views reuse that host.
- Each host generates a fresh access token and sends it through the readiness
  pipe. URLs have the form `http://127.0.0.1:PORT/TOKEN/hello` or
  `http://127.0.0.1:PORT/TOKEN/markdown?path=ENCODED_ABSOLUTE_PATH`, and task
  pages `http://127.0.0.1:PORT/TOKEN/tasks?root=ENCODED_ABSOLUTE_PATH`. The host
  validates the token and Host header; responses suppress outgoing referrers.
- Closing or hiding a view keeps the server running. `M-x portal-start-server`
  can prewarm it explicitly; `M-x portal-stop-server` stops it, and
  `M-x portal-restart-server` starts a replacement. Hosted apps that have
  already loaded keep their page while the host stops or restarts; press `g` in
  one's buffer to reload it from the host, starting the host first if needed.
- Startup is bounded by `portal-server-start-timeout` (five seconds by default).
  Failures leave diagnostics in `*portal-server*`, and a hosted app that was
  waiting stays at `about:blank`; press `g` in its buffer, or run
  `portal-hello`, to retry.
  There is no automatic restart loop.
- Emacs supervises the child through a pipe. stdout carries a versioned JSON
  readiness line and hosted action requests; stdin carries contexts and action
  results. stderr carries diagnostics. Closing stdin requests shutdown,
  including when Emacs exits unexpectedly. Normal shutdown also handles OS
  termination signals and has a forced-termination fallback.
- `portal-server-program` selects the standalone executable. At runtime it is
  launched directly, without a shell or any lookup of Bun on PATH. Runtime
  loading of `.env` and `bunfig.toml` is disabled in the compiled binary.

Control protocol version 3 announces readiness, port, and access token and
supports [hosted app actions](docs/hosted-actions.md). The app host sends `ready`
and `request` records; Emacs sends `context`, `forget`, and `result` records.
Rebuilding publishes the host executable atomically. An already running host
keeps its old code until `portal-restart-server` is called.

## Markdown previews

Run `M-x portal-preview-markdown` in a Markdown file buffer to preview it
directly. Markdown modes and common file extensions are recognised. From other
buffers, the command prompts for a saved local file. Use `C-u M-x
portal-preview-markdown` to choose another file explicitly. Each file has one
preview buffer, such as `*portal: notes.md*`; previewing it again reuses it.
The Bun server reads the file, renders
it with its [built-in Markdown API](https://bun.com/docs/runtime/markdown),
and returns a complete HTML page with embedded light/dark CSS. Rendering happens
in memory, without temporary HTML files or additional npm dependencies.

The preview is light or dark with the system's appearance, and switches when
the system does, even if your Emacs frames force a dark or light title bar with
`ns-appearance`. To keep previews one way, set `portal-web-appearance`, or run
`M-x portal-web-set-appearance`:

```elisp
(setopt portal-web-appearance 'light) ; or 'dark; nil follows the system
```

This applies to every web view, including the task browser and Excalidraw.
Open previews change at once, without reloading.

Headings, lists, fenced code, tables, strikethrough, task lists, and heading
anchors are supported. Press Command-R to reread the file on screen from disk, or
from Emacs, `g` (`portal-web-reload`), which also starts a
stopped host. A loaded preview stays as it is while the host stops or restarts.
Missing or unreadable files produce an error page.

The preview follows links like a browser:

| Link | Where it goes |
| --- | --- |
| `#anchor` | Scrolls within the page |
| A local Markdown file, such as `architecture.md` or `other.md#heading` | Opens in the same preview, at the heading if there is one |
| Any other local file, such as `src/server.ts#L42` | Opens in Emacs in another pane, at line 42 for `#L42` or `#L42-L50` |
| A local image or folder | Opens in Emacs, in `image-mode` or Dired |
| `https://…` and other sites | Opens in the default browser |

Relative links resolve from the folder of the document on screen, and local
absolute paths and `file:` URLs work the same way. After following a Markdown
link, the buffer is renamed after the new file, `g` rereads it, and
`portal-preview-markdown` on that file finds this preview. Back and Forward in
the toolbar, or `l` and `r` in the preview buffer, move through the documents
this preview has shown and restore their reading positions. Following a new
link after going back discards the old forward pages, as in a browser; opening
a file in Emacs or a website does not.

Opening a file in Emacs is one click, with no need to leave the preview first.
Emacs selects the file's pane and takes the keyboard, ready for editing, while
the preview stays in its own pane at the same reading position. The file goes
to another pane, reusing one or splitting the frame. Rules in
`display-buffer-alist` still decide: if one puts the file in the preview's own
pane, the hidden preview keeps its page. **Open in Emacs** in the toolbar, or
`M-x portal-preview-open-in-emacs`, does the same for the Markdown file on
screen, including after Back or Forward.

To go back to reading, click the preview, which selects its pane and gives it
the keyboard, or select its pane and press `RET`. From anywhere else,
`M-x portal-preview-return` selects the preview that the frame last opened a
file from, showing it again if it was hidden, and gives it the keyboard. The
page is not reloaded. There is no global key for it; bind one if you like.

This version previews saved contents only, with no automatic refresh. It does
not show relative inline images, or add syntax highlighting, Mermaid, or math
rendering. HTTP(S) images and links can use their absolute URLs. Going back past
an app host restart shows a "Not found" page; `g` reloads from the running host.
Raw HTML is displayed as text, and a page-specific Content Security Policy
blocks scripts. Bun currently marks its Markdown API unstable; it is tested
here with the Bun version listed above.

## Pi implementation/review loops (opt-in)

The separate [pi task extension](extensions/task/README.md) adds `/task` to pi:
start from a local task file or an instruction, keep an interactive Claude Code
implementor in tmux, and automatically run a fresh in-process pi reviewer after
each committed submission. State, Markdown feedback and an event log stay on disk;
human decisions pause the loop and interrupted work can be resumed explicitly.

This package requires no Portal UI or workmux and is not installed by the native
build. Its local execution state does not change `project.org` or the Portal task
browser. See its README for installation, prerequisites, permissions, tests and
recovery limitations.

## Task view

`M-x portal-tasks` lists the actionable tasks in the current project's
`project.org`. It needs [org-ql](https://github.com/alphapapa/org-ql) from
MELPA, and is tested with org-ql 0.8.10 and MELPA's 20250421.133. The rest of
Portal works without it.

Tasks are the headings with their own `:task:` tag, as the
[author-tasks skill](.agents/skills/author-tasks/SKILL.md) describes. A task is
actionable when its keyword is `TODO`, every task its `DEPENDS_ON` property
names by `CUSTOM_ID` is `DONE`, and it is not scheduled after today. They are
listed by priority, where none counts as Org's default, then nearest deadline,
then file order. A deadline makes a task urgent, never eligible.

`v` switches to all tasks, grouped as Actionable, Blocked, Deferred and Closed.
After its title, a blocked or deferred task says why: each prerequisite it waits
for, with its state and a link to it; a prerequisite that does not exist or
whose `CUSTOM_ID` another task shares; a missing or shared `CUSTOM_ID` of its
own; a dependency cycle; a keyword other than `TODO`; or a date it is scheduled
for. A `CANCELLED` prerequisite blocks like any other that is not `DONE`.
Closed tasks have a done keyword. Prerequisites can also be in the file's Org
archives, such as `project.org_archive`, where `org-archive-subtree` moves
finished tasks; the view does not list archived tasks.

`RET` shows a task in its [detail](#task-detail). Each line is an Org agenda
line, so Org's other agenda keys act on its task: `t` changes its state and
`TAB` goes to it in its file, for example. `g` redraws the view, and `q`
leaves it.

With [evil-collection](https://github.com/emacs-evil/evil-collection), the view
is in Evil's normal state, where evil-collection's agenda keys come before the
view's. There `RET`, `v` and `q` work as above, and `gr` or `gR` redraws the
view. Its other agenda keys still act on a task, such as `t`, and `r`, which
refiles it. This is tested with Evil 1.15.0 and evil-collection 3.0.3, and
with MELPA's 20260728.1438 and 20260818.145.

The project is the one being edited, as for
[quick terminals](#quick-project-terminal): in a terminal, the terminal's
own project; elsewhere, the project of the file or Dired buffer the frame
selected last. Each project has one view, such as `*tasks: ~/src/app*`, which
keeps its choice of actionable or all tasks. The view reads the buffers of
`project.org` and its archives, saved or not. It is redrawn when its pane is
selected, or shows it again, after a change or on a new day; when one of those
files is saved; and on `g`. Each pane stays on its task.

### Task detail

`RET` on a task shows it in the project's task detail, such as
`*task: ~/src/app*`, in the same pane. The detail is an Org indirect buffer of
the task's file, narrowed to the task and showing all of it, as `C-c C-x b`
shows a subtree. It has folds of its own, so the file's buffer stays folded as
it was. Everything else is Org: type into the task, fold it, follow and insert
links, tick checkboxes, schedule it, and change its state with `C-c C-t`. Any
state can be set by hand, whether or not the task is actionable. Saving and
undo act on the file's buffer, and edits not yet saved stay there when you
leave the detail.

A link to a task's `CUSTOM_ID`, such as `[[#search-index][the index]]`, shows
that task in the detail, from `project.org` or its archives. So does a blocker's
link in the view. Org follows every other link as usual. `M-,`, wherever
`xref-go-back` is bound, goes back: to the task whose link you followed, where
you were in it, and finally to the view, on the task you opened. The view is
redrawn on the way back, so its readiness reflects your edits. If you killed
the view meanwhile, Back makes it again, listing all tasks if it did. The project has
one detail, reused for each task. Tasks are found again by their file and
`CUSTOM_ID` each time, across `project.org` and its archives. A task without a
`CUSTOM_ID`, or one that shares it, opens in its file instead, as in Org's
agenda, and a link to a shared `CUSTOM_ID` says so rather than pick a task.

`DONE` and `CANCELLED` tasks stay in the view's Closed group. Reopen one by
setting it back to `TODO` in its detail or with `t`. Reopening or cancelling
changes only the keyword, so the task's sections stay. Cancelling a task does
not stop a terminal working on it.

### Starting Claude on a task

`M-x portal-tasks-implement` starts Claude on an actionable task: the one on
the view's line, or the one point is in, in the task detail or in
`project.org` itself. No key is bound to it; bind one if you like. Claude runs
in a new terminal, named after the task, such as
`*claude: search-index*`, at the project root. The program and its arguments
are `portal-tasks-claude-program` and `portal-tasks-claude-arguments`, read at
each start, then the initial prompt; [Implementing a task](#implementing-a-task)
describes them and the shell that finds the program. The first time Claude runs in a
folder, it may ask whether you trust it.

Window placement follows Emacs's `pop-to-buffer` rules, for both new and
existing runs. Use `display-buffer-alist` or `display-buffer-base-action`
to choose your layout. For example, to show `*claude: ...*` terminals in the
entire frame, add this to your Emacs config:

```elisp
(add-to-list 'display-buffer-alist
             '("\\`\\*claude: " display-buffer-full-frame))
```

The task is judged again first, from `project.org` and its archives as they
are in Emacs. A task that is not actionable starts nothing, and the message
says why. If `project.org` has unsaved changes, Emacs offers to save it;
declining, or a failed save, starts nothing and keeps the edits. So does a
save hook that changes the buffer or the file again, and a `project.org`
changed on disk since Emacs read it: revert or save it, then try again.

The initial prompt has Claude read the task's brief first and implement the
task, following the repository's instructions. Once the work and its checks
pass, Claude is to mark the task `DONE` in `project.org`, found by its
`CUSTOM_ID`, and record its verification there, normally in the
implementation's pull request. Starting Claude changes no task. There is no
shared in-progress state: other checkouts see the task done through Git.

The brief is a new file in `temporary-file-directory` that only you can read
and no one can write, such as
`portal-task-search-index-AbC123.org`. It holds the task's subtree as saved,
with its child sections, and nothing else: no neighboring tasks or
prerequisites. Comments before it give the project, the path of
`project.org`, the task's `CUSTOM_ID`, the lines it was on and the SHA-256 of
the saved file. Links in the task stay relative to `project.org`, and the line
numbers only record where it was. The prompt names the brief with an `@`
mention, so Claude Code attaches it to the first message under its normal
permissions, with no tool call or permission prompt. The brief lasts as long
as its terminal. It is deleted when the buffer is killed, `C-c C-k` ends the
terminal, or Emacs exits; if Emacs itself is killed, it stays in the
temporary directory.

Running the command on a task whose terminal still exists shows that
terminal instead of starting another run. `C-u M-x portal-tasks-implement`
starts another.

## Task browser

`M-x portal-tasks-browser`, or `(portal-tasks-browser)` from Lisp, lists the
current project's saved Markdown tasks in a web view with the navigation
toolbar. The view opens
at once and loads the list when the app host is ready, starting the host first
if needed. Click a task to read it in the same view; the **Tasks** link returns
to the list. Emacs stays the editor: the page shows saved files, and every
change to a task is saved by Emacs. Nothing moves or deletes task files.

This repository now writes its tasks in `project.org`, for the
[task view](#task-view); the Markdown originals stay in `tasks/`, the default
root, for comparison. Agents use the
[author-tasks skill](.agents/skills/author-tasks/SKILL.md).

### Completing and editing tasks

Each list row and task page has **Complete**, or **Reopen** for a completed
task, and **Edit in Emacs**. They are ordinary buttons, apart from the task
link: click one, or Tab to it and press Return or Space.

**Complete** and **Reopen** save the task with `status: done` or
`status: todo`. They change only that value: the body, other front matter,
comments, quoting, a byte order mark and CRLF line ends all stay as they were.
A status written some other way, such as with a YAML tag, an anchor or in more
than one place, is left alone, and the page asks you to edit it in Emacs. So
are a task with unsaved changes in an Emacs buffer (save it first), a
read-only file, a file that changes while the action runs, and a failed save;
each reports why and changes nothing, since the file is replaced whole. The
file is checked once more just before it is replaced; like any editor's save,
only a save elsewhere in that instant could still be overwritten. An
unmodified buffer visiting the task shows the saved file.
Each button sets the status it names, so pressing it again, or twice, leaves
the task as it asked. The page shows what is happening, and reports success
only once the file is saved. The file is saved in the viewed task folder
alone: no commit, branch or other checkout changes, and a worktree's copy of
a task is independent of the main checkout's.

**Edit in Emacs** opens the task's current source in another pane, reusing a
buffer that visits it, unsaved changes and all, and gives Emacs the keyboard.
The task page and its history stay; `M-x portal-preview-return` comes back.

Saving any file in the task folder in Emacs refreshes the task browser pages
of that folder in place, from the saved files: the address, history, view, filter,
folds, reading position and keyboard focus stay, and Emacs keeps the keyboard.
A hidden view refreshes once it is shown again, and a page that Back or Forward
shows again is checked the same way. Completing a row that the filter hides
moves focus to the row that takes its place. A deleted, invalid or conflicting
task shows its problem, with a link back to the list. `g` still reloads the
page, which picks up changes made outside Emacs.

### Implementing a task

Click **Implement with Claude** on a task detail to open a dedicated native
terminal using Emacs's display rules. Claude starts in the project root with
`--dangerously-skip-permissions` and an initial prompt such as
`implement @tasks/fix-search.md`. Folder tasks use their actual `content.md`
path. The project is captured when the task browser opens; selecting another
project later does not change the launch directory.

The task page submits a normal form to the app host, which resolves the current
source by task ID and requests the terminal through Emacs. Duplicate submissions
share one launch. Reloading the result page does not start another session.
Errors appear on the detail page. A task folder with no known project remains
browsable but cannot launch Claude.

Configure `portal-tasks-claude-program` and `portal-tasks-claude-arguments` before
opening a task browser to choose the executable or adjust its arguments. The
program defaults to `claude`; arguments default to
`("--dangerously-skip-permissions")`. The terminal starts your interactive login
shell, loads its startup files, and resolves `claude` on that shell's PATH.
Programs such as `gh` therefore use your shell setup even when GUI-launched
Emacs cannot find them. No Emacs environment-import package is required for
Portal terminals. Lisp-side `setenv` and `exec-path` changes do not configure
these programs; use your shell dotfiles or an explicit executable path.
A missing program's error appears inside the terminal. Claude's first-run login
or setup can still appear there. The view keeps running when hidden, and
killing its terminal buffer ends it.

See [hosted app actions](docs/hosted-actions.md) for the reusable instance/action
interface and its process protocol. Restart Emacs after rebuilding the native
module, and use the matching app host (protocol 3).

### Choosing the task root

`portal-tasks-directory` names the task root. It defaults to `tasks/`, which is
relative to the `project.el` root; an absolute directory is used as it is. Set
it for one project in that project's `.dir-locals.el`:

```elisp
((nil . ((portal-tasks-directory . "backlog/"))))
```

The project is the one being edited. From a terminal, a web view or another
auxiliary buffer, it is the project of the file or Dired buffer the frame
selected last, as for [quick terminals](#quick-project-terminal), and that
project's directory-local settings apply. Outside a project, the command asks
for a task folder, and `C-u M-x portal-tasks-browser` chooses any local folder. Remote
folders are rejected, and symbolic links in the path are resolved.

Each task root has one buffer, such as `*portal: tasks ~/src/app/tasks*`.
Running the command again shows it at its current page; another project gets
its own. A missing task folder shows how to start one, without creating it. A
folder with no tasks shows "No tasks", and one with only completed tasks offers
**Show completed**.

### Writing tasks

A task is a single Markdown file, or a folder holding its document and
attachments. Both work the same, at any depth, and folders group tasks:

```text
tasks/
  fix-search.md                 # a task
  markdown-navigation/          # a task with attachments
    content.md
    mockup.png
    implementation-notes.md     # a supporting document, not a task
  big refactor/                 # a group: a folder with no task of its own
    extract something in c.md   # a task in the group
    implement something/
      content.md                # a task in the group, with attachments
  assets/
    search.png                  # an attachment of fix-search.md
  README.md                     # a document, since it has no status
```

Every `.md` file under the task root, at any depth, can be a task. A file named
exactly `content.md` is its folder's own task, except directly in the root,
where it is a task named `content`. Other files are supporting material, and
symbolic links are never followed. A document is a task when its YAML front
matter has a `status`:

```markdown
---
status: todo
---

# Fix search

Searching with spaces returns no results.
```

`status` is `todo` or `done`, exactly. Completed tasks leave the list until you
turn on **Show completed**, and their pages stay reachable. Documents without
front matter, or without a `status`, are not listed. Front matter that is not
closed or not a YAML mapping, an invalid status or title, and unreadable files
and folders are listed under **Problems** with their paths, and the other tasks
still show.

Supporting Markdown inside a task folder is a task too once it has a `status`:
before nested folders were discovered, it was ignored. Remove `status` from a
supporting document that should stay a document.

A task's title is its front matter `title`, or else its first level-one
heading outside code fences, or else its ID. The ID is the front matter `id`
or, without one, the task's path in the root: `big refactor/extract something in c`
for `big refactor/extract something in c.md`, and `big refactor/implement something`
for its `content.md`. Moving `fix-search.md` to `fix-search/content.md` keeps
the task's ID and address. Without an `id`, renaming or moving the file changes
both; with one, the task keeps its ID and address wherever it moves, including
into another folder. An `id` is lowercase letters and digits in words joined by
single hyphens, such as `extract-c-interface`. Before moving a task that others
depend on, give it an `id`; its current name keeps their references working
when it fits that form.

IDs are unique in the task root, whether written or taken from a path, and one
location holds one task. If two tasks share an ID, or `fix-search.md` and
`fix-search/content.md` both exist, neither is listed: **Problems** names the
files, and each task's page shows the conflict until it is resolved. The same
file name in two folders, such as `a/fix.md` and `b/fix.md`, is two tasks.

#### Folders

A folder without a task of its own is a group, named after the folder. It has
no status or ID, and it cannot be a dependency. A folder with a task
`content.md` is a parent task, shown with its title, and it can hold more tasks
and folders. When a folder's `content.md` has no `status`, it is a document and
the folder is a group; when it is invalid or conflicting, **Problems** shows it
and the folder is a group, so its tasks stay reachable. `a/fix.md` beside a
folder `a/fix/` with no task of its own shows as a task and a separate group.

Folders only organize work. A parent's `status` and `depends_on` are its own:
nothing is inherited, completing the tasks in a folder completes nothing else,
and depending on a parent waits for that parent's own status. To make a parent
wait for its tasks, list their IDs in its `depends_on`.

#### Dependencies and order

`depends_on` lists the IDs of the tasks that must be done first:

```markdown
---
id: implement-c-adapter
status: todo
depends_on:
  - extract-c-interface
---

# Implement the C adapter
```

A todo task is **Ready** when every task it depends on is done, and otherwise
**Blocked** by them. Status stays exactly what you saved: nothing is marked
done for you. Only `depends_on` makes a dependency; links and a `Blocked by`
section in the body are for readers. IDs in `depends_on` are compared exactly
and never read as paths.

Unfinished tasks are numbered in an order they could be completed: each
after what it depends on, and otherwise by ID, across every folder. A number
is a position in that order, not permission to start. A blocked task is dimmed
and names the positions it waits for, nearest first, such as `after 7, 6`; past
three it adds a count, such as `+2`. Everything shown at full strength can
start now. A done task's title is dimmed and struck through. Positions are renumbered as work is done, so they refer only to the
list on screen. A done task satisfies the tasks that depend on it, whatever its
own dependencies. Tasks that cannot be ordered, and the unfinished tasks
waiting on them, have no number: a `depends_on` that is not a list of IDs, a
missing, invalid, or conflicting task, or a cycle among unfinished tasks. Their
rows name the problem, or the task they wait for by ID when it has no position.
**Problems** names each file and ID, including for completed tasks, in either
view.

#### Tree and execution views

The list has two views, switched with **Tree** and **Execution** at its top.
Both show the same numbers, what blocked tasks wait for, and problems.

- **Tree**, the default, shows each task once in its folders. Press a group's
  row, or the arrow beside a parent task, to fold what it holds; the arrows
  are keyboard controls, apart from the task links. Folders and tasks at one
  level follow their earliest numbered task, then their paths. This is for
  browsing: a folder's tasks can be interleaved with other folders' work.
  Completed tasks are marked **done**.
- **Execution** lists unfinished tasks in order across all folders, each with
  the folders holding it. Tasks that cannot be ordered follow under **Blocked
  by dependency problems**, by ID.

Completed tasks are hidden until **Show completed**, except a completed parent
task whose folder still holds unfinished work. A group with nothing to show is
hidden. **Show completed** shows the whole tree, or in the execution view adds
a separate **Completed** section; it changes no number. The view and filter
are part of the page address, so links, Back and Forward, `g`, and an app host
restart keep them. `g` unfolds the tree again.

A task's page shows its ID, the tasks it depends on and the tasks it blocks,
each with its status, and whether it is ready. Links to completed tasks work
with either filter. Its folders, above the page, lead back to the list or to
a parent task's page.

To complete a task, press **Complete** on its row or page, or edit
`status: todo` to `status: done` in Emacs and save. Either way the task browser
refreshes; `g` rereads the page on screen from the saved files, including
after an app host restart.

### Links and attachments

Relative links and images in a task resolve from its attachment folder: the
folder holding a single-file task, such as the task root for `fix-search.md`
or `big refactor/` for a task file in that group, or the task's own folder.
Moving a task can break its relative links and images, even when its ID stays.

| Link | Where it goes |
| --- | --- |
| `#anchor` | Scrolls within the page |
| Another task's file anywhere in the task root, such as `../fix-search.md#notes` | That task's page in the same view, keeping the view and filter |
| An inline image, such as `![Search](assets/search.png)` | Shown in the page |
| Any other file in the attachment folder | Opens in Emacs in another pane, as from a Markdown preview; `#L42` goes to line 42 |
| A missing file, or one outside the attachment folder | Crossed out, with the reason as its tooltip |
| `https://…` and other sites | Opens in the default browser |

Mock-up HTML and code open in Emacs as source; the task browser never runs them.
Opening a file keeps the task page and its history, and
`M-x portal-preview-return` comes back to it. Back and Forward in the toolbar,
or `l` and `r`, move between list and task pages, keeping the filter and reading
position. Raw HTML in a task is shown as text, and the host serves only image
files from the attachment folder.

## Web view behaviour

A web view is a Portal view of the web kind. Remote pages use
[WebKit's URL request loading](https://developer.apple.com/documentation/webkit/wkwebview);
local pages use `loadFileURL` with read access to the containing directory so
relative scripts, styles, and images can load. JavaScript is enabled by default.

- Each web buffer has one web view, which appears in the selected pane showing
  the buffer ([ADR 0001](docs/adr/0001-one-portal-view-per-buffer.md)). Other
  panes showing the same buffer display only its text. To see two pages side by
  side, open two buffers.
- Web views belong to no frame: show the buffer in another frame and its page
  moves there. Deleting a frame only hides its web views.
- Hiding the view, with `q` or by showing another buffer, keeps the page loaded,
  including its navigation, DOM, scroll position, and form state. Cookies use
  WebKit's default data store, except in hosted apps, which keep no cookies or
  storage between Emacs sessions.
- A hosted app's page never leaves the app host. When it would navigate
  anywhere else, the navigation is cancelled and the URL opens in the default
  browser. Clicking a link to a local `file:` URL gives Emacs the keyboard and
  sends a `follow` message with the URL over the [bridge](docs/editor-bridge.md)
  instead: WebKit never lets an app host page load a local file, so a script
  in its own content world, out of the page's reach, catches such clicks. Each
  page a hosted app commits, including after Back and Forward, sends a `page`
  message. URLs go over the bridge because a long path would not fit in a
  notification record.
- Pages see the system's light or dark appearance as CSS's
  `prefers-color-scheme`, not the appearance an Emacs frame forces with
  `ns-appearance`. `portal-web-appearance` set to `light` or `dark` overrides it
  for every web view, open or new.
- A chord the page does not use reaches Emacs, and Command-Escape works, while a
  page has focus.
  Clicking a view to enter it sends a `select TARGET` record, and Emacs selects
  the pane showing it.
- This is a URL viewer, without an address bar, downloads, popup windows, or
  JavaScript dialog UI. Failed loads can be inspected through `:error` in
  `(portal--inspect (portal-view-target))`.

Lisp can give any buffer a web view: `(portal-web-open URL TOOLBAR)` opens one
for the current buffer and loads URL. TOOLBAR is `"navigation"` (back, forward,
find, zoom and reload), `"contents"` (those and a table of contents),
`"markdown"` (those, a table of contents and, for a hosted app, Open in Emacs)
or `"none"`.
Loading the page a view shows again, ignoring its fragment, reloads it without
a new history entry.
`(portal-web-open-hosted PATH TOOLBAR)` opens a hosted app instead: the view
opens at once, at `about:blank`, and loads PATH, such as `"/hello"`, from the
app host as soon as the host is ready, starting the host if needed.
A hosted app and its buffer exchange JSON objects over the
[bridge](docs/editor-bridge.md): `(portal-web-send PLIST)` sends one to the
app, and the buffer-local `portal-web-bridge-function` is called with each one
the app sends, in order. Other web views have no bridge.

## Implementation

| File | Responsibility |
| --- | --- |
| `portal.el` | The package root: loads every feature |
| `portal-view.el` | Module loading, the shared Portal view lifecycle (open, placement, hiding and closing), and the notification pipe |
| `portal-web.el` | Web buffers, URL and HTML previews, Hello and Markdown previews on the app host, and the bridge |
| `portal-excalidraw.el` | Excalidraw drawing buffers, a hosted-app client of the bridge |
| `portal-launcher.el` | Opt-in launcher frame lifecycle, its global shortcut, command sessions and dismissal |
| `portal-global-shortcut.el` | Named global shortcuts: validation, conflicts by name, queuing presses and calling their functions from the command loop |
| `portal-input.el` | Chords that fall through to Emacs, read with the view's buffer's keymaps; focus policy and input notifications |
| `portal-terminal.el` | Terminal buffers, their names, projects and cached metadata, completion, and terminal commands |
| `portal-terminal-bindings.el` | Runtime native keymaps, validation, and registration |
| `portal-terminal-quick.el` | Project scratch terminals, bottom panel, and callable toggle command |
| `portal-agent-process.el` | Pure process identity: TTY ownership, runtime launch grammar, and outer-agent selection |
| `portal-agent-discovery.el` | Agent incarnations, hide/show transitions, activity invalidation and asynchronous collection |
| `portal-agents.el` | Manual terminal labels, dashboard rows, visibility and user commands |
| `portal-project.el` | Each frame's editing context, and project roots through `portal-project-function` |
| `portal-server.el` | Lazy shared-process startup, readiness, logs, and shutdown |
| `host/server.ts` | Local HTTP server and parent-process lifetime |
| `host/hello.html` | Embedded Hello World page, styles, and JavaScript |
| `host/markdown.ts` | Local Markdown reads, HTML rendering, and error pages |
| `host/markdown.css` | Embedded Markdown typography and light/dark colours |
| `host/bridge.d.ts` | The `portalBridge` interface hosted apps use |
| `native/Core/emacs.c` | The Emacs module: function registration, argument and result conversion, and errors |
| `native/Core/views.c` | The view registry: targets, kind checks, attachment bookkeeping, closing, inspection, and change announcements |
| `native/Core/input.c` | Who gets each key: the app, a view shortcut or Emacs; binding matching, offers to pages, handoff states and serials, literal and cancel decisions |
| `native/Core/terminals.c` | Terminal rules: option checks, the sorted theme catalog, themes for every terminal, paste and Enter, reading text, and announcing changes |
| `native/Core/web.c` | Web views' rules: which URLs load and how, where a page may navigate, whether it can go back or forward, and the bridge's queue, senders and records |
| `native/Core/toolbar.c` | Toolbars: each view's buttons and which work, zoom and text size with their limits, the table of contents, the find field and its searches, visibility and colors, and what a click does |
| `native/Core/scripts/` | Browser scripts every platform's web views share, embedded in the core: local links, and the toolbar's contents and find count |
| `native/Core/shortcuts.c` | Global shortcuts: chord notation, registrations and their IDs, replacing a chord without losing it, held keys, and press records |
| `native/Core/channel.c` | The notification pipe: record validation, the queue of waiting records, retries, and the pipe's descriptor |
| `native/Core/include/portal.h` | The platform interface: the primitives a platform implements ([ADR 0003](docs/adr/0003-platform-interface-primitives.md)), their ownership and thread rules, and the calls a platform makes into the core |
| `native/Backend.swift` | The macOS backend: implements `portal.h` on the main thread with the Swift features |
| `native/CoreCalls.swift` | Swift's calls into the core, such as sending a record or reporting what a page did, the shared scripts' glue, and the timer primitive |
| `native/Launcher.swift` | Dedicated NSPanel attachment, Emacs NS compatibility, placement, and presentation identity |
| `native/Hotkeys.swift` | The hot key primitives: Carbon registrations, key codes, and reporting presses and releases to the core |
| `native/NativeHost.swift` | Shared frame attachment, geometry, focus return, and keyboard routing |
| `native/WebView.swift` | The web view kind: WebKit pages, storage, loading, what pages report to the core, and the bridge's WebKit glue |
| `native/NativeInput.swift` | macOS input primitives: key chords, held and replayed events, literal delivery, Command-Escape, and focus reports |
| `native/Views.swift` | The view kind protocol, and `NativeView`: attaching either kind to a frame, and the parking window |
| `native/Terminal.swift` | The terminal view kind: Ghostty sessions, the terminal primitives, the theme catalog, terminal input, and title, directory and exit reports |
| `portal-toolbar.el` | Toolbar option, face colors, and commands reading the core's toolbar state |
| `native/Toolbar.swift` | The AppKit strip the core's state draws: buttons, ownership dot, find field, layout and colors, and the view container |
| `native/WebToolbar.swift` | The WebKit side of the toolbar's primitives: the shared contents script in an isolated world, calls of its functions, and find |
| `native/Package.swift` | One native library and pinned Ghostty dependency |

These are ordinary source boundaries within one native module. A small
`NativeSurface` protocol lets each feature expose its view and keyboard handler.
`NativeHost` knows neither WebKit nor Ghostty: it attaches views to the correct
frame, remembers the original Emacs responder, and uses one event monitor to
route keys to the focused surface or a pending Portal command. A key released
after focus changes is not delivered to the newly focused feature.

Features own their state and cleanup. Closing a web view does not destroy a
terminal, and closing a terminal does not remove web views.

The C bindings register every Lisp function and convert its arguments and results.
Lifecycle functions call the core's view registry, input functions its input handoff,
terminal functions its terminal rules, web functions its web rules, and toolbar
functions its toolbars. Portal's rules live in the core, and `portal.h` holds only
the primitives a platform must provide and the calls it makes into the core
([ADR 0003](docs/adr/0003-platform-interface-primitives.md)); `native/Backend.swift`
implements the primitives on macOS. They use plain C types: borrowed UTF-8 arguments
with explicit lengths, results allocated with `malloc` that the core frees, and an
explicit error result that becomes a Lisp `error`. Structured results, such as
`portal--inspect`'s state, cross as JSON, which the bindings parse with
`json-parse-string`. The bindings check that argument strings are valid UTF-8, since
Emacs copies a unibyte string's raw bytes unchanged.

A platform implements these 26 primitives:

| Area | Primitives |
| --- | --- |
| Views | `portal_view_create`, `portal_view_destroy`, `portal_view_attach`, `portal_view_detach`, `portal_view_describe` |
| Input | `portal_view_focus`, `portal_view_unfocus`, `portal_view_replay`, `portal_view_literal` |
| Web views | `portal_web_parse_url`, `portal_web_load`, `portal_web_go`, `portal_web_post`, `portal_web_zoom`, `portal_web_find`, `portal_web_call`, `portal_web_set_appearance` |
| Terminals | `portal_terminal_list_themes`, `portal_terminal_apply_theme`, `portal_terminal_paste_text`, `portal_terminal_press_enter`, `portal_terminal_read_text`, `portal_terminal_set_font_size` |
| Toolbars | `portal_toolbar_draw`, `portal_toolbar_focus` |
| Timers | `portal_timer_start` |

It tells the core what happened with `portal_notify` and `portal_timer_fired`; for
input, `portal_input_key` and `portal_input_focus`; for pages, `portal_web_posted`,
`portal_web_navigating`, `portal_web_committed`, `portal_web_loaded`,
`portal_web_history`, `portal_web_failed`, `portal_web_found`,
`portal_web_returned` and `portal_web_headings`; for toolbars,
`portal_toolbar_clicked` and `portal_toolbar_typed`; and for terminals,
`portal_terminal_changed`. `portal_web_script` hands it the
browser scripts every platform shares.

The notification pipe was the first of Portal's rules in the core,
`native/Core/channel.c`. `portal--channel` hands it the pipe's descriptor, and
platform code sends records by calling `portal_notify`, which the core
implements ([details](docs/terminal-input-bridge.md#the-notification-pipe)). The
core asks the platform for one primitive in return, a timer that calls it back.
Calls into the core run on the module thread and never reach Emacs.

Terminal and web views run on the shared Portal view lifecycle
([ADR 0002](docs/adr/0002-portal-view-native-seam.md)). `portal-view.el` makes
every native lifecycle call: `portal--open KIND OPTIONS` returns a target such as
`terminal:3` or `web:4`, and `portal--place`, `portal--hide`, `portal--close` and
`portal--inspect` take that target.

The C core owns every view's identity, in `native/Core/views.c`. It gives out
targets, with IDs that are global across kinds and never reused, even after a
failed open, so a stale target can never reach a newer view. It holds each
platform view from create to destroy, checks the kind of every view that a kind's
operation names, and keeps what every kind shares: whether the view is attached,
and at which edges. The platform supplies five primitives: create a view of a kind,
destroy it, attach it at a rectangle in the frame with a given title, detach it, and
describe what only it knows, such as a page's title or a terminal's grid.
`portal--inspect` combines that description with the core's `:id`, `:kind`,
`:visible` and `:edges`. Closing removes the target before the platform destroys
the view, so the platform destroys it exactly once and nothing it does meanwhile
reaches the view. The core drops a record the platform sends for a target that
names no open view. A primitive that fails changes nothing: a failed open leaves
nothing registered, and a failed placement, such as for a deleted frame, leaves
the view where it was and still open, for Lisp to place again or close.

The core also owns Portal's terminal rules, in `native/Core/terminals.c`, and asks
the platform for six primitives on one terminal, or on the engine: list the theme
names, apply a named theme or the default, paste text, press Enter, read all text, and
set the font size. Before the platform creates a terminal, the core checks its
options: `:directory` must be a string; `:command`, `:argv` and
`:theme` a string or nil; `:command` and `:argv` mutually exclusive; and `:theme`
a name the platform lists. The adapter decodes literal arguments from `:argv`
and starts the user's interactive login shell to execute them. The core checks a
theme's name the same way before applying it to every open terminal, oldest
first, so an unknown name changes none. If
one terminal rejects a theme, the error is that terminal's: those before it keep the
new theme, and it and those after it keep their old one. `portal--terminal-themes`
returns the platform's names sorted by code point. `portal--terminal-paste` pastes,
then, with ENTER, presses Enter as a separate key, but only if the paste succeeded.
Enter is its own primitive: input replays real native events and needs no synthetic
key. Reading text on macOS selects all and leaves the selection active. The macOS
platform keeps the Ghostty types, binding strings such as `select_all` and
`set_font_size`, and the default theme that follows the system appearance. The
core keeps each terminal's text size, which starts at `PORTAL_TERMINAL_POINTS`.

A terminal describes its `:ready`, `:title`, `:pwd`, `:columns`, `:rows` and
`:exited`, which every platform reports. `:title` and `:pwd` are what the running
program last set and reported, `""` until it does; Ghostty passes on only working
directories reported from this host, percent-decoded. Other facts are diagnostics
for tests: `:layer`, the class of the macOS renderer's layer, and `:focused`, which
input owns. A process that exits leaves its view open with its last output, and its
buffer too, until Lisp closes it; nothing restarts the shell. Closing the view,
which destroys it, ends the process. As for every kind, the core never passes a
closed terminal to the platform: a stale target fails with "No Portal view TARGET",
and a theme reaches only open terminals.

The platform reports each change of title, working directory or exit with
`portal_terminal_changed`. The core sends Emacs one `terminal TARGET` record, and no
other for that view until `portal--inspect` has described it, so a program that
retitles itself constantly cannot flood the pipe. The texts stay with the platform,
which reports them in any length; `portal-terminal.el` inspects the view for them
and caches them in the buffer. A change reported while the view opens has no target
yet, so the core drops its record; Lisp inspects every new terminal once. On macOS, Ghostty reports an exit as a request to
close the surface, at once because Portal turns off its `wait-after-command` and
counts no exit as a failed launch; Portal keeps the view, and the first key after
the exit returns the keyboard to Emacs.

Web views' rules live in the core too, in `native/Core/web.c`
([details](docs/editor-bridge.md#transport)). It checks each URL Lisp loads,
and either asks the platform to load it or, for the document already on screen,
to reload it. It answers every navigation a hosted app's page asks for: allow it on
the app host's origin, open another site in the default browser, or hand a local
file to Emacs. It owns the bridge's queue and its one outstanding `bridge` record,
and decides which posted messages to keep from what the platform observed about
the sender, never from what a page claims. The platform supplies seven primitives
for web views: parse a URL, returning its own spelling of it, and, on one view, load
a URL, step through history (back, forward or reload, as an enum), post a
message to the page, set its zoom, find text in it, and call a function of a shared
script with a JSON argument; finds and calls answer later, with the token the core
gave them. The core keeps every URL in the platform's spelling, the one
WebKit reports pages in, with spaces percent-encoded and Unicode hosts in punycode,
so it compares URLs byte for byte and one parser decides when two are the same. It reports what pages do by
calling the core: a message was posted, a navigation is wanted, a page was
committed or finished loading, its history changed, something failed, a find or
call finished, or the contents script counted headings. Those calls name
the view by target, so a completion that finishes after the view closed reaches
nothing. The browser scripts every platform shares, for local links and the
toolbar's contents, are JavaScript in `native/Core/scripts`, which the core embeds
with `#embed` when it is compiled, so no platform needs files or the app host at run
time. Each is a function the platform starts in an isolated world with its own
transport; only platform glue names WebKit. Hosted apps see one interface,
`window.portalBridge`, with `postMessage` and `receive`.

Toolbars live in the core too, in `native/Core/toolbar.c`. It keeps each view's
layout, fixed when the view opens from `:toolbar` or, for a terminal, `:quick`; its
zoom or text size, with the zoom steps and the 1 to 255 point limits; whether the
table of contents is open and how many headings the page has; and the find field's
text and matches. It reads who has the keyboard from the input core and whether the
page can go back or forward from the web core, and never copies them. After anything
that may change what a toolbar shows, the core builds a snapshot, a `portal_toolbar`
with the visibility and colors in it, and asks the platform to draw it only if it
differs from the last one drawn; nothing serializes JSON to decide. A click, the
find field's text, a Lisp command and a keyboard shortcut all run the same code on
the same state, and `portal--toolbar-action` returns that state as JSON. Searches
run one at a time, each a count by the contents script and then a find: text that
changes replaces the searches still waiting, a page that finishes loading drops the
result of one from before and searches again, and a result no request waits for
reaches nothing. Opening find gives the field the keyboard with
`portal_toolbar_focus`; closing it gives the page the keyboard with
`portal_view_focus`, but only while the view still has it, so it never takes the
keyboard back from Emacs or another view. The platform keeps drawing: AppKit
buttons and the search field, layout, SF Symbols, tooltips, accessibility, tracking
areas and appearance changes, and turns face colors into `NSColor`s.

Rectangles are in Emacs's frame pixels, from the top left of the frame's content
area, as `window-inside-pixel-edges` reports them. On macOS these are AppKit points,
so the platform only flips the y axis. On each window change, `portal-view.el` picks one window per view,
in any frame: the selected window if it shows the buffer, then the view's current
window, then any other window showing the buffer. With none, the view is hidden.
A geometry cache means nothing crosses the seam when nothing moved. Each placement
renames the frame briefly so Swift can find its native window; nothing about
frames is cached. Placing a view in another frame moves it there within the one
call. In Swift, `NativeView` attaches both kinds, and each kind implements the
small `PortalView` protocol. Detaching parks a view in an offscreen window that is
never shown. New views start there, so a view is always in some window and its session
or page keeps running. Deleting a frame hides its views, and the next sync places each
one wherever its buffer is still shown. Killing the buffer or changing its major
mode closes the view. Operations that belong to one kind have their own exports,
such as `portal--web-load TARGET URL`. Batch
tests replace the native module with `test/portal-fake-native.el`.

The frame-title trick and the geometry cache mean there is no polling timer. No
native code retains an Emacs value or environment pointer after a module call
returns: the C bindings copy each argument, and the backend sees only those copies. Native navigation callbacks report to the core; they never call
back into Lisp.

## Verification

Tested with macOS 27.0, Swift 6.4, and Emacs 31.1 with `--module-assertions`.
C and Swift compile with warnings treated as errors; Lisp byte compilation also
passes without warnings.

`ctest --test-dir build -R startup` loads `portal.el` by absolute path in a
fresh `emacs --batch -Q`, without `-L` or a fake backend, and verifies that
Portal's features and commands are available from an unrelated directory, and
that loading registers no global shortcut and loads no native code.

`ctest --test-dir build -R global-shortcut` runs the Lisp module on the real C
core, built with the fake backend, whose hot keys refuse F19 as if another
application had it. It feeds `shortcut` records to the pipe's filter as the
core sends them for presses, and runs what the filter queued through the
command loop's key lookup. It checks two names calling a lambda and a command;
that setting a name again, on its chord or another, leaves one registration and
frees the old chord; that unloading fails, keeping the feature and a chord it
cannot release; that invalid names, functions and notation, another name's
chord in any spelling, and a refused chord change nothing; that a function's
error is a message, keeps every shortcut, and lets the press queued behind it
run; that records split across reads arrive, malformed and stale ones do not,
and a press while one waits is dropped; that removal is independent and
repeatable; and that unloading and a real `kill-emacs` release every chord.
`ctest -R launcher` checks that the launcher's mode is a client of the same
module: it sets and removes only its own shortcut, atomically.

Batch tests of web buffers run with `ctest --test-dir build -R web`. They cover
`portal-open-url` opening a new buffer each time, the view following the selected
pane after a split, `portal-preview-html` reusing its buffer, `g`, `q` and
killing the buffer, the toolbar each command chooses, and Hello and the Markdown
preview opening at once and loading once a simulated app host is ready. Markdown
tests feed the fake native adapter `page`, `follow` and `edit` bridge messages
and `select` records. They check document identity, handoff placement with and without
`display-buffer-alist` rules, line fragments, images and folders, failed
handoffs, paths longer than a record, Open in Emacs, and return tracking across
buffers, previews and frames. One test
opens a Markdown preview with the real app host, which `ctest` passes through
`PORTAL_TEST_HOST`. It checks that the preview loads once the host is ready,
stays as it is while the host stops and restarts, and that `g` reloads it.
Batch task browser tests run with `ctest --test-dir build -R tasks`. They cover
project-relative, absolute and directory-local task roots, auxiliary buffers,
explicit and prompted roots, remote roots, one buffer per root, `g` and restart
recovery of the page on screen, and attachment handoff. Status edits keep a BOM,
CRLF line ends, file modes and every other byte, and refuse buffers with
unsaved changes, read-only files, files changed since the edit was planned,
failed saves (leaving no temporary file) and files outside the root. Edit in Emacs reuses a modified buffer beside the page, and saving a file
refreshes only the loaded views of its root. One test runs the real app host,
and `ctest -R actions` sends status changes, a repeated change, a refusal and
Edit in Emacs from the compiled host through Emacs's command loop.
Batch task view tests run with `ctest --test-dir build -R tasks-view`, against
org-ql 0.8.10 and the libraries it loads that Emacs lacks, and Evil 1.15.0 and
evil-collection 3.0.3, which CMake downloads into `build/elpa` from NonGNU ELPA
and release tags and verifies by hash. They cover the
project from a file, an auxiliary buffer, a terminal and the view itself, and
two projects apart; readiness from unsaved edits, a cancelled prerequisite,
missing, shared and untagged IDs, cycles, a keyword other than `TODO`, and
archived prerequisites; schedules from yesterday to tomorrow, deadlines and
ordering; links to blockers; `g`, saving, a new day and returning, each pane
keeping its task; the empty list; Org's agenda keys on a line; and typing the
view's keys in evil-collection's normal state, its other keys staying. Task detail
tests check that `RET` shows the whole task with its own folds, the file's
staying folded and typing at the task's end touching no folded text, and
reuses one detail; that keys other than `M-,` are Org's;
that tasks without a unique `CUSTOM_ID` open in their file and links to a
shared one are refused; that task links,
archived tasks and blockers' links in the view show their task, and `M-,` goes
back to each link's place and to the view on its task, even after another pane
moved the view, or the All tasks view was killed; that typing, `C-c C-t`, undo and
saving there change the file's buffer, unsaved edits surviving the way back
and a reopened detail; and that closed tasks reopen and blocked tasks change
state. `portal-tasks-implement` tests start Claude, as the fake terminal
records it, from a view line, the detail and `project.org`, in a project
whose path has spaces and quotes. They check the literal arguments and
directory, the brief's provenance and exact subtree beside 3000-line
neighbors, an unchanged file, showing a task's terminal again, an explicit
second run, and each brief deleted with its terminal. Blocked, closed,
unidentified and other files' tasks, declining to save, a failed save, a
save hook that changes the buffer or the file again, a file changed on disk
and a terminal that fails to start each start nothing, and an accepted save
puts the edit in the brief.
Agent dashboard batch tests run with `ctest --test-dir build -R agents`. They
check that the dashboard is one plain buffer that opens no view or app host;
that tracking keeps two terminals in one directory apart, follows renames,
keeps exited programs and labels, and drops closed, killed and replaced
terminals, including a reset quick terminal and a new view in the same buffer,
while untracking leaves terminals running; that rows follow reported titles,
directories, exits and project reassignment, a directory never reassigning a
project; that a refresh with nothing changed rewrites nothing, and one with
changes keeps the sort order, each window's session and screen line, the
selected window and focus, and asks native code, the user and the system
nothing; that `g` works with live updates off; that one timer runs while the
dashboard is shown in any number of windows, none while hidden, shown only on
an invisible frame, killed or with live updates off, and that showing it again
refreshes it; and that `RET` gives the right ordinary, quick, hidden or
other-frame terminal the keyboard. The `agents-evil` test uses the pinned Evil
and evil-collection packages to check Enter navigation in normal state.
`test/portal-agents-benchmark.el` measures
refresh time, allocation and redraws at 10, 50 and 100 tracked terminals; see
its commentary to run it.
`bun test host` checks that status edits change only the status value, in
block and flow YAML, with quoted keys and values, comments, unknown fields, a
BOM, CRLF and multibyte text; that tagged, anchored, duplicated and otherwise
unsafe entries are refused, as are bytes that are no longer the task; and that the action route resolves moved IDs,
serializes repeated requests, rejects other origins, contexts and roots, and
that task pages run only their own hashed script.

The graphical web tests wait for real WebKit page loads. They verify JavaScript
execution, relative local assets, a page staying loaded while hidden, repeated
loading and native URL validation.
The Markdown graphical tests use the real app host and real mouse clicks. They
check that Back and Forward restore reading positions, that a source link hands
the keyboard to Emacs in one click, that clicking the preview selects its pane,
that `portal-preview-return` and `RET` return without reloading, and that
Command-Escape still returns to Emacs, and `RET` re-enters. In a frame forcing the
opposite appearance, a preview follows the system's, and `portal-web-appearance`
turns the page on screen light or dark without reloading it.
The task browser graphical tests check real list and task pages: Back and
Forward restore the filter and reading positions, `g` rereads the saved file,
and `g` loads the page on screen after an app host restart. They also check
task links, inline images in both layouts, and one-click handoff of
attachments, with mock-up HTML opening as source.
They also check dimmed blocked rows and what they wait for, struck-through
completed rows, links to
prerequisites and the tasks they block, including completed ones, the view and
filter across those links, and a dependent becoming ready after its
prerequisite is saved as done. For nested folders they check indentation,
folding groups and parent tasks with real keys, folds kept by Back, completed
parents above unfinished work, folder links, and reloading after a saved move.
Task operations are checked with real clicks and keys: completing a row in
place, with the filter hiding it and focus on the next row, at the same
scroll position and without a new history entry; Tab and Return on a row's
button without opening the task; reopening from a task page, keeping focus on
its button; Edit in Emacs handing the keyboard to the source pane; a save
refreshing the page while Emacs keeps the keyboard, including a hidden page
once it is shown; Back showing the list without a task completed on its page;
and an action refused over unsaved changes.
The graphical toolbar tests type and paste into the real find field and step through matches
with real keys, check that closing find leaves the keyboard with Emacs once the user
returned there, that web state survives buffer switches, reload and a theme change,
that a terminal's grid follows its text size and live toolbar visibility, and that
Excalidraw and a quick terminal have no strip.
The combined graphical suite includes web, terminal, Excalidraw, Markdown, toolbar,
and shared input tests, plus
coexistence checks for both startup orders, real keyboard handoff, WebKit key-up
delivery alongside terminals, independent cleanup, and shared-frame deletion.
They do not assert Lisp caches, hook names, or implementation call counts.
The task view's graphical tests check that redisplay redraws a view after an
edit once its pane is selected again or shows it again, and that typing `RET`
and `M-,` shows a task while another pane keeps the file folded, then returns
to the redrawn view on that task.
The terminal picker's graphical tests type real keys, one at a time as a person
types, into Consult, Vertico and Orderless from `build/elpa`, from an ordinary
buffer, a terminal that has the keyboard and a quick panel. They check that
`M-.` moves the live terminal into the preview window, including from another
frame, without the keyboard, that typing stays in the minibuffer and reaches no
shell, that cancelling puts every view and the keyboard back, and that accepting
gives the chosen terminal the keyboard once the minibuffer closes.
Automatic discovery has batch tests in `ctest --test-dir build -R agent-discovery`:
real asynchronous pipes, process identity, nested/spoofed controls, PID reuse,
hidden/manual collection, bounded failures, pending triggers, and recorded Claude
lifecycle/compaction/error/trust fixtures replayed through dashboard rows. Codex
fixtures cover startup, working, completion, approvals, denial, cancellation and
model failure. Mixed-agent checks isolate status sources and discovery options,
reject delayed Claude results after a Codex replacement, and suppress redraws
for spinner frames and blinking approval markers. Pi tests replay recorded tool,
cancellation and provider-error lifecycles, reject pre-discovery/delayed progress,
and cover hidden collection, manual refresh, source loss and repeated-state
redraw suppression. `ctest --test-dir build -R pi-extension` tests the shipped
extension, including synthetic retry, compaction, nested UI prompts and
conversation/reload events; these simulations are not live-provider captures.
Runtime cases cover option values, attached values, short flag clusters,
terminators, execution modes, unknown options and every supported runtime pairing
for Claude, Codex and Pi. With Node installed, CTest also runs actual Node
processes on PTYs through the native collector and checks
that a preload named `claude` is not mistaken for the executed script, and that
Node with a spoofed Bash argument name does not produce an agent row.
`ctest --test-dir build -R processes` checks Darwin argument parsing, including
NUL padding and truncation, and launches real nested PTYs with an inherited
marker to verify TTY ownership. `portal-agents-benchmark-discovery` in
`test/portal-agents-benchmark.el` compares 10, 50 and 100 simulated sessions;
pass `"codex"` for title inference or `"pi"` for progress instead of Claude.

For the real tmux exclusion test, set `PORTAL_TEST_PROCESS_SNAPSHOT` to the
absolute path of `build/portal-process-tests`, have tmux on Emacs's `exec-path`,
and run `portal-discovery-gui-inherited-tmux-marker` from
`test/portal-agent-discovery-gui-tests.el` in a fresh graphical Emacs. It uses
an isolated tmux socket and a fixture executable; no Claude credentials or
requests are needed. It verifies a direct run alongside attached and detached
tmux runs inheriting their Portal terminal's marker.

For the opt-in real-Claude smoke test, set `PORTAL_TEST_CLAUDE_DIRECTORY` to an
already trusted project, load `test/portal-agent-discovery-gui-tests.el` in a
fresh graphical Emacs, and run `portal-discovery-gui-plain-claude`. It starts
plain Claude sessions, sends one harmless prompt, verifies automatic rows and
working/idle, navigation and exit/relaunch, then closes its terminals.

For `portal-discovery-gui-mixed-codex-claude`, also set
`PORTAL_TEST_CODEX_DIRECTORY` to a project already trusted by both agents. It
starts plain Claude and Codex sessions in that directory, sends Codex a harmless
prompt, checks their separate activity and exact navigation, hides/reopens the
dashboard, quits/relaunches Codex, and discovers and visits a hidden quick-terminal
Codex. A spoofed Codex name with an approval title remains a negative control.

For `portal-discovery-gui-mixed-pi-claude-codex`, also set
`PORTAL_TEST_PI_AGENT_DIR` to a disposable Pi agent directory containing the
bundled `portal-pi.ts` in `extensions/`, credentials for one harmless request,
and settings with terminal progress off. The directory must have a project
trust decision (or `defaultProjectTrust: "never"`) so startup can reach the TUI.
Install this additional test-only extension in that directory:

```typescript
export default function (pi) {
  pi.registerCommand("portal-test-prompt", {
    description: "Portal smoke test input",
    handler: async (_args, ctx) => {
      await ctx.ui.input("Portal smoke test", "Type PORTAL_OK");
    },
  });
}
```

It launches plain Pi, Claude and optionally Codex in one directory, verifies
Pi work and dialogs, repeats a dialog with the dashboard hidden, tests `/new`
and `/reload`, quits/relaunches Pi and visits a hidden quick Pi terminal. It
uses that temporary Pi directory without changing the user's settings.

The agent dashboard's graphical tests use real terminals and redisplay's window
hooks. They check that `RET` gives a hidden terminal, one shown in another
frame and a quick terminal the keyboard, and that the dashboard in another frame
pulls a terminal there; that a title a shell sets appears without `g` while
another terminal keeps the keyboard, and unchanged ticks redraw nothing; and
that hiding, showing in another frame, an invisible frame and killing leave one
timer only while shown.

Build the test-only event injector shown above, then run the suite in a disposable
graphical Emacs. Batch Emacs has no native window and
cannot exercise these behaviours:

```sh
emacs -Q --module-assertions -L "$PWD" -L "$PWD/test" \
  -L "$PWD/build/elpa/consult-3.10" -L "$PWD/build/elpa/vertico-2.15" \
  -L "$PWD/build/elpa/orderless-1.8" -L "$PWD/build/elpa/org-ql-0.8.10" \
  -L "$PWD/build/elpa/marginalia-2.13" \
  -L "$PWD/build/elpa/launcher-731146d95d7d1ff16f48e7a200da873c8d8b375c" \
  -L "$PWD/build/elpa/org-super-agenda-1.3" -L "$PWD/build/elpa/ts.el-0.3" \
  -L "$PWD/build/elpa/ov-1.0.6" -L "$PWD/build/elpa/s.el-1.13.1" \
  -L "$PWD/build/elpa/ht.el-2.3" -L "$PWD/build/elpa/dash-2.20.0" -l "$PWD/portal.el" \
  --eval "(module-load \"$PWD/build/test-terminal-input.dylib\")" \
  -l "$PWD/test/portal-tests.el" \
  -l "$PWD/test/portal-terminal-tests.el" \
  -l "$PWD/test/portal-integration-tests.el" \
  -l "$PWD/test/portal-excalidraw-gui-tests.el" \
  -l "$PWD/test/portal-input-gui-tests.el" \
  -l "$PWD/test/portal-toolbar-gui-tests.el" \
  -l "$PWD/test/portal-markdown-gui-tests.el" \
  -l "$PWD/test/portal-tasks-gui-tests.el" \
  -l "$PWD/test/portal-tasks-view-gui-tests.el" \
  -l "$PWD/test/portal-terminal-choose-gui-tests.el" \
  -l "$PWD/test/portal-agents-gui-tests.el" \
  -l "$PWD/test/portal-launcher-gui-tests.el" \
  -l "$PWD/test/portal-launcher-daily-use-tests.el" \
  -l "$PWD/test/portal-global-shortcut-gui-tests.el" \
  --eval '(ert-run-tests-interactively "^portal-")'
```

Apart from the packages in `build/elpa`, the Lisp tests use only Emacs's
built-in libraries. A standalone AppKit check
also verifies guest Escape retains focus, while Command-Escape and
focused-view removal return focus to the editor:

```sh
for core in channel views input terminals web toolbar shortcuts; do
  xcrun clang -std=c11 -Wall -Wextra -Werror -I native/Core/include \
    -c native/Core/$core.c -o build/$core.o
done
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -I native/Core/include -import-objc-header test/native-core.h \
  native/Backend.swift native/CoreCalls.swift native/NativeHost.swift native/NativeInput.swift \
  native/Launcher.swift native/Hotkeys.swift \
  native/Views.swift native/Toolbar.swift native/WebToolbar.swift native/WebView.swift \
  test/native-checks.swift test/native-terminal-stub.swift test/native-views.swift \
  test/native-focus.swift build/channel.o build/views.o build/input.o build/terminals.o \
  build/web.o build/toolbar.o build/shortcuts.o \
  -framework AppKit -framework WebKit -framework Carbon -o build/check-focus
build/check-focus
```

The checks open web views through the core's registry and the macOS primitives,
as Emacs does, with `test/native-views.swift` in place of the Emacs bindings. They also
check that a hosted web view keeps no data between sessions, that a page
outside the app host goes to the default browser while the app stays, that
only a hosted app's main frame can use the bridge, that `portalBridge` is ready
before the page's scripts on first load and on reload, that a failed delivery
reaches Emacs, and that a hosted app reports each committed page over it.
Loading the page on screen again reloads it without a new history entry. A click on it sends `select`, and a click
on a local link, even one longer than a record, returns the keyboard to Emacs
and sends `follow` over the bridge. A full notification pipe delays records without losing or
reordering them, retried on the Swift timer, and records still waiting when
Emacs replaces the pipe go to the new one; a closed view's records never go.
`test/native-terminal-stub.swift` stands in for the terminal kind, so they build
without Ghostty, and they link the core's registry, input handoff, terminal and web
rules, toolbars and pipe without the Emacs bindings.

Replace `test/native-focus.swift` and `build/check-focus` with
`test/native-toolbar.swift` and `build/check-toolbar` to check toolbar layout with
the real core: buttons that keep the keyboard where it was, the ownership dot, back
and forward in previews, zoom limits, the TOC across hiding and reload, typing into
the real find field, Return, Shift-Return and Escape, Command-F and Command-R after the page,
closing find after the keyboard went back to Emacs, live visibility and colors, a
view without a toolbar filling its pane, and a Markdown preview's Open in Emacs.
Keys reach the find field through the event loop, as real presses do, since the
field reads Shift from the current event.

Both standalone checks use `test/native-checks.swift` to print failures with a
source location and exit with status 1. Use its `check`, `require`, and `fail`
helpers for test expectations, and `runChecks` at the entry point to report thrown
errors. This keeps ordinary test failures from triggering macOS crash dialogs;
crashes in the native code under test are still reported by macOS. The checks
still open real windows to exercise AppKit and WebKit.

For the launcher's native checks, replace `test/native-focus.swift` and
`build/check-focus` in that command with `test/native-launcher.swift` and
`build/check-launcher`. They exercise negative monitor origins, offset/clamping
rules, display-change notifications, attachment rejection and rollback, donor
restoration, focus-loss records and panel release.

For global shortcuts, use `test/native-shortcuts.swift` and
`build/check-shortcuts`. They register real Carbon hot keys through the core's
shortcuts, as the Emacs bindings do, on F13 to F16, which other apps are
unlikely to have. A competing registration in the process stands in for another
application: its chord is refused, and the previous one keeps working. They check
that a chord is taken while registered and free once released or replaced, that
setting the same chord again keeps its Carbon registration under a new ID and
restarts it, so that a press from before the set that Carbon delivers only
afterwards sends nothing, that a hot key event from before its registration, an
unknown one and a held key's repeats send nothing, that records reach the pipe with no view open, and that
the Carbon handler is removed with the last hot key, over 20 set/remove cycles.
Events are sent to the installed handler, not typed.
The graphical `portal-launcher-gui-` tests use
the real Emacs NS view, including repeated show/hide and delete/recreate,
appearance/font changes, child-frame deletion, native keyboard input and exact
geometry on every connected monitor. A test-only Carbon event injector covers
the installed native callback, pipe parsing, and command-loop show/dismiss under
a transient keymap. This injection does not establish physical-key or Spaces
behavior. Run them with subroutine trampolines enabled.
Command-session tests type native Escape and queue C-g into nested prompts, invoke the
shortcut again, delete/disable during a prompt and immediately re-enter. They
exercise stock completion and Vertico/Orderless/Marginalia, propagate a command
error after hiding, and use the running Finder app to verify cancellation,
successful external activation and actual native focus-loss delivery. The
focus test temporarily activates already-running applications, including Finder.
The NS injector holds synthetic C-g even in an ordinary `read-string`, so that
key is tested as an Emacs command-loop event. Physical C-g and mouse click-away
are covered by the user's recorded daily-use acceptance. Session ID
and stale-record policy are covered by batch ERT and the C notification tests.
The launcher's shortcut is a global shortcut there: the injected press shows
and hides the panel through the real command loop, and one from before the
mode was enabled again is ignored.

Presentation tests run a real Vertico picker in a minibuffer panel at two
sizes. From inside the prompt they check that the minibuffer is the panel's
only window, starts at the top and fills it, that ten candidates show
unclipped with no mode line, and that the native geometry is as requested;
typing, Down and Return select a candidate. In a minibuffer panel, stock
completion completes with Tab and shows `*Completions*` nowhere. A buffer panel
shows or hides the mode lines of its window, a split and switched buffers,
while the ordinary window on the same buffer keeps its own. Alternating kinds
and mode-line settings keeps one launcher frame and restores every session
setting; afterward, ordinary prompts with stock completion and Vertico use the
ordinary frame as before. The dismissal, error, focus-loss and cancellation
focus tests run in both kinds. With `PORTAL_LAUNCHER_SCREENSHOTS` set to a
directory, these tests save pictures of the panel there. The injector's
`portal-test-capture-target` reads them from the surface Emacs drew into, so it
needs no Screen Recording permission; they show no panel shadow or corners.

The graphical `portal-global-shortcut-gui-` tests send hot key events to the
installed Carbon handler with `portal-test-hotkey`, with no Portal view or
launcher frame. Two shortcuts, a lambda and a command, run through the real
command loop while another application stays frontmost, and no frame or window
changes. A function's error leaves the next queued press to run, a press from
before a function changed on the same chord is ignored, and a removed shortcut's
hot key is no longer handled. Held and doubled presses run once, and a shortcut
runs inside a minibuffer prompt's command loop. These do not establish physical
key delivery: `test/global-shortcut-smoke.sh` starts a disposable Emacs for a
person to press two chords in another app, and prints what ran and which app
was in front.

Verify the failure reporter without opening windows:

```sh
python3 -B -m unittest discover -s test -p 'test_native_checks.py'
```

The C core has its own tests. They load the real bindings, compiled
with `test/portal-fake-backend.c` in place of the Swift backend, into batch Emacs
with `--module-assertions`. They need only CMake, a C compiler and Emacs; they do not
use Swift, Apple frameworks, Bun or Ghostty. The application itself still requires
macOS, and so does the core's pipe for now: it relies on `F_SETNOSIGPIPE`.

```sh
cmake -S native/Core -B build/core
cmake --build build/core
ctest --test-dir build/core --output-on-failure
```

`ctest -R views` runs `test/portal-views-tests.c`, a C program that drives the view
registry with the fake platform, which counts every primitive the core calls and any
call that names a destroyed view or a view of the wrong kind. It checks that targets
are never reused, including after close or a failed open; that invalid targets,
wrong-kind lookups and invalid rectangles reach no platform view; that repeated
placement attaches the same platform view each time, and repeated hiding detaches it
once; that a failed placement, or a primitive the platform refuses, changes nothing;
that hiding keeps a session and its size and placing it in another frame keeps the
same platform view; and that closing destroys a view once, after which neither Lisp
calls nor a late record from the platform reach it.

`ctest -R input-core` runs `test/portal-input-tests.c`, which presses keys as a
user would through the fake platform. The fake routes each press as the macOS
platform does, holding what the core says to hold and replaying it when the test
runs its event loop, and plays a page's answers and Emacs's side with
`portal--input` actions. It checks who gets each key: a terminal's program gets
typing and every chord but Super's, which falls through to Emacs as typed; a
page is offered each chord, and keeps those it uses, while an unused one goes
to the view's shortcuts or Emacs, with the keys typed after it; Super-C and
Super-V copy and paste; and the keyboard moving while a page decides. It also
checks that keys typed before Emacs acknowledges are held and replayed in
order, and stay with Emacs when its command never read them;
that only the first key after a native binding's chord, when it repeats it,
goes to the app, while after a chord that fell through the trigger is
Emacs's and its repeats are dropped; C-g, Command-Escape and Emacs's unfocus;
that a click abandons a handoff before it selects the pane, while Emacs's own
focus changes do not; that serials of finished or abandoned handoffs, or another
view's, do nothing; that hiding or closing ends a handoff; binding profiles,
with Shift and punctuation; and that an invalid or colliding binding leaves the
previous configuration working.

`ctest -R terminals` runs `test/portal-terminals-tests.c`, which drives the core's
terminal rules with the same fake platform. It checks that invalid options, including
unknown or inexact theme names, create nothing; that the theme catalog is sorted and
escaped; that a theme reaches every open terminal and no web view, that an unknown name
reaches none, and that a terminal rejecting it stops the change there; that Enter
follows a paste only when asked and never after a failed paste; that wrong-kind,
unknown and closed targets reach no platform view; that platform errors and refusals
reach Lisp; and that a terminal whose process exited stays open and describable until
closed. Records go to a real pipe: a change sends one `terminal` record, later changes
wait until the view is inspected, and web views, unknown targets and closed terminals
send none.

`ctest -R toolbar-core` runs `test/portal-toolbar-tests.c`, which drives the core's
toolbars with the fake platform, answering its finds and script calls by hand. It
checks each layout's buttons and which of them work, including views without a
toolbar and an invalid `:toolbar`; zoom steps and text sizes stopping at their limits,
and a size the platform refuses; the keyboard's text size, Command-F and Command-R shortcuts,
which a page that uses those chords keeps; the ownership dot and its clicks; searches running one at a time in
order, newer text replacing waiting searches, match counting and wrapping; a page
that loads dropping old results and searching again; the table of contents across
pages; closing find only returning the keyboard to a view that has it; state kept
across hiding, another frame and hidden toolbars; drawing only what changed, and
drawing again after a refused draw; clicks on buttons a toolbar does not have; and
that a closed view hears nothing.

`ctest -R web-core` runs `test/portal-web-tests.c`, which drives web views' rules and
the bridge as Lisp and a platform would, with records going to a real pipe. It checks
which URLs load, that about:blank in a new view and the document on screen do not add
history entries, and that a failed load keeps the view's address. On the bridge, it
checks message order, `change` coalescing, one record until Emacs receives, draining
and re-arming, and payloads larger than a record. It rejects frames, other pages and
the core's own types, and ordinary pages get no bridge. It checks every navigation
decision, including claimed origins in user names; that a local link or an edit sends
`escape` before `bridge`, even with a URL longer than a record; that a delivery failure
from a page that has gone is ignored; and that a closed view hears nothing. It checks
`:appearance` before a view opens, and that an appearance reaches every open web view,
oldest first, stopping at one that fails.

`ctest -R shortcuts-core` runs `test/portal-shortcuts-tests.c`, which plays the
platform for the core's global shortcuts, with records going to a real pipe. It
checks the notation's spellings and its invalid forms, including NUL bytes;
that another registration's chord, an invalid one, one the platform refuses and
a removed ID change nothing; that the same chord restarts its platform
registration under a new ID while another chord is registered before the old
one is released, and that a release the platform refuses keeps both; that IDs
are never reused; and that a press sends one record until released, carries the
current ID, and sends nothing once its shortcut has moved or gone.

The full build runs the same module tests as `ctest --test-dir build -R module`. They check
the 30 functions and their arities, the input functions' conversion of chords and
binding JSON, the toolbar theme's conversion of face colors, and the conversion of
options, edges, and strings,
including NUL bytes and non-ASCII text. They also check that malformed strings (non-strings,
raw bytes, surrogates), vectors, and plists, and invalid optional arguments, signal
without calling the backend. A signal raised while converting an argument reaches
Lisp unchanged, and a backend error becomes a Lisp `error` with its message. A
bridge record for the fake platform's echoing app reaches a connected pipe, waits while
none is, and survives its reader being deleted.

`ctest -R channel` runs `test/portal-channel-tests.c`, a C program that drives the
pipe with real POSIX pipes, firing the fake platform's timers by hand. It fills a
pipe and checks that records of every kind arrive in order, none lost or
duplicated, as it drains. It also covers records waiting while disconnected or
moving to a new pipe, cancelled retries, malformed and oversized records,
descriptor ownership, and a closed reader with SIGPIPE's default action, which
would end the test. A narrow write seam interrupts or shortens writes, which a
real pipe cannot do on demand.

The compiled-host integration tests run without a graphical display:

```sh
./build.sh
ctest --test-dir build --output-on-failure
```

They exercise real HTTP requests, a relocated binary with no Bun on PATH,
shared startup, graceful shutdown, restart, crash recovery, startup timeout,
and partial or incompatible readiness messages.
They also check Markdown output, local link rewriting, rereading saved changes,
invalid paths, access-token and Host validation, and non-executable raw HTML.
Task browser tests use real folders: recursive discovery of both layouts,
groups and parent tasks, repeated names, Unicode names and encoded IDs,
unreadable folders, symbolic links, status and title rules, problems and
duplicates, filtering, the tree and execution views of one dependency graph,
ID-preserving moves and conversion, reloads after edits, link rewriting from
nested folders, missing and invalid roots, and image reads kept inside the
attachment folder.

## Scope

Web and terminal views support any number of buffers, each with one view that
follows its buffer into any frame.

The buffer remains an ordinary Emacs buffer. This does not add native widgets to
Emacs's text rendering system. The module runs inside Emacs, so use a separate
`emacs -Q` process while experimenting.

Implementation files are licensed under [GPL-3.0-or-later](LICENSE).
