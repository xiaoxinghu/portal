# Launcher setup and daily-use validation

The opt-in launcher passed the user's full daily-use checklist on 2026-10-04:
normal configuration, fullscreen/Spaces, monitor changes, IME and VoiceOver.
The `launcher-daily-use` task is complete. Automated evidence and manual
acceptance are distinguished below; support remains limited to the recorded
environment.

The checklist used Portal's then-built-in picker and `portal-launcher-mode`'s
chord. Since 2026-10-05, user configuration composes launchers; setup, migration
and rollback below use the
[launcher.el recipe](launcher.md#application-launcher-with-launcherel-optional).
Native panel behavior is unchanged, but manual results describe the removed picker.

## Tested environment

| Component | Tested configuration |
| --- | --- |
| Emacs | GNU Emacs NS 31.1, revision `a360712c9d272d950d8d8255ef74570f7e90b7d9`, dynamic modules and native trampolines enabled |
| macOS | 27.0.1 (26A434), Apple Silicon |
| Application picker | `launcher.el` revision `731146d95d7d1ff16f48e7a200da873c8d8b375c`, through Portal's former built-in adapter |
| Repeatable completion matrix | Stock completion; Vertico 2.15, Orderless 1.8, Marginalia 2.13 |
| Isolated copy of active settings | Vertico 20260830.123 with multiform and directory bindings, Orderless 20260830.1156, Marginalia 20260821.1231; styles `(orderless partial-completion basic)`, 10 candidates, no cycling or posframe |
| Theme and font in that isolated run | Modus Themes 20260829.1926, `modus-vivendi-tinted`, JetBrainsMono Nerd Font 17 |
| Displays in prior geometry checks | Gigabyte M32U and LG ULTRAFINE, both Retina, unequal origins; logical-point geometry passed |

Active settings were inspected read-only in normal Emacs; only relevant
completion/theme configuration was copied into disposable automated runs.
Later user-confirmed normal-session results appear below. Other Emacs revisions,
ports and macOS versions are unverified; runtime restricts the Emacs build.
Outbound native drag-and-drop is cancelled. Commands must be synchronous and
use the panel's minibuffer; choosing other frames requires wrappers.

## Set up a fresh session

1. Follow [Build and run](../README.md#build-and-run) with the Emacs installation
   that will load the module. After native updates, rebuild Portal and restart
   Emacs. Never mix new Lisp with an already-loaded old module.
2. Install `launcher.el` at the tested revision and copy the guide's recipe—or
   your own launcher—into the trial configuration. Portal neither installs nor
   downloads it.
3. Load Portal and evaluate the setup in disposable graphical Emacs with your
   completion/theme configuration and an unused shortcut chord. Loading
   `portal-launcher` and presenting register nothing; only
   `portal-global-shortcut-set` does. Keep `native-comp-enable-subr-trampolines`
   enabled; fix native compiler errors before presenting, without bypassing guards.
4. Try the workflow below, then explicitly evaluate the documented setup in a
   **fresh normal session** and repeat. Record actual packages, theme, input source,
   keyboard and monitor arrangement. Copied settings fragments do not count as
   complete normal configuration.
5. Keep an ordinary Emacs frame with a text buffer and live Portal web/terminal
   views. Verify usability before, during and after launcher enable/disable.
   Do not rebuild the loaded binary during the session.

The launcher needs only Emacs and the shared native module, with no app host,
separate launcher application or `emacsclient` on its shortcut path. Busy Lisp
delays shortcuts.

## Migrate the M-x.app launcher shortcut

Start Portal on a different chord to allow restoring either launcher. In M-x
Settings, record the launcher row's trigger and Eval expression, such as
`(my/popup-command #'launcher)`. Trash **only that row**, then assign its freed
chord with `portal-global-shortcut-set`.

Keep M-x, its other shortcut rows, `emacsclient` path and URL handlers.
`emacs://`, `org-protocol://`, modifier double-taps and multiple shortcut bindings
remain M-x features outside this milestone. Verify an existing URL/org-protocol
action after migration. Portal never automatically reads, edits or migrates M-x
preferences.

## Roll back

Remove launcher setup from the init file to prevent re-registration on reload.
Evaluate `(portal-global-shortcut-remove 'app-launcher)` for each shortcut name,
then `(portal-launcher-mode -1)`. Verify the panel disappears and its chord no
longer invokes Portal. Disabling during a prompt cancels the session before
deleting the panel. Repeated disable/removal is safe; disabling alone retains
all shortcuts.

This releases shortcut registrations, dedicated frame, launcher hooks and frame
guards. Ordinary frames, web views and terminal sessions keep working; their
shared native module remains loaded. Restart Emacs to replace it. Optionally
restore the saved M-x row and chord; do not uninstall M-x or remove its URL
handlers.

## Repeatable checks

Run the batch checks, then the focused graphical suite:

```sh
./test.sh
./test.sh gui --suite launcher-daily-use-gui --allow-gui
```

The graphical suite opens a disposable `emacs -Q` with the test-only AppKit
injector, runs two tests, and fails for failures or skips; `run.log` in its
[recorded run](testing.md#skips-repetition-and-evidence) has ERT's output.
Native windows temporarily take focus; wait for completion before using other apps.
The configured Emacs must match the build's header and supported revision.
`./test.sh gui --suite launcher --allow-gui` also runs the launcher's other
graphical suites: lifecycle, focus, geometry and completion.
[test/launcher-daily-use.sh](../test/launcher-daily-use.sh) runs the focused suite.

To check an isolated completion/theme fragment without changing your init:

```sh
PORTAL_LAUNCHER_CONFIG=/absolute/path/to/completion-and-theme.el \
  ./test.sh gui --suite launcher-daily-use-gui --allow-gui
```

The fragment adds installed packages to `load-path`, enables their modes and
loads the theme before testing. The completion test preserves its settings.
Do not pass a full init: it may start unrelated services or UI. Use the fresh
normal-session procedure for that acceptance check. Default runs use
CMake-downloaded packages.

On the validation machine, batch native-trampoline compilation requires the
existing Homebrew GCC library-path workaround. Missing `emutls_w` means compiler
setup failure. The successful run used:

```sh
export LIBRARY_PATH="/opt/homebrew/lib/gcc/current:/opt/homebrew/lib/gcc/current/gcc/aarch64-apple-darwin25/15${LIBRARY_PATH:+:$LIBRARY_PATH}"
```

This path is machine-specific; verify the installed GCC directory elsewhere.
The checks keep native trampolines enabled and do not change compiler settings.

The combined suite exposed test isolation failure: ordinary native-window
mutation/deletion can asynchronously activate the previous app, correctly
cancelling the next prompt before typing finishes. A four-test reproduction
failed before, and passed after, the shared GUI fixture let native events settle
during cleanup. The full launcher suite passes together; the production
focus-loss observer is unchanged.

## Hands-on validation

Procedures retain historical command names. Now substitute your launcher
command, such as `my/app-launcher`, for `portal-launcher-present`, use its global
shortcut, and follow the [documented rollback](launcher.md#migrate-from-the-built-in-launcher).

For regression runs, record date, Portal commit, Emacs revision, macOS build,
complete init, completion/theme versions, keyboard/input-source names, display
layout and every row's result: **pass**, **fail** or **not tested**, with exact
symptoms. Failures need a reproduction and a fix or explicit scope decision;
missing equipment/results are not passes.

| Check | Procedure and expected result | Current production evidence |
| --- | --- | --- |
| Normal configuration | In fresh normal Emacs, enable the documented setup. Physically invoke from another app, launch a stopped app, then reactivate it. Destination gets focus without raising an ordinary Emacs frame. | Pass: user-confirmed full checklist on 2026-10-04 |
| Selection without typing | Open and press Return on the highlighted app. Reopen, choose another with Down/Up and press Return. Both launch the selection without typed text. | Pass: user-confirmed manual retest on 2026-10-04 after the selection fix; automated minibuffer and native key checks also pass |
| Refresh and search | `C-u M-x portal-launcher-present` refreshes, `M-x launcher-refresh` works separately. Enter `!gh portal launcher` and unmatched text; check the encoded query and destination focus. A freshly installed/removed test app appears/disappears after refresh. | Pass: user-confirmed full checklist on 2026-10-04 |
| Cancellation | From another app, try Escape, C-g, the chord again and a queryless bang: panel closes without external action and focus returns. Click another app during a prompt; it keeps focus. Empty completion results also cancel; Return accepts a highlighted app. | Pass: user-confirmed full checklist on 2026-10-04 |
| Failure and recovery | Run `(portal-launcher-present (lambda () (interactive) (error "Launcher recovery check")))` from Emacs; it reports the error and hides. Invoke normally again. Repeat a stale bundle/open failure while another app is active. | Pass: user-confirmed full checklist on 2026-10-04 |
| Fullscreen and Spaces | Put another app fullscreen. Invoke, type, select and cancel without switching Spaces; repeat in another Space and verify focus return and successful activation. | Pass: user-confirmed full checklist on 2026-10-04 |
| Monitor changes | Invoke on each monitor. Test unplugging one with the panel visible and with it hidden; reconnect and invoke again. No stranded panel, wrong display or unreachable prompt. Record origins, scale and removed monitor. | Pass: user-confirmed full checklist on 2026-10-04 |
| Chinese/Japanese IME | Name the macOS input source. Compose, e.g. Pinyin `nihao`; open/navigate candidates and commit `你好`. Verify marked text/candidate positioning, committed text and cancellation; restore the prior source. ASCII, pasted Unicode and dead keys do not qualify. | Pass: user-confirmed full checklist on 2026-10-04 |
| VoiceOver | Enable VoiceOver and summon the panel. Record spoken prompt, editable input, candidate names, current selection and navigation/accept/cancel ability. Check focus after dismissal; restore prior VoiceOver state. Accessibility trees or screenshots alone cannot establish speech. | Pass: user-confirmed full checklist on 2026-10-04 |
| Reload and rollback | Re-evaluate launcher setup, disable twice, re-enable and use again. Ordinary text input, web navigation and the same terminal shell work throughout. Disable and confirm the chord is free; restore the M-x launcher row if applicable and test an existing URL binding. | Pass: user-confirmed full checklist on 2026-10-04 |

## Evidence recorded on 2026-10-03

Both new graphical tests pass with stock completion and the isolated active
completion/theme settings above. Native AppKit events type an app name and spaced
bang query, cancel empty input and Escape, trigger an open error, then read a
recovery prompt. External launch/browser calls are fixtures, not proof of human
app launch.

The coexistence test opens a second ordinary frame, live shell and WebKit page.
Three reload/disable/re-enable cycles preserve shell PID and both view identities,
run shell commands and load new pages after each rollback, and verify panel,
shortcut registration and frame-guard removal. An initial assertion passed a
buffer instead of a window; fixing it passed without production changes.

The build, all 32 CTest suites, host formatting/type checks, native
failure-reporter tests, changed-test byte compilation and Org structure/identity
checks pass. All 14 launcher GUI tests pass together; the two focused tests also
pass with stock and copied local completion/theme settings in fresh processes.

The [application integration record](launcher-applications.md) retains the
earlier real-app smoke, cold/warm timings and static monitor measurements.
The task in [project.org](../project.org) records final manual acceptance.

## Selection correction on 2026-10-04

The user's manual test found Return on a highlighted app required typed text. The adapter
now accepts the completion reader's result, superseding empty-input cancellation.
The configured test checks selection without typing, stock completion's empty
results, Escape and queryless bangs. The hands-on matrix includes initial and
arrow-key selection.

All 15 combined launcher GUI tests pass with updated regressions, as do launcher
CTest, changed-test byte compilation, shell syntax and Org validation. The
copied-settings rerun remains inconclusive, not a pass: extra keystrokes changed
fixture `Calculator` input. The earlier configured run is historical evidence;
later user-confirmed normal-session results supply hands-on acceptance. GUI
checks used an alternate shortcut because the user's running Emacs held the
normal chord.

## Manual acceptance on 2026-10-04

After PR #74 merged the selection fix, the user said manual tests looked good
and asked to proceed. Explicitly asked whether this covered the full checklist,
including fullscreen/Spaces, monitor changes, IME and VoiceOver, they confirmed
“all works”. Every row is therefore recorded as a user-verified pass, completing
the daily-use task.

Manual results rest on that confirmation. The environment table retains earlier
automated runs' versions/settings; the user supplied no additional input-source
names, environment versions or VoiceOver transcripts. The interrupted
copied-settings run remains inconclusive, not an automated pass.

## User-configured launchers on 2026-10-05

Portal's application picker, default command, shortcut option and toggle were
removed. Both automated daily-use tests now run without launcher.el. With caller
completion/theme settings, the completion test's picker records intended launches:
a typed name, Escape, Return without typing, failed launch and recovery prompt.
The coexistence test evaluates the [launcher guide's](launcher.md) picker, hello
and shortcut examples on test chords, shortcuts twice per cycle. Across three
cycles, disabling preserved all three shortcuts; removing them freed their
chords. Shell and web page kept working. Both passed the full launcher graphical
run; [application notes](launcher-applications.md) record the separate launcher.el
smoke test.

## Content-fitted minibuffer panels on 2026-10-05

Minibuffer panels now fit their displayed content by default; `'(720 240)`
and other numeric sizes stay fixed, and buffer panels keep 720 × 420. See
[Panel size](launcher.md#panel-size). Native focus, dismissal and shortcut
behavior is unchanged: fitting is layout only.

Automated evidence: all 28 launcher graphical tests, the 26-test launcher
suite and both daily-use tests, which use fixed sizes, passed together in one
disposable Emacs on the tested build. The new fitting tests cover five, two,
no and five rows, Vertico 2.15 with `vertico-resize` grow-only, t and nil,
group titles, line spacing, wrapped input, timers, echo-area messages, nested
prompts, the screen's bottom, the pointer on the other display, and marked text
kept while the panel resizes. Focus-loss, nested-dismissal, error and
kind-alternation tests also run with an automatic height. The
[implementation notes](launcher-native-panel.md#content-fitted-minibuffer-panels)
record measured heights.

Marked text was set and committed through Emacs's NS text-input client from a
test event monitor, not a physical input method. Not re-run: the hands-on
checklist above. Physical CJK input methods, display disconnection and
VoiceOver with a resizing panel are not tested; their earlier passes used fixed
panels. Repeat those rows before relying on fitted panels with them.
