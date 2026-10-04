// SPDX-License-Identifier: GPL-3.0-or-later
// Executed by Node >=22.19 in Claude's Bash tool and lifecycle hooks.

import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
	acquireLock,
	askHuman,
	atomicWrite,
	event,
	json,
	load,
	readClaudeStatus,
	runtimePath,
	submit,
} from "./store.ts";

export function recordHook(
	dir: string,
	input: Record<string, unknown>,
	run?: string,
) {
	const release = acquireLock(path.join(dir, ".mutation.lock"), 3);
	try {
		recordHookLocked(dir, input, run);
	} finally {
		release();
	}
}
function recordHookLocked(
	dir: string,
	input: Record<string, unknown>,
	run?: string,
) {
	const state = load(dir);
	if (input.session_id !== state.implementor.session)
		throw new Error("Hook belongs to another Claude session");
	// Claude's nested subagents must not drive the root session's lifecycle.
	if (input.agent_id) return;
	const old = readClaudeStatus(dir);
	// A delayed hook from an earlier launch of the same Claude UUID is not current evidence.
	if (run !== undefined && old?.run !== run) return;
	const name = input.hook_event_name;
	let status = old?.status ?? "starting";
	let turn = old?.turn ?? null;
	let prompt = old?.prompt ?? null;
	if (name === "SessionStart") status = "starting";
	else if (name === "UserPromptSubmit") {
		status = "working";
		turn = randomUUID();
		prompt =
			typeof input.prompt === "string" && input.prompt.trim()
				? input.prompt
				: null;
	} else if (name === "PreToolUse")
		status = input.tool_name === "AskUserQuestion" ? "waiting" : "working";
	else if (name === "PostToolUse") status = "working";
	else if (name === "PermissionRequest" || name === "Notification")
		status = "waiting";
	else if (name === "Stop") status = "idle";
	else if (name === "StopFailure") status = "failed";
	else if (name === "SessionEnd") status = "exited";
	else return;
	event(dir, "claude_event", { hook: name, status, turn, run: old?.run });
	atomicWrite(
		runtimePath(dir, "claude.json"),
		json({
			session: state.implementor.session,
			status,
			turn,
			prompt,
			run: old?.run,
		}),
	);
}
export function main(args: string[]) {
	const [operation, dir, version, value, evidence] = args;
	if (!dir)
		throw new Error(
			"Usage: claude-helper.ts read|submit|need-decision|hook TASK_DIRECTORY ...",
		);
	if (operation === "read") return json(load(dir));
	if (operation === "hook") {
		if (!process.env.PI_TASK_RUN)
			throw new Error("Missing Claude launch identity");
		recordHook(
			dir,
			JSON.parse(readFileSync(0, "utf8")),
			process.env.PI_TASK_RUN,
		);
		return "";
	}
	if (
		process.env.PI_TASK_RUN &&
		readClaudeStatus(dir)?.run !== process.env.PI_TASK_RUN
	)
		throw new Error("This Claude launch is no longer current");
	if (!version || !/^\d+$/.test(version))
		throw new Error("Supply the state version returned by read");
	if (operation === "submit" && value && evidence)
		return json(
			submit(dir, Number(version), value, readFileSync(evidence, "utf8")),
		);
	if (operation === "need-decision" && value)
		return json(askHuman(dir, Number(version), readFileSync(value, "utf8")));
	throw new Error(
		"Usage: submit DIR VERSION FULL_COMMIT CHECKS_FILE | need-decision DIR VERSION QUESTION_FILE",
	);
}
if (
	process.argv[1] &&
	import.meta.url === pathToFileURL(process.argv[1]).href
) {
	try {
		process.stdout.write(main(process.argv.slice(2)));
	} catch (error) {
		console.error(String(error));
		process.exitCode = 1;
	}
}
