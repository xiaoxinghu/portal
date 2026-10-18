# The C core asks each platform only for primitives

Portal's native module has two interfaces. Emacs calls ADR 0002's Lisp functions through `native/Core/emacs.c` into the C core. Platforms implement `native/Core/include/portal.h`: Swift on macOS today, possibly GTK on Linux later. This interface describes platform duties, not Portal features: create a native view, attach it to a frame at a rectangle, load a URL, message a page, paste into a terminal, or give a view the keyboard. Portal's rules live once, in the core: target identity, input handoff, notification order and bridge queue. Platforms report key presses, page messages and title changes through core functions. New platforms implement a short primitive list; tests run the real core against a fake platform.

Four rules apply:

1. Request only operations the core cannot build from existing primitives: for rectangles, triangles and polygons, ask for a line.
2. Merge operations only when they are one capability; runtime string verbs are not a merge (ADR 0002).
3. Platforms call the core only on the module-call thread, never reaching Emacs. Emacs records use the core's notification pipe.
4. With one implementation and one caller, `emacs.c`, the core needs no separate portable interface beyond the Lisp functions.

## Considered Options

- **A platform interface that mirrors the Lisp functions.** The first portable-core task moved bindings into C without moving logic. This starting point would make every platform reimplement Portal's rules behind 19 operations; later tasks reduce it.
- **One generic call with a verb and JSON arguments.** Rejected for ADR 0002's reasons: it hides platform obligations and checks them only at runtime.

## Consequences

Each remaining portable-core task moves one area of logic into the core, replacing its Lisp-shaped operations in `portal.h` with only the necessary primitives and events. Lisp function names and behavior stay unchanged.
