---
id: testing-strategy
status: done
---

# Make test selection explicit, headless by default, and coverage-preserving

## Problem and outcome

Native tests repeatedly take desktop focus, and a single implementation task can
run overlapping suites several times. Preserve the project's behavioral coverage
while making ordinary development quiet, focused verification predictable, and
full regression reproducible through one command.

This is one coordinated implementation task: classification, runners, coverage
migration, and agent guidance must agree. Implement it in stages below rather
than splitting policy from the commands that enforce it. This document is a
plan, not permission to start implementation or run disruptive checks.

## Current-main findings

Revalidated against `main` at `879cbfb` after the documentation refactor:

- `docs/testing.md` already exists. It covers testing principles, safety and
  native procedures, but has no unified runner or situation-to-suite policy.
- `CONTRIBUTING.md` owns routine contributor commands and links to that guide.
  `README.md` and `docs/README.md` also link to it. `AGENTS.md` requires reading
  Contributing but does not directly require reading the testing guide.
- `CONTEXT.md` is domain vocabulary, not workflow guidance. Do not put the
  testing strategy there or rely on an optional domain-document link to load it.
- CTest already runs headless C, batch Emacs, Bun and compiled-host integration
  suites. The earlier audit found 33 registered suites and 92 tests in the then
  combined GUI invocation; derive the current inventory, not hard-coded totals.
  Include tests outside CTest, such as `test/list-todo-tasks.test.ts`, Python
  tests, standalone native checks, shell fixtures and optional smoke tests.
- GUI fixtures raise windows and deliberately activate applications. Launcher
  tests include 100 hide/show cycles, lifecycle matrices and focus-settling
  waits. Fake-backend tests cannot replace native focus or rendering evidence.
- Recent task reports record six successful runs of a 25-test GUI selection,
  plus a separate run of daily-use tests already in that selection. Another
  task repeated GUI tests to diagnose and verify a focus flake. Some reruns
  were justified, but there is no explicit repetition/evidence-reuse policy.
- GUI suites import other suites for helpers, so a broad ERT selector can run
  unrelated registered tests. C core tests can also be run twice by executing
  both the standalone core build and the top-level CTest suite.
- Two Evil input cases were skipped in the audited batch run despite CMake
  downloading Evil for other suites. Account for skips, not just suite exits.

## Scope and non-goals

Deliver the test commands, selection policy, focused headless coverage additions,
coverage-preserving GUI reductions, runner regression tests and documentation.
No product-behavior changes, user-config edits, external harness changes,
automatic cloud provisioning, or general-purpose distributed test service.
Do not remove useful native coverage to meet an arbitrary runtime/test-count
budget. Benchmarks remain measurements, not pass/fail tests unless they already
have an explicit invariant; include tests of benchmark tooling in the inventory.

## Command contract

Add a repository-root `./test.sh` entry point. It may delegate to small scripts,
CMake/CTest, ERT and the existing language runners; do not build a second test
framework. Resolve paths from the repository root, honor configured tools and
build directories, and document clean-checkout setup. Build prerequisites once
per invocation, incrementally, without unnecessary native builds for pure tests.

Each category has a dedicated command:

| Category | Command | Boundary and use |
| --- | --- | --- |
| Unit / batch | `./test.sh unit` | Pure logic, real C core with fake platform, batch Lisp behavior and fast isolated language tests. No windows, credentials or foreground changes. |
| Headless integration | `./test.sh integration` | Real compiled host, HTTP/process/PTY interactions, package integration and headless browser behavior. No visible browser or native windows. |
| Native GUI E2E | `./test.sh gui --allow-gui` | Real Emacs/AppKit/WebKit/Ghostty integration, focus and redisplay, plus relevant standalone native checks. Fresh disposable processes. |
| Stress / stability | `./test.sh stress --allow-gui` | Explicitly bounded lifecycle churn and stability cases. Tag headless versus desktop-requiring members; a headless selection must not require GUI permission. |
| External integration | `./test.sh external --allow-external --allow-gui` | Existing live-agent and optional third-party recipe checks, with their pinned/configured prerequisites and explicit resource-use permission. |
| Manual acceptance | `./test.sh manual --interactive --allow-gui` | Guide and record human-only checks: physical keys, Spaces/fullscreen, display changes, IME and VoiceOver where applicable. Never fabricate automated passes. |

