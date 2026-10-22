# Input bridge

Emacs hosts native apps as a browser hosts pages. Views behave like their apps
outside Emacs; unused chords reach Emacs through the view buffer's keymaps.
The module's C core routes each key; Emacs owns commands and remaining key
sequences. Runtime Elisp bindings need no rebuild or restart.

## Who gets a key

The core (`native/Core/input.c`) routes keys pressed in a view to the first taker:

1. **The configured escape**, Command-period (`⌘.`) by default, returns and
   leaves the keyboard with Emacs. `RET` in the view's buffer or a view click
   returns it to the view. Set `portal-input-escape-key` to change this reserved
   chord live; it is the last resort when an app uses needed keys. With
   `portal-input-double-escape`, a plain Escape typed soon after another
   that the app got, with no press between, returns too.
2. **A native binding** (below): a chord claimed for Emacs in terminals.
3. **The view's app.** Only chords can continue: character-typing keys with
   Control, Meta (Option) or Super (Command). Plain and Shift keys, and
   non-character keys (arrows, Return, Tab, function keys), always stay in the app.
   - Terminal programs get every chord except Super's: tmux gets `C-b`, the
     shell `C-a` and `M-f`. macOS Ghostty sends programs nothing for Super
     unless they enable the kitty keyboard protocol; Portal gives those up.
   - Web pages are offered each chord and keep those they use.
4. **The view's shortcuts.** Super-C copies and Super-V pastes in every view.
5. **Emacs** reads the remaining sequence, including plain keys, through the
   view buffer's keymaps, including Evil's, and runs the command as if typed there.

