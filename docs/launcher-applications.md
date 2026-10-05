# Application launcher integration

Portal has no application picker. Use the
[launcher.el recipe](launcher.md#application-launcher-with-launcherel-optional)
in user configuration; its optional integration smoke test runs outside the
build. Until 2026-10-05, Portal ran its launcher.el adapter,
`portal-launcher-applications`, by default and downloaded launcher.el for tests.
The [historical record](#historical-the-built-in-adapter) preserves that adapter's
design and evidence, not the current setup.

## The recipe and launcher.el follow-ups

Inspected on 2026-10-05 at
[launcher.el 731146d](https://github.com/xiaoxinghu/launcher.el/blob/731146d95d7d1ff16f48e7a200da873c8d8b375c/launcher.el),
then `main`'s head. `launcher` acts on one completion result. With each result
supplied and `open`/browser mocked:

| Completion result | What `launcher` does |
| --- | --- |
| `""` | Opens `https://www.google.com/search?q=`, an empty search |
| `"  "` | Searches Google for two spaces |
| `"!g"` | Searches Google for `!g` |
| `"!gh "` | Opens `https://github.com/search?q=`, an empty search |
| `"Calculator"` | Runs `open -a /System/Applications/Calculator.app` |

Stock completion's prompt map binds Space to `minibuffer-complete-word`.
Typing `!gh portal` searched Google for `!ghportal`: completion consumed Space.

Removing the documented wrapper, `my/launcher-read` and `my/launcher-reader`,
requires these upstream launcher.el changes:

1. An empty or blank completion result takes no action.
2. A configured bang with no query, such as `!g` or `!gh `, takes no action.
3. Space inserts a space in its prompt where stock completion would complete a
   word, keeping an explicitly customized binding.
4. Optionally, `if-let` and `when-let`, obsolete in Emacs 31.1, become
   `if-let*` and `when-let*`; loading reports a warning for each.

Selection needs no change: launcher.el accepts a highlighted candidate whenever
completion returns it, as Vertico does on Return without typing. Portal's adapter
caused the earlier failure by checking typed text; see the correction below.

The wrapper applies rules 1–3 in user configuration. For one call,
`my/app-launcher` binds `completing-read-function` to `my/launcher-read`, saving
the user's reader in special variable `my/launcher-reader`. `my/launcher-read`
calls it and returns its result unchanged, including text properties for candidate
lookup. Without a closure, files lacking `lexical-binding` work under Emacs 31's
dynamic binding. The first version returned a closure over the reader, causing
`void-variable`; review caught it, and a batch test now loads recipe files under
both bindings.
Empty results and queryless bangs signal `quit`: the panel cancels, closes and
returns focus to the previous app. No keymap, global setting or launcher.el
function changes, leaving `M-x launcher` unchanged. The bang test reads
`launcher-bangs` and splits words, so `" !g "` also cancels.

## Optional integration smoke test

The external `launcher-recipe` suite runs
[the recipe tests](../test/portal-launcher-recipe-tests.el) in a disposable
graphical Emacs; Portal's build does not need launcher.el. Point it at a
directory with launcher.el:

```sh
PORTAL_LAUNCHER_EL=/absolute/path/to/launcher.el-directory \
  ./test.sh external --suite launcher-recipe --allow-external --allow-gui
```

[test/launcher-recipe.sh](../test/launcher-recipe.sh) runs the same command.

It loads the guide's recipe from a dynamically bound file, moves its chord to
Control-Option-Command-F20 and types native key events into the real panel.
With Spotlight, `open` and browser mocked, the input test checks:

- Stock completion and Vertico/Orderless/Marginalia: typed app, spaced `!gh`
  query, queryless bang, empty result and Escape.
- Vertico without typing: Return on the first app, after Down, and after Down/Up.
- Prefix-argument index refresh; shortcut running the same command; prompts as
  the panel's only window; restoration of the user's completion reader.

The launch test activates Safari or another running app, then uses real Spotlight
and `open`: Escape keeps that app frontmost; typing `Finder` and Return activates
the running Finder.

Run on 2026-10-05: both tests passed, with launcher.el 731146d (SHA-256
`7211f80c73a498215fdf1f1bc592c7b9148a965bf91e9da1d18b9df1e87819cb`), GNU Emacs
NS 31.1 revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`, macOS 27.0.1
(26A434), and Vertico 2.15, Orderless 1.8 and Marginalia 2.13 from
`build/elpa`. Spotlight indexed 506 applications; Safari was frontmost
before launch. The first input run failed in its fixture: it expected one
Spotlight query per refresh, but launcher.el queries four default directories.
The fixture now sets one directory.

## Historical: the built-in adapter

This records the adapter from 2026-10-03 to 2026-10-05.
`portal-launcher-command`, `portal-launcher-applications`,
`portal-launcher-mode`'s shortcut and the `launcher-applications` CTest suite
are gone.

`portal-launcher-command` defaulted to `portal-launcher-applications`, which
loaded optional `launcher.el` and ran its command in the existing session.
Portal added no catalog, discovery process, native provider or search.
`launcher.el` owned the cache and exact bundle paths; annotations were never
parsed into application identities.

Tested with launcher.el at 731146d, GNU Emacs NS 31.1 revision
`a360712c9d272d950d8d8255ef74570f7e90b7d9`, and macOS 27.0.1 (26A434). CMake
downloaded a hash-checked copy of that dependency into `build/elpa` for tests.

### Input policy and package follow-ups

The adapter delegates to the user's `completing-read-function`, returning the
chosen string and text properties unchanged for upstream lookup by original
label. The package supplies path annotations via `completion-extra-properties`,
without a completion category. Bang collection reads actual minibuffer contents,
needed when Orderless requests all candidates with an empty string.

Two presentation policies are scoped to this invocation:

- Blank completion results and configured queryless bangs cancel the session
  using existing cleanup/focus return. Return accepts highlighted apps without
  typed text, including initial and arrow-key selections. The reader's final
  result determines the action.
- Stock Space completes words, consuming bang-query separators. This prompt
  replaces that default with literal Space; Tab still completes. Explicitly
  customized bindings survive. The shared minibuffer keymap never changes.

The tested `launcher.el` revision's unwrapped command searches empty input and
uses stock Space; future package changes can address both. Portal's scoped
adapter leaves `M-x launcher` unchanged, patching neither package files nor
global advice. Upstream can also replace obsolete `if-let`/`when-let`; their load
warnings do not prevent operation on this Emacs build.

Prefix refresh passes through: `C-u M-x portal-launcher-present` refreshes before
reading; `M-x launcher-refresh` works separately. No per-keystroke scans occur.
Discovery failure retains the cache; an empty index reports an error and retries
next invocation. Missing cached bundles or failed `open` report errors, never
falling back to another app or search. Refresh after moving apps. Browser-function
errors use normal session cleanup; asynchronous failures after URL acceptance
remain the browser's responsibility.

### Verification on 2026-10-03

Seven adapter ERT tests use the pinned package, temporary bundle directories
and mocked Spotlight/open/browser actions. Coverage: duplicate non-ASCII names,
path spaces, decorated strings, real stock and Vertico/Orderless/Marginalia
completion, encoded fallback and all three bang searches, untouched prompts,
explicit installation/removal refresh, discovery/open/browser failures, empty indexes,
cache reuse and unchanged ordinary `launcher` behavior. The separate launcher
suite checks loading without the package and the setup error.

All 12 launcher graphical tests pass with module assertions. The application test
sends native AppKit keys to the real panel using stock completion and Vertico 2.15,
Orderless 1.8 and Marginalia 2.13. It checks default-command routing, app selection,
a spaced bang query, empty input, Escape and preserved ordinary-window selection.
This repeatable suite mocks external actions.

A separate disposable GUI smoke test used real Spotlight and `open -a`:

- Typing `Calculator` launched and focused the stopped app. After switching to
  Finder, reinvoking activated the same Calculator process without focusing the
  ordinary Emacs frame.
- Prefix refresh rebuilt the 506-entry index. Escape returned focus to Calculator.
- `!gh portal launcher` sent the correctly encoded URL through configured OpenIn
  to Chrome. A separate run with a locally bound Chrome browser function also
  passed the browser-focus assertion without changing system browser preferences.
  UI inspection confirmed both GitHub tabs showed `portal launcher`; test tabs
  were then closed.

App switching dismissed the initial smoke run. Waiting for asynchronous Finder
activation before invoking the next session fixed the harness; the rerun passed
without native focus changes.

The complete graphical suite then passed: 78 expected results (including all
seven graphical input tests), zero unexpected and one skipped shell-startup test
with a separate harness. An earlier full run overlapped browser UI inspection,
dismissing a nested prompt early; the serial rerun passed. All 32 CTest suites,
host formatting/type checks, native failure-reporter tests and changed-file byte
compilation also pass.

Both connected Retina displays passed exact geometry, including 713x407 points:
Gigabyte M32U at `(0, 0)` and LG ULTRAFINE at `(2560, -483)`. Automated input/geometry
does not confirm physical shortcuts, fullscreen/Spaces, monitor unplugging or
click-away. Those checks, complete user configuration, IME and VoiceOver remain
in `launcher-daily-use`; physical GUI acceptance remains unchecked.

### Selection correction on 2026-10-04

The initial adapter cancelled on empty typed text even with a valid highlighted
app. It now checks the final result: Return on the first app and after Down/Up
navigation works without typing. Actual empty results and queryless bangs cancel.

Two regressions reproduce both reported cases with real Vertico/Orderless
minibuffers and exact fixture paths; both failed before the fix. A native-panel
test checks Return, Down/Return and Down/Up/Return with AppKit keys and mocked
launches. Original stock/enhanced completion checks follow the same policy.
Dependencies and native implementation are unchanged.

All 32 CTest suites and all 13 launcher GUI tests pass, along with host
format/type checks, native failure-reporter tests, changed-file byte compilation
and Org task validation. The GUI run used a test-only alternate shortcut because
the normal chord was already registered by the user's running Emacs.

### Discovery timing

One fresh batch Emacs process, the default four discovery directories, 506
applications, and the tested package revision:

| Operation | Elapsed time |
| --- | ---: |
| Cold `launcher--ensure-index` | 1.231 seconds |
| Explicit `launcher-refresh` immediately afterwards | 0.431 seconds |
| 1,000 cached `launcher--ensure-index` calls combined | 0.079 milliseconds |

These measure catalog work, excluding panel creation, human typing and app
startup. Cold and refresh samples each include one garbage collection. Cached
time is an aggregate near timer resolution, not end-to-end latency. A busy Emacs
command loop can still delay invocation.

Checks then ran as `launcher` and `launcher-applications` CTest suites and,
with the pinned package on `load-path`, `portal-launcher-gui-` tests. This machine's
native trampolines also needed the existing Homebrew GCC library-directory
workaround in `LIBRARY_PATH`; project compiler settings were unchanged.
