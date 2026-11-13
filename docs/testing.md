# Testing Portal

Tests define coverage. Do not duplicate their inventory here.

## Verifying work

1. Run the [default loop](../CONTRIBUTING.md#default-loop) while working:
   CTest, Bun and Python tests, lint and type checks, then the view and input
   graphical scripts. Run the [full set](../CONTRIBUTING.md#full-set) once
   before merging. For native view, keyboard or launcher changes, also run
   the relevant standalone checks below.
2. Graphical checks open real windows, take keyboard focus and can crash.
   Run them in a logged-in desktop session and leave it alone meanwhile, or
   [in a VM](#graphical-checks-in-a-vm).
3. Report commands, results and skipped checks, and which tier ran. Report
   graphical checks you could not run as not run.

For this Homebrew Emacs build, set its native compiler library path before
running checks from a shell. CLI launches do not inherit the app's environment:

```sh
export LIBRARY_PATH="$(/usr/libexec/PlistBuddy -c Print:LSEnvironment:LIBRARY_PATH /Applications/Emacs.app/Contents/Info.plist)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
```

`SDKROOT` also lets a Homebrew GCC built against Command Line Tools use the
selected Xcode's SDK when the guest has no separate Command Line Tools install.
For an SSH-only test account, set these in its `~/.zshenv` so non-interactive
builds inherit them. Verify actual native compilation, not only
`native-comp-available-p`, before saving a prepared VM.

## Writing tests

- Test at the narrowest useful boundary. Use the real core with a fake platform
  for shared rules. Use native integration tests for behavior controlled by
  AppKit, WebKit or Emacs's command loop.
- Test what the app host serves in Bun, beside it in `host/*.test.ts`: routes,
  headers, Markdown previews, local images, the offline editor bundle and its
  dependency releases. They call `respond` with a `Request`, without a
  listener or Emacs.
  `test/portal-server-tests.el` tests only the Emacs seam: how Emacs starts the
  host, reads its handshake, restarts it and cleans up after it.
- Graphical tests prove the seam between Emacs and what it embeds: that keys,
  pages, files and questions cross it. Keep one such proof per feature.
  Matrices of rules live in the C core's tests, command behavior in batch
  Lisp, and the host's bundle and dependency releases in its Bun tests. Leave
  Ghostty's parser, WebKit's rendering, Excalidraw's importers and stylesheet
  colors to their own projects; give a drawing its content as a file.
- Launcher tests may drive Vertico, Orderless and Marginalia. The panel must
  fit what Emacs draws for the completion stacks people use, which only a
  graphical Emacs shows; the tests check the panel, not those packages.
- Assert observable results, not incidental caches, hook names or call counts.
  Platform contracts include resource ownership and ordering.
- Drive input and focus tests through the event loop. Direct handler calls do
  not prove keyboard access.
- Mark web fixture fields that tests type into `spellcheck=false`. Otherwise
  macOS may show its correction panel, whose nested event loop holds Emacs's
  main thread until a key arrives, so the next injected key never comes.
- After giving a web view the keyboard, wait until its page has focus before
  typing. WebKit tells the page asynchronously; an earlier key reaches the page
  but not its field.
- A page is hidden to WebKit while other apps' windows cover its frame, even
  with the keyboard in it, and WebKit refuses it fullscreen then. Wait for
  `document.visibilityState` to be `visible` before relying on it. Where
  WebKit refuses fullscreen outright, as on GitHub's macOS runners, the
  fullscreen tests skip; run them in the VM.
- Isolate fixtures. Clean up buffers, processes, files and registrations, even
  after failure. Leave user configuration and existing sessions untouched.
- CTest runs suites in parallel. Keep each one to its own temporary files and
  dynamically chosen ports; mark a suite that cannot share the machine
  `RUN_SERIAL`.
- Keep default checks headless and credential-free. Register them in the
  [CMake suite](../CMakeLists.txt) or [core suite](../native/Core/CMakeLists.txt).
  Keep special setup beside the test. Use
  [native failure helpers](../test/native-checks.swift) to avoid assertion
  failures that trigger macOS crash dialogs.

## Test tiers

ERT tags place each test in a tier. Tag a test `:gui` when it needs graphical
Emacs. Tag it `:expensive` when it is a long soak or a matrix of variants
whose plain case another test covers: the full set runs it, the default loop
does not. Every runner narrows its selector through
[portal-test-tiers.el](../test/portal-test-tiers.el): `:expensive` tests run
only when `PORTAL_TEST_EXPENSIVE` is set and not empty, and batch Emacs never
selects `:gui` tests. `test/vm.sh` passes the variable on to the VM. Register
a new batch suite with `${ert_batch}` in CMake, and start a graphical one
through `portal-gui-ert-start`, so that it honours the tiers too.

## Evidence and safety

Fake-backend tests cannot prove native window behavior. Injected AppKit or Carbon
events cannot prove physical-key delivery, Accessibility, Spaces or fullscreen
behavior. Verify those manually.

An Emacs without an Accessibility grant cannot post a chord, and nothing can
grant one from a shell. The Accessibility alert can be checked in the VM: TCC
attributes an Emacs started from the runner's shell to sshd, a
platform binary it never prompts for, so start Emacs with `open -n -W -a` in
the runner's command, reset with `tccutil reset Accessibility org.gnu.Emacs`,
and read the alert's lifetime from `log show` (`universalAccessAuthWarn`
launches and WindowServer's `AppVisible` assertion on it).

Run GUI checks in disposable graphical Emacs or standalone processes; they
take focus and can crash. Keep launcher subroutine trampolines enabled.
Report skips and manual checks separately from passes. Record the native acceptance
environment; old results are not current evidence. Support claims follow the
[platform acceptance checks](platforms.md#acceptance-checks).

## Graphical checks in a VM

Graphical checks take the desktop's focus. To run them in a logged-in macOS
VM instead, set up passwordless SSH to it and name its SSH alias once per clone:

```sh
git config portal.testVm portal-vm
```

Every worktree of the clone shares the setting. The graphical scripts then
rerun themselves in the VM through `test/vm.sh`, so `sh test/views-gui.sh`
builds and runs there, and [`sh test/gui-all.sh`](#every-graphical-suite) runs
every suite there after one build. `git config --unset portal.testVm` runs them
locally again. For other commands, such as standalone checks, call the runner from the
checkout under test:

```sh
bash test/vm.sh
bash test/vm.sh sh test/launcher-daily-use.sh
```

Each run copies tracked and untracked non-ignored files, including uncommitted
changes, into a new `~/portal-test-runs/run.XXXXXXXX/repo` directory. Deleted
files, Git metadata and ignored build outputs stay out. Once it has the VM's
desktop, the run moves them to `~/portal-test-runs/work`, replacing the
previous run's tree, builds there, then runs the command there.
Pass `sh -c 'command…'` for compound commands.

When the previous run's build is complete, its `build/portal-build.eld`
records the [source identity](install.md#what-portal-checks) of the new files,
and the files the build reads beyond those, its license notices' sources and
the C core's tests, are unchanged too, the run keeps that build, with the host's packages, and says it is skipping
`./build.sh`. Changes to Lisp, tests and documentation need no rebuild. The
identity covers neither the guest's Emacs nor Xcode: after changing either,
delete `~/portal-test-runs/work` so that the next run builds afresh.

Commands inherit the installed Emacs app's native compiler library path, which
direct SSH launches miss. Trampolines stay enabled. `PORTAL_TEST_VM` names the
VM for one run, ahead of the setting; graphical scripts run there even in a
clone without it.
`PORTAL_TEST_TIMEOUT` sets a positive integer limit in seconds per build/test stage
(default: 1,200). Timing starts after acquiring the desktop lock.
Requires Bash, macOS's built-in `lockf`, SSH and rsync. No Python or extra npm
packages.

Runs have separate files but share the desktop and VM resources. One guest-wide
file lock queues builds and GUI commands. The guest build prepares the GUI test
artifacts; it does not replace host verification.
Always use the runner for GUI work; manual tests bypass its lock.
Keep commands in the foreground. The runner terminates their process group on
completion or timeout. SSH disconnects can leave runs active until timeout.
Reconnect to inspect saved logs.

Remote output goes to `build.log` and `test.log` in the run directory. Commands
can save more `*.log` files in `PORTAL_TEST_LOGS`, the run directory, or in its
subdirectories. Logs and `exit-status` files, at the top and one directory
down, copy back to `.cache/vm/<run>/`. Command failure status reaches the
caller.
The next run replaces the work tree, so a failed run also keeps an APFS clone
of it in its `repo/` for diagnosis; it takes space only once the work tree
changes. Remove failed runs' directories when no longer needed.
Keep at least 5 GiB free per fresh guest build. Leave host disk space for VM
image growth.

Guest preparation (the runner works with any macOS VM reachable over SSH):

- Use a virtual display and shared/NAT networking. With Tart, run
  `tart run --no-graphics portal-test`: this hides the host viewer, while the
  guest still has a graphical desktop. Keep that process running during tests.
- Enable Remote Login. Install the host's SSH public key, verify the guest host
  key, and configure an SSH alias. Keep private keys on the host.
  Use the same account for SSH and the guest desktop.
- Install Xcode with Swift 6.2 or newer. Select its developer directory and
  complete first-launch setup. Install Homebrew, then CMake, Ninja and Bun.
  Keep Homebrew tools under `/opt/homebrew/bin`.
- Match the host's graphical Emacs and its compiler libraries. Check the
  revision and native compilation against [launcher prerequisites](launcher.md).
  Do not use a terminal-only formula. Homebrew updates/upgrades can change the
  build; recheck the host/guest match before upgrading.
- Keep the guest desktop logged in and unlocked. Disable sleep, display sleep,
  screen saver and automatic logout. Keep display size and scale stable.
  The runner also holds a `caffeinate` assertion.
- Verify GUI tests with the VM viewer closed. SSH access alone does not prove
  AppKit, WebKit or Ghostty works.

Default: launcher daily-use acceptance check, not the full GUI suite.
Pass other graphical Emacs or standalone AppKit checks as needed.

### Managing the Tart guest

For a rebuild, use the [versioned VM recipe](test-vm.md) in `tools/tart/`.
It stages the matching toolchain, creates a new guest, provisions its settings
and checks native compilation. Keep images and staged binaries outside Git.

On an Apple Silicon Mac, install Tart with `brew install openai/tools/tart`.
Create a fresh guest from Apple's installer, then configure it as above:

```sh
tart create portal-base --from-ipsw latest --disk-size 100
tart set portal-base --cpu 4 --memory 8192 --display 1920x1200px --no-display-refit
tart run portal-base
```

On macOS 26 or newer, `--disk-format asif` at creation uses Apple's sparse disk
format. Keep the guest on a macOS version supported by the host. On a macOS 27
host and guest, Tart's `--provisioning-opts` can create the account, enable
automatic login and enable SSH on first boot; see `tart run --help`.

After preparation, shut down macOS cleanly inside the guest. Preserve
`portal-base` and create a working copy:

```sh
tart clone portal-base portal-test
tart run --no-graphics --no-audio --no-clipboard portal-test
```

Keep one working VM between runs so the runner can reuse its build. Cloning a
fresh VM for every suite loses that cache. APFS clones initially share disk
blocks, with changed blocks consuming additional space.

Point the `portal-vm` SSH alias at the working VM. This example uses the guest
account `portal` and resolves Tart's current IP instead of hard-coding a DHCP
address; adjust the executable path if Homebrew is installed elsewhere:

```sshconfig
Host portal-vm
  HostName portal-tart
  User portal
  HostKeyAlias portal-tart
  ProxyCommand /bin/sh -c 'exec /usr/bin/nc "$(/opt/homebrew/bin/tart ip portal-test)" 22'
  BatchMode yes
  ConnectTimeout 10
  ServerAliveInterval 15
  ServerAliveCountMax 3
```

Install the host's public key in the guest and verify its SSH host key before
running tests. A stopped VM must be started before using the alias. Run
`sh test/views-gui.sh` and `sh test/input-gui.sh` with the viewer closed to
check native rendering and focus before relying on the environment. If macOS
interrupts a fresh guest with the [printer-discovery permission prompt](test-vm.md#resolve-the-first-print-permission-prompt), resolve it in the viewer and
repeat the affected suite with the viewer closed; a passing SSH check alone
does not establish a working GUI session.

Export the prepared, shut-down base to a backup destination:

```sh
tart export portal-base /path/to/backups/portal-base.tvm
tart import /path/to/backups/portal-base.tvm portal-restored
```

Boot the restored copy and check it before relying on the archive. Keep a copy
on another disk for protection against host disk loss. A local clone is useful
for resetting test state, but is not an independent backup. Shut down the guest
cleanly before cloning or exporting; do not copy a running disk image. Local
VMs live under `~/.tart/vms/` by default.

## Every graphical suite

To run every graphical suite in the [full set](../CONTRIBUTING.md#full-set),
each in a fresh Emacs:

```sh
PORTAL_TEST_EXPENSIVE=1 sh test/gui-all.sh
```

In the VM, the runner builds once and the suites run one after another in the
same run. A failing suite does not stop the others; the wrapper ends with each
suite's result and fails if any failed. The [real-server tier](#against-a-real-rex-server)
is "not run" where no Rex Server is installed, and fails nothing. Each suite logs to a directory of its
own in `PORTAL_TEST_LOGS`, or `build/gui-all` outside the runner: `views`,
`input`, `launcher`, `terminal-shell-startup`, `rex-server` and `package`, each with the
suite's output in `test.log`, its `exit-status` and its diagnostics, such as
`gui-progress.log`. In the VM they copy back below `.cache/vm/<run>/`. The
wrapper raises `PORTAL_TEST_TIMEOUT` to 3,600 seconds, as one stage runs every
suite and `test/package-gui.sh`'s own build. Calling the runner directly keeps
its default, so set the limit too:

```sh
PORTAL_TEST_TIMEOUT=3600 bash test/vm.sh sh test/gui-all.sh
```

## View graphical checks

For ordinary terminal and web views (WebKit loading, terminals, their
coexistence, Markdown previews and Excalidraw) in one fresh Emacs:

```sh
sh test/views-gui.sh
```

Pass an ERT selector regexp to run part of its tier. It fails on any skip. The
[platform matrix](platforms.md) uses it as the view acceptance check.

## Input graphical checks

Graphical ERT suites run through [gui-ert.sh](../test/gui-ert.sh). It compiles
and loads the test-only event injector, adds `build/elpa` to Emacs's load path,
and runs the suite in one fresh Emacs. The injector needs no Accessibility
permission. Reuse it for other GUI suites, as
[input-gui.sh](../test/input-gui.sh) does; keep dependency versions in CMake.

For keyboard input checks in a fresh Emacs process (the terminal
and coexistence tests run in the [view suite](#view-graphical-checks)):

```sh
sh test/input-gui.sh
```

It passes only with every selected test as expected and none skipped. Give
`input-gui.sh` an ERT selector regexp to run part of its tier.

### Diagnosing a stalled GUI run

`gui-ert.sh` prints each test's start, result and duration to standard error
as it happens, and appends a start and end record to `gui-progress.log` in
`PORTAL_TEST_LOGS`, or `build/` without it. In the VM, standard error goes to
`test.log`; watch a run with the path `bash test/vm.sh` prints:

```sh
ssh "$(git config portal.testVm)" tail -f '~/portal-test-runs/run.XXXXXXXX/test.log'
```

A stuck native call can stop every Lisp timer, including `with-timeout`, so a
shell watchdog bounds each test. When no test starts or ends for
`PORTAL_GUI_TEST_TIMEOUT` seconds (default: 60), it samples Emacs into
`emacs-sample.log`, kills Emacs and its subprocesses, reports which test did
not finish, and exits 124. Emacs gives each subprocess its own process group,
so the runner's cleanup alone would leave them holding the desktop lock. Both logs copy back with `test.log`. The runner's stage timeout still
bounds the whole command. To rerun only the stalled test, in the tier that
stalled:

```sh
PORTAL_TEST_EXPENSIVE=1 sh test/views-gui.sh '^portal-integration-focus-'
```

In the sample, read the main thread below the test's Lisp frames. A nested
AppKit event loop there, such as `NSCorrectionPanel _interceptEvents`, waits
for an event that the blocked test would have injected. Failed VM runs keep
their `repo/`; delete it once you have the logs.

On 2026-10-11, all 39 selected cases passed in each of two fresh Emacs
processes, with none skipped. The guest ran macOS 27.0.1 (26A434) arm64, with
macOS's default text correction on, and the `emacs-plus-app` cask's Emacs 31.1,
build `31.1-349`. A deliberately stalled test, blocked in a synchronous
`call-process`, exited 124 after 66 seconds and named itself; the next suite
then ran. These cases inject AppKit events into Emacs; they do not prove
physical-key delivery.

The standalone focus check below also verifies live escape rebinding.
Physical-key delivery on the affected macOS version still needs a manual check.

## App host checks

The `app-host` CTest suite runs `bun test` in `host/`, and `app-host-seam` runs
the Emacs side. Both need a build: the Bun tests read the generated editor
bundle and start the compiled `build/portal-host` (or `$PORTAL_BUILD/portal-host`).
After `./build.sh`, run them directly:

```sh
(cd host && bun test)
```

## Rex checks

Tests of the [Rex client](rex.md) never connect to a real Rex server, and so
never to yours. They use [a fake one](../test/fake-rex-server.py): a Python
program that speaks Rex's control protocol on a Unix socket in a temporary
directory, answers a hello and the methods a connection calls, and does what
a test tells it on its standard input: its sessions and their blocks, canned
results and errors per method, events on demand, answers held back or never
sent, dropped connections, refused upgrades, fragments, pings and garbage.
It also shows a block as a real server does: it attaches, claims and sizes
it, gives tickets and serves a block's data stream, with a snapshot, the
program's output a test sends, split as the test asks, and Rex's own
messages, and paints from a screen the test sets, in parts when asked.
It changes nothing by itself: a test that sends `block_created` also says
what `session.list_blocks` returns from then on. It reports each command
done, and `portal-fake-rex-command` returns only then, so the next thing a
client asks meets the command. It frames WebSocket itself,
so it can break the framing too. Its docstring lists the commands and what
it reports; [portal-fake-rex.el](../test/portal-fake-rex.el) starts and
scripts it from any Emacs, batch or graphical, and any other harness can
run it as a subprocess. Extend it there as the client grows.

Three suites use it or the fake platform:

- `rex-core` runs the core's connection rules against the fake platform's
  sockets, with no server at all: its requests and answers, and every step
  of showing a block in a fed terminal, the stream's framing split
  anywhere, typing in order and the reports it drops.
- `rex` runs `portal-rex.el` on the built module against the fake server, in
  batch Emacs: message sockets need no window. Batch Emacs runs no main run
  loop, so the module's `rex ID` record never arrives there; these tests take
  messages by waiting, as `portal-rex-call` does.
- `test/portal-rex-gui-tests.el`, part of `sh test/views-gui.sh`, proves the
  record: events, answers and a lost connection reaching an idle Emacs, and
  blocks' buffers following a server meanwhile. It also shows a block in a
  real Ghostty view: the first paint, the stream, a pane's new size, a
  hidden buffer kept current, keys typed in order with one write out at a
  time, and queries in the block's output that the view leaves unanswered.
  And who sizes the block: the claims Emacs sends as a pane is placed,
  selected, resized, given the view or typed in and as Emacs loses and
  regains the keyboard, while another client, which the fake plays, takes
  the block at a size of its own that the view then holds.

The fake follows what a real server was seen to send, from a preview
protocol that moves every few days, so tests against it prove only that
Portal matches that reading. The real-server tier checks the reading.

### Against a real Rex server

```sh
sh test/rex-server-gui.sh
```

It runs [the real-server tests](../test/portal-rex-server-gui-tests.el) in one
fresh graphical Emacs. Each test starts a Rex server of its own through
[portal-real-rex.el](../test/portal-real-rex.el): `rex server run` on a socket
in a temporary directory, which is also the server's home and state, with no
configuration and nothing restored or saved. The `rex` commands a test runs,
as another client would, reach that server alone. Stopping it ends its
blocks, and the script fails if one outlives the run. Your own Rex server and
its sessions are never touched.

Rex is private beta software, so the tier runs only where a Rex Server is
installed: the `rex` program that `PORTAL_TEST_REX` names, or else the test
VM's `/Applications/Rex Server.app`, which [the VM recipe](test-vm.md#rex-server)
pins, or the one Rex's Mac app keeps. Elsewhere it says so, exits 77 and
counts as not run; report it so. It prints the Rex version it ran against.

It belongs to the [full set](../CONTRIBUTING.md#full-set), not the default
loop. Run it too after changing what Portal sends a Rex server or reads from
one, and after [moving the Rex pin](test-vm.md#move-the-rex-pin). With
`portal.testVm` set it runs in the VM, against the pinned Rex.

[portal-rex-parity.el](../test/portal-rex-parity.el) holds checks that run
against both servers: the handshake, `server.version`, `session.list`,
`session.list_blocks` with the buffers made of it, an unknown method, the
calls the core makes to show a block, with the shapes of their answers, how
a block's size follows its owner as Emacs and a second client of the
test's own claim and size it, and an idle block ended by killing its
buffer, with the two replies that say it is idle, and a buffer finding its
block again by ID after Emacs reconnects. The `rex` suite runs them against the fake, the tier against
a real server. When only the tier's run fails, the real server has moved:
bring the fake, and Portal, into line with it. Add a check there when the fake
can answer it as cheaply as the real server.

A change whose correctness depends on what a real server does adds a test to
the tier, with `portal-real-rex-cli` for what another client does.

## Package installation checks

The `package` CTest suite installs a copy of the checkout through
[the installation guide](install.md)'s use-package examples in empty home
directories, with and without Consult and Embark. It fails on any compilation
error or warning, even when package-vc reports success; a copy with a planted
compilation error proves that. It also upgrades an older copy with
`package-vc-upgrade` from an Emacs that has loaded it, and installs a copy whose
build fails as it installs, which package-vc only warns about. The default
loop runs only the plain installation and loading from a clone; the variants are
`:expensive`.
`test_resolve_bun.py` covers Bun selection with stand-in executables and
archives. Neither builds native code nor downloads anything.

For first use in graphical Emacs (the offered build, then a terminal and a web
view in a fresh Emacs), run:

```sh
sh test/package-gui.sh
```

It installs and builds its own copy of Portal. In the VM the runner's build
comes first, so the script raises `PORTAL_TEST_TIMEOUT` to 2,400 seconds.

## Launcher graphical checks

For the launcher's whole graphical suite, daily-use checks included, in one
fresh Emacs:

```sh
sh test/launcher-gui.sh
```

Pass an ERT selector regexp to run part of its tier. Tests that need a second
display skip. Set `PORTAL_LAUNCHER_SCREENSHOTS` to a directory to save the panel's
drawings there. The next VM run replaces the work tree, so save them in the run
directory, then copy them back from the printed run directory:

```sh
bash test/vm.sh sh -c 'mkdir -p "$PORTAL_TEST_LOGS/screenshots" &&
  PORTAL_LAUNCHER_SCREENSHOTS="$PORTAL_TEST_LOGS/screenshots" sh test/launcher-gui.sh'
```

## Combined graphical suite

Test coexistence in one fresh graphical Emacs. Load `portal.el`,
the injector, `test/portal-tests.el` and `test/portal-terminal-tests.el` before
`test/portal-integration-tests.el`. Add relevant `test/*-gui-tests.el` files.
Run `M-x ert` with selector `^portal-`. Batch Emacs cannot test native windows.

## Standalone AppKit checks

These checks isolate native integration from Emacs bindings and Ghostty.
No build target exists. After `./build.sh`, run these commands. To build and
run them in the VM, pass the same `sh -c` command to `bash test/vm.sh`:

```sh
sh -c '
set -eu
for core in channel views input terminals web shortcuts status rex json; do
  xcrun clang -std=c11 -Wall -Wextra -Werror -I native/Core/include \
    -c native/Core/$core.c -o build/$core.o
done
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -I native/Core/include -import-objc-header test/native-core.h \
  native/Backend.swift native/CoreCalls.swift native/NativeHost.swift native/NativeInput.swift \
  native/Launcher.swift native/Hotkeys.swift native/KeyPost.swift native/StatusPanel.swift \
  native/MessageSocket.swift native/Views.swift native/WebView.swift \
  test/native-checks.swift test/native-terminal-stub.swift test/native-views.swift \
  test/native-focus.swift build/channel.o build/views.o build/input.o build/terminals.o \
  build/web.o build/shortcuts.o build/status.o build/rex.o build/json.o \
  -framework AppKit -framework WebKit -framework Carbon -o build/check-focus
build/check-focus
'
```

Swap `test/native-launcher.swift`,
`test/native-shortcuts.swift` or `test/native-status.swift` for
`test/native-focus.swift`. Rename the output to match. These checks open real
windows or register real hot keys.

## C core checks

Run this standalone build for shared rules without the native backend.
It still needs macOS for `F_SETNOSIGPIPE`; a fake platform does not make the pipe
portable.

```sh
cmake -S native/Core -B build/core
cmake --build build/core
ctest --test-dir build/core --output-on-failure
```
