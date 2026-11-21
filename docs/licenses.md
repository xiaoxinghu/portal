# Licenses and third-party notices

Portal is licensed under [GPL-3.0-or-later](../LICENSE). Its build outputs also
contain third-party code and fonts under their own licenses.

The build copies `LICENSE` and the `licenses/` directory to `build/licenses/`,
which goes into every binary Portal distributes.
[licenses/README.md](../licenses/README.md) is the notice itself: what the
outputs contain and where their source is. `licenses/texts/` holds the
third-party license texts, copied unedited from upstream; `.gitattributes`
keeps Git from normalizing them.

The notices are kept by hand, as comparable Emacs packages do theirs: Ghostel
ships libghostty-vt, and emacs-zmq ships libzmq, each with a tagged repository
as its only source pointer. No test checks them. The owner decided on
2026-11-21 that this is enough while Portal is small: the GPL-3.0 code is
nearly all the owner's own, the tagged repository pins every other input,
z2d's MPL-2.0 asks only that recipients be told where its source is, and
JavaScriptCore's LGPL relinking is a rebuild with another Bun.

When a dependency adds a component with a new license, add its text to
`licenses/texts/` and a line to `licenses/README.md`.
