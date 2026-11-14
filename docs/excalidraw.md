# Draw and save local Excalidraw files

[Documentation index](README.md) · [Build and run](../README.md#build-and-run)

## Local Excalidraw drawings

Run `M-x portal-excalidraw` for a new drawing; Command-S or `C-x C-s` names and
saves it. Existing `.excalidraw` files opened with `C-x C-f` or Dired enter
`portal-excalidraw-mode` automatically. A prefix argument to
`portal-excalidraw` prompts for an existing or new file.

- Draw, type, paste text/images, and use the normal Excalidraw editing tools.
- Command-S, `C-x C-s` and the drawing's **Save** button save through Emacs.
  Drawings leave `C-x` unused, so `C-x C-s` reaches Emacs even with drawing
  focus. `C-c C-r` in the buffer reopens the drawing.
- Command-period (`⌘.`, configurable via `portal-input-escape-key`) returns
  keyboard focus to Emacs and subtly grays out the drawing; `RET` re-enters it.
  Bare Escape remains available for drawing/text editing.
- Each drawing buffer has one Excalidraw hosted web view: it opens immediately
  and loads when the app host is ready. Switching buffers hides it, preserving
  contents, selection and undo history. In splits, it stays in its pane;
  `RET` or a click in another pane showing the buffer brings it there. Independent drawings can appear together.
- Drawings use standard Excalidraw JSON with embedded images. Emacs owns saving,
  modified indicators, backup settings, auto-save and overwrite checks.
  Save/close prompts include untitled modified drawings.
- `M-x revert-buffer` reloads from disk. `C-c C-r` reopens a failed view from
  the buffered drawing, preserving unsaved changes but resetting undo history.
  Use it after a host restart if more Excalidraw assets need loading. Stopping
  the host leaves open drawings loaded.

## The scratch drawing

`M-x portal-excalidraw-scratch` is to drawing what `*scratch*` is to text: one
drawing, always there, that saves itself. In a window that does not show it,
the command shows it there, ready to draw in: the drawing has the keyboard,
and its view moves there if another window had it. In the window that shows
it, the same command puts it away: the window shows what it showed before, and
Emacs has the keyboard. No key is bound; bind the command in your
configuration, as for any Portal command.

- It is one `.excalidraw` file, `portal-excalidraw-scratch-file`, by default
  `portal/scratch.excalidraw` in your Emacs directory. The command makes the
  file and its directory when they are missing, and visits it in
  `portal-excalidraw-mode` like any drawing.
- Each change is in the file a moment after the last stroke, with no prompt;
  there is nothing to save. Put away, the drawing keeps its view and undo
  history, so it comes back as it was; killing its buffer, or quitting Emacs,
  writes what is still in flight, and the drawing comes back from the file.
- It never asks: not to save, not to kill its buffer, not to quit. When the
  file changed on disk, as with two Emacsen drawing in it, the drawing
  overwrites it: the last write wins. A write that fails says so in the echo
  area and keeps the buffer modified, and the next change tries again.
  Emacs asks before killing it only while the last write failed, as the
  drawing is then in no file.
- Nothing empties it, and nothing offers to. `C-x C-w` writes it to another
  file: the buffer becomes that file's, an ordinary drawing, and the command
  opens the scratch drawing from its own file again.

Only the scratch drawing saves itself; every other drawing saves when asked.

## Slides

A drawing's slides are its frames. **Slides** in the drawing's menu, or
`M-x portal-excalidraw-arrange`, covers the editor with Arrange, which shows
them in order: a filmstrip with each slide's number, image and frame name, the
selected slide large, and its presenter notes. The mode line says `:Arrange`
after the mode's name meanwhile. A drawing without frames says so.

- Slides follow the number in each frame's `customData.slidesOrder`, the key
  Excalidraw+ uses; frames with the same number, as a duplicated frame has,
  then frames without one, go top to bottom, then left to right. Notes are the
  frame's `customData.presenterNotes`, plain text. Both are kept in the
  drawing's file, so Excalidraw+ reads them too.
- A slide's image is the frame alone, cut at its edge, on the drawing's
  background, and looks the same in a light or dark Emacs. Arrange draws again
  only the slides whose frame or contents changed since it last drew them; a
  new name, number or notes do not change the image.
- Arrange opens at the slide nearest the middle of the editor's view. `Up` and
  `Down` select a slide; `Return`, or a double click, edits it: the editor comes
  back showing that frame. `Escape`, the **Draw** button or
  `M-x portal-excalidraw-draw` go back to the editor where it was.
- Command-S and `C-x C-s` save in Arrange too. Other keys never reach the
  editor under it, but Command-Z and Shift-Command-Z; chords Arrange does not
  use reach Emacs.
- Looking at slides never modifies the buffer. `C-c C-r` and `revert-buffer`
  reopen the drawing in the editor.

Arrange edits a slide's place, name and notes, and nothing else: it neither
makes nor deletes slides, and no frame moves on the canvas. Each edit is
written to the frames in the editor's drawing at once, modifies the buffer
like any change in the editor, and is saved with it.

- **Order**: drag a slide in the filmstrip, or move the selected one with
  `Option-Up` and `Option-Down`. A move numbers every slide `0`, `1`, `2` ...
  in its new order, so it also settles duplicated numbers and frames that had
  none.
- **Notes**: type in the box under the slide. They are written when typing
  stops for half a second and when the box loses the keyboard; empty notes
  remove the key. `Escape` leaves the box for the filmstrip.
- **Name**: click a slide's name in the filmstrip and type. `Return` or
  leaving the field writes it, `Escape` drops it, and an empty name is the
  frame's default, `Frame`.
- **Undo**: each edit is one step of the editor's own undo history. Command-Z,
  in Arrange or in the editor, takes back the last, and Shift-Command-Z
  puts it back. In the notes box or a name, they are the field's own.

## Presenting

**Present** in Arrange or in the drawing's menu, or `M-x portal-excalidraw-present`,
presents the slides from the one Arrange selects, or from the editor from the
slide nearest the middle of its view. Two windows show them:

- The **slide window** is a new Emacs frame with nothing of Emacs in it: no
  mode line, minibuffer, tab bar, tool bar or fringes. It shows the current
  slide, letterboxed on black. Share that window in a video call, or move it
  to a projector and make it fullscreen (`M-x toggle-frame-fullscreen` or the
  green button): while a slide window is open, frames resize to the pixel, so
  a fullscreen one fills the display. It keeps drawing while another window
  covers it or it is on another Space. Customize
  `portal-excalidraw-slides-frame-parameters` to place or size it.
- The drawing's pane becomes the **console**, for the speaker: the current
  slide, as large as fits whatever its frame's size; the next one, small,
  or **End** after the last; the current slide's notes, their line breaks
  kept, scrolling when they are long; `3 / 12`
  and the slide's name; the time of day and the time since presenting
  started, in minutes and seconds, which **Reset** sets back to zero; and
  **Previous**, **Next** and **Stop**. Neither clock is saved. The console
  only shows notes: edit them in Arrange. It keeps the keyboard, and the mode
  line says `:Present 3/12`.

`Right`, `Down`, `Space` and `Page Down` show the next slide; `Left`, `Up` and
`Page Up` the previous; `Home` and `End` the first and the last. They work in
either window, so the slide window can be fullscreen with the console out of
sight, and a presentation clicker, which types `Page Up` and `Page Down`,
works in both.

From Emacs, `C-c C-n` (`portal-excalidraw-next-slide`) and `C-c C-p`
(`portal-excalidraw-previous-slide`) in the drawing's buffer move both windows
too, a prefix argument that many slides, and leave the keyboard where it is.
Being Control chords the console does not use, they reach Emacs from the
console as well. Outside Present they say that the drawing is not being
presented.

`Escape`, **Stop** or `M-x portal-excalidraw-stop-presenting` stops: the slide
window and its frame go, and the drawing shows Arrange at the slide that was
showing. Killing the slide window's buffer, deleting its frame or closing it
stops the same way. Killing the drawing, changing its major mode, `C-c C-r` and
`revert-buffer` close the slide window. Presenting never modifies the buffer.

`portal-host` bundles Excalidraw 0.18.1, React, CSS, lazy modules and fonts. Bun
installs pinned npm dependencies at build time; runtime needs neither npm
packages nor internet. The page blocks external assets, CDN font fallbacks and
remote embeds. Document persistence uses neither localStorage nor IndexedDB.
The integration covers local documents, not cloud collaboration, online library
installation, persistent personal libraries or image export.

Restart Emacs after rebuilding the native module. See
[the bridge](editor-bridge.md) for implementation and tests.
