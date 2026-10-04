# Durable pi task loops

An opt-in pi extension: a persistent **interactive Claude Code** implementor in
plain tmux, followed by a **fresh in-process pi SDK review** on every iteration.
TypeScript owns routing; the main model does not have to remember the next step.
There is no workmux, MCP server, background orchestration daemon, or Portal UI dependency.

## Install

Requires macOS, pi **1.0.2**, Node **22.19+**, Git, tmux and the official Claude Code
CLI (CLI surface checked with **2.1.289**). macOS's bundled `lockf` supplies kernel
file locking. Other operating systems are not supported in this first version.
Claude and pi use their own normal authentication. Hooks supplied through Claude's
`--settings` must be allowed. Permission checks are not disabled.

From this checkout, opt in with an absolute path:

```sh
pi install /absolute/path/to/portal/extensions/task
```

Restart pi or `/reload`. Alternatively, try it for one process:

```sh
pi -e /absolute/path/to/portal/extensions/task/index.ts
```

This uses the SDK and TypeBox supplied by the pi host. The extension does not
install itself, modify personal settings, install global Claude hooks, or need
Bun at runtime. Keep the package directory available: live Claude sessions call
its helper scripts. Upgrade/pause running tasks deliberately before moving it.

## Start and resume

Inside an interactive pi session, choose the desired reviewer model, then:

```text
/task tasks/implement-login-fix.md
/task Fix the login bug. Re-enable submission after a failed request and add a regression test.
/task "tasks/a task with spaces.md"
/task --text Fix tasks/implement-login-fix.md
```

Quotes around instructions are optional; the command receives the whole remainder,
not shell arguments. One enclosing pair of quotes is accepted. File contents are
copied verbatim to `task.md`; the source remains untouched. A recognizable missing
path or a file followed by extra instructions is an error, not a new literal task.
Use `--text` to force literal interpretation (including reserved command words).
Empty tasks are rejected.

The current directory selects the Git repository. A unique `task/<slug>-<id>`
branch is created from the **local `main` commit**, not from the checked-out branch.
No fetch, checkout of the main working copy, dirty-file transfer, secret copying,
automatic rebase, merge or cleanup happens. The main checkout may have unrelated
uncommitted work. Configure ignored development files in the new worktree yourself
when necessary. Repositories without `main` fail before creating a task.

The command prints the task directory, worktree and attach command. Tasks live in:

```text
<git-common-directory>/pi-tasks/<id>/
  task.md
  state.json
  events.jsonl
  review/feedback/001.md
  review/feedback/002.md
  .runtime/                 # Generated prompts/settings, lifecycle status,
                            # checks evidence, diff, detached review checkouts
```

The worktree is a sibling under `<repository>.worktrees/<id>`. Only `task.md` and
`state.json` are needed to describe a newly allocated task; runtime material is
generated as execution starts. Pi reviewer transcripts use pi's regular session
storage, and the active transcript reference is recorded in state/events.

The task schema contains full paths. Keep the repository/task/worktree locations
stable; moving them requires explicit repair. This first version manages one
selected task per pi session. Different pi sessions can manage different tasks.

```text
/task /absolute/path/to/existing-task-directory
/task status
/task pause
/task resume
/task decide Preserve backward compatibility.
/task retry
```

- A directory invocation selects the task, validates it and starts reconciliation.
  A persisted pause stays paused until `/task resume`.
- `status` prints state and the Claude attach command.
- `pause` stops automatic handoffs and aborts a live SDK review. **It does not stop
  Claude**; attach if you want to interrupt it. Its state remains resumable.
- `resume` clears the pause and reconciles disk state. An interrupted review starts
  a fresh SDK session against the same submitted commit.
- `decide` records a human answer in state and the event log, then returns through
  the implementor; it never directly approves code.
- `retry` explicitly retries an ambiguous implementor wake-up. Inspect Claude
  first. This is not a generic repair command and cannot approve a review.

Pi must stay running for orchestration/review. Claude survives pi shutdown while
its tmux server remains alive. After restarting pi, invoke `/task DIRECTORY`.
After a reboot, the recorded Claude UUID is resumed in the existing worktree;
missing Claude transcripts are an operational failure, never silently replaced
with a new conversation.

## Observe and interact

```sh
# Use the session name printed by /task.
tmux attach-session -t pi-task-<id>
# Read-only observation does not block automatic handoffs:
tmux attach-session -r -t pi-task-<id>
# Or inspect without attaching:
tmux capture-pane -p -t pi-task-<id> -S -100
```

Detach with `Ctrl+b d`. For active co-driving, `/task pause` first. Automatic input
is refused while a writable tmux client is attached or the task's single-pane
layout changed. Detach, inspect state, then resume/retry explicitly. Do not rename
the managed tmux session or move Claude into its separate native `/bg` runtime.

Pi shows reviewer activity in its status area and emits visible completion/error
messages. The main model is not automatically prompted by these notifications.
The reviewer has an independent context and persisted transcript, not another TUI
or OS process. Do not open that transcript in another writable session while the
reviewer is running.

## Submission and feedback contract

Claude reads `task.md`, `state.json`, referenced feedback, and human decisions.
The only injected follow-up is **`Check task state and feedback.`** Instructions,
feedback and check results are never pasted through tmux or piped into pi.

