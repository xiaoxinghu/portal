# CI services for Portal's macOS GUI tests

Research date: 2026-10-06. This is a provider assessment, not a record of successful
Portal runs on these services. Prices below are USD before tax and were checked
against the linked vendor pages on this date.

## Recommendation

For the current personal, private repository, first try a pinned **standard
GitHub-hosted Apple Silicon macOS runner**, because it requires the least setup;
accept it only after the graphical and Metal pilot below passes. For dependable
control of the desktop, keep **a dedicated MacStadium M4 Mac with a self-hosted
GitHub Actions runner** as the fallback. **Buildkite hosted macOS** is the strongest
managed candidate for interactive diagnosis because it explicitly provides access
to a running job's desktop; **CircleCI** explicitly documents native macOS UI tests.
Neither provider's reviewed documentation establishes Portal's Metal compatibility.
Blacksmith offers real macOS, but its organization-only integration excludes this
repository as currently owned, and GUI/Metal behavior remains unverified.
The table separates those promises from the things we still need to measure.

## What must actually work

Portal needs a graphical Emacs with native windows, AppKit/WebKit, and a functioning
Metal device for Ghostty terminal surfaces; passing batch ERT or compiling on macOS
is insufficient. The launcher additionally requires the exact GNU Emacs NS build
specified in the [README](../README.md#scope), plus its matching module header.
The [testing guide](testing.md) requires disposable graphical processes and
end-to-end event-loop checks. The [daily-use launcher script](../test/launcher-daily-use.sh)
starts a graphical Emacs, schedules ERT after startup, and fails on skipped tests.
Its test injector does not require Accessibility permission.

A macOS VM can meet these requirements: Apple's Virtualization framework supports
accelerated graphics and Metal inside macOS guests. Therefore “virtualized” alone
is no reason to reject a service; an active desktop session and working rendering
on that service's particular image are the acceptance gates.
[Apple's Virtualization presentation](https://developer.apple.com/videos/play/wwdc2022/10002/)

## Provider comparison

| Service | Evidence relevant to real GUI tests | Fit, limits, and cost |
| --- | --- | --- |
| Blacksmith | Real macOS on M4; reviewed documentation does not establish an active GUI session or Metal availability. | Organization-only integration blocks this personal repository. Published starting price $0.08/min. Details below. |
| GitHub-hosted standard macOS | Real macOS VMs; current standard Apple Silicon image is M1. The reviewed runner reference does not promise Portal-compatible GPU or desktop behavior. | Cheapest setup for the existing repository; pilot required. $0.062/min after included minutes. [Runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing). |
| GitHub-hosted macOS XLarge | **Explicitly lists 8 GPU cores of hardware acceleration** alongside 5 M2 CPU cores. | Strong managed GPU candidate, but **organizations on Team/Enterprise only**, so unavailable to the current personal repository. $0.102/min; included minutes do not apply. GUI/Emacs trial still required. [Specifications](https://docs.github.com/en/actions/reference/runners/larger-runners), [eligibility](https://docs.github.com/en/actions/concepts/runners/larger-runners), [pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing). |
| Buildkite hosted macOS | Documents **browser-based desktop access to running macOS jobs**, including graphical applications and UI-test debugging. Apple Silicon M4 VMs. | Best documented managed desktop visibility; Metal remains a pilot gate. Pro/Enterprise plan required, plus $0.12/min for 6 vCPU/28 GB or $0.24/min for 12 vCPU/56 GB. Standard maximum job duration 4 hours; no custom macOS base image upload. [Desktop access](https://buildkite.com/docs/agent/buildkite-hosted/desktop-access), [limits](https://buildkite.com/docs/agent/buildkite-hosted/macos), [pricing](https://buildkite.com/platform/pipelines/hosting-options/mac-hosted-agents/). |
| CircleCI macOS executor | Explicit documentation for **native macOS app UI testing**, including permission setup through its macOS orb. | Credible managed GUI pilot. Documentation is focused on Xcode UI tests, not arbitrary Emacs/Metal suites; verify our workload. UI-test permission setup is image-sensitive. [Native macOS UI tests](https://circleci.com/docs/guides/test/testing-macos/). |
| Cirrus CI / Cirrus Runners / Tart | Cirrus CI documents macOS VMs on Apple Silicon using Tart. Tart's maintainer confirms paravirtualized Metal support. | Promising VM technology; hosted service's unattended desktop still needs verification. Cirrus Runners integrates with GitHub Actions at $150/month per concurrency slot, but its documented setup requires a GitHub organization. Cirrus CI is a separate service/configuration. [CI macOS guide](https://cirrus-ci.org/guide/macOS/), [Tart Metal support](https://github.com/openai/tart/discussions/344), [Runners setup](https://cirrus-runners.app/setup/), [Runners pricing](https://cirrus-runners.app/). |
| MacStadium dedicated Mac + self-hosted CI | Dedicated genuine Apple hardware, root access, and remote desktop options. Provides control over the actual Mac's desktop and GPU. | Strongest control for exact Emacs, permissions and display setup; we maintain the runner/session. Published M2 8 GB $109/month, M4 16 GB $149/month; no trial for individual Macs. [Hardware/pricing](https://macstadium.com/pricing), [remote workspaces](https://macstadium.com/solutions/workspace). |
| AWS EC2 Mac + self-hosted CI | Bare-metal Macs with GPU specifications; official procedure for GUI access using VNC, ARD or Screen Sharing. | Technically credible, more infrastructure to manage. Dedicated Host has **24-hour minimum allocation**, one Mac instance per host; poorly matched to occasional short GUI jobs. [EC2 Mac constraints](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-mac-instances.html), [GUI access](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-to-mac-instance.html). |

## Blacksmith

Blacksmith **does now offer macOS**, launched in April 2026. Its engineering account
describes M4 Mac hosts running macOS guests through Apple's Virtualization.framework;
these are real macOS VMs, not Linux containers.
[Mac runner launch](https://www.blacksmith.sh/blog/how-we-shipped-mac-runners-in-3-weeks)

The current catalog includes `blacksmith-6vcpu-macos-26` (24 GB RAM, 150 GB disk)
and a 12-vCPU option (48 GB, 250 GB), plus macOS 15 images. The pricing page lists
macOS starting at **$0.08/minute**. The 3,000 free minutes are normalized x64
2-vCPU minutes: one 6-vCPU macOS minute consumes 20, so the allowance buys
**150 macOS minutes** if used entirely on that size.
[Instance types and allowance](https://docs.blacksmith.sh/blacksmith-runners/overview),
[pricing](https://www.blacksmith.sh/pricing)

There are two adoption gates. First, the current quickstart explicitly excludes
personal repositories; Portal would need an organization arrangement.
[Eligibility](https://docs.blacksmith.sh/introduction/quickstart)
Second, the reviewed runner and launch documentation does not confirm a logged-in
WindowServer session, GUI-process launch behavior, Metal device access, or unattended
Emacs GUI testing. This is **unverified support, not evidence of incompatibility**.

Before a Blacksmith trial, obtain confirmation of those capabilities for the exact
runner label and whether they persist without a remote desktop connection. Then
run the acceptance pilot below. M4 hardware and compatibility with GitHub's image
contents alone do not establish GUI suitability. For this repository today,
Blacksmith is a conditional candidate rather than the first choice.

## Important distinctions

**Do not reject GitHub using old “Metal is unavailable” reports.** Its current
XLarge specification explicitly includes GPU acceleration, and a runner-images
maintainer's August 2026 investigation reports MPS workloads working on
`macos-15`, with a different result on `macos-26` traced to Apple's OS framework.
That is useful evidence that standard runners merit a probe, not proof that
Ghostty rendering and Emacs focus behavior work. Pin the image label, record the
actual image version, and fail the graphics preflight rather than skipping it.
[GitHub investigation](https://github.com/actions/runner-images/issues/14380)

**A desktop viewer and an unattended GUI job are related but distinct.** Buildkite
has unusually direct documentation of a real job desktop. CircleCI's documentation
establishes native UI-test support and its permission workaround. Neither alone
proves that our shell-launched Emacs has the expected foreground, event loop,
WebKit rendering and Ghostty surface. On a dedicated Mac, run the agent in the
logged-in GUI user's session and verify it after reboot and remote disconnection;
Buildkite's self-hosted guide explicitly supplies a LaunchAgent configuration for
GUI access. The same session requirement matters when using GitHub's runner.
[Buildkite's macOS agent setup](https://buildkite.com/docs/agent/self-hosted/install/macos)

**Repository ownership affects the shortlist.** A read-only GitHub API check on
2026-10-06 identified `xiaoxinghu/portal` as private with owner type `User`.
Blacksmith, GitHub larger runners and Cirrus Runners' documented organization setup therefore
require an ownership/plan decision before adoption. Do not transfer the repository
merely to conduct a graphics trial on standard GitHub-hosted macOS or a dedicated
self-hosted Mac.

## Acceptance pilot before adopting a provider

1. Install the pinned graphical NS Emacs and matching header, plus the toolchain
   in [Contributing](../CONTRIBUTING.md#build-and-editor-setup). Cache that exact
   Emacs build or bake it into a controlled image where supported; do not accept
   an arbitrary Homebrew Emacs for the launcher tests. Verify native trampoline
   compilation and its compiler-library dependencies with trampolines enabled.
2. Record macOS, Xcode/Swift, Emacs revision, runner image version, display geometry
   and `system_profiler SPDisplaysDataType`. Check `MTLCreateSystemDefaultDevice()`
   and then render an actual Ghostty terminal; a non-nil Metal device alone is
   insufficient. Confirm an active GUI session with a real graphical Emacs frame.
3. Build and run the required headless checks, then execute
   `test/launcher-daily-use.sh` in a fresh graphical Emacs with a timeout. Require
   both expected tests to pass and zero skips. Keep the project's injector setup.
4. Run the relevant standalone AppKit checks and the combined graphical suite
   described in [Testing Portal](testing.md). Exercise focus transfers, terminal
   input/rendering and WebKit rendering together. Serialize GUI suites per desktop
   so they cannot steal focus from one another.
5. Repeat across fresh runner instances; for a persistent Mac, repeat after reboot
   and with the remote viewer disconnected. Save Emacs logs, crash reports,
   environment metadata and screenshots when permitted. A clean exit or successful
   compile is not sufficient evidence of native rendering.

This pilot validates automated native event delivery. Physical-key delivery,
Accessibility, Spaces and fullscreen behavior still require the separate manual
evidence called for by the repository's testing guide. Credential-dependent live
agent checks remain opt-in and should not be conflated with GUI infrastructure.
