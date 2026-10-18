# Portal view native seam: per-target calls, named per-kind exports, frame title on every placement

Emacs drives every Portal view through lifecycle calls addressed by native target (`web:3`, `terminal:2`): open, place, hide, close, inspect. Kind-specific operations have named exports, such as `portal--web-send` and `portal--terminal-paste`. Each placement resolves the frame afresh by temporarily giving it a unique title; no frame information is cached across the seam. These choices are simplest for two view kinds and prevent stale information between Emacs and the native module.

The native module exports these 17 functions:

- **Lifecycle**, for every view kind: `portal--open`, `portal--place`, `portal--hide`, `portal--close`, `portal--inspect`, and `portal--channel` for the notification pipe.
- **Web:** `portal--web-load`, `portal--web-go`, `portal--web-appearance`, and the bridge's `portal--web-send` and `portal--web-receive`.
- **Terminal:** `portal--terminal-paste`, `portal--terminal-text`, `portal--terminal-theme`, `portal--terminal-themes` and `portal--terminal-bindings`.
- **Input:** `portal--input`.

## Considered Options

- **One declarative layout call placing every view.** Rejected. Every call must include every open view, so one registry mismatch breaks all later syncs. All-or-nothing validation pays off only for interdependent views; one view per buffer avoids that dependency (ADR 0001).
- **A generic `portal--call TARGET VERB JSON` for kind operations.** Rejected. Adding view kinds would leave the native module unchanged, but string verbs get only runtime checks and can't be documented. This generality serves a third kind that does not yet exist.
- **Caching a native frame handle instead of renaming on each call.** Rejected. Stale handles, such as after non-native fullscreen swaps the frame's window, would require invalidation and retry. Renaming costs little: it happens only when view geometry changes. If Emacs exposes reliable native-window identification, only one function in `portal-view.el` changes.
