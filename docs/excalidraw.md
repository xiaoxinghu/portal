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

## Slides

A drawing's slides are its frames. **Slides** in the drawing's menu, or
`M-x portal-excalidraw-arrange`, covers the editor with Arrange, which shows
them in order: a filmstrip with each slide's number, image and frame name, the
selected slide large, and its presenter notes. The mode line says `:Arrange`
after the mode's name meanwhile. A drawing without frames says so.

- Slides follow the number in each frame's `customData.slidesOrder`, the key
  Excalidraw+ uses; frames with the same number, then frames without one, go
  top to bottom, then left to right. Notes are the frame's
  `customData.presenterNotes`. Arrange shows them; it does not change them yet.
- A slide's image is the frame alone, cut at its edge, on the drawing's
  background, and looks the same in a light or dark Emacs. Arrange draws again
  only the slides whose frame or contents changed since it last drew them.
- Arrange opens at the slide nearest the middle of the editor's view. `Up` and
  `Down` select a slide; `Return`, or a double click, edits it: the editor comes
  back showing that frame. `Escape`, the **Draw** button or
  `M-x portal-excalidraw-draw` go back to the editor where it was.
- Command-S and `C-x C-s` save in Arrange too. Other keys never reach the
  editor under it; chords Arrange does not use reach Emacs.
- Looking at slides never modifies the buffer. `C-c C-r` and `revert-buffer`
  reopen the drawing in the editor.

`portal-host` bundles Excalidraw 0.18.1, React, CSS, lazy modules and fonts. Bun
installs pinned npm dependencies at build time; runtime needs neither npm
packages nor internet. The page blocks external assets, CDN font fallbacks and
remote embeds. Document persistence uses neither localStorage nor IndexedDB.
The integration covers local documents, not cloud collaboration, online library
installation, persistent personal libraries or image export.

Restart Emacs after rebuilding the native module. See
[the bridge](editor-bridge.md) for implementation and tests.
