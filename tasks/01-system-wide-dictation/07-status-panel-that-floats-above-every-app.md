---
status: done
---
# Status panel that floats above every app

# Status panel that floats above every app

Dictation runs from other apps, where Emacs's mode line and echo area are
out of sight; sounds are the only sign of what it is doing. Show its status,
such as "Recording" or "Transcribing", in a small panel that floats above
every app.

Portal supplies the panel and knows nothing about dictation: Lisp shows a
line of text in it and hides it. Which statuses exist, their wording, and
when to hide an outcome belong to the user's configuration. A waveform is
deferred.

## Options

Added after trying the first version, following Hammerspoon's `hs.alert`,
dunst, posframe and Raycast's HUD and toasts: nine positions, an offset, the
screen, a fixed or bounded size, wrapping to several lines, a tone (neutral,
progress with a spinner, success, warning, error, recording with a
breathing red dot) and a timeout. Icons chosen by the caller, colors,
several panels at once and click actions are deferred.

## Plan

- Platform primitives in `native/Core/include/portal.h`: list the screens,
  measure a panel, show text with a tone in a rectangle, and hide. The core's
  `status.c` picks the screen, the size and the rectangle.
- `portal-status-show TEXT &key ...` and `portal-status-hide` in
  `portal-system.el`; the timeout is a Lisp timer.
- macOS: a borderless nonactivating `NSPanel` that can never become key or
  main and ignores the mouse, at status-bar level, on every Space and over
  fullscreen apps. Showing it never activates Emacs or changes the frontmost
  app or its keyboard focus.
- The fake backend records the shown text, for the batch tests.

## Acceptance

- [ ] From another app, `portal-status-show` shows the panel without taking
      focus: typing still goes to that app.
- [ ] The panel shows on another Space and over a fullscreen app.
- [ ] Showing new text while shown replaces it; hiding a hidden panel does
      nothing.
- [ ] Each position, offset, size and tone looks right on a real screen.
- [ ] CTest covers the placement rules and the Lisp options through the
      fake backend.
