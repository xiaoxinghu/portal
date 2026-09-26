# 08: Spike: what coding agents signal inside a Portal terminal

Type: AFK (escalate on failure) · Status: todo

## What to build

This is a throwaway check that records which signals Claude Code and Codex actually send inside a Portal terminal view. The results settle the open questions in [the agent state design](../agent-state-design.md#open-questions-for-task-08). They fix the mapping from signals to transitions that task 09 builds, and they decide whether task 12 is needed. None of this code gets merged. Record the findings in this file.

**Instrument**
- Make `HostedTerminal` (`native/Terminal.swift:7`) adopt these delegates:
  - `TerminalSurfaceBellDelegate`
  - `TerminalSurfaceProgressReportDelegate`
  - `TerminalSurfaceCommandFinishedDelegate`
  - `TerminalSurfaceDesktopNotificationDelegate`
  - `TerminalSurfaceFocusDelegate`
- Log every callback with a monotonic timestamp and the terminal ID to a file, along with every title change. The protocols are in `build/swift/checkouts/libghostty-spm/Sources/GhosttyTerminal/Surface/TerminalSurfaceViewDelegate.swift`.
- Add a Claude Code hook that runs on every event in the [hooks reference](https://code.claude.com/docs/en/hooks) with `"async": true`. It appends a timestamp and the stdin JSON to a second log. Install it through `claude --settings <file>` so your own settings don't change.
- Run `env` in a Portal terminal and record `TERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` and `INSIDE_EMACS`.

**Scenarios.** Run each one with Claude Code, using default settings apart from the logging hook. Then run it with Codex, with `tui.notifications` on.

1. A prompt that edits a file and finishes.
2. A permission prompt that you approve, where the approved command is `sleep 20`, followed by the end of the turn.
3. A permission prompt that you deny.
4. A question from the agent (`AskUserQuestion` in Claude Code).
5. An interrupt with Esc in the middle of a turn.
6. A turn that spawns a subagent.
7. Quitting the agent back to the shell.

**Focus cases.** Repeat scenario 1 in each of these states when the turn ends:
- the terminal focused;
- Emacs focused on another window in the same frame;
- the terminal buffer hidden with `quit-window`;
- another application focused.

## Acceptance criteria

- [ ] Findings are recorded under a `## Findings` heading in this file, with the versions of Emacs, macOS, libghostty-spm, Claude Code and Codex
- [ ] A table for each agent shows, for each scenario, the in-band signals and hook events in order, with their relative times
- [ ] Each open question in the design is answered, with how it was checked
- [ ] The *Signals to transitions* section of task 09 is updated to match what was observed
- [ ] A decision is recorded on whether in-band signals are enough. They are enough if, for Claude Code with no configuration, *turn started*, *blocked*, *turn ended* and *agent gone* can each be told apart within one second in every scenario and every focus case. If they are enough, mark task 12 `Status: dropped` and give the reason. If they are not, list the gaps task 12 must close.
- [ ] If neither in-band signals nor hooks can tell *blocked* apart, stop and ask the user before starting task 09
- [ ] No spike code is merged

## Blocked by

None; can start immediately. It uses today's terminal code.