Aggregate commands:

- `./test.sh` defaults to `./test.sh headless`: unit plus headless integration.
- `./test.sh regression --allow-gui` runs the entire self-contained automated
  regression: unit, integration, native GUI and bounded stress cases, including
  cross-feature coexistence. External credentials and human acceptance are
  explicitly outside this named scope and listed in its report.
- `./test.sh all --allow-gui --allow-external --interactive` is exhaustive:
  regression plus every registered external and manual check. Preflight all
  required tools, optional packages, trusted projects and credentials without
  printing secrets or changing user settings. Missing prerequisites or absent
  human evidence mean **incomplete**, not "all tests passed". The command must
  not silently downgrade to the self-contained regression.

`all` is the literal all-tests entry point; `regression` is the unattended full
self-contained regression. This distinction is necessary because real provider
requests and physical IME/key/display acceptance cannot be made credential-free
or unattended by renaming them E2E tests.

Support `--suite NAME` for explicit feature selection and `--list` for a read-only
execution plan on category/aggregate commands. Print exact suites/tests, category,
desktop/external effects, expected skips and required setup before execution.
Unknown categories/suites and empty selections fail. Use exact identifiers, not
unanchored substring matching. Allow additional repetition only through an
explicit bounded stress option such as `--repeat N`; never retry until green.

## Situation-to-test policy

Put the authoritative policy in `docs/testing.md`, with this minimum matrix:

| Situation | During development | Required final verification |
| --- | --- | --- |
| Task prose / ordinary documentation only | Metadata, discovery, links and diff checks | No native build or GUI suite. Executable examples are not prose-only. |
| Lisp/C/TypeScript logic change | Affected unit and headless integration suites | Full headless aggregate once for the final candidate; affected native tests if the observable native contract changes. |
| Executable launcher examples | Launcher batch suite in both binding modes | Full headless checks; relevant GUI/recipe checks if native interaction or third-party integration behavior changed. |
| Browser script or CSS change | Headless browser integration plus relevant host tests | Full headless checks and affected embedded-WebKit/native handoff cases; retain real rendering assertions. |
| Native view, launcher, terminal, toolbar or input change | Narrowest batch/native regression that demonstrates the change | Full headless plus affected GUI and standalone native suites; broaden to coexistence for shared lifecycle/input/bridge changes. |
| Shared test fixtures, runner/build selection or broad platform change | Runner tests and focused suites | Full self-contained regression, scheduled with desktop permission. |
| Suspected flake / lifecycle leak | Isolated reproducible case first | Explicit bounded stress run after a fix; retain every attempt's result. |
| Release / broad integration validation | Prepare prerequisites and schedule desktop time | Full self-contained regression; exhaustive `all` for acceptance requiring external/manual evidence. Record incomplete acceptance honestly. |

Selection must consider callers, shared fixtures, native boundaries, browser
assets, dependencies and executable docs, not just the filename changed. When
impact is uncertain, broaden the affected suites and explain why. Do not add a
fragile automatic diff-to-test mapper as a substitute for this policy.

GUI permission is specific to a planned run/window of desktop use. Agents must
ask before launching disruptive checks on the user's active desktop, state their
scope, and defer them rather than weaken the acceptance criteria. A user-approved
dedicated graphical runner is the preferred long-term home for routine native
regression; provisioning one is outside this task. A worktree or terminal
session alone does not isolate macOS focus.

## Implementation plan

### 1. Inventory and classify without losing coverage

- Enumerate all current executable tests and manual procedures; record their
  boundary, feature, prerequisites and existing entry point. Keep the executable
  registry as the source of truth, not a growing prose list of every test.
- Give each automated test one primary category and one or more feature labels.
  Use CTest labels and explicit ERT selectors where applicable. Initially classify
  mixed suites conservatively as integration rather than mislabeling them unit.
- Extract shared GUI fixtures into helper-only files. Loading a helper must not
  register unrelated tests. Preserve cross-feature tests as explicit members.
