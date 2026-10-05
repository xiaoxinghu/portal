# Testing Portal

`./test.sh` runs every test, by category, from the repository root. Tests are
the coverage reference; do not maintain a parallel inventory here. Automated
suites are registered in CMake with [`portal_suite`](../test/suites.cmake), and
manual checks in [the runner](../test/runner.py); `./test.sh all --list` prints
every suite, its tests, effects and setup. For the checks a PR needs besides
tests, see [checks before a PR](../CONTRIBUTING.md#checks-before-a-pr).

## Commands

| Category | Command | Boundary and use |
| --- | --- | --- |
| Unit / batch | `./test.sh unit` | Pure logic, the real C core with a fake platform, batch Lisp and fast isolated language tests. No windows, credentials or focus changes. |
| Headless integration | `./test.sh integration` | The compiled app host, HTTP, processes, PTYs, package integration and Playwright's headless WebKit. No visible browser or native window. |
| Native GUI end to end | `./test.sh gui --allow-gui` | Real Emacs, AppKit, WebKit and Ghostty: focus, redisplay and native input, each suite in a fresh disposable Emacs, plus the standalone AppKit checks. |
| Stress / stability | `./test.sh stress --allow-gui` | Bounded lifecycle churn. Headless members, such as `views-stress`, run without `--allow-gui` when selected alone. |
| External integration | `./test.sh external --allow-external --allow-gui` | Live agents with credentials and the third-party launcher.el recipe, given their configured prerequisites. |
| Manual acceptance | `./test.sh manual --interactive --allow-gui` | Guides a person through physical keys, Spaces and fullscreen, display changes, IME and VoiceOver, and records what they report. |

`./test.sh` alone runs `./test.sh headless`: unit and headless integration.
`./test.sh regression --allow-gui` runs the whole self-contained regression:
unit, integration, native GUI and stress, including the cross-feature
`coexistence` suites; external and manual checks are outside it, and its report
says so. `./test.sh all --allow-gui --allow-external --interactive` is every
test: the regression plus every external and manual check. It checks their
prerequisites first, and reports **incomplete**, exiting 3, when any is
missing, a manual check was not made, or a declared optional skip happened.
It never runs less than it names.

- `--suite NAME` narrows a command to suites or manual checks with that exact
  name or feature; repeat it for more. An unknown name or a selection with no
  suite in the command's categories is refused.
- `--list` prints the plan: suites, their tests, category, effects, declared
  optional skips, setup and build targets. It runs, builds and writes nothing
  and needs no permission: it reads a configured build's registry, and refuses
  when that is missing or older than the CMake files that define it. Test
  names are read from the suites' files.
- `--repeat N` (at most 20) runs the selection N times and needs `--reason`.
- `--reason TEXT` records why a run repeats earlier ones (see below).
- `--jobs N` sets how many headless suites run at once; desktop suites run
  one at a time. `--build-dir DIR` selects another build, relative to the
  current directory, and `--no-build` uses it as it is. Every suite uses that
  build: graphical Emacs loads its module, app host and event injector, which
  CTest names in `PORTAL_TEST_BUILD`, and manual helpers get it with its
  configured Emacs.
- `./test.sh evidence [RUN]` lists recorded runs or compares one with the tree.

Exit status: 0 passed, 1 failed, 2 refused (nothing ran), 3 incomplete,
130 interrupted.

On a clean checkout, install the [prerequisites](../README.md#build-and-run)
and run `./test.sh`. It configures `build/` with the `dev` preset if needed,
honoring `EMACS` and `EMACS_INCLUDE` as `./build.sh` does, then builds only
what the selected suites need, incrementally, once per run: `portal-test-unit`,
`portal-test-integration` or `portal-test-desktop`. Headless runs never build
the native module. The first run downloads the hash-checked Emacs packages,
and integration runs install the WebKit build of the Playwright version in
`host/bun.lock` into `build/playwright` (about 300 MB); desktop runs build the
module, the test-only event injector and the standalone checks.

## Choosing checks

| Situation | During development | Required final verification |
| --- | --- | --- |
| Task prose or ordinary documentation only | Metadata, discovery, links and `git diff --check` | No native build or GUI suite. Executable examples, such as `docs/launcher.md`'s, are not prose. |
| Lisp, C or TypeScript logic | Affected unit and headless integration suites | `./test.sh` once for the final candidate; affected native suites if the observable native contract changes. |
| Executable launcher examples | `./test.sh unit --suite launcher` (both binding modes) | `./test.sh`; launcher GUI or recipe suites if native interaction or third-party integration changed. |
| Browser script or CSS | `tasks-page` and the relevant host suites | `./test.sh` and the affected embedded WebKit and native handoff suites; keep real rendering assertions. |
| Native view, launcher, terminal, toolbar or input | The narrowest batch or native suite that shows the change | `./test.sh` plus the affected GUI and standalone native suites; add `--suite coexistence` for shared lifecycle, input or bridge changes. |
| Shared test fixtures, runner or build selection, broad platform change | Runner tests (`--suite test-tools`) and focused suites | `./test.sh regression --allow-gui`, in scheduled desktop time. |
| Suspected flake or lifecycle leak | An isolated, reproducible case first | A bounded `--repeat` run after the fix; every attempt stays recorded. |
| Release or broad integration validation | Prepare prerequisites and schedule desktop time | `./test.sh regression --allow-gui`; `./test.sh all …` for acceptance that needs external or manual evidence. Record incomplete acceptance as such. |

Select by what a change can affect, not only by the file changed: its callers,
shared fixtures, native boundaries, browser assets, dependencies and executable
documentation. Features name these in `--list`; `--suite FEATURE` runs a
feature's suites in a category. When the impact is uncertain, broaden the
affected suites and say why. There is no automatic diff-to-test mapping.

## Desktop and external permission

Suites with the `desktop` effect open windows, take focus or register system
hot keys; `external` ones use credentials, make real requests or run
third-party code. The runner refuses them without `--allow-gui` or
`--allow-external`, and manual checks without `--interactive`.

Permission is for one planned run in one window of desktop time. Agents ask
before any run on the user's active desktop, saying which suites will run and
for how long, and defer it rather than weaken acceptance when the desktop is
unavailable. A worktree or terminal session does not isolate macOS focus.
Desktop runs from every worktree of the repository share one lock, in Git's
common directory (`PORTAL_TEST_DESKTOP_LOCK` names another file); a second one
is refused while the first runs. A user-approved dedicated graphical runner is
the preferred long-term home for routine native regression.

Native input cannot reach test windows while another app is active or the
screen is locked: key and click injection tests then fail together. The runner
refuses to start on a locked screen. If injection tests fail while someone used
the machine, rerun them with `--reason` before suspecting the change.

Live-agent suites use trusted projects, credentials and real requests: set
`PORTAL_TEST_CLAUDE_DIRECTORY`, `PORTAL_TEST_CODEX_DIRECTORY` and
`PORTAL_TEST_PI_AGENT_DIR`, with `claude`, `codex` and `pi` on `PATH`; see
their [test-local prerequisites](../test/portal-agent-discovery-gui-tests.el).
For the mixed Pi check, use a disposable agent directory with `portal-pi.ts`,
terminal progress disabled, and a `/portal-test-prompt` command calling
`ctx.ui.input("Portal smoke test", "Type PORTAL_OK")`. The launcher recipe
needs `PORTAL_LAUNCHER_EL`, the directory of the tested launcher.el. Do not
alter user settings.

## Skips, repetition and evidence

A required test that skips fails its suite. A suite may declare an optional
skip that depends on equipment, such as a second display for
`portal-launcher-gui-minibuffer-panel-stays-on-its-display`, or tmux for
`portal-discovery-gui-inherited-tmux-marker`. Declared skips are reported and
leave `all` incomplete. Reports list each suite as passed, failed, not run or
not selected, with its tests' failures, unexpected skips and declared skips,
and each manual check as passed, failed or not tested.

Each run is recorded in `build/test-runs/`: the source identity (every file's
Git blob ID in the working tree, including uncommitted changes), tool and
dependency versions, relevant variables, the digests of the artifacts the
suites run, the command and selection, start and end times, build time, each
suite's result and duration, ERT results per test, and the log. The runner
checks the source identity again at the end: a run whose inputs changed while
it ran is incomplete.

Reuse evidence instead of repeating it. A commit, push or review transition
alone changes no input. Evidence for a suite is its latest result from a run
with the same sources, tools and variables in which the suite needed the same
built files, with the same digests; other suites' files do not matter, and a
suite missing a file it needs has no evidence. When every selected
suite has such a passing result, possibly from several runs, the runner cites
them and runs nothing, judging them as the requested command would: a
declared skip leaves `all` incomplete. Repeating them needs `--reason`, and so
does any selection including a suite that failed with unchanged evidence. Do
not run both an aggregate and a subset it covers for the same inputs unless
investigating a documented issue. `./test.sh evidence RUN` lists what changed
since a run; changes to code or tests invalidate the affected evidence, while
prose-only changes leave test evidence valid. Never retry until green:
`--repeat` runs are bounded, and every attempt, failed ones included, stays in
the record.

## Writing tests

- Test at the narrowest boundary that can demonstrate the behavior. Use the real
  core with a fake platform for shared rules; use native integration tests when
  AppKit, WebKit or Emacs's command loop determines the outcome.
- Assert observable results, not incidental caches, hook names or call counts.
  At a platform boundary, resource ownership and ordering are part of the contract.
- For input and focus regressions, drive events through the event loop. Calling
  a handler directly cannot establish that a user can reach it with the keyboard.
- Keep fixtures isolated and clean up buffers, processes, files and registrations
  even after failure. Avoid user configuration and existing sessions. Restore
  global state a fixture changes, such as the clipboard.
- Register each suite with `portal_suite` in the relevant
  [CMake file](../CMakeLists.txt) or the [core's](../native/Core/CMakeLists.txt):
  one category, its features, effects and needs. Keep default checks headless
  and credential-free.
- A Lisp suite is one test file run by [`portal-suite.el`](../test/portal-suite.el),
  which runs exactly the tests that file defines. Put shared fixtures in
  `test/*-testing.el` files, which define no tests; never require another
  suite's test file. Declare an optional skip with `--allow-skip NAME` in the
  suite's command, beside the condition that needs it.
- Move a permutation out of a graphical suite only to a headless test that
  shows the same behavior, keep a representative native case, and show the
  replacement fails on a targeted mutation. Keep focus-settling waits until a
  demonstrated synchronization replaces them.
- Use [native failure helpers](../test/native-checks.swift) rather than
  assertions that turn ordinary test failures into macOS crash dialogs.

## Evidence and safety

A passing fake-backend test does not establish native window behavior, and
Playwright's WebKit is not Portal's embedded WKWebView. Injected AppKit or
Carbon events do not establish physical-key delivery, Accessibility, Spaces or
fullscreen behavior; those need manual evidence. Report skipped tests and manual
checks separately from passes, and record the environment for native acceptance
rather than treating an old result as current evidence.

## Terminal graphical checks

Graphical suites run in disposable `emacs -Q --module-assertions` processes,
with `portal.el`, the CMake-built packages in `build/elpa` and the test-only
event injector, `build/test-terminal-input.dylib` (target
`portal-test-injector`), which needs no Accessibility permission. Keep launcher
subroutine trampolines enabled. Run them through `./test.sh`, never in a working
Emacs: a native defect can crash the process.

## Combined graphical suite

Each graphical suite runs in its own fresh Emacs; ordinary tests run once.
Feature coexistence is tested by explicit cross-feature suites, with the
`coexistence` feature: native terminals and web views together
(`coexistence-gui`), toolbars over each view kind (`toolbar-gui`) and the
launcher with live views (`launcher-daily-use-gui`). Batch Emacs cannot
substitute for native windows.

## Standalone AppKit checks

These isolate native integration from Emacs bindings and Ghostty. CMake builds
them on demand (target `portal-native-checks`) and registers them as the
`native-focus`, `native-toolbar`, `native-launcher` and `native-shortcuts` GUI
suites; they open real windows or register real hot keys. The launcher's
placement arithmetic runs without a window as the `launcher-geometry` unit
suite, and many attach cycles as `native-launcher-stress`.

## Manual checks

`./test.sh manual --interactive --allow-gui` shows each check's procedure,
offers its helper script, and records the result, notes and operator:
[physical global shortcuts](../test/global-shortcut-smoke.sh) and the launcher's
[hands-on validation](launcher-daily-use.md#hands-on-validation), one check per
row. Missing equipment or results are not passes.

## C core checks

For a focused change to shared rules, the standalone core build avoids Swift,
Bun and Ghostty. It still requires macOS for `F_SETNOSIGPIPE`; a fake platform
does not make the pipe portable. Its suites are the top-level build's `core`
feature, so do not run both for the same inputs.

```sh
cmake -S native/Core -B build/core
cmake --build build/core
ctest --test-dir build/core --output-on-failure
```

## Troubleshooting

- Plain `ctest --test-dir build` still runs the unit and integration suites
  once `./test.sh` has built their prerequisites. `ctest -C opt-in` would also
  run desktop and external suites without the gates or the desktop lock: use
  `./test.sh` for those.
- A graphical suite whose file fails to load exits with the error instead of
  waiting; one that hangs is stopped at its CTest timeout. Its output, ERT's
  report included, is in the run's `run.log`.
- On the validation machine, native-trampoline compilation in batch needs the
  Homebrew GCC library path in `LIBRARY_PATH`; missing `emutls_w` means compiler
  setup, not a Portal failure.
- `--allow-gui` is refused while another worktree's desktop run holds the lock;
  the message names it. The lock is released when that run exits.
