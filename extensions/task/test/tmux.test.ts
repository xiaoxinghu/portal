// SPDX-License-Identifier: GPL-3.0-or-later
import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { TaskController } from "../controller.ts";
import { command, load, runtimePath } from "../store.ts";
import { shellQuote, tmuxImplementor, WAKE } from "../transport.ts";
import { fixture, until } from "./support.ts";

test("real tmux + Node helper: two interactive turns, one Claude UUID, files carry feedback", async () => {
	const f = fixture();
	const savedPath = process.env.PATH;
	const savedHelper = process.env.PI_TASK_TEST_HELPER;
	const tmux = command("/bin/sh", ["-c", "command -v tmux"]);
	const server = `pi-task-test-${process.pid}-${Date.now()}`;
	const bin = path.join(f.root, "bin");
	fs.mkdirSync(bin);
	const fake = fileURLToPath(new URL("./fake-claude.mjs", import.meta.url));
	fs.writeFileSync(
		path.join(bin, "tmux"),
		`#!/bin/sh\nexec ${shellQuote(tmux)} -L ${shellQuote(server)} -f /dev/null "$@"\n`,
		{ mode: 0o700 },
	);
	fs.writeFileSync(
		path.join(bin, "claude"),
		`#!/bin/sh\nexec node ${shellQuote(fake)} "$@"\n`,
		{ mode: 0o700 },
	);
	process.env.PATH = `${bin}:${savedPath}`;
	process.env.PI_TASK_TEST_HELPER = fileURLToPath(
		new URL("../claude-helper.ts", import.meta.url),
	);
	const errors: Error[] = [];
	let reviews = 0;
	const controller = new TaskController(
		f.dir,
		tmuxImplementor,
		async ({ state }) => {
			reviews++;
			return {
				round: state.review_round,
				reviewed_commit: state.submitted_commit ?? "",
				outcome: reviews === 1 ? "changes_required" : "approved",
				content: "BULK_FEEDBACK_ONLY_ON_DISK: review the fixture again.",
			};
		},
		{ state: () => {}, error: (e) => errors.push(e) },
	);
	try {
		controller.start();
		await until(
			() => load(f.dir).phase === "approved" || errors.length > 0,
			"real terminal review loop",
		);
		expect(errors).toEqual([]);
		expect(reviews).toBe(2);
		const s = load(f.dir);
		expect(s.phase).toBe("approved");
		expect(tmuxImplementor.alive(s)).toBe(true);
		const trace = fs.readFileSync(
			runtimePath(f.dir, "mock-trace.jsonl"),
			"utf8",
		);
		expect(trace).not.toContain("BULK_FEEDBACK_ONLY_ON_DISK");
		const records = trace
			.trim()
			.split("\n")
			.map((line) => JSON.parse(line));
		expect(records.filter((r) => r.prompt).map((r) => r.prompt)).toEqual([
			WAKE,
			WAKE,
		]);
		expect(records[0].args).toContain(s.implementor.session);
		expect(records[0].args).not.toContain("--dangerously-skip-permissions");
		expect(records[0].args).not.toContain("-p");
		expect(records[0].args).not.toContain("Fix source.txt and verify it.");
	} finally {
		await controller.close();
		spawnSync(tmux, ["-L", server, "kill-server"]);
		if (savedPath === undefined) delete process.env.PATH;
		else process.env.PATH = savedPath;
		if (savedHelper === undefined) delete process.env.PI_TASK_TEST_HELPER;
		else process.env.PI_TASK_TEST_HELPER = savedHelper;
		fs.rmSync(f.root, { recursive: true, force: true });
	}
}, 20_000);