- Prevent overlap inside aggregates: ordinary tests execute once, including core
  tests, daily-use checks and Python/Bun tests currently outside CTest. Deliberate
  stress iterations are separately identified, not accidental duplicate runs.
- Make required dependencies available to their suites, including the audited
  Evil input tests. Unexpected skips fail the required run; declared optional
  skips are visible and cannot satisfy exhaustive acceptance.

### 2. Implement safe runners and repeatable evidence

- Implement the commands above and incremental build targets for the injector
  and standalone native binaries instead of recompiling copied recipes each run.
- Native runs are serial and mutually exclusive across repository worktrees;
  conflicting desktop runs fail clearly. Headless tests may run in parallel
  after checking fixture/port/temp-file isolation.
- Use explicit test selectors, bounded process timeouts, exit-status propagation,
  signal-safe cleanup and disposable Emacs instances with the supported build.
  Do not touch the user's running Emacs, configuration, clipboard permanently,
  terminal sessions or unrelated processes. Restore fixture-owned global state.
- Store per-run results in ignored build output: source/input identity (including
  relevant uncommitted changes), tools/dependency versions, command/selection,
  start/end times, passes/failures/skips, per-suite durations and logs. Record
  build time separately. Check source identity again at completion so concurrent
  edits do not attach results to the wrong tree.
- Reuse successful evidence within a task only when relevant source, tests,
  generated artifacts, dependencies, selection and environment are unchanged.
  No automatic persistent cache is required: comparing recorded inputs and
  citing a valid run is enough. A commit or review transition alone is not a
  reason to rerun. Code or test changes invalidate affected evidence.
- Each rerun states its reason. Do not rerun both an aggregate and a fully covered
  subset for the same unchanged inputs unless investigating a documented issue.
  Do not turn a failed run green by hiding earlier attempts.

### 3. Move suitable permutations to headless tests

- Add a pinned, genuinely headless browser test setup for `host/tasks-client.ts`.
  Exercise the real page script with controlled HTTP/bridge inputs: in-place
  refresh ordering/coalescing, hidden-page refresh, retained folds/history/scroll,
  DOM focus, status/edit actions, error recovery and stale/replaced content.
  Use a real headless browser for layout/focus behavior, not a DOM mock pretending
  to prove rendering. Keep representative embedded WKWebView and Emacs handoff
  checks; browser WebKit is not identical to the native integration.
- Expand batch completion/policy tests using the existing real-minibuffer pattern
  in `test/portal-completion-testing.el`, with native calls faked only at their
  boundary. Move eligible input/result/configuration matrices here while retaining
  native key delivery, panel layout, focus return and command-loop integration.
- Separate pure launcher rectangle/clamping cases from window-creating fixtures
  where feasible. Preserve real placement, attachment, display notification and
  responder-chain checks. Do not distort production architecture merely to move
  a small assertion out of a GUI fixture.
- Move high-cycle lifecycle cases into stress while keeping representative
  lifecycle transitions in routine GUI regression. Exhaustive aggregates still
  execute the existing bounded stress coverage.
- Before removing a GUI assertion/permutation, map the behavior to its replacement
  and retained integration coverage. Demonstrate replacement sensitivity using a
  failing-before test or targeted mutation. Do not delete unique native evidence.
- Measure before/after with the same environment and selection, during approved
  desktop time. Preserve focus-settling waits until a demonstrated synchronization
  improvement replaces them; avoid blanket sleep shortening or repeated full-suite
  baselines. Report GUI launches/activations and repeated work as well as runtime.

### 4. Make the strategy discoverable and mandatory for agents

- Update the existing `docs/testing.md` rather than creating a competing guide.
  Keep testing principles, evidence limits, category meanings, selection matrix,
  permission rules, skip/repetition policy and runner troubleshooting there.
- Update `CONTRIBUTING.md` with the canonical copyable commands and final-check
  policy, linking detailed procedures to the guide. Formatting, type checking,
  changed-Lisp compilation and `git diff --check` remain required where applicable;
  test aggregation does not silently replace these non-test checks.
