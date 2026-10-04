// SPDX-License-Identifier: GPL-3.0-or-later
// A PTY-attached launcher, not print mode. Leaves normal Claude permissions intact.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import path from "node:path";
import {
	acquireLock,
	atomicWrite,
	event,
	json,
	load,
	readClaudeStatus,
	runtimePath,
} from "./store.ts";
import { WAKE } from "./transport.ts";

const dir = process.argv[2];
const resume = process.argv[3] === "resume";
if (!dir) throw new Error("Task directory required");
const state = load(dir);
const releaseProcess = acquireLock(runtimePath(dir, ".claude.lock"));
const run = randomUUID();
const releaseStatus = acquireLock(path.join(dir, ".mutation.lock"), 3);
try {
	atomicWrite(
		runtimePath(dir, "claude.json"),
		json({
			session: state.implementor.session,
			run,
			status: "starting",
			turn: null,
			prompt: null,
		}),
	);
} finally {
	releaseStatus();
}
const child = spawn(
	"claude",
	[
		resume ? "--resume" : "--session-id",
		state.implementor.session,
		"--settings",
		runtimePath(dir, "settings.json"),
		"--append-system-prompt-file",
		runtimePath(dir, "implementor.md"),
		"--add-dir",
		dir,
		"--",
		WAKE,
	],
	{
		cwd: state.worktree,
		stdio: "inherit",
		env: { ...process.env, PI_TASK_DIRECTORY: dir, PI_TASK_RUN: run },
	},
);
child.on("error", (error) => {
	console.error(error);
});
child.on("close", (code, signal) => {
	try {
		const release = acquireLock(path.join(dir, ".mutation.lock"), 3);
		try {
			const old = readClaudeStatus(dir);
			if (old?.run !== run) return;
			event(dir, "claude_exited", { code, signal, run });
			atomicWrite(
				runtimePath(dir, "claude.json"),
				json({
					session: state.implementor.session,
					run,
					status: "exited",
					turn: old?.turn ?? null,
					prompt: old?.prompt ?? null,
				}),
			);
		} finally {
			release();
		}
	} catch (error) {
		console.error(error);
	} finally {
		releaseProcess();
	}
	process.exitCode = code ?? 1;
});
