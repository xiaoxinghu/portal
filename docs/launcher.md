# Configure launchers and global shortcuts

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

- [Global shortcuts](#global-shortcuts): register functions without showing a panel
- [Native launcher panel](#native-launcher-panel-opt-in): examples and setup
- [Set up safely](#set-up-safely): compatibility and fresh-session requirements
- [Presentation options and lifecycle](#presentation-options-and-lifecycle)

## Global shortcuts

Pressing a global shortcut's chord calls a Lisp function from any application
without activating Emacs, selecting a frame or showing a panel. The function decides what appears.
Loading Portal registers nothing. Name each shortcut with a symbol:

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

Re-setting a name replaces its chord/function and releases the old chord,
keeping one registration per name across configuration reloads. Interactive
commands use `call-interactively`; other zero-argument functions use `funcall`.
Lambdas capturing values, like `pattern` above, need lexical binding: start the
file with `;;; -*- lexical-binding: t -*-`. Without it, Emacs 31 uses dynamic
binding and pressing that shortcut signals `void-variable`.
`portal-global-shortcut-set` returns the name. It errors without changes for:

- Names other than non-nil symbols.
- Functions requiring arguments.
- Invalid notation or a chord held by another name (identified in the message).
- Chords macOS refuses because the system or another application holds them.

`portal-global-shortcut-remove` returns t if the name was set, nil otherwise.
It signals only if macOS cannot release the chord, retaining it on failure.

Notation uses case-insensitive, hyphen-separated modifiers (`Control`, `Option`,
`Command`, `Shift`) followed by `A`–`Z`, `0`–`9`, `Space`, `Escape` or `F1`–`F20`.
Require at least one of Control, Option or Command; never repeat a modifier.
Letters/digits denote **US physical key positions**, independent of input layout
and Emacs's `ns-*-modifier` settings. Shift must be explicit; capitals do not
imply it. Fn, Caps Lock, punctuation, left/right modifier distinctions and
multi-key sequences are unsupported. Function keys must send the key, not its media action.
Alternate spellings, such as `command-control-option-p`, denote the same chord.
System-reserved shortcuts or hotkey utilities may intercept registered chords;
choose another if delivery fails.

The native module registers chords with Carbon. Presses send records through
Portal's notification pipe even without open Portal views, subprocesses or an
Accessibility event tap. The filter only queues input; the command loop calls
the function like a bound key, including during minibuffer prompts. Emacs must
be running; busy Lisp delays calls, with no responsiveness guarantee.
Holding a chord calls once. Presses are dropped if the same shortcut already
has a waiting press, or if they predate its latest set/removal. During key
sequences or single-key prompts, presses are read there instead and call nothing.

Function errors produce a message naming the shortcut, or open the debugger
with `debug-on-error`. All shortcuts remain set; unlike other command errors,
no waiting input (including other shortcut presses) is discarded. Unloading
`portal-global-shortcut` or exiting Emacs releases all chords. Failed release
prevents unloading and keeps the feature loaded. Removing one shortcut or
disabling/deleting the launcher panel preserves the others.

## Native launcher panel (opt-in)

`portal-launcher.el` presents Emacs functions in one reusable, borderless,
nonactivating macOS panel using Portal's existing module. Portal chooses no
command or chord: loading, presenting and enabling `portal-launcher-mode`
register no global shortcut. Your configuration composes launchers: a command
calls `portal-launcher-present` with options, then runs via M-x, an Emacs key or
a [global shortcut](#global-shortcuts) from any application. Examples below need
no other package and work with or without `lexical-binding`.

First [Set up safely](#set-up-safely): internal Emacs NS interfaces require the
pinned build and native subroutine trampolines. Use fresh disposable graphical
Emacs.

### A minimal picker

After building and loading Portal:

<!-- example: launcher-picker -->
```elisp
(require 'portal-launcher)

(defun my/pick-fruit ()
  "Pick a fruit in Portal's panel and show the choice."
  (interactive)
  (message "Picked %s"
           (portal-launcher-present
            (lambda () (completing-read "Fruit: " '("Apple" "Banana" "Cherry") nil t))
            :kind 'minibuffer)))

(keymap-global-set "C-c f" #'my/pick-fruit)
```

`M-x my/pick-fruit` and `C-c f` run the same command, showing only the prompt
and inline completion UI, such as Vertico. `portal-launcher-present` returns the function's value (the
fruit here), or nil on dismissal.

### A persistent buffer

A buffer UI, such as a dashboard, can outlive its setup function:

<!-- example: launcher-hello -->
```elisp
(define-derived-mode my/hello-mode special-mode "Hello")
(keymap-set my/hello-mode-map "n" #'my/hello-greet)

(defun my/hello-greet (name)
  (interactive "sName: ")
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert "\nHello " name "!")))

(defun my/hello ()
  (interactive)
  (portal-launcher-present
   (lambda ()
     (switch-to-buffer (get-buffer-create "*Hello*"))
     (let ((inhibit-read-only t))
       (erase-buffer)
       (insert "Hello world!"))
     (my/hello-mode))
   :kind 'buffer :mode-line nil :keep-open t))
```

With `:keep-open t`, panel commands (here `n`) use its minibuffer until dismissal,
when the call returns nil. Display rules, Escape/C-g and focus handling persist.
Later command errors are reported without closing the panel. Dismissal kills no
buffers; `*Hello*` retains its contents. `:keep-open` requires `:kind 'buffer`
and defaults to nil, hiding on function return. The open panel runs a recursive
edit, bracketing the mode name in the default mode line.

### A buffer that fits its content

A buffer panel can take the height of what it shows, as a minibuffer panel does
by default. Bind an automatic size around the call:

<!-- example: launcher-fitted-hello -->
```elisp
(defun my/hello-fitted ()
  "Show `my/hello' as tall as its text, up to 480 points."
  (interactive)
  (let ((portal-launcher-size '(640 auto))
        (portal-launcher-height-limits '(content 480)))
    (my/hello)))
```

The panel opens at its least height and grows a line with each greeting, then
stops at 480 points, where its window scrolls as usual. Text that timers and
processes insert fits too, without a key press. See
[buffer panels that fit](#buffer-panels-that-fit) for what counts.

![The fitted hello panel after five greetings](images/launcher-buffer-fitted-hello.png)

### Global shortcuts for launchers

Set a global shortcut for each launcher that should open from any
application. A shortcut need not present a panel:

<!-- example: launcher-shortcuts -->
```elisp
(portal-global-shortcut-set 'pick-fruit "Control-Option-Command-F" #'my/pick-fruit)
(portal-global-shortcut-set 'hello "Control-Option-Command-H" #'my/hello)
(portal-global-shortcut-set 'clock "Control-Option-Command-K"
                            (lambda () (message "%s" (format-time-string "%H:%M"))))
```

`(portal-global-shortcut-remove 'hello)` removes only that shortcut. Panel and
shortcut lifetimes are separate: dismissal, hiding, deletion or disabling
`portal-launcher-mode` preserves every shortcut. Re-evaluating configuration
keeps one registration per name. Pressing a launcher's chord with a panel open
cancels its session without presenting another; press again to open another
launcher. See [Global shortcuts](#global-shortcuts) for notation, conflicts and
delivery.

### Application launcher with launcher.el (optional)

Portal includes no application picker. The separate
[launcher.el](https://github.com/xiaoxinghu/launcher.el) discovers apps with
Spotlight, launches/activates them with `open -a` and searches other text online.
`!g`, `!yt` and `!gh` plus a space and query select an engine. It owns its index,
duplicate-name labels, path annotations and `launcher-app-directories`,
`launcher-fallback-search-url` and `launcher-bangs` options. This recipe was
tested at:

```elisp
(use-package launcher
  :vc (:url "https://github.com/xiaoxinghu/launcher.el"
       :rev "731146d95d7d1ff16f48e7a200da873c8d8b375c")
  :commands (launcher launcher-refresh))
```

At that revision, `launcher` searches empty strings and queryless bangs. Stock
Space completes a word, consuming the space in `!gh query`. Until launcher.el
handles these, wrap its reader in your configuration, as Portal's former adapter
did:

<!-- example: launcher-app -->
```elisp
(defvar my/launcher-reader nil
  "The completion reader that `my/launcher-read' calls.")

(defun my/launcher-read (&rest arguments)
  "Read a choice for launcher.el, calling `my/launcher-reader' with ARGUMENTS.
In stock completion, Space inserts a space, so that \"!gh query\" can be
typed.  An empty result or a bang with no query cancels instead of searching."
  (let* ((choice (minibuffer-with-setup-hook
                     (lambda ()
                       (when (eq (key-binding " ") #'minibuffer-complete-word)
                         (use-local-map (define-keymap :parent (current-local-map)
                                          "SPC" #'self-insert-command))))
                   (let ((completing-read-function my/launcher-reader))
                     (apply my/launcher-reader arguments))))
         (words (split-string choice)))
    (when (or (null words)
              (and (null (cdr words)) (assoc (car words) launcher-bangs)))
      (signal 'quit nil))
    choice))

(defun my/app-launcher ()
  "Launch an app or search the web with launcher.el in Portal's panel.
With a prefix argument, launcher.el rebuilds its app index first."
  (interactive)
  (let ((my/launcher-reader completing-read-function)
        (completing-read-function #'my/launcher-read))
    (portal-launcher-present #'launcher :kind 'minibuffer)))

(portal-global-shortcut-set 'app-launcher "Control-Option-Command-P" #'my/app-launcher)
```

The panel shows only prompt and candidates. With Vertico or another highlighting
UI, Return accepts the highlighted app without typing, including the first or
an Up/Down selection. Stock completion shows no candidates in a minibuffer
panel: type a name, complete with Tab, or use `:kind 'buffer` for `*Completions*`.
Stock Space inserts a space and Tab completes; customized Space bindings remain.
The wrapper preserves your reader and global settings, leaving `M-x launcher`
unchanged. A variable rather than a closure holds the reader, supporting files
with or without `lexical-binding`.

`C-u M-x my/app-launcher` rebuilds the index before prompting;
`M-x launcher-refresh` rebuilds separately. Refresh after installing, removing
or moving apps. Launching focuses the app as the panel hides. Escape, C-g,
the chord again, empty results and queryless bangs close without action,
returning focus to the previous app. Clicking another app hides the panel and
keeps that app frontmost. Discovery/launch errors close the panel; retry is
possible. Once launcher.el handles all three input rules, present `#'launcher`
directly and remove `my/launcher-read` and its variable. The
[application notes](launcher-applications.md) record upstream follow-ups and
an optional integration smoke test.

### Set up safely

Start in disposable graphical Emacs: internal NS dependencies mean native defects
can crash it. Initially only GNU Emacs NS **31.1**, revision
`a360712c9d272d950d8d8255ef74570f7e90b7d9`, is accepted. Rebuild Portal and restart
Emacs before using new bindings. Native-compiled Emacs needs working
`modify-frame-parameters` and `delete-frame` trampolines to prevent guard bypass
or deletion with live session prompts. Keep `native-comp-enable-subr-trampolines`
enabled; a missing, unbuildable trampoline prevents presentation before frame
creation.

First test new setups in fresh disposable Emacs with your completion/theme
settings. After they pass, explicitly evaluate them in a fresh normal session. The launcher
runs inside Emacs without the app host, a separate application or per-invocation
`emacsclient`. Emacs must already run; long Lisp work delays invocation.

`(portal-launcher-mode -1)` deletes the panel and frame guards. Ordinary frames,
Portal views and global shortcuts remain usable; the next presentation recreates
the panel. The shared native module stays loaded for other features. Restart
Emacs to replace it; rebuilding or unloading Lisp cannot replace a loaded module.

To remove a configured launcher, delete its init setup and run
`(portal-global-shortcut-remove 'app-launcher)` and `(portal-launcher-mode -1)`.
Other Portal features and shortcuts keep working.

### Presentation options and lifecycle

The explicit buffer API remains available:

```elisp
(portal-launcher-show (get-buffer-create "*Launcher*"))
(portal-launcher-resize 713 407)
(portal-launcher-hide)
(portal-launcher-show)          ; same frame and content
(portal-launcher-mode -1)       ; delete the frame
```

`portal-launcher-present` chooses appearance per call without registering
shortcuts or changing completion:

```elisp
;; Only the prompt and an inline completion UI, such as Vertico:
(portal-launcher-present (lambda () (completing-read "Fruit: " '("Apple" "Banana")))
                         :kind 'minibuffer)
;; Any function of no arguments; its value is returned:
(portal-launcher-present (lambda () (read-string "Name: ")) :kind 'minibuffer)
;; A buffer window without mode lines:
(portal-launcher-present #'my/buffer-command :kind 'buffer :mode-line nil)
```

`:kind 'buffer` (default) shows a buffer window above the panel's own minibuffer.
Displayed buffers appear in the panel; call-created windows are deleted on hide.
`:kind 'minibuffer` makes the whole panel a minibuffer: prompt first, inline
completion directly below. Displayed buffers appear nowhere:
stock `*Completions*` is hidden, though Tab completes and Return accepts. Vertico,
Icomplete's vertical mode and Fido show candidates. Commands displaying/previewing
buffers, splitting windows or otherwise needing a buffer window require `buffer`.

Changing kind replaces the dedicated frame; repeating the same kind reuses it.
By default, a minibuffer panel's height fits its content, and with `(WIDTH auto)` a
buffer panel's does too; see [Panel size](#panel-size).

`:mode-line nil` hides panel mode lines, including new windows and switched
buffers; default t shows each buffer's own. It sets the `mode-line-format`
window parameter, preserving other frames' mode lines, then restores previous
parameters on hide. Minibuffer panels have no mode lines.

Interactive commands use `call-interactively`, receiving prefix arguments;
zero-argument functions use `funcall`. They run with `*Portal Launcher*` current,
the panel's minibuffer and the user's completion setup, including Vertico,
Orderless and Marginalia. Nested prompts stay there. Invalid functions/options
error before anything appears.

Function return hides the panel unless kept open. Escape, C-g, another
invocation, `portal-launcher-hide` or keyboard focus loss cancels the whole
session. Errors propagate after cleanup. Frame deletion/disabling unwind prompts
before releasing the frame. Cancellation returns focus to the previous app while
the panel owns the keyboard; successful external actions and click-away preserve
destination focus. Original Emacs window selection returns without activating
Emacs. Display rules, presentation options and cancellation keys are session-only.

Functions must be synchronous. Invoke after any existing minibuffer has
finished. Functions that deliberately use other frames or catch arbitrary
throws need explicit wrappers.

Customize [`portal-launcher-size`](#panel-size) (default nil),
[`portal-launcher-height-limits`](#height-limits) (default `(100 nil)`), `portal-launcher-offset`
(`(0 0)`, positive right/down), `portal-launcher-screen` (nil: pointer's monitor),
`portal-launcher-font`, `portal-launcher-shadow` and `portal-launcher-corner-radius`.
Each presentation or show applies them, including `let` bindings. Size/offsets use
AppKit logical points, independent of Retina scale. The panel centers in the
monitor's usable area, clamps onscreen and repositions on display changes.
`portal-launcher-frame-parameters` sets initial colors, fringes and borders.

Fonts, buffers and appearance use ordinary Emacs customization. Native roles are
fixed: decoration, fullscreen, parentage, toolbar and focus-policy changes are
rejected. Deleting the frame is supported; the next show recreates it. Hide
preserves launcher content and selects the previous ordinary window without
changing its buffer.

For plain buffer presentation outside a command session, finish or cancel an
active launcher minibuffer before hiding it. Outbound native drag-and-drop is
cancelled.
See [implementation and measured geometry](launcher-native-panel.md).

#### Panel size

`portal-launcher-size` sets each kind's size, in AppKit logical points:

| Value | Minibuffer panel | Buffer panel |
| --- | --- | --- |
| `nil` (default) | Width 720, height fits its content | 720 × 420 |
| `(WIDTH auto)` | Width WIDTH, height fits its content | Width WIDTH, height fits its buffer in a presentation |
| `(WIDTH HEIGHT)` | Fixed WIDTH × HEIGHT | Fixed WIDTH × HEIGHT |

WIDTH is an integer of at least 200, HEIGHT one of at least 100. Buffer panels
keep their size unless you choose `(WIDTH auto)`; see
[buffer panels that fit](#buffer-panels-that-fit). A fitted
minibuffer panel's height follows what it displays, as that changes: the
prompt, the input with its wrapped lines, the completion UI's visible rows
(including group titles and annotations) and messages shown inline in the
minibuffer, plus the frame's internal borders. Typing that narrows five
candidates to two or none shrinks the panel; deleting it grows the panel again.
Completion updates from timers fit without a key press, and nested prompts fit
as they start and end. Your completion UI still chooses how many rows to show,
for example with `vertico-count`; Portal changes no completion setting.

The panel opens no taller than its content at that moment, normally the
minimum before the prompt appears, centered as the offset and screen settings
say. That first placement fixes its screen, left edge, width and top edge for
the presentation: later changes move only the bottom edge, so the prompt stays
put, and moving the pointer to another display moves nothing. By default the
height never drops below 100 points, so a one-line prompt can leave space below
it; [height limits](#height-limits) change that bound and add a maximum. Growth
stops at the bottom of the monitor's usable area; rows beyond it are clipped,
while the prompt stays at the top and completion keys keep working. A change
in the display arrangement may center the panel again; its new top edge then
stays. An echo-area message, which briefly replaces the minibuffer, keeps the
input's height.

```elisp
(defvar vertico-count)  ; Vertico's option: bind it dynamically, as Vertico reads it

(defun my/app-launcher-five ()
  "Run `my/app-launcher' showing five Vertico rows, at width 640."
  (interactive)
  (let ((portal-launcher-size '(640 auto))
        (vertico-count 5))
    (my/app-launcher)))
```

Numeric sizes are fixed, not maxima: an existing `'(720 240)` keeps its blank
space below a short list, and content taller than a fixed height clips at the
bottom. Remove the setting to fit minibuffer panels, or replace it with
`'(720 auto)` to fit both kinds. `portal-launcher-resize` always sets numeric
dimensions, for both kinds, and stops a buffer panel fitting for the rest of
its presentation; it refuses to run during a minibuffer presentation, whose
panel cannot become a buffer panel. Interactively it offers the current
numbers, or 720 × 420.

![A fitted panel with five Vertico rows and group titles](images/launcher-minibuffer-fitted-rows.png)

![The same panel after typing "alp"](images/launcher-minibuffer-fitted-filtered.png)

![No matches: the 100-point minimum](images/launcher-minibuffer-fitted-minimum.png)

#### Buffer panels that fit

With `(WIDTH auto)`, a buffer panel's height follows its window's buffer during a
`portal-launcher-present` call, as a minibuffer panel's follows its prompt. Bind
it around the calls that should fit, as in
[a buffer that fits its content](#a-buffer-that-fits-its-content), or set it for
both kinds. Outside a presentation, `portal-launcher-show` needs a numeric size
and signals an error otherwise.

The panel measures the buffer as Emacs displays it at the panel's width:
wrapped lines, faces and line spacing, images and overlay strings, plus the
window's mode, header and tab lines and the frame's internal borders. A final
newline adds the empty line after it, where the cursor can be. It measures from
the buffer's beginning wherever the window is scrolled, so scrolling or moving
point never shrinks the panel, and it stops measuring at the maximum height, so
a long chat or log costs no more than a full panel. Typing, commands, text that
timers and processes insert, and switching the window to another buffer all
refit, in the same panel, native session and keyboard focus, without a key
press. Portal never moves point, scrolls or truncates: at the maximum height or
the bottom of the screen, the window scrolls as Emacs always does, and whether
it follows new output is up to the buffer's own code.

The buffer window never gets shorter than Emacs's `window-min-height`, 4 lines
by default, so a one-line buffer leaves blank lines below it; lower that option
for more compact panels. Completion UIs such as Vertico grow and shrink the
minibuffer from Lisp, which signals `args-out-of-range` in a window shorter
than that.

The minibuffer below counts as one line. While it reads a prompt, the panel
makes room for what the prompt displays, including an inline completion UI's
rows, and shrinks again as they narrow; a prompt that the buffer window also
shows, as `vertico-buffer` does, counts once. Emacs's `max-mini-window-height`,
a quarter of the frame by default, still decides how much of that room the
minibuffer takes; the buffer window gets the rest. Vertico lets its minibuffer
take all it needs. An echo-area message never resizes the panel: Emacs shows it
as in any frame, over the buffer's last lines when it needs more than one, and
the buffer shows whole again once the message clears.

The panel fits one window. If the call splits it, the height stays as it is,
but at least the split windows' legal height, and the windows are left as the
call made them; fitting resumes once one window is left. While all of the
buffer fits, the window shows it from its beginning. `portal-launcher-resize`
stops fitting for the rest of the call.

#### Height limits

`portal-launcher-height-limits` bounds a fitted height as `(MIN MAX)`, in
points. It applies only where `portal-launcher-size` fits content; numeric
sizes stay fixed and ignore it. The default `(100 nil)` keeps the behavior
above.

| Element | Values |
| --- | --- |
| MIN | A positive integer, or `content` for the panel frame's legal height |
| MAX | `nil` for the space below the panel's top edge, or a positive integer of at least MIN |

```elisp
;; As short as the prompt allows, and at most 480 points tall:
(setopt portal-launcher-height-limits '(content 480))
```

Four heights decide the panel's size, each overriding the ones before it:

1. **Content height**: what the panel displays, plus the frame's internal
   borders, as described above.
2. **Configured limits**: MIN raises it and MAX caps it. Content beyond MAX
   is clipped at the bottom, as at the screen's edge.
3. **Legal frame height**: the least height Emacs allows the panel's frame:
   the minibuffer's line, each other window's least height, and the internal
   borders, at the frame's font. A window's least height is a line of its text
   with its mode and header lines, and at least `window-min-height` lines.
   A minibuffer panel needs one line; with Menlo 24 and the default 16-point
   borders that is 60 points. A buffer panel needs its window's least height
   too, four lines with Emacs's default `window-min-height`. With MIN
   `content`, a one-line prompt shrinks the panel to it; a numeric MIN below
   it gives it too. Emacs keeps a frame at least this tall, so a shorter panel
   would cut off its prompt or break completion UIs that resize the
   minibuffer; Portal never asks for one, and changes no window-size setting
   to allow one.
4. **Available space**: the panel stops at the bottom of the monitor's usable
   area, below its anchored top edge. This wins over everything, so a panel
   near the bottom of a small display can be shorter than MIN or than its
   legal height.

Invalid limits signal an error before anything is shown, an active session is
cancelled or a shown panel is replaced. That includes a MIN larger than MAX and
a MAX below the legal height of the panel the presentation would show. The
legal height depends on that panel's font and decorations: Portal measures an
existing minibuffer panel when the presentation would reuse it unchanged.
Otherwise it measures a hidden candidate frame, then deletes it: with the
existing panel's own borders and other size parameters plus
`portal-launcher-font` when the presentation would reuse that panel with that
font, or with a new panel's parameters when it would make one. A buffer panel's
candidate has the existing panel's font and windows, which the presentation
keeps, with the buffer the presentation shows first in the selected one, and
mode lines as `:mode-line` asks. If the legal height grows later in a
presentation, as with a larger font or another buffer's header line, it wins
over MAX rather than cutting off the prompt. Each presentation reads
the option once, including a `let` binding of it; fitting never changes it.

With `'(content 144)`, Menlo 24 and the default borders, five rows stop at 144
points, then no matches shrink the panel to its 60-point legal height:

![Five rows capped at 144 points](images/launcher-minibuffer-limited-maximum.png)

![The 60-point legal height: the prompt alone](images/launcher-minibuffer-legal-minimum.png)