- Add a direct instruction in `AGENTS.md` to read `docs/testing.md` before selecting
  or running checks, including its desktop-permission rule. Keep this short and
  avoid duplicating the matrix. `CLAUDE.md` already points to `AGENTS.md`; preserve
  that routing. This makes the strategy part of mandatory repository instructions,
  not merely a discoverable link, without claiming any model is mechanically
  guaranteed to obey it.
- Keep `CONTEXT.md` focused on vocabulary. Refresh the testing description in
  `docs/README.md` and relevant current testing links/recipes. Preserve launcher
  example markers in `docs/launcher.md`; do not rewrite historical evidence as
  new verification or recreate the old large README testing section.

## Acceptance

- [x] Every existing test/procedure is classified, including tests outside CTest;
  no behavior disappears without an evidenced replacement or explicit retained
  native/manual check.
- [x] Each category has its dedicated command; default/headless commands open no
  windows and make no credentialed requests. A clean checkout has documented,
  reproducible setup and incremental prerequisites.
- [x] `--list` is non-disruptive; feature selection is exact; invalid/empty
  selections fail. Helper imports cannot broaden the selected suite.
- [x] Full regression covers all self-contained automated categories once, with
  explicit bounded stress iterations and retained cross-feature coexistence.
  Exhaustive `all` also covers external/manual checks, reporting incomplete and
  exiting nonzero if required prerequisites/evidence are missing.
- [x] GUI/external/manual execution requires the appropriate explicit gates;
  overlapping GUI runs across worktrees cannot compete for desktop focus.
- [x] Runner tests cover planning, deduplication, gates, missing dependencies,
  timeouts, failures, skips, cleanup, concurrency and aggregate exit status using
  harmless fake subprocesses. Testing runner safety does not itself steal focus.
- [x] Required Evil input cases run rather than skip. Reports distinguish passed,
  failed, declared skipped, pending/manual and not selected results.
- [x] Headless task-client coverage exists; eligible completion/geometry matrices
  and stress separation reduce routine GUI work with a before/after behavioral
  mapping and regression-sensitivity evidence. Native focus/rendering coverage
  remains intact; no arbitrary speed target weakens tests.
- [x] Per-run evidence identifies tested inputs/environment, records durations and
  all attempts, and supports safe reuse instead of redundant unchanged reruns.
- [x] `docs/testing.md`, `CONTRIBUTING.md` and `AGENTS.md` agree on selection,
  commands, required gates, repetition and evidence. Existing documentation
  entry points still work; `CONTEXT.md` stays domain-focused.
- [x] Final implementation verification includes runner/headless tests and one
  approved full self-contained regression on the final candidate. Any subsequent
  change invalidates affected evidence; external/manual outcomes are explicitly
  recorded rather than inferred from the regression result.

## Verification and completion record

Implemented 2026-10-05/06. `./test.sh` runs [test/runner.py](../test/runner.py)
(Python 3.9 standard library). [`portal_suite`](../test/suites.cmake) labels
each CTest suite with one category, features, effects and needs; desktop,
stress and external suites exist only in the `opt-in` CTest configuration, so
plain `ctest` stays headless. Lisp suites run one file each through
[portal-suite.el](../test/portal-suite.el); shared fixtures moved to
`test/portal-gui-testing.el`, `portal-launcher-testing.el` and
`portal-agents-testing.el`, which define no tests. Manual checks are listed in
the runner and read their procedures from their documents.

**Browser tooling:** `playwright-core` 1.63.0, exact in `host/package.json`
and `bun.lock`; its WebKit 26.6 (revision 2359) installs into
`build/playwright` (target `portal-test-browser`) and runs headless under
`bun test`. Frontmost-app sampling showed no focus change during its runs.