Plain keys never reach Emacs: single-key bindings such as Evil's `i` would make
view buffers act strangely. Views resemble Evil's insert state: plain keys type,
chords reach Emacs, the configured escape, or Escape twice, leaves native input
([Evil](keyboard.md#evil)). Give a Space leader a chord binding too, like Doom's `M-SPC`:

```elisp
(evil-set-leader 'normal (kbd "s-'"))
```

## Native bindings

Native bindings claim terminal-program chords, such as Control chords, for
Emacs commands. Super chords need none: they reach Emacs anyway.

```elisp
;; A nested shortcut available in every terminal:
(portal-terminal-bind-key portal-terminal-native-map
                          "C-] b" #'switch-to-buffer)

;; Only in quick terminals:
(portal-terminal-bind-key portal-terminal-quick-native-map
                          "C-]" #'portal-terminal-toggle)

;; Remove an interception at runtime:
(portal-terminal-unbind-key portal-terminal-native-map "C-] b")
```

Both maps start empty. The quick map overlays the shared map; removing overrides
reveals shared bindings. Removing a prefix map's last command releases its first
chord to Ghostty. Helpers apply changes immediately; direct
`keymap-set`/`keymap-unset` edits require `portal-terminal-refresh-bindings`.
Maps apply only while the native terminal has focus. Repeating a binding's first
chord as the next key sends it to the program.

## Across the boundary

The native input machinery is shared by terminal and web views.

1. Registration validates and snapshots native maps. Only first chords cross
   into the module as characters and Portal modifiers (Shift 1, Control 2,
   Meta 4, Super 8), never platform key flags. Command maps stay in Lisp.
   The C core rechecks and replaces both profiles only without collisions.
2. The platform captures view key presses as chords: the character typed with
   Shift but no other modifier (or no character), plus modifiers. On macOS,
   Option is Meta and Command is Super. The core answers: pass, take, hold or offer.
   - Handoff returns the keyboard to Emacs and sends the view target and a new
     handoff serial through the notification pipe. The platform holds the
     trigger and all subsequent key events until Lisp acknowledges.
   - Offering delivers a chord to the page, holding subsequent events until it
     answers. WebKit resends unused keys through the application; the platform
     reports them through `portal_input_unused`, and the core runs a shortcut
     or starts a handoff. Pages that use chords receive the held events.
     Usage is known after an isolated-world script in every frame reports
     delivery and WebKit finishes all its keys. In editable content, keys reach
     WebKit's queue only after the input method finishes. WebKit would deliver
     the next queued key before returning an unused one, so pages receive one
     chord at a time. After one second without an answer, a chord counts as
     used if the page saw it; otherwise, including views without pages, it does not.
3. `portal-input--dispatch` selects the originating view's Emacs window and
   acknowledges. The platform replays held events in order, including repeats,
   releases and modifier changes. Lisp reads a fallthrough chord's sequence
   with `read-key-sequence-vector` and the buffer's keymaps, or a native binding's
   remaining prefix map. Normal command remapping applies; execution occurs
   outside the process filter.
4. Completion releases the trigger and normally focuses the selected Portal view.
   Subsequent keys belong to Emacs. Keys unread by the sequence or command
   (including after a whole-command chord) become its next command; Emacs keeps
   the keyboard while any wait. It also keeps it for pending prefix arguments
   or transient keymaps, such as those left by `universal-argument` and isearch;
   explicit unfocus; errors; ordinary buffers; or user-ended handoffs. Commands
   hiding the originating view, such as showing another terminal in its pane,
   silently end its handoff; the selected view still resumes. When finishing
   fails, Lisp first drains existing pipe records: an `escape` sent during a
   command, even one reading no input, keeps Emacs in control.

View handoffs are idle, awaiting acknowledgement, reading a command, or executing
it, separate from platform-reported keyboard ownership. Lisp actions name the
handoff serial and act only while it remains active; late acknowledgements or
completions never affect other handoffs or views. Hiding, closing or Emacs's
`unfocus` silently ends a handoff. User termination through the escape chord or a
view click first sends `escape`. So do hosted local-link handoffs: the web
core (`native/Core/web.c`) calls `portal_input_escape` before sending
`bridge`. Emacs-initiated focus changes never end handoffs. Pages never take the keyboard themselves: a page focusing
an element, as autofocus does, makes WebKit ask the window for it, and the
platform refuses unless the view has the keyboard or Emacs, the core or a click
is giving it. The platform checks `portal_input_is_escape` before holding
or offering a key, then returns focus immediately without Lisp or JavaScript
round trips. The core times Escape twice by each key's press time, which
the platform passes with every key, so an Escape held behind an offer and
replayed later counts from when it was typed. On the second, the core
returns focus itself and answers TAKE. `portal--input-escape-key` validates and replaces the core's reserved
chord; the same setting updates the Portal buffer's Emacs keymap.

While Emacs reads a sequence, `C-g` cancels it and trigger repeats are dropped.
Pressing the trigger again joins the sequence, as in `C-x C-x`. WebKit retries
of unhandled keys are consumed after first delivery, so page input never later
becomes an Emacs command.

## The notification pipe

All native notifications share one pipe. `portal-view.el` owns the reading end,
creating the pipe process with the first view and passing it to `portal--channel`.
The C core owns the writing end (`native/Core/channel.c`). Input handoffs send
records directly; platform code, including hosted bridges and click `select`
records, calls the core's `portal_notify`.

Records are single lines, `TYPE TARGET FIELD...`, of space-separated printable
ASCII words, at most `PIPE_BUF` bytes for atomic writes. The core rejects other
records and returns acceptance status. Delivery preserves send order. Full pipes
queue records in the core, retried by a platform-provided timer: busy Emacs delays
but never loses or reorders them. Without a connected pipe, or after Emacs closes
its end, records wait for reconnection and precede new records on the new pipe.
The pipe never raises SIGPIPE, so closed readers cannot terminate Emacs; children
do not inherit it. Input records include the handoff serial:

| Record | Sent when |
| --- | --- |
| `key TARGET SERIAL CHARACTER MODIFIERS` | A chord the view's app did not use reaches Emacs, as typed: Shift made CHARACTER |
| `binding TARGET SERIAL EVENT` | The view captures the first chord of a native terminal binding |
| `literal TARGET SERIAL 0` | A binding's first chord is repeated while Emacs reads the rest of the sequence |
| `cancel TARGET SERIAL 0` | `C-g` is pressed in the view while Emacs reads the rest of the sequence |
| `escape TARGET SERIAL 0` | The configured escape cancels a handoff, as does a click that hands off to Emacs or selects the view's pane |

Entering a view by click sends `select TARGET`; Emacs selects its pane. Each
change of whether a view has the keyboard, whatever moved it, sends
`focus TARGET 1` or `focus TARGET 0`, which the buffer's mode line shows. Terminal
title, working-directory or process-state changes send one `terminal TARGET`
until Emacs inspects the view for the new text, of any length.

Reads can split records or contain several. `portal-view.el` assembles lines
and dispatches through `portal-view-record-handlers`, calling each type's handler
with the target buffer current. Missing buffers or handlers cause records to be
dropped. Process-filter handlers never prompt. `portal-input` registers five
input types and queues records as events such as
`(portal-input-key (TARGET SERIAL CHARACTER MODIFIERS))` for the command loop;
a `focus` record only updates the buffer's mode line.
`portal-web` registers `bridge` for hosted-app messages
([the bridge](editor-bridge.md)). `portal-terminal` registers `terminal`, caching
`portal--inspect` results in the terminal buffer.

## Boundaries and verification

Native bindings start with modified printable ASCII: `C` = Control, `M` = Option,
`s` = Command. Use resulting punctuation (`s-!`, not `s-S-1`); remaining keys use
normal Emacs syntax. The reserved escape accepts one printable ASCII key or
`<escape>` with Control, Meta or Super; see [keyboard controls](keyboard.md).
System-wide shortcuts, such as Spotlight's Command-Space, intercept events
before Portal.

Verified with:

- [Registration tests](../test/portal-terminal-bindings-tests.el).
- [Core input tests](../test/portal-input-tests.c): fake-platform key presses and
  page answers; routing order, used/unused offers, shortcuts, keyboard changes
  during offers, delayed acknowledgement, rapid tails, repeated triggers, literal
  delivery, cancellation, stale serials, and hiding/closing during handoffs.
- Batch [Lisp input tests](../test/portal-input-tests.el): sequences read through
  buffer keymaps including Evil, escape, cancel, type-ahead, prefix arguments
  and transient keymaps.
- Batch [record dispatch tests](../test/portal-view-tests.el): split, batched and
  unknown-target records.
- [Pipe tests](../test/portal-channel-tests.c): full pipes, reconnects, malformed
  records and closed readers.
- Graphical [terminal](../test/portal-terminal-tests.el) and
  [web input](../test/portal-input-gui-tests.el) tests with real AppKit input:
  Super-chord Emacs commands, `C-b` and `C-a` reaching the shell, used/unused page
  chords, immediate keys after chords (within sequences or after whole commands),
  copy/paste, live rebinding, quick-only scope, shifted characters, cancellation,
  literal PTY bytes and rapid minibuffer input.
