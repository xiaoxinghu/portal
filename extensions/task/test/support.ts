// SPDX-License-Identifier: GPL-3.0-or-later
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { recordHook } from "../claude-helper.ts";
import {
	createTask,
	git,
	initialize,
	load,
	runtimePath,
	type State,
	submit,
} from "../store.ts";
import { WAKE } from "../transport.ts";

export function fixture() {
	const root = mkdtempSync(path.join(os.tmpdir(), "pi-task-test-"));
	const repo = path.join(root, "repo");
	mkdirSync(repo);
	git(repo, "init", "-b", "main");
	git(repo, "config", "user.name", "Task Tests");
	git(repo, "config", "user.email", "task@example.test");
	writeFileSync(path.join(repo, "source.txt"), "base\n");
	git(repo, "add", ".");
	git(repo, "commit", "-m", "base");
	const dir = createTask(repo, "Fix source.txt and verify it.\n", {
		provider: "test",
		model: "reviewer",
	});
	return { root, repo, dir };
}
export function hook(
	dir: string,
	name: string,
	extra: Record<string, unknown> = {},
) {
	recordHook(dir, {
		session_id: load(dir).implementor.session,
		hook_event_name: name,
		...extra,
	});
}
export function implementation(dir: string, content = "fixed\n"): State {
	initialize(dir);
	hook(dir, "UserPromptSubmit", { prompt: WAKE });
	let s = load(dir);
	writeFileSync(path.join(s.worktree, "source.txt"), content);
	git(s.worktree, "add", ".");
	git(s.worktree, "commit", "-m", content.trim());
	mkdirSync(runtimePath(dir, ""), { recursive: true });
	writeFileSync(runtimePath(dir, "checks.md"), "Checked source.txt; passed.\n");
	s = submit(
		dir,
		s.version,
		git(s.worktree, "rev-parse", "HEAD"),
		"Checked source.txt; passed.",
	);
	hook(dir, "Stop");
	return s;
}
export async function until(
	predicate: () => boolean,
	description = "condition",
) {
	const deadline = Date.now() + 10_000;
	while (!predicate()) {
		if (Date.now() > deadline)
			throw new Error(`Timed out waiting for ${description}`);
		await new Promise((resolve) => setTimeout(resolve, 15));
	}
}
