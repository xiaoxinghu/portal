# Rebuilding the macOS test VM

Keep the recipe in Git and the large binary artifacts in backup storage. The
scripts in `tools/tart/` capture the setup used for Portal's Tart guest:

- `recipe.conf`: tested OS and IPSW checksum, Tart, Xcode, Emacs revision, Rex Server build and virtual hardware.
- `cellar.txt`: the exact compiler libraries and build tools copied from the host.
- `stage.sh`: archives those tools and apps and the pinned Rex Server, fetches
  the pinned Bun with its checksum, and writes checksums for the complete
  staging directory.
- `create.sh`: checks the local Apple IPSW checksum and creates a new VM with the recipe's hardware.
- `provision.sh`: installs the staged tools and configures the guest test account.
- `install-rex.sh`: installs the staged Rex Server; `provision.sh` runs it, and
  it alone [moves the Rex pin](#move-the-rex-pin) in a prepared guest.
- `verify.sh`: checks the desktop account, OS, toolchain, Rex Server and real native compilation.

This is a versioned installation recipe, not a claim of bit-for-bit reproducible
macOS disks. Account setup, SSH trust, Apple's OS installation and runtime state
also affect a VM. Preserve the staged binaries and the IPSW: Homebrew may no
longer offer these versions when you need to rebuild. The staging step fails if
the host no longer has the pinned versions instead of silently upgrading them.

## Stage the tools on the host

Use an Apple Silicon host with the versions recorded in `recipe.conf`, Xcode
at `/Applications/Xcode.app`, graphical Emacs at `/Applications/Emacs.app`,
the listed Homebrew kegs under `/opt/homebrew/Cellar`, and Rex's Mac app
with the pinned [Rex Server](#rex-server):

```sh
bash tools/tart/stage.sh .cache/tart-toolchain-v1
```

The output directory must be new. It contains the app archives, compiler kegs,
Bun, Rex Server, the recipe and provisioning scripts, and `SHA256SUMS`.
Preserve the whole directory outside the checkout with the Git commit that
created it, and keep it private: Rex is beta software. It contains no
passwords or SSH keys. Xcode is copied from your licensed local installation;
the script does not download it or log in to an Apple account.

The guest receives these fixed tools directly; Homebrew itself is not needed
by the recipe. Updates are a deliberate new recipe/staging version, not an
unattended `brew upgrade` inside the baseline.

## Rex Server

The guest has Rex's server and nothing else of Rex, for the
[real-server tier](testing.md#against-a-real-rex-server). Rex's Mac app keeps
its server as a bundle of its own, `Rex Server.app`, whose
`Contents/MacOS/rex` is both the server and its command-line client. That
bundle alone runs a server with no sign-in, no first-run step and no window.
The guest has it at `/Applications/Rex Server.app`.

`recipe.conf` pins it: `REX_VERSION`, as `rex version` prints it,
`REX_BUILD`, the bundle's `CFBundleVersion`, `REX_SHA256`, the checksum of
`Contents/MacOS/rex`, and `REX_TEAM_ID`, the Developer ID team that must have
signed it. `stage.sh` copies the bundle from this Mac's Rex app: the build
Rex keeps under `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/`,
or the copy inside the app itself. When neither is the pinned build it fails,
names the build this Mac has, and prints the lines that would pin it.
`install-rex.sh` checks the signature, build and checksum again before it
replaces the guest's copy, and `verify.sh` checks the installed one.

It stays put. The server has no updater of its own: Rex's Mac app updates
it, and the app is never installed in the guest, which `verify.sh` checks. A
server run in the guest was seen to open no network connection. The tier's
servers run with a temporary home and state and restore nothing, so each run
starts from nothing.

**Keep it private.** Rex is private beta software, used here under an
invitation. It goes in the staging directory with the other large binaries,
outside Git. Never commit it, attach it to a release, or put it, the staging
directory or a guest image containing it anywhere public; no script
downloads it. If this Mac's Rex cannot be used, ask its owner for the app.

### Move the Rex pin

Rex's preview changes every few days. To follow it, update Rex's Mac app on
this Mac, then:

```sh
bash tools/tart/stage.sh --rex-only .cache/tart-rex
```

It fails, printing the new `REX_` lines; put them in `recipe.conf`. Stage
again, now with the new pin, and install it in the guest, here `portal-vm`.
The test user is an administrator, so this needs no root:

```sh
bash tools/tart/stage.sh --rex-only .cache/tart-rex-1925
rsync -a --delete .cache/tart-rex-1925/ portal-vm:rex-stage/
ssh portal-vm 'bash rex-stage/install-rex.sh rex-stage && bash rex-stage/verify.sh rex-stage'
```

`--rex-only` stages the recipe and Rex alone, not Xcode or Emacs. Then run
the `rex` CTest suite and `sh test/rex-server-gui.sh`, and commit the new pin
with what ran. A parity failure there means the fake must follow the real
server. Keep the staged directory with the recipe commit, privately.

## Create and provision

Install the recorded Tart version. Obtain Apple's restore IPSW for the exact
OS build in `recipe.conf`, then create a new name (existing VMs are never replaced):

```sh
bash tools/tart/create.sh portal-base-v2 /path/to/UniversalMac_27.2.1_26B131_Restore.ipsw
# Record the IPSW SHA-256 printed by the command with the staging artifacts.
tart run --dir="setup:$PWD/.cache/tart-toolchain-v1:ro" portal-base-v2
```

Complete Setup Assistant with a dedicated `portal` account. Enable automatic
login and Remote Login for that account, and keep the desktop unlocked. Account
creation and host-key verification are explicit steps; the recipe stores no
password and does not bypass macOS permission prompts.

In the **guest's** Terminal, run:

```sh
sudo bash '/Volumes/My Shared Files/setup/provision.sh' \
  '/Volumes/My Shared Files/setup' portal
```

The provisioner refuses a physical Mac or an OS that differs from the recipe.
It accepts Xcode's license, completes first launch, disables sleep and the test
account's screen lock/screensaver, installs shell compiler settings, and grants
only passwordless `shutdown -h now`. It preserves other shell settings. It can
be rerun on a prepared guest, but is intended for dedicated disposable test VMs.
An incompatible or partially installed app pair fails rather than being removed.

The app archives are extracted into an empty directory and signatures checked
before installation. Copying over an existing Xcode can leave stale files that
invalidate its signature. Compiler settings include `SDKROOT`, because the
pinned GCC otherwise searches for a Command Line Tools SDK the guest may lack.

Install only the host's public SSH key in the guest, verify the guest host key,
and configure the SSH alias as described in
[Testing Portal](testing.md#managing-the-tart-guest). Never copy a private key.

## Resolve the first print permission prompt

With the viewer open, run `sh test/input-gui.sh` through the VM runner once.
The print-panel case can display **“Allow ‘Emacs’ to find devices on local
networks?”** while macOS looks for printers. Choose **Don’t Allow** in this
dedicated test VM; printer discovery is not needed by these tests. This is an
explicit macOS privacy decision, not a setting the provisioning script edits
behind the system's back. Let that warm-up run finish, preserving any failures,
then perform acceptance with no viewer as below.

This prompt caused the original first-run failures: a focus trace recorded
`UserNotificationCenter` taking focus during the print test, and the viewer
confirmed the local-network dialog. It also reproduced with the viewer open.
The print test could pass while later input tests failed because Emacs was
inactive. A retry alone does not prove the permission prompt has been resolved.
The original `bootstrap-2026-11-11` archive predates this step; resolve it after
restoring that archive before accepting a new baseline.

## Accept and preserve a baseline

Shut down the guest cleanly and restart without the viewer, using the same
read-only staging directory if you want to repeat `verify.sh`. Run the verifier
as the desktop user, then run all GUI suites through the existing runner:

```sh
# In the guest, or through SSH:
bash '/Volumes/My Shared Files/setup/verify.sh' '/Volumes/My Shared Files/setup'
# On the host, from Portal, with portal.testVm pointing at this guest:
PORTAL_TEST_EXPENSIVE=1 sh test/gui-all.sh
```

Preserve failed runs and investigate interruptions before accepting the image.
A single-display VM skips the multi-monitor launcher case. Once permissions
are resolved, repeat the GUI acceptance after a clean shutdown and boot to
check that the prepared state survives a restart.

After acceptance, shut down before cloning or exporting. Give each accepted
image a new version, and record its SHA-256, recipe commit, IPSW checksum and
validation result alongside the archive. `bootstrap-image.json` records the
initial manually prepared image; it was created before these scripts existed.
An exported image preserves the actual installed environment; the Git recipe
preserves how to rebuild it.

[Tart also supports OCI registries](https://github.com/openai/tart/blob/main/docs/quick-start.md#working-with-a-remote-oci-container-registry).
For shared image distribution, use a private registry and unique version tags
(or a recorded digest); keep its credentials outside Git. Do not publish the
local test-account image to a public registry. Local `.tvm` archives with
checksums are sufficient for this workstation's backup workflow.
