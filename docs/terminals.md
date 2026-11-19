# Work with terminals

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

- [Quick project terminal](#quick-project-terminal)
- [Independent terminals](#native-ghostty-terminal)
- [Names, projects and directories](#names-projects-and-directories)
- [Choosing terminals](#choosing-terminals)
- [Consult and Embark](#consult-and-embark)
- [Appearance and native bindings](#appearance-and-native-bindings)

For native test procedures, see [Testing Portal](testing.md#view-graphical-checks).

## Quick project terminal

`M-x portal-terminal-toggle` summons a scratch terminal in the frame's bottom
half. Repeat to dismiss and return to editing, even without terminal focus.
No global shortcut is installed. Call `(portal-terminal-toggle)` from Lisp or
bind any Emacs key sequence in your configuration:

```elisp
(keymap-global-set "s-`" #'portal-terminal-toggle)
```

Command chords reach Emacs, so the same key dismisses the panel with Ghostty
focus. See [the input bridge](terminal-input-bridge.md) for native event delivery
to Elisp and native bindings that claim chords, such as Control chords, otherwise
sent to terminal programs.

Each project has one quick shell, summonable from any frame. Panels and remembered
heights belong to frames; summoning elsewhere moves the same shell to that panel.
New shells start at the current file/Dired buffer's project root, found by
`portal-project-function` (default: `project.el`). Help and auxiliary buffers use
the frame's last selected file/Dired directory. Outside projects, the file's
directory applies; without editing context, `portal-terminal-quick-directory`
defaults to home. Remote contexts are rejected.

Dismissal hides the panel, preserving shell, directory, environment, partial
input, scrollback and foreground programs. Reopening never sends `cd` or replaces
the shell. `npm run dev` keeps running while hidden; reopen and interrupt with
`C-c`. File/project switching leaves visible panels unchanged; dismiss and
resummon to select the new project's shell.

Bind these quick-terminal commands to Command chords:
`portal-terminal-quick-dismiss` hides without ending the shell;
`portal-terminal-quick-reset` confirms, then starts a fresh shell at the project
root; `portal-terminal-quick-forget` confirms, then forgets the project's shell.
Reset/forget target the visible panel, otherwise the editing project. Escape,
`q` and `C-g` remain terminal input. Clicking the editor leaves the panel visible.
`portal-terminal-quick-height` sets initial height (default `0.5`); dismissal
remembers manual resizing.

Quick terminals have no ordinary selection, numbering, cycling, naming or
multiple-instance workflow. Busy shells stay busy until completion or
interrupt/reset. Frame deletion only hides the shell; quitting Emacs ends it,
with no restart persistence. Exited shells do not silently restart: use reset.

Run the buffer/window/project tests with `ctest --test-dir build -R quick-terminal`.
`ctest --test-dir build -R terminal-metadata` uses the fake native module to check
names, projects and directory reports: same-name project disambiguation,
root lookups after renames, hidden reports, changes during opening, ignored
directory reports, reassignment, exits/kills, all-field completion with Emacs
styles, and quick-terminal name/project retention. The graphical suite tests
Command-chord toggling from inside the panel and a real foreground process
continuing while it is hidden.

## Native Ghostty terminal

To compare terminal performance, run `./benchmark.sh --label portal` inside the
embedded shell and `./benchmark.sh --label ghostty` in standalone Ghostty.
See [benchmark methodology and FPS research](terminal-benchmark.md) for
latency, frame timing, optional Instruments captures and interpretation limits.

After `./build.sh`, load `portal.el` and run `M-x portal-terminal`, or launch a
fresh graphical Emacs:

```sh
emacs -Q -L "$PWD" -l "$PWD/portal.el" --eval '(portal-terminal)'
```

The pane embeds a real Ghostty Metal surface. Ghostty owns the PTY, shell,
terminal state, fonts, rendering, selection and scrollback. Your normal shell
starts in the current local `default-directory`; interactive commands, Vim and
other TUIs use the real protocol engine, not Emacs text, WebKit or Bun.

- Click or press `RET` in the terminal buffer to focus it.
- The shell gets typing and every Control/Option chord, including Escape,
  `C-g`, `C-c` and tmux's `C-b`. Emacs runs Command chords in the terminal buffer,
  then returns focus.
- `Command-period` (`⌘.`, configurable via `portal-input-escape-key`),
  Escape twice [once turned on](keyboard.md#escape-twice), or
  **Return to Emacs** leaves Emacs in control. Use normal
  bindings, then `RET` to re-enter Ghostty.
- Mouse-select and use `Command-C` / `Command-V` for the macOS clipboard;
  trackpad or mouse wheel scrolls. Non-Latin IME composition remains manually
  unverified.
- The mouse pointer over a terminal is the one Ghostty asks for: the I-beam
  over its text, the hand over a link while Command is held, and the arrow
  while a program, such as Vim or tmux, has the mouse. A fed terminal's pane
  shows it beside the grid too.
- `quit-window`, buffer switching and frame deletion only hide terminals;
  redisplay returns the same running shell. Buffer kill or
  `portal-terminal-close` ends its shell; `portal-terminal-close-all` ends all
  embedded shells, and the [Rex blocks](rex.md#end-a-block) shown in Emacs.

These commands have no keys; bind them in Emacs, using Command chords for
access inside terminals:

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

These are Emacs operations: terminal buffers replace tmux windows, Emacs windows
replace panes. Emacs handles splits, buffers and switching; terminals have no
tab/split keys. Run tmux inside a terminal to retain `C-b`. There are no saved
per-terminal pane layouts or tmux copy mode. Each buffer has one Portal view,
which stays in its pane whichever pane is selected; other panes showing the
buffer say the terminal is showing elsewhere, and `RET` or a click there brings
it ([ADR 0001](adr/0001-one-portal-view-per-buffer.md)). Splitting a terminal
leaves it where it was, so the new pane is free for another buffer. Views
belong to no frame: switching to a terminal elsewhere moves its view, shell and
scrollback. After `C-c C-k` the buffer stays and says the terminal has ended. Selection,
numbering and cycling cover every terminal. Different buffers can display and
run simultaneously.

### Names, projects and directories

Portal names buffers once at startup: `*terminal: portal*` for project `portal`
shells, `*claude: portal*` for `portal-terminal-start` running `claude`; Emacs
adds `<2>` for repeats. Matching root names, such as worktrees both called
`portal`, become `research/portal`; outside projects, names use the abbreviated
start directory. Rename with `portal-terminal-rename` or `rename-buffer`;
Portal never renames again, regardless of program titles.

Terminals belong to their starting directory's project, found by
`portal-project-function` using `project.el` by default; Projectile users can
set it to `projectile-project-root`. Shell directory changes leave assignment unchanged.
`M-x portal-terminal-set-project` reassigns, or clears with a prefix. Quick
terminals always retain their original project.

Shell directory reports update the buffer's `default-directory` (used by
`C-x C-f`, Dired and new terminals) and `list-buffers-directory` (shown by Ibuffer
and `list-buffers`). Ghostty's bundled integration reports at every zsh/bash
prompt; any program can report via OSC 7. Ghostty accepts only this host's
reports. Portal rejects nonexistent/nonlocal directories, such as container
paths, and never passes reports to TRAMP. Until a report arrives, the buffer
retains the starting directory.

Each terminal also reports its foreground program: the executable of the
process group in the foreground of its pty, the shell at a prompt and the
program while one runs. Nothing announces that a shell started a program, so
Portal samples it at each title and directory report and about once a second.
A terminal multiplexer stops directory reports at itself; the program fact
still names it, so user configuration can recognise one and follow its state
through its own interface.

Program exit adds `:exited` to the mode line; buffer and last output remain
until killed.

Packages can use `(portal-terminal-buffers PROJECT QUICK)` to list terminals in
creation order. PROJECT filters by assigned root, regardless of current shell
directories; QUICK includes quick terminals. `(portal-terminal-metadata BUFFER)`
returns `:name`, `:project`, `:directory`, `:title`, `:program`, `:progress`,
`:exited`, `:quick` and `:status`, cached from native change reports even
while hidden. `:status` is what a [Rex block's](rex.md#what-a-blocks-program-is-doing)
program says it is doing, such as an agent waiting for you, and nil for
every other terminal.
These are only facts: titles are program-set, not process names; `:program` is
an executable path, the shell's at a prompt, or nil until one is known; live
shells may be busy or idle.

The buffer of a [Rex block](rex.md#a-buffer-for-every-block) is a terminal
too, from the moment Emacs connects, whether or not a window has shown it
yet: it is listed, chosen and cycled to like the others, and showing it
opens its view. Its details come from its server, as
[the Rex guide](rex.md#a-blocks-details) says; until a window first shows
it, Portal knows only its name and project.

`(portal-terminal-start DIRECTORY PROGRAM ARGUMENTS NAME)` runs PROGRAM with
literal ARGUMENTS in a new terminal, optionally named NAME, and shows it with
`pop-to-buffer` under Emacs display rules. The native adapter starts the
user's interactive login shell, lets it load startup files, restores DIRECTORY,
then runs the program with `exec`. The shell's PATH resolves programs; Emacs
need not find them. Arguments are quoted literally, including spaces, quotes,
Unicode and shell metacharacters. Launches support POSIX-compatible shells
(`sh`, `bash`, `zsh`, `dash`, `ksh`) and fish. The shell owns its environment:
Lisp-side `setenv`, buffer-local `process-environment` and `exec-path` cannot
affect launched programs. The shell reports missing programs inside the
terminal.

### Choosing terminals

`M-x portal-terminal-choose` lists all terminals;
`M-x portal-terminal-choose-project` filters by current project: the terminal's
assignment, or the edited file/Dired buffer's project, regardless of shell
movement. `M-a` switches lists, preserving input. Candidates show name, project,
directory and title; completion matches every field. Category `portal-terminal`
tries `basic` and `substring` before your styles, like Emacs buffers; customize
with `completion-category-overrides`. With Orderless, `portal api npm` finds a
terminal titled `npm run dev` in project `portal`'s `api/` directory. Each
candidate is annotated with the program in its foreground, by file name, and
with whether it is quick or has exited. [Rex blocks'](rex.md#portals-terminal-commands)
buffers are listed with the rest.

When a [Rex block's program says what it is doing](rex.md#what-a-blocks-program-is-doing),
as Claude Code does, its candidate shows it in a column after the name: a mark
and a word, the same width in every row. A blocked program shows why, such as
`question`, `permission` or `auth`, or `blocked`; then `failed`, `done` and
`working`. Other terminals have a blank column, so the rest of the line stays
aligned; with no status in the list there is no column, and the list looks as
it always has. The program's message follows in the annotation, cut to
`portal-terminal-status-message-width` columns, or, for a block that waits
without one, how long ago it reported:

```
*rex: work/claude*     ● question  portal  ~/portal  Clean up the task now?
*rex: work/ken*        ✓ done      ken     ~/ken     12 min ago  zsh
*rex: work/claude<2>*  ◌ working   portal  ~/portal  Reading slides.ts
*terminal: portal*                 portal  ~/portal  zsh
```

The words are part of the candidate, so typing `question` or `working`
keeps those blocks. The faces `portal-terminal-status-blocked`, `-error`,
`-done` and `-working` inherit `warning`, `error`, `success` and `shadow`;
`portal-terminal-status-marks` sets the marks, for a font without them.

Blocks that [wait for you](rex.md#what-a-blocks-program-is-doing), blocked
or finished and not yet seen, come first, the one that has waited longest at
the top. Recently selected terminals follow; the current one comes last,
waiting or not. `RET` on empty input takes the first. Order, columns and
messages are fixed at opening; previews do not count as selections. `portal-terminal-next`, `-previous` and `-select-index` retain
creation order.

The New group starts terminals at the project root, or current directory
outside projects. "New named terminal…" prompts first: `server` yields
`*server: portal*`. Completion requires a listed entry; typing alone never starts
a shell. Quick terminals require `portal-terminal-choose-quick` and open in their
panels. Choosing from a quick panel opens in the editing window behind it,
leaving the panel visible; cancelling returns to it.

Killing a buffer with a running program always asks first, whether through
`C-x k`, Ibuffer, Embark or `portal-terminal-kill-pane`. Ghostty programs are
not Emacs processes, so Emacs's own process question never appears. Set
`portal-terminal-confirm-kill` to nil to skip confirmation. Its default, t,
asks while the program may be busy: Portal cannot tell a shell of its own at
its prompt from a busy one, so it asks for every running program, as
`always` does, while a [Rex block](rex.md#end-a-block) at its prompt ends
without a question. Exited programs need none; quick reset/forget retain
their own questions. `M-x portal-terminal-select`
selects by name, where terminals of its kind show.

### Consult and Embark

Loading `portal.el` and Consult, in either order, enables
`portal-terminal-consult-mode` without configuration. `consult-buffer` accepts
`t SPC` for Portal-only terminals; pickers use Consult with your completion UI.
Portal never requires Consult. When a terminal picker opens before anything
has loaded Consult, and Consult is installed, the picker loads it, so the first
picker after startup already previews, even when your config loads Consult
lazily. Vertico, Orderless and Marginalia use ordinary completion.

Opt out with `portal-terminal-consult-auto-enable` set to nil before loading
Portal and Consult: pickers then never load Consult either. Or disable active
integration with `M-x portal-terminal-consult-mode`; it stays off.

Enable the optional Embark adapter and project picker binding in your config:

```elisp
(with-eval-after-load 'embark
  (require 'portal-terminal-embark)
  (portal-terminal-embark-mode))
(keymap-set project-prefix-map "t" #'portal-terminal-choose-project) ; C-x p t
```

`portal-terminal-consult-mode` adds Consult preview and narrowing to pickers:
`t` for terminals, `w` for the blocks that wait for you, `n` for New.
`consult-buffer` and `consult-project-buffer` add a Terminal group, hidden until
narrowing with `t` (`t SPC`, or `consult-narrow-key` then `t`). It contains all
terminals or those assigned to Consult's project; the default list still shows
each once as a buffer. `consult-buffer` adds a Waiting group too, hidden until
narrowing with `w`: the Rex blocks that wait for you, longest waiting first,
so "who needs me" is `w SPC`. In a picker, `w` keeps those of the terminals
it lists.

`M-.` previews the terminal at point in the originating window, or the editing
window behind a quick panel. The live view moves there, even across frames,
and returns on moving on/cancelling; only acceptance counts as selection.
Programs see the preview window's size, so preview waits for `M-.` by default.
Previews never take focus: typing stays in the minibuffer. Quick terminals are
not previewed. To preview on movement or change narrowing keys:

```elisp
(consult-customize portal-terminal-consult-source portal-terminal-consult-project-source
                   :preview-key '(:debounce 0.3 any) :narrow ?T)
```

The Waiting group is `portal-terminal-consult-waiting-source`, customized the
same way.

`consult-buffer`'s Buffer group previews terminals like other buffers, using
`consult-preview-key`. Marginalia replaces Portal's annotations in Consult's
groups, the program's message among them, with buffer mode/directory
annotations; the status column is part of the candidate and stays.

`portal-terminal-embark-mode` keeps terminal candidates as buffers: Embark buffer
actions work; `E` exports to Ibuffer. Live-terminal targets in any prompt,
Ibuffer or Embark Collect also get these actions; other buffers retain Embark's
buffer map:

| Key | Action |
| --- | --- |
| `RET` | Select it where terminals of its kind show |
| `r` | Rename it |
| `d` | Open Dired in its directory |
| `c` | Start another shell in its directory: a new shell, not a copy |
| `W` | Copy its directory |
| `p` | Assign it to another project, or with `C-u` to none |
| `k` | End it, asking as killing it asks |

Actions target sessions even after same-prompt renames. Candidates mixed with
New export to Embark Collect, like mixed Consult lists; narrow with `t` for Ibuffer.

Projectile users set both project functions. `consult-project-function` takes
MAY-PROMPT; the old `consult-project-root-function` no longer exists.

```elisp
(setq portal-project-function #'projectile-project-root
      consult-project-function (lambda (_may-prompt) (projectile-project-root)))
```

With terminal focus, Command bindings reach Emacs, including in quick terminals:

```elisp
(keymap-global-set "s-b" #'consult-buffer)
(keymap-global-set "s-t" #'portal-terminal-choose-project)
```

Minibuffer closure focuses the chosen terminal; cancellation refocuses the
originating terminal.

Adapters are tested with GNU ELPA Consult 3.10, Embark 1.2, Vertico 2.15,
Orderless 1.8, and MELPA Consult 20260829.1558 and Embark 20260610.302. Internal
APIs—Consult's `consult--multi` and `consult--buffer-preview` source helpers and
Embark's `embark--targets`—are confined to `portal-terminal-consult.el` and
`portal-terminal-embark.el`.

`ctest --test-dir build -R terminal-choose` checks pickers using Emacs completion
and the fake native module: recent-use order, creation-order cycling, assigned
projects, `M-a`, New, quick panels, closed terminals and kill confirmation, and
the status column, its order and its filtering.
`-R 'terminal-(consult|embark)'` checks adapters against the releases above,
downloaded to `build/elpa` and hash-verified by CMake. A keyboard macro types into
a real minibuffer, exercising Consult narrowing/preview/lookup and Embark targets,
actions and Ibuffer export as in normal use.

## Appearance and native bindings

Configure in Lisp after loading `portal.el` (changes apply to running terminals):

```elisp
(setq portal-terminal-theme "Dracula") ; nil follows system light/dark appearance
```

`portal-terminal-theme` takes an exact, case-sensitive name from
`(portal-terminal-themes)`, set through `setq` or Customize, even before loading
Portal in your init file. Changes recolor running terminals, including hidden
ones, and apply to new ones without restarting shells. `nil` restores Alabaster
(light) and Afterglow (dark). Named themes ignore system appearance changes.

In a frame that is itself see-through, such as one with a frosted
background, terminals can be see-through too:

```elisp
(setq portal-terminal-opacity 0.85) ; from 0 to 1; the default, 1, is opaque
```

Below 1, every terminal draws its theme's background at that opacity, so
the frame shows through it. Its text, cursor and selection stay solid,
and so do cells a program gives a background of its own: a colored
`ls`, a status line, and a full-screen program that paints its whole
screen, such as vim with a color scheme or htop. That is Ghostty's rule
for `background-opacity`, and Portal keeps it. A
[Rex block](rex.md) held smaller than its pane is glass across the pane,
with no seam around its grid. Changes apply to running terminals, hidden
ones included, and to new ones, and outlast theme and text size changes.

The text Emacs keeps in a view's buffer, the placard that says where the
view is, is hidden in the pane that has the view, so it never shows
through; other panes showing the buffer still show it.

In an ordinary, opaque frame the terminal shows Emacs's own background
through itself instead, tinting it. So set the opacity where the frame
becomes see-through, and back to 1 where it stops. With the frost
package, for example, whose global `frost-mode` makes the frame frosted:

```elisp
(add-hook 'frost-mode-hook
          (lambda () (setq portal-terminal-opacity (if frost-mode 0.85 1))))
```

Portal does not ask whether a frame is see-through: the setting is the
whole of it.

A terminal's text is the size of Emacs text: the height of the `default`
face in the frame that shows it, times its buffer's text scale. Portal has
no size setting of its own. Whatever changes the base font changes the
terminals with it, reflowing their grids without restarting shells:
`global-text-scale-adjust` (`C-x C-M-=`, `C-x C-M--`, `C-x C-M-0`) for every
frame, `set-face-attribute` on one frame, `set-frame-font`, or a theme. A
terminal in a frame with a larger font is larger, and one shown in another
frame takes that frame's size. `text-scale-adjust` zooms one terminal, as it
zooms any buffer: `C-x C-=`, `C-x C--` and `C-x C-0`, or Command-=, Command--
and Command-0, which reach Emacs from inside Ghostty too
([keys](keyboard.md#terminal-commands)). The mode line shows the usual text
scale lighter, such as `+1`. Sizes may be fractional, and a terminal shows
nothing smaller than 6 points or larger than 72. A hidden terminal takes its
size when it is shown again.

To keep terminals a step smaller than the rest of Emacs text, zoom each
new one out:

```elisp
(add-hook 'portal-terminal-mode-hook (lambda () (text-scale-set -1)))
```

Command chords run in the terminal buffer using its keymaps. Minibuffer
interaction finishes before focus returns to the selected terminal. Ordinary
buffer selection leaves Emacs in control. Custom commands can call
`portal-terminal-unfocus` to stay in Emacs even with a terminal selected;
errors also leave focus in Emacs.

`portal-terminal-native-map` adds opt-in standalone/nested shortcuts to all
terminals, claiming otherwise program-bound chords such as Control;
`portal-terminal-quick-native-map` overlays it for quick terminals. Make live
changes with `portal-terminal-bind-key` / `portal-terminal-unbind-key`, or call
`portal-terminal-refresh-bindings` after direct edits. Maps start empty with no
global shortcuts. First chords are one modified ASCII key in `kbd` notation:
Meta means Option, Super means Command. Remaining keys use normal Emacs notation.

The C core catches Command and registered first chords, notifying Emacs through
the pipe shared by every Portal view
([details](terminal-input-bridge.md#the-notification-pipe)). It holds fast follow-up
keys until Lisp can read the keymap and run the command. Ordinary I/O stays
native, without polling timers or Lisp terminal redraws.

The terminal uses the pinned [GhosttyTerminal Swift wrapper](https://github.com/Lakr233/libghostty-spm/tree/2.2.2026110702)
and its Ghostty build, with Portal's
[patches](../CONTRIBUTING.md#the-ghostty-dependency). Release 2.2.2026110702 ships Ghostty
[`042b16b`](https://github.com/ghostty-org/ghostty/commit/042b16b6146ada29877dfeeea9f286889e4adeb1)
of 2026-11-01. The Rex server the [test VM](test-vm.md) pins,
0.1.0-preview.14, carries Ghostty `5813c9461` of 2026-11-06, 169 commits
later, so a terminal the server runs can use sequences Portal's copy does not
know yet; `tools/ghostty-version.py` reports
[how far apart they are](rex.md#ghostty-versions). Themes come from the wrapper's bundled catalog;
standalone Ghostty preferences are not loaded.
Ghostty app-level window/tab commands are unimplemented; its Command bindings
never apply, since the core routes them to Portal shortcuts or Emacs. Buffers
contain instructions, not live terminal text, so Emacs search/movement cannot
operate on it. Native input/presentation still shares Emacs's main thread:
latency parity during GC or long-running Lisp is not guaranteed.

`(portal--inspect (portal-view-target))` reports actual native surface, grid,
bounds, focus and title for the selected terminal. `(portal--terminal-text TARGET)`
selects and returns all native scrollback text, leaving selection active.
Neither is normally polled. Restart Emacs after rebuilding a loaded module.

## On Linux

In an Emacs built with pgtk, on Wayland, a terminal is the same Ghostty,
built by Portal from source with its own patches
([Ghostty on Linux](../CONTRIBUTING.md#ghostty-on-linux)), and drawn on a
surface of its own over the pane ([how](architecture.md#terminals-on-linux)).
What differs from macOS:

- **Keys.** The escape back to Emacs is Control-Escape
  (`portal-input-escape-key`). Ghostty's own copy and paste are
  Control-Shift-C and Control-Shift-V; its other Linux key bindings are
  off, so Alt and Control chords reach the shell. Super chords go to Emacs,
  as Command chords do on macOS.
- **Themes** are the catalog of the Ghostty Portal builds, with the same
  names. Without `portal-terminal-theme`, a terminal is Alabaster or
  Afterglow as the desktop prefers light or dark, which the XDG desktop
  portal says, and changes with it.
- **The clipboard** is the desktop's, and selecting text copies it to the
  primary selection. A paste that Ghostty would ask about, such as text with
  a newline in it, goes ahead: you asked for it. A program asking to read
  the clipboard is refused, since there is nobody to ask.
- **Rex blocks** do not open: their fed terminals need patches Portal's
  Linux build does not apply yet.
