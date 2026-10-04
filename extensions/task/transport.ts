// SPDX-License-Identifier: GPL-3.0-or-later
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
	atomicWrite,
	command,
	json,
	runtimePath,
	type State,
} from "./store.ts";

export const WAKE = "Check task state and feedback.";
export const shellQuote = (value: string) =>
	`'${value.replaceAll("'", "'\\''")}'`;
const helper = fileURLToPath(new URL("./claude-helper.ts", import.meta.url));
const runner = fileURLToPath(new URL("./claude-runner.ts", import.meta.url));
export interface Implementor {
	alive(state: State): boolean;
	start(dir: string, state: State, resume: boolean): void;
	wake(state: State): void;
}
export function prepareClaude(dir: string, s: State) {
	const call = `node ${shellQuote(helper)}`;
	const task = shellQuote(dir);
	const hook = {
		type: "command",
		command: `${call} hook ${task}`,
		timeout: 10,
	};
	atomicWrite(
		runtimePath(dir, "settings.json"),
		json({
			hooks: {
				SessionStart: [{ hooks: [hook] }],
				UserPromptSubmit: [{ hooks: [hook] }],
				PreToolUse: [{ hooks: [hook] }],
				PostToolUse: [{ hooks: [hook] }],
				PermissionRequest: [{ hooks: [hook] }],
				Notification: [
					{ matcher: "permission_prompt|elicitation_dialog", hooks: [hook] },
				],
				Stop: [{ hooks: [hook] }],
				StopFailure: [{ hooks: [hook] }],
				SessionEnd: [{ hooks: [hook] }],
			},
		}),
	);
	atomicWrite(
		runtimePath(dir, "implementor.md"),
		`# Task implementor\n\nTask directory: ${dir}\nWorktree: ${s.worktree}\n\nRead task.md and state.json in the task directory whenever prompted to check the task.\nRead the feedback file referenced by state.feedback and state.decision when present.\nEarlier human decisions are the human_decision records in events.jsonl; preserve them too.\nAll substantive instructions and reviews live on disk. This conversation persists across rounds.\nFollow repository instructions, including AGENTS.md and CLAUDE.md. Work only on the allocated\nbranch in this worktree. Do not create another worktree or rebase the pinned base.\n\nRun the required checks and commit a completed implementation. Write a checks report to\n${runtimePath(dir, "checks.md")} naming commands and actual results (or explain why checks\ncould not run). Read current state with:\n\n    ${call} read ${task}\n\nSubmit using that state's version and the full HEAD SHA:\n\n    ${call} submit ${task} VERSION FULL_COMMIT ${shellQuote(runtimePath(dir, "checks.md"))}\n\nAfter successful submission, finish your response and leave the code unchanged until the\nnext task instruction. A separate pi reviewer evaluates this exact commit.\nIf the state is code_review or approved, report it and wait instead of editing.\nIf paused, wait for the human to resume automatic management.\n\nFor a product/design decision only a human can make, write the question and options to\n${runtimePath(dir, "question.md")} and call:\n\n    ${call} need-decision ${task} VERSION ${shellQuote(runtimePath(dir, "question.md"))}\n\nThen finish your response. Permissions remain interactive: do not bypass them.\nNever edit state.json, completed feedback, or the event log directly. If a helper rejects\na stale version, reread state and inspect the reason before retrying.\n`,
	);
}
export function preflight() {
	for (const [exe, args] of [
		["git", ["--version"]],
		["tmux", ["-V"]],
		["node", ["--version"]],
		["claude", ["--version"]],
	] as const)
		command(exe, [...args]);
	command("/bin/sh", ["-c", "command -v lockf"]);
	const [major, minor] = command("node", ["--version"])
		.slice(1)
		.split(".")
		.map(Number);
	if (!major || major < 22 || (major === 22 && Number(minor) < 19))
		throw new Error("Node >=22.19 is required for the Claude helper");
}
export const tmuxImplementor: Implementor = {
	alive(s) {
		const result = spawnSync(
			"tmux",
			["has-session", "-t", `=${s.implementor.tmux}`],
			{ encoding: "utf8" },
		);
		if (result.error) throw result.error;
		if (result.status !== 0) return false;
		const identity = command("tmux", [
			"show-options",
			"-v",
			"-t",
			s.implementor.tmux,
			"@pi-task-session",
		]);
		if (identity !== s.implementor.session)
			throw new Error("tmux session identity differs; inspect before repair");
		return true;
	},
	start(dir, s, resume) {
		// Multiple argv elements are exec'd directly by tmux; task text is never shell code.
		const id = command("tmux", [
			"new-session",
			"-d",
			"-P",
			"-F",
			"#{session_id}",
			"-e",
			`PATH=${process.env.PATH ?? ""}`,
			"-s",
			s.implementor.tmux,
			"-c",
			s.worktree,
			"node",
			runner,
			dir,
			resume ? "resume" : "new",
		]);
		command("tmux", [
			"set-option",
			"-t",
			id,
			"@pi-task-session",
			s.implementor.session,
		]);
	},
	wake(s) {
		const panes = command("tmux", [
			"list-panes",
			"-s",
			"-t",
			s.implementor.tmux,
			"-F",
			"#{pane_id}",
		]).split("\n");
		const pane = panes[0];
		if (panes.length !== 1 || !pane || !/^%\d+$/.test(pane))
			throw new Error(
				"Task terminal layout changed; inspect before sending input",
			);
		if (
			command("tmux", [
				"list-clients",
				"-t",
				s.implementor.tmux,
				"-F",
				"#{client_readonly}",
			])
				.split("\n")
				.includes("0")
		)
			throw new Error(
				"A human is attached to Claude; detach before automatic handoff",
			);
		command("tmux", ["send-keys", "-t", pane, "-l", WAKE]);
		command("tmux", ["send-keys", "-t", pane, "Enter"]);
	},
};
