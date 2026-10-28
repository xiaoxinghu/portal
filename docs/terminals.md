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
- `quit-window`, buffer switching and frame deletion only hide terminals;
  redisplay returns the same running shell. Buffer kill or
  `portal-terminal-close` ends its shell; `portal-terminal-close-all` ends all
  embedded shells.

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
per-terminal pane layouts or tmux copy mode. Each buffer has one Portal view
in its selected pane; other panes showing it display only buffer text
([ADR 0001](adr/0001-one-portal-view-per-buffer.md)). Views belong to no frame:
showing a terminal elsewhere moves its view, shell and scrollback. Selection,
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
`:exited` and `:quick`, cached from native change reports even while hidden.
These are only facts: titles are program-set, not process names; `:program` is
an executable path, the shell's at a prompt, or nil until one is known; live
shells may be busy or idle.

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
terminal titled `npm run dev` in project `portal`'s `api/` directory. Exited/quick terminals
are annotated.

Recently selected terminals come first; the current one comes last. `RET` on
empty input takes the first. Order is fixed at opening; previews do not count
as selections. `portal-terminal-next`, `-previous` and `-select-index` retain
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
`portal-terminal-confirm-kill` to nil to skip confirmation. Exited programs need
none; quick reset/forget retain their own questions. `M-x portal-terminal-select`
selects by name, where terminals of its kind show.

### Consult and Embark

Loading `portal.el` and Consult, in either order, enables
`portal-terminal-consult-mode` without configuration. `consult-buffer` accepts
`t SPC` for Portal-only terminals; pickers use Consult with your completion UI.
Portal neither loads nor requires Consult. Vertico, Orderless and Marginalia
use ordinary completion.

Opt out with `portal-terminal-consult-auto-enable` set to nil before loading
Portal and Consult, or disable active integration with
`M-x portal-terminal-consult-mode`.

Enable the optional Embark adapter and project picker binding in your config:

```elisp
(with-eval-after-load 'embark
  (require 'portal-terminal-embark)
  (portal-terminal-embark-mode))
(keymap-set project-prefix-map "t" #'portal-terminal-choose-project) ; C-x p t
```

`portal-terminal-consult-mode` adds Consult preview and narrowing to pickers:
`t` for terminals, `n` for New. `consult-buffer` and `consult-project-buffer` add
a Terminal group, hidden until narrowing with `t` (`t SPC`, or
`consult-narrow-key` then `t`). It contains all terminals or those assigned to
Consult's project; the default list still shows each once as a buffer.

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

`consult-buffer`'s Buffer group previews terminals like other buffers, using
`consult-preview-key`. Marginalia replaces Portal's exited/quick notes with
buffer mode/directory annotations.

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
projects, `M-a`, New, quick panels, closed terminals and kill confirmation.
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

The terminal uses the pinned [GhosttyTerminal Swift wrapper](https://github.com/Lakr233/libghostty-spm/tree/2.2.2026100303)
and its Ghostty build. Themes come from the wrapper's bundled catalog;
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