A task-specific instruction file teaches Claude the Node helper commands:

```text
node /package/claude-helper.ts read TASK_DIRECTORY
node /package/claude-helper.ts submit TASK_DIRECTORY VERSION FULL_COMMIT CHECKS_FILE
node /package/claude-helper.ts need-decision TASK_DIRECTORY VERSION QUESTION_FILE
```

The helper validates version, phase, branch, clean checkout (including untracked
files), full commit SHA and active Claude turn. It snapshots the checks report,
records its hash and marks `code_review`. Claude then finishes its response.
A `Stop` hook alone never submits work. Hooks are scoped to this launch and ignore
Claude's nested subagents. Questions and permission prompts remain visible in the
real Claude terminal; ordinary idle is not proof of task completion.

Each reviewer inspects a detached checkout of the submitted commit and a full diff
against the fixed base commit. It has only read/search tools and `submit_review`:
no shell, write/edit tools, ambient extensions, MCP, user skills, parent transcript,
or implementor transcript. Repository instructions are read as review material.
The reviewer inspects the implementor's check report but **does not independently
run tests**. Approval is a model review of the pinned revision, not an independently
verified CI result. Put required checks and acceptance criteria in the task.
Tool restrictions are not an operating-system sandbox.

`submit_review` receives structured arguments (`round`, `reviewed_commit`,
`outcome`, Markdown `content`). Code validates them, waits for successful SDK run
completion, generates the frontmatter and atomically publishes Markdown:

```markdown
---
round: 1
base_commit: abc123...
reviewed_commit: def456...
outcome: changes_required
---

## R1 · P1 · Failed requests leave submission disabled

Location, evidence, required change and verification guidance...
```

The three outcomes are `approved`, `changes_required`, `needs_human_decision`.
State stores the exact feedback path and content hash. Normal reconciliation does
not parse YAML or guess the current feedback by scanning filenames. Editing a
published review does not change its verdict; it invalidates the artifact hash.
A provider error, abort, invalid/conflicting submission, changed checkout or absent
result cannot approve even if the model earlier submitted an approval candidate.

Rejections automatically go back to the same Claude session. Every review uses a
new pi session. There is no iteration cap in v1: pause a non-converging or expensive
loop yourself. Human-required verdicts stop the loop. Approval ends local routing;
there is no automatic merge or cleanup. The implementor follows the repository's
normal commit/push/PR instructions before handing its revision to review.

## Persistence and recovery

`state.json` is authoritative; helpers serialize updates under a kernel lock and
reject stale versions. State and feedback use temporary files, file fsync, atomic
rename and directory fsync. Final feedback is published before its state reference.
The coordinator's separate kernel lock prevents two pi sessions managing the task.
Lock inodes stay on disk; their presence is **not** ownership. Kernel ownership is
released on process loss, and startup never steals a lock based on elapsed time.
Use a local filesystem, not a network-shared task directory.

`events.jsonl` records intentions and completed transitions, Claude lifecycle,
checks, reviewer session references, failures and decisions. A truncated trailing
record is separated from future records and remains diagnostic, not authoritative.
The log is not a multi-file transaction or a substitute for valid artifacts.

Filesystem notifications prompt reconciliation; they do not prove completion.
Startup and explicit resume always reread disk. There is no background polling or
time-based task advancement. A lost watcher notification may need `/task resume`.
The native lock holder uses a bounded local startup/release handshake; its timeout
fails the operation, never advances a task phase.

Known interrupted states resume deterministically. Missing/modified feedback,
unpublished feedback after a file-before-state crash, changed task text, wrong
branches/commits, lost check evidence and contradictory lifecycle state fail closed.
The extension reports the task directory and stops automatic management. It never
stashes/discards work or guesses an approval. A failed wake-up is not silently
repeated: inspect the actual Claude session, then use `/task retry` if appropriate.

Ask the main model to inspect the task, Git and event log when repair is needed.
Its `repair_task` tool requires your explicit confirmation, a matching state version
and a reason. It can start a new review round of a verified submission, or retry
implementation while discarding a missing/modified feedback reference. Old files
remain as evidence, the repair is logged, and management stays paused until you
resume. It cannot approve code, bypass a pending human decision, repair malformed
JSON or rewrite task scope. Those deeper corruptions require manual restoration
from verified evidence. Intentions in a log are not proof that their effects happened.

## Development and verification

```sh
cd extensions/task
bun install --frozen-lockfile --ignore-scripts
bun run check
# From repository root, run the repository-wide formatter/linter:
bun run --cwd host check
```

Tests exercise temporary real Git repositories, state/feedback validation,
revision conflicts, human decisions, interrupted review recovery, kernel-lock
release after SIGKILL, isolated SDK construction, and a full two-round loop using
**real tmux and Node helpers with a fake interactive Claude CLI**. Fake reviewer
sessions cover candidate-then-error/abort behavior. No model requests are made by
these checks. Run the native/host project checks separately as documented in the
repository README.

An authenticated end-to-end run with the real Claude and reviewer model has **not**
been performed as part of these automated checks. For that opt-in smoke test, use a
disposable trusted repository with `main`, a small task and explicit checks; verify
initial trust/permission prompts, read-only attach, a requested correction, exact
commit approval, and a pi restart during review. Keep normal permission controls.
