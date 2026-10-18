# Keyboard controls

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Shared keyboard controls

Native views run apps inside Emacs, like pages in a browser. Terminal,
Excalidraw and HTML/Markdown views behave as outside Emacs; unused chords
reach Emacs:

| Keys in a view | Where they go |
| --- | --- |
| Typing: plain and Shift keys, arrows, Return, Tab, Escape | The app, always |
| A chord (Control, Option or Command with a key that types a character) the app uses | The app |
| Command-C, Command-V | Copy and paste, in every view |
| Any other chord | Emacs, as if typed in the view's buffer; Emacs reads the rest of its key sequence |
| Command-period (`⌘.`, configurable) | Return to Emacs and stay there |
| `RET`, or a click, while Emacs owns a Portal buffer | Enter the app |

`s-x` and other Emacs Command bindings work inside terminals; `C-x b` works
on pages that leave Control-X unused. Terminal programs get every Control and
Option chord: tmux keeps `C-b`. Pages get first claim on chords, as in a browser.
Plain keys never reach Emacs, which also binds single keys. Give an Evil Space
leader a chord too, such as `(evil-set-leader 'normal
(kbd "s-'"))`. Emacs handles splits, buffers and switching; views have no tab
or split keys.

Commands finish minibuffer interaction before returning to the selected native
view. Explicit unfocus, errors or selecting an ordinary buffer leave Emacs in
control. `C-g` cancels Emacs key-sequence reading. The content never changes
color or size. Ordinary buffers get no global physical keybinding.

## Who has the keyboard

The window's mode line says who has the keyboard, right after the major
mode's name, where Emacs shows a buffer's process state: `Ghostty[app]` or
`Portal Web[app]` while the view has it, and `Ghostty[emacs]` while Emacs
does, including while Emacs reads a command the view handed it. A terminal
whose program has exited adds `:exited`, as in `Ghostty[emacs]:exited`.
Hovering the indicator says how to move the keyboard.

The state is colored the way Emacs colors a buffer's state elsewhere.
`[app]` is bold in the theme's `warning` color, the face
`portal-mode-line-app`, as compile colors its running status; `[emacs]` is
plain bold, `portal-mode-line-emacs`. While the app has the keyboard the
pane's whole mode line also takes `portal-mode-line-app-line`, by default
the theme's `highlight`, the way solaire-mode recolors its buffers, so the
pane reads as the app's before anyone reads the tag, and explains why an
Emacs key just typed into the app. Themes differ in how far `highlight` is
from their mode line; inherit another of the theme's faces for more contrast.

```elisp
(setq portal-input-mode-line-tint nil)   ; keep the mode line's usual colors
(set-face-attribute 'portal-mode-line-app-line nil :inherit 'secondary-selection)
(set-face-attribute 'portal-mode-line-app nil :inherit 'error)
```

The indicator is the construct `portal-input-mode-line-process`, which
`portal-input-mode` puts in `mode-line-process`, the variable that comint,
compile and eat use for the same purpose. The default mode line and packages
that render that variable, such as doom-modeline, powerline, telephone-line
and mood-line, show it without configuration. A hand-built
`mode-line-format` includes it where it includes the mode name:

```elisp
(setq-default mode-line-format
              '("%e" mode-line-front-space mode-line-buffer-identification "  "
                mode-name mode-line-process "  " mode-line-misc-info))
```

## The escape key

`portal-input-escape-key` reserves one chord across all native views, before
an app can claim it. The default is `"s-."` (Command-period). Change it live with
Customize or, for example:

```elisp
(setq portal-input-escape-key "C-s-g") ; Control-Command-G
```

Use a single printable ASCII key or `<escape>` with Control (`C`), Option (`M`)
or Command (`s`). Multi-key sequences, function keys, and bare or Shift-only
keys are not supported. Write shifted punctuation as `"s-!"`, not `"s-S-1"`.
The previous chord stops being reserved when the setting changes. The escape
works during pending handoffs too, without waiting for Lisp or the app. macOS
and system-wide shortcut utilities can still intercept keys before Portal.

## Web page commands

In Portal web buffers, `g` and `s-r` run `portal-web-reload`, and `l` and `r`
run `portal-web-back` and `portal-web-forward`, with Emacs focus. Command-R
reaches Emacs from inside the page too, unless the page claims the chord. A
page's history survives hiding and redisplay; killing the buffer releases it.

A terminal's native bindings can claim a chord its program would otherwise
get, such as a Control chord (see [the input bridge](terminal-input-bridge.md)).
macOS's own shortcuts, such as Command-Space, still come first.

Click a page or press `RET` to interact. Entering by click also selects its
Emacs pane, keeping selection and keyboard focus aligned. Back in Emacs, `q`
hides the web view and `g` reloads. The mode line and minibuffer remain available.

Restart Emacs after rebuilding the native module to try these controls.
