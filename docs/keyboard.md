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
| Escape twice, quickly, once [turned on](#escape-twice) | Return to Emacs; the app gets the first |
| `RET`, or a click, while Emacs owns a Portal buffer | Enter the app |

`s-x` and other Emacs Command bindings work inside terminals; `C-x b` works
on pages that leave Control-X unused. Terminal programs get every Control and
Option chord: tmux keeps `C-b`. Pages get first claim on chords, as in a browser.
Plain keys never reach Emacs while the app has the keyboard. Emacs, which
also binds single keys, gets them once you return to it; see
[Evil](#evil). Emacs handles splits, buffers and switching; views have no
tab or split keys.

Commands finish minibuffer interaction before returning to the selected native
view. Explicit unfocus, errors or selecting an ordinary buffer leave Emacs in
control. `C-g` cancels Emacs key-sequence reading. The content never changes
color or size. Ordinary buffers get no global physical keybinding.

## Who has the keyboard

The window's mode line has a light right after the major mode's name, where
Emacs shows a buffer's process state: a dot, lit as in `Ghostty ●` or
`Portal Web ●` while the view has the keyboard, and dimmed as in `Ghostty ○`
while Emacs has it, including while Emacs reads a command the view handed it.
A terminal whose program has exited adds `:exited`, as in `Ghostty ○:exited`.
Hovering the light says who has the keyboard and how to move it.

Lit, the dot takes the face `portal-mode-line-app`, by default the theme's
`mode-line-emphasis`, its face for the mode line's live parts. Dimmed, it takes
`portal-mode-line-emacs`, the theme's `shadow`, its face for inactive text.
The dot changes shape as well as face, so it reads under any theme, and in a
terminal. `portal-input-mode-line-light` chooses other characters, for a mode
line font that draws these poorly. While the app has the keyboard the pane's
whole mode line also takes `portal-mode-line-app-line`, by default the theme's
`highlight`, the way solaire-mode recolors its buffers, so the pane reads as
the app's before anyone reads the light, and explains why an Emacs key just
typed into the app. Themes differ in how far `highlight` is from their mode
line; inherit another of the theme's faces for more contrast.

```elisp
(setq portal-input-mode-line-tint nil)   ; keep the mode line's usual colors
(set-face-attribute 'portal-mode-line-app-line nil :inherit 'secondary-selection)
(set-face-attribute 'portal-mode-line-app nil :inherit 'error)
(setq portal-input-mode-line-light '("◆" . "◇"))
```

Anything else in the mode line can follow the light too. In a view's buffer,
the face `portal-mode-line-focus` takes the lit face while the view has the
keyboard and the dimmed face while Emacs has it; elsewhere it is plain. The
hook `portal-input-focus-change-hook` runs in the buffer on each change, and
`portal-input-focused-p` says which. For example, with nerd-icons, as
doom-modeline uses, each kind of view gets its own icon, lit with the light:

```elisp
(with-eval-after-load 'nerd-icons
  (dolist (icon '((portal-terminal-mode nerd-icons-devicon "nf-dev-terminal")
                  (portal-web-mode nerd-icons-mdicon "nf-md-web")
                  (portal-excalidraw-mode nerd-icons-mdicon "nf-md-draw")))
    (add-to-list 'nerd-icons-mode-icon-alist
                 (append icon '(:face portal-mode-line-focus)))))
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

## Escape twice

`portal-input-double-escape` makes Escape typed twice within that many
seconds, with no key between, return to Emacs, as the escape key does. The
app gets the first Escape, as vim or a page dialog would without Portal; the
second never reaches it. A single Escape, or two typed more slowly, stay the
app's. It is off by default: Escape typed twice out of habit in a terminal's
vim would leave the terminal. An Escape that leaves a page's
[fullscreen](#fullscreen-pages) does not count.

```elisp
(setq portal-input-double-escape 0.3)   ; nil turns it off
```

Changes apply live. The interval counts from when each key was pressed, so
a busy Emacs does not stretch it.

## Evil

A view's buffer works like Evil's states. While Emacs has the keyboard, as
it does for a new view until you enter it, every key reaches the buffer in
normal state: a Space leader and other single-key bindings work. Entering the view is
insert state: keys type into the app, and its chords that the app does not
use reach Emacs. To move between them with Vim's keys, bind `i` and turn on
Escape twice:

```elisp
(evil-define-key 'normal portal-input-mode-map "i" #'portal-input-focus)
(setq portal-input-double-escape 0.3)
```

To reach a Space leader without leaving the app, give it a chord too, such
as `(evil-set-leader 'normal (kbd "s-'"))`.

## Web page commands

In Portal web buffers, `g` and `s-r` run `portal-web-reload`, and `l` and `r`
run `portal-web-back` and `portal-web-forward`, with Emacs focus. Command-R
reaches Emacs from inside the page too, unless the page claims the chord. A
page's history survives hiding and redisplay; killing the buffer releases it.

`s-l` reads another URL or a search for this buffer, and `s-t` for a new
buffer ([address bar](web-views.md#address-bar)). `s-d` bookmarks the page,
`b` and `M-s-b` load a bookmarked page in this buffer, and `B` and `s-B` open
one in a new buffer ([bookmarks](web-views.md#bookmarks)).

`C-s` and `s-f` find text in the page, and `s-g` and `s-G` find it again;
`+`, `-` and `0`, or `s-=`, `s--` and `s-0`, zoom its site
([find and zoom](web-views.md#find-and-zoom)), and `s-p` prints it in the
system's print panel ([print](web-views.md#print)). The Command chords reach
Emacs from inside the page too, as Command-R does.

A terminal's native bindings can claim a chord its program would otherwise
get, such as a Control chord (see [the input bridge](terminal-input-bridge.md)).
macOS's own shortcuts, such as Command-Space, still come first.

Click a page or press `RET` to interact. Entering by click also selects its
Emacs pane, keeping selection and keyboard focus aligned. Back in Emacs, `q`
hides the web view and `g` reloads. The mode line and minibuffer remain available.

### Fullscreen pages

A page can go fullscreen, as a video player does from its fullscreen button.
It then fills the screen in a window of its own, where every key is the
page's: Portal's escape key, chords for Emacs and Escape twice do not apply.
Escape leaves fullscreen, as in Safari, and the page returns to its pane, or
wherever Emacs has put its buffer meanwhile. It has the keyboard again if it
had it before, as it does after a click on that button; otherwise Emacs keeps
the keyboard.

Restart Emacs after rebuilding the native module to try these controls.
