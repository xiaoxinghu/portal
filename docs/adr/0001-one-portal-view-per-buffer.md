# One Portal view per buffer, staying in its pane

Every buffer has at most one Portal view: a terminal session or a hosted app's document can appear in only one place at a time, and this rule keeps all view kinds consistent. For two web pages side by side, open two buffers. Other panes showing the buffer show its text, a placard: "This terminal is showing in another pane. RET or a click brings it here." Once the view closes while the buffer lives, the placard says so instead.

The view stays in the pane it is in while that pane shows its buffer, whichever pane is selected. It used to go to the selected pane showing its buffer, so it jumped on a mere change of selection: in a terminal, splitting and then selecting the new pane swapped the terminal and the buffer text between the two panes. The person split to put something else in the new pane; the terminal crossing over on the way looked like a bug. Nothing we surveyed moves a live view on a change of focus alone: Emacs's own xwidgets on macOS stay in the first window, and browsers leave a placard where a picture-in-picture video was.

The view moves in exactly three cases:

- Its pane is deleted or shows another buffer. It goes to another pane showing the buffer: the selected pane if that is one, else the first in window order, in any frame. With none, it is hidden, not ended.
- The buffer is switched into the selected pane: the pane shows the buffer now, was live when the views were last placed and did not show the buffer then, as after `switch-to-buffer` or the terminal chooser. While the minibuffer is selected, the selected pane is the window it returns to, so previews there, such as Consult's, show their views, and cancelling one returns the view to a pane that still shows the buffer. A pane a split made since never takes the view this way.
- A take: RET or a click in a pane showing the placard brings the view there and gives it the keyboard.

`portal-view.el` keeps what it needs to tell these apart: the live windows when the views were last placed, and for each view the windows that showed its buffer then. Emacs's `window-old-buffer` makes the same distinction, but only where the window change hooks run; batch tests place views directly.

## Considered Options

- **A native view in every pane showing the buffer.** Web views formerly gave each pane an independent page. We dropped this because terminals and hosted apps cannot support it; retaining it for web alone would give view kinds different lifecycles. Mirroring one view into other panes from an offscreen render is not allowed for WKWebView on macOS, and a GPU terminal would pay for it on every frame.
- **The view follows the selected pane showing its buffer.** It made the view jump on a change of selection, as above.