**Final category mapping** (`./test.sh all --list` prints each suite's tests):

| Category | Suites |
| --- | --- |
| unit (30) | launcher, global-shortcut, startup, pi-extension, host-actions, host-tasks, todo-tasks, quick-terminal, terminal-metadata, terminal-choose, terminal-bindings, agents, agents-evil, tasks-view, terminal-consult, terminal-embark, view, toolbar, input, excalidraw, test-runner, launcher-geometry, channel, views, input-core, terminals, web-core, toolbar-core, shortcuts-core, module |
| integration (9) | processes, agent-discovery, actions, ui-host, web, tasks, native-check-helpers, benchmark-tool, tasks-page |
| gui (19) | web-gui, terminal-gui, terminal-startup-gui, coexistence-gui, excalidraw-gui, input-gui, markdown-gui, tasks-gui, toolbar-gui, terminal-choose-gui, agents-gui, global-shortcut-gui, tasks-view-gui, launcher-gui, launcher-daily-use-gui, native-focus, native-toolbar, native-launcher, native-shortcuts |
| stress (3) | views-stress (headless), launcher-stress-gui, native-launcher-stress |
| external (2) | agent-discovery-live, launcher-recipe |
| manual (11) | global-shortcut-physical-keys and the ten rows of the launcher's hands-on validation |

Formerly outside CTest: Python tests (now `native-check-helpers`,
`benchmark-tool`, plus the new `test-runner`), `test/list-todo-tasks.test.ts`
(`todo-tasks`), the standalone AppKit recipes (`native-*`, built by CMake),
`terminal-shell-startup.sh` (`terminal-startup-gui`), `launcher-daily-use.sh`
and `launcher-recipe.sh` (now wrappers of `./test.sh`), the combined GUI
procedure (per-file GUI suites) and `global-shortcut-smoke.sh` (manual).
`benchmark.sh` and `test/portal-agents-benchmark.el` remain measurements, not
tests; `docs/agent-discovery/` holds a research harness, not tests.

**Behavior migrations:**

| Behavior | Before | Now | Sensitivity evidence |
| --- | --- | --- | --- |
| Picker results with stock and Vertico completion | 10 native presentations | batch `portal-launcher-completion-returns-what-completion-returns`; GUI keeps letters+Return, arrow+Return, Escape | Treating an empty result as cancel fails only the batch test |
| Command completion stack, stock and enhanced | GUI, both | batch both; GUI enhanced | — (matching is Lisp; frames/visibility stay native) |
| *Completions* shows nowhere, fixed and fitted | GUI, two sizes | batch both; GUI fitted | Removing the minibuffer display rule fails the batch test |
| Placement arithmetic, 4 sizes × 2 offsets × displays | GUI, 8 placements per display | windowless `launcher-geometry` on 3 display areas; GUI 2 real placements per display | Removing the clamp fails `launcher-geometry` |
| 100 hide/show and 20 delete cycles | routine GUI | `launcher-stress-gui`; routine keeps 3 and 2 | retained, not replaced |
| 20 native attach/detach cycles | routine native check | `native-launcher-stress`; routine keeps 2 | retained |
| Task page script | GUI only | `tasks-page`, 9 headless WebKit tests; GUI tasks suite unchanged | 9 of 10 page-script mutations fail a test; removing the scroll restore does not change browser WebKit's scroll, so `tasks-gui` keeps that evidence |
| Live-agent suite's tmux identity case | external only, needing an env var | `agents-gui`, declared optional without tmux | — |

**Measurements (same machine, 2026-10-06, with the user active on it):**
headless before: serial `ctest` 50.7 s + separate Python/Bun 5.3 s, 289 ERT
executions (10 duplicates), 2 Evil skips; after: `./test.sh` 17 s, parallel,
no duplicates or skips. GUI before (base commit's documented procedures):
combined suite 99 tests in 154.0 s wall (1 skip), daily-use 10.2 s and
shell-startup 2.7 s re-running 3 of those tests, standalone checks 33.0 s
including 20.2 s of recompilation; 7 GUI processes, about 201 s. After:
desktop phase 209.8 s for 102 ERT tests (no duplicates) and 5 native runs,
including stress formerly in routine runs; 21 GUI processes, one fresh Emacs
per suite; routine launcher GUI tests 72.6 s → 63.6 s. Frontmost-app changes
(10 vs 23) are confounded by the user's concurrent activity. A first base run
is excluded: the measurement wrapper lacked lexical binding and idled until a
1200 s watchdog stopped it.

**Commands and results** (records in `build/test-runs/` of the worktree):

- `./test.sh` (headless) on the final commit: 39 of 39 suites passed in 17 s;
  from an empty build directory of an exported checkout, it configured, built
  only the unit and integration prerequisites (11.1 s, including WebKit) and
  passed 39 of 39 in 57 s, building no native module.
- `./test.sh regression --allow-gui`, approved desktop time (option A): on
  `07b07fd`, all 21 desktop suites passed and `ui-host` failed once from a
  latent race in `portal-server-restarts-and-recovers-after-a-crash` (1 of 64
  runs at 8 in parallel; 0 of 160 after waiting for the sentinel, `d1896ac`).
  On `d1896ac`, 60 of 61 suites passed, 365 ERT executions: headless 17.9 s,
  desktop 191.3 s. `portal-launcher-gui-minibuffer-panel-fits-vertico` drew
  no Vertico rows before typing once, a timing flake under load in an
  unchanged test; a recorded `--repeat 3` of `launcher-gui` on the same inputs
  passed 3 of 3. Later commits changed only `test/test_runner.py` and the
  browser install rule; the registry and desktop artifacts are identical, so
  the desktop evidence stands and the headless aggregate was rerun.
- Runner tests (15) pass under Python 3.14 and 3.9, including during
  concurrent edits to the checkout; `bun run --cwd host check` and
  `typecheck`, changed-Lisp byte compilation and `git diff --check` pass.
- Mutation evidence is in the migration table above.

**Review round 1** found five defects, now fixed in `1604d52` and `0e0a2f0`:
desktop entry points now take the module, app host and injector from the
selected build (`PORTAL_TEST_BUILD`) and manual helpers its configured Emacs;
`--build-dir` is made absolute; reuse is per suite, keyed to the digests of
the files each suite runs and judged as the requested command would, so a
reused declared skip leaves `all` incomplete and a failure needs `--reason` in
any selection; and `--list` reads a copy of a configured registry, writing,
building and downloading nothing. Runner tests grew to 21 (relative paths,
reuse under `all`, per-suite artifacts with failure retries, a read-only
listing checked with a recording fake `cmake`, helper build and Emacs, and the
real registry's desktop commands). A manual helper in its own session hung up
the terminal as it exited; streamed subprocesses now read no input.

- An exported checkout with no default `build/`, configured only through
  `--build-dir ../alt-build`: `unit` 30/30, including the registry check that
  every desktop command uses that build; `--list` then worked, and no
  `build/` appeared. With deliberately broken files in its default `build/`
  (a junk module and injector, a host that exits 1), `web-gui`,
  `markdown-gui` and `terminal-startup-gui` passed from the alternate build.
- `./test.sh regression --allow-gui` on `0e0a2f0` (approved desktop time):
  60/61 suites, 365 ERT executions, headless 33.6 s, desktop 204.5 s.
  `portal-integration-focus-and-cleanup-in-either-startup-order` once lost an
  injected `C-x b`; a recorded `--repeat 5` of `coexistence-gui` on identical
  sources, tools and artifact digests passed 5/5.
- Known flakes, unchanged tests: `fits-vertico` failed 1 in 5 fresh launcher
  runs and the coexistence focus case 1 in 8 runs, on a machine in use.

**Review round 2** found that artifact discovery dropped missing files and
split paths containing spaces, so a deleted tool or an unfingerprinted
changed one could be cited as passing. Fixed in `dda9a08`: a suite's built
files are whole arguments and assigned values inside the build, a missing one
stays required with no digest, and evidence needs the same set of files with
the same digests. Two new runner tests (deleted tool; spaced build path with a
tool made to fail; missing or changed implicit desktop files) fail against the
previous runner and pass now; 23 runner tests pass under Python 3.14 and 3.9.
Since the round-1 regression only the runner's evidence logic, its tests, docs,
`.gitignore` and this record changed; the CTest registry, Lisp suites and
scripts are identical, and `./test.sh` passed 39/39 on `dda9a08`.

**External and manual:** not run. `agent-discovery-live` needs credentials,
trusted projects and the three agents; `launcher-recipe` needs launcher.el;
the eleven manual checks need a person. `./test.sh all` reports them
incomplete until they are done. Known flake: `fits-vertico`, 1 failure in 5
fresh-Emacs launcher runs on a machine in use.
