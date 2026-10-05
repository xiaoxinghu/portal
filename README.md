# Portal: native views in Emacs

Portal puts native WebKit pages and Ghostty terminals inside macOS Emacs panes.
For Emacs users who want a real terminal or a local document preview alongside
editing, each buffer has one native view that follows it across splits, resizing
and frames. Hidden pages and terminal sessions keep running.

The bundled app host provides Markdown previews, a Markdown task browser and an
offline Excalidraw editor. Optional launchers present your own Emacs commands in
a native panel, invoked by global shortcuts you configure.

## Scope

Portal requires **graphical macOS Emacs with dynamic modules**; it is not a
cross-platform package or a replacement for Emacs's text rendering. The native
module runs inside Emacs: a defect can crash that process. Start in a disposable
`emacs -Q`, and restart Emacs after rebuilding a module it has already loaded.

The opt-in launcher has a stricter compatibility gate: **GNU Emacs NS 31.1,
revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`**, with native subroutine
trampolines enabled. Other builds are rejected for this feature. Read
[launcher safety and setup](docs/launcher.md#set-up-safely) before enabling it.
Recorded environments and validation limits are in the
[testing guide](docs/testing.md) and [launcher daily-use record](docs/launcher-daily-use.md).

## Build and run

You need graphical macOS Emacs and its matching `emacs-module.h`, Apple's
Swift 6.2 or newer and Clang (Xcode), CMake 3.29 or newer, Ninja, and Bun with
`Bun.markdown.html` (tested with Bun 1.3.14). Install CMake and Ninja with
`brew install cmake ninja` or your tool manager, and install Bun for building.
The first build downloads locked host/test dependencies and the pinned
GhosttyKit binary (about 77 MB) and Swift wrapper. No Zig installation is needed.

Use the graphical Emacs executable that matches the build's header. For a
non-default installation, select it using [build and editor setup](CONTRIBUTING.md#build-and-editor-setup)
before building. From a clone of this repository, run:

```sh
./build.sh
emacs -Q -l "$PWD/portal.el" --eval '(portal-hello)'
```

The build produces `build/portal.bundle` and the standalone `build/portal-host`.
The new Emacs should show **Hello World in a native web view**; its app host
starts automatically. Click the page or press `RET` to enter it, and press
Command-Escape to return to Emacs. `q` hides the view; killing its buffer closes it.

Try `M-x portal-terminal` for a shell, `M-x portal-preview-markdown` for a saved
Markdown file, `M-x portal-tasks-browser` for the project's Markdown tasks, or
`M-x portal-excalidraw` for a local drawing. Loading Portal registers no global
shortcuts. Runtime use needs neither Bun nor Node nor adjacent web assets; see
[distribution layout](CONTRIBUTING.md#build-outputs-and-distribution).

## Documentation and contributing

Start with the [documentation index](docs/README.md) for user guides, design
notes and research. [Contributing](CONTRIBUTING.md) covers the worktree workflow,
editor setup, generated files and checks before a PR. [Testing Portal](docs/testing.md)
covers `./test.sh`, which checks a change needs, and native procedures;
[AGENTS.md](AGENTS.md) adds agent-specific working instructions.

For help or reproducible bug reports, use the repository's
[GitHub issues](https://github.com/xiaoxinghu/portal/issues). Include the Emacs
version/revision, macOS version, Portal commit and relevant diagnostics (for app
host failures, `*portal-server*`), removing credentials or private content.
Implementation files are licensed under [GPL-3.0-or-later](LICENSE).

## Guide links retained from the original README

The detailed manual has moved into `docs/`. The headings below preserve existing
README links; follow them to the maintained guides.

## Global shortcuts

See [registering, replacing and removing global shortcuts](docs/launcher.md#global-shortcuts).

## Native launcher panel (opt-in)

See [configuring a native launcher panel](docs/launcher.md#native-launcher-panel-opt-in).

### A minimal picker

See [the minimal picker example](docs/launcher.md#a-minimal-picker).

### A persistent buffer

See [a persistent buffer launcher](docs/launcher.md#a-persistent-buffer).

### Global shortcuts for launchers

See [binding global shortcuts to your launchers](docs/launcher.md#global-shortcuts-for-launchers).

### Application launcher with launcher.el (optional)

See [the tested launcher.el recipe](docs/launcher.md#application-launcher-with-launcherel-optional).

### Set up safely

See [launcher safety and compatibility](docs/launcher.md#set-up-safely).

### Migrate from the built-in launcher

See [migration and rollback](docs/launcher.md#migrate-from-the-built-in-launcher).

### Presentation options and lifecycle

See [presentation options and lifecycle](docs/launcher.md#presentation-options-and-lifecycle).

## Shared keyboard controls

See [keyboard ownership, shortcuts and toolbars](docs/keyboard.md).

## Local Excalidraw drawings

See [drawing, saving and reopening Excalidraw files](docs/excalidraw.md).

## Quick project terminal

See [summoning a project's quick terminal](docs/terminals.md#quick-project-terminal).

## Native Ghostty terminal

See [opening and managing terminals](docs/terminals.md#native-ghostty-terminal).

### Names, projects and directories

See [terminal names, project assignment and shell directories](docs/terminals.md#names-projects-and-directories).

### Choosing terminals

See [terminal selection and kill confirmation](docs/terminals.md#choosing-terminals).

### Agent dashboard

See [agent discovery, activity sources and dashboard setup](docs/agents.md).

### Consult and Embark

See [optional Consult and Embark integration](docs/terminals.md#consult-and-embark).

## Bun UI host

See [app host lifecycle, diagnostics and restart](docs/app-host.md).

## Markdown previews

See [Markdown preview navigation and limitations](docs/web-views.md#markdown-previews).

## Task view

See [the optional Org task view](docs/org-tasks.md#task-view). This is separate
from the Markdown task browser used for this repository's tasks.

### Task detail

See [editing an Org task in its detail buffer](docs/org-tasks.md#task-detail).

### Starting Claude on a task

See [starting Claude on an Org task](docs/org-tasks.md#starting-claude-on-a-task).

## Task browser

See [browsing Markdown tasks](docs/tasks.md#task-browser).

### Completing and editing tasks

See [status changes and editing in Emacs](docs/tasks.md#completing-and-editing-tasks).

### Implementing a task

See [starting Claude on a Markdown task](docs/tasks.md#implementing-a-task),
including the default permission-skipping arguments.

### Choosing the task root

See [project and task-root selection](docs/tasks.md#choosing-the-task-root).

### Writing tasks

See [Markdown task format and identity](docs/tasks.md#writing-tasks).

#### Folders

See [nested groups and parent tasks](docs/tasks.md#folders).

#### Dependencies and order

See [dependencies, readiness and ordering](docs/tasks.md#dependencies-and-order).

#### Tree and execution views

See [browsing by folder or execution order](docs/tasks.md#tree-and-execution-views).

### Links and attachments

See [task links and attachment boundaries](docs/tasks.md#links-and-attachments).

## Web view behaviour

See [HTML files and URLs](docs/web-views.md#html-files-and-urls) and
[web view lifecycle and APIs](docs/web-views.md#web-view-behaviour).

## Implementation

See [native boundaries, ownership and failure rules](docs/architecture.md).

## Verification

See [testing procedures and coverage](docs/testing.md).
