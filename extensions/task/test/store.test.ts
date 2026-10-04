// SPDX-License-Identifier: GPL-3.0-or-later
import { afterEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import path from "node:path";
import { recordHook } from "../claude-helper.ts";
import {
	acquireLock,
	askHuman,
	atomicWrite,
	decide,
	event,
	feedbackPath,
	git,
	initialize,
	json,
	load,
	parseInput,
	publishReview,
	readClaudeStatus,
	repair,
	runtimePath,
	submit,
	update,
	validateState,
} from "../store.ts";
import { fixture, hook, implementation } from "./support.ts";

const roots: string[] = [];
const setup = () => {
	const f = fixture();
	roots.push(f.root);
	return f;
};
afterEach(() => {
	for (const root of roots.splice(0))
		fs.rmSync(root, { recursive: true, force: true });
});

test("file, quoted path, long instruction and resume input; missing paths fail before side effects", () => {
	const { repo, dir } = setup();
	fs.mkdirSync(path.join(repo, "tasks"));
	const file = path.join(repo, "tasks", "a task.md");
	fs.writeFileSync(file, "original\n");
	expect(parseInput('"tasks/a task.md"', repo)).toEqual({
		kind: "file",
		file,
		content: "original\n",
	});
	expect(parseInput("Fix the bug\nand add tests", repo)).toEqual({
		kind: "text",
		content: "Fix the bug\nand add tests",
	});
	expect(parseInput('"Fix the bug"', repo)).toEqual({
		kind: "text",
		content: "Fix the bug",
	});
	expect(parseInput(`--text ${file}`, repo)).toEqual({
		kind: "text",
		content: file,
	});
	expect(parseInput(dir, repo)).toEqual({
		kind: "resume",
		directory: fs.realpathSync(dir),
	});
	for (const input of [
		"",
		"tasks/missing.md",
		"./missing",
		"tasks/a.md extra words",
	])
		expect(() => parseInput(input, repo)).toThrow();
	fs.writeFileSync(path.join(repo, "task.md"), "task");
	expect(() => parseInput("task.md extra words", repo)).toThrow();
});

test("worktree initialization pins main without changing the main checkout; repeat initialization is safe", () => {
	const { repo, dir } = setup();
	const main = git(repo, "rev-parse", "HEAD");
	git(repo, "checkout", "-b", "user-branch");
	fs.writeFileSync(path.join(repo, "dirty.txt"), "keep me");
	const s = initialize(dir);
	expect(s.base_commit).toBe(main);
	expect(git(repo, "branch", "--show-current")).toBe("user-branch");
	expect(fs.readFileSync(path.join(repo, "dirty.txt"), "utf8")).toBe("keep me");
	expect(initialize(dir)).toEqual(s);
	expect(git(s.worktree, "branch", "--show-current")).toBe(s.branch);
	expect(fs.existsSync(path.join(s.worktree, "dirty.txt"))).toBe(false);
});

test("state shape, task identity, feedback references and versions fail closed", () => {
	const { dir } = setup();
	const s = initialize(dir);
	expect(() => update(dir, "stale", () => {}, s.version - 1)).toThrow(
		"State changed",
	);
	expect(() => validateState({ ...s, schema: 2 })).toThrow();
	expect(() => validateState({ ...s, feedback: "../../outside.md" })).toThrow();
	fs.writeFileSync(path.join(dir, "task.md"), "changed scope");
	expect(() => load(dir)).toThrow("task.md changed");
});

test("submission needs an active turn, full SHA, clean correct branch and expected version", () => {
	const { dir } = setup();
	let s = initialize(dir);
	const head = git(s.worktree, "rev-parse", "HEAD");
	expect(() => submit(dir, s.version, head, "passed")).toThrow(
		"active implementor",
	);
	hook(dir, "UserPromptSubmit", { prompt: "work" });
	fs.writeFileSync(path.join(s.worktree, "extra.txt"), "untracked");
	expect(() => submit(dir, s.version, head, "passed")).toThrow("unsubmitted");
	fs.unlinkSync(path.join(s.worktree, "extra.txt"));
	expect(() => submit(dir, s.version, head.slice(0, 7), "passed")).toThrow(
		"full commit",
	);
	s = submit(dir, s.version, head, "passed");
	expect(s.phase).toBe("code_review");
	expect(s.review_round).toBe(1);
	expect(() => submit(dir, s.version, head, "passed")).toThrow("not accepting");
});

test("structured review generates immutable Markdown and an exact hash-checked state reference", () => {
	const { dir } = setup();
	let s = implementation(dir);
	s = update(dir, "review_start", (v) => {
		v.review_attempt = { id: "attempt", session: null };
	});
	const review = {
		round: 1,
		reviewed_commit: s.submitted_commit,
		outcome: "changes_required",
		content: "## R1 · P1\nFix it.\n",
	};
	expect(() =>
		publishReview(dir, s.version, { ...review, round: 2 }, "attempt"),
	).toThrow("Stale");
	expect(() => publishReview(dir, s.version, review, "old-attempt")).toThrow(
		"Stale",
	);
	s = publishReview(dir, s.version, review, "attempt");
	expect(s.feedback).toBe("review/feedback/001.md");
	expect(s.phase).toBe("changes_required");
	const md = fs.readFileSync(path.join(dir, s.feedback ?? ""), "utf8");
	expect(md).toContain(`reviewed_commit: ${s.submitted_commit}`);
	expect(md).toContain("outcome: changes_required");
	fs.appendFileSync(path.join(dir, s.feedback ?? ""), "manual change");
	expect(() => load(dir)).toThrow("modified");
});

test("dirty/new HEAD, orphan feedback and incomplete review cannot approve", () => {
	const { dir } = setup();
	let s = implementation(dir);
	s = update(dir, "review_start", (v) => {
		v.review_attempt = { id: "a", session: null };
	});
	const review = {
		round: 1,
		reviewed_commit: s.submitted_commit,
		outcome: "approved",
		content: "Approved.",
	};
	expect(() =>
		publishReview(dir, s.version, { ...review, content: "" }, "a"),
	).toThrow();
	fs.appendFileSync(path.join(s.worktree, "source.txt"), "dirty");
	expect(() => publishReview(dir, s.version, review, "a")).toThrow(
		"unsubmitted",
	);
	git(s.worktree, "add", ".");
	git(s.worktree, "commit", "-m", "new head");
	expect(() => publishReview(dir, s.version, review, "a")).toThrow("HEAD");
	expect(load(dir).phase).toBe("code_review");
});

test("an orphan result is not silently adopted after file-before-state interruption", () => {
	const { dir } = setup();
	let s = implementation(dir);
	s = update(dir, "review_start", (v) => {
		v.review_attempt = { id: "a", session: null };
	});
	atomicWrite(
		path.join(dir, feedbackPath(1)),
		"---\noutcome: approved\n---\npartial or unaccepted",
	);
	expect(() =>
		publishReview(
			dir,
			s.version,
			{
				round: 1,
				reviewed_commit: s.submitted_commit,
				outcome: "approved",
				content: "Approved",
			},
			"a",
		),
	).toThrow("repair");
	expect(load(dir).phase).toBe("code_review");
});

test("human decisions persist in state and the event log; no automatic approval", () => {
	const { dir } = setup();
	const s = initialize(dir);
	askHuman(dir, s.version, "Which storage backend?");
	expect(load(dir).phase).toBe("needs_human_decision");
	decide(dir, "Use SQLite.");
	expect(load(dir).decision).toBe("Use SQLite.");
	expect(load(dir).phase).toBe("implementing");
	expect(fs.readFileSync(path.join(dir, "events.jsonl"), "utf8")).toContain(
		"Use SQLite.",
	);
	expect(() => decide(dir, "approve")).toThrow("No pending");
});

test("locks reject concurrent owners; a persistent lock inode is not ownership", () => {
	const { dir } = setup();
	const file = path.join(dir, ".test.lock");
	const release = acquireLock(file);
	expect(() => acquireLock(file)).toThrow("already owned");
	release();
	release();
	expect(fs.existsSync(file)).toBe(true);
	acquireLock(file)();
});

test("nested Claude agents cannot alter root lifecycle; permissions are visible", () => {
	const { dir } = setup();
	initialize(dir);
	hook(dir, "UserPromptSubmit", { prompt: "hello" });
	const before = fs.readFileSync(runtimePath(dir, "claude.json"), "utf8");
	hook(dir, "Stop", { agent_id: "nested" });
	expect(fs.readFileSync(runtimePath(dir, "claude.json"), "utf8")).toBe(before);
	hook(dir, "PermissionRequest");
	expect(
		JSON.parse(fs.readFileSync(runtimePath(dir, "claude.json"), "utf8")).status,
	).toBe("waiting");
	hook(dir, "PostToolUse");
	expect(
		JSON.parse(fs.readFileSync(runtimePath(dir, "claude.json"), "utf8")).status,
	).toBe("working");
});

test("late hooks from a prior launch of the same Claude UUID cannot change current lifecycle", () => {
	const { dir } = setup();
	const s = implementation(dir);
	const old = readClaudeStatus(dir);
	if (!old) throw new Error("Missing lifecycle fixture");
	const current = { ...old, run: "current-launch" };
	atomicWrite(runtimePath(dir, "claude.json"), json(current));
	recordHook(
		dir,
		{ session_id: s.implementor.session, hook_event_name: "StopFailure" },
		"old-launch",
	);
	expect(readClaudeStatus(dir)).toEqual(current);
	recordHook(
		dir,
		{
			session_id: s.implementor.session,
			hook_event_name: "UserPromptSubmit",
			prompt: "Continue",
		},
		"current-launch",
	);
	expect(readClaudeStatus(dir)?.status).toBe("working");
});

test("explicit versioned repair discards missing feedback, records a reason and stays paused", () => {
	const { dir } = setup();
	let s = implementation(dir);
	s = update(dir, "review_start", (v) => {
		v.review_attempt = { id: "a", session: null };
	});
	s = publishReview(
		dir,
		s.version,
		{
			round: 1,
			reviewed_commit: s.submitted_commit,
			outcome: "changes_required",
			content: "Fix it.",
		},
		"a",
	);
	fs.unlinkSync(path.join(dir, s.feedback ?? ""));
	expect(() => load(dir)).toThrow("missing");
	expect(() => repair(dir, s.version - 1, "retry_review", "Lost file")).toThrow(
		"State changed",
	);
	const next = repair(
		dir,
		s.version,
		"retry_review",
		"Feedback was lost; re-review the verified commit.",
	);
	expect(next.phase).toBe("code_review");
	expect(next.review_round).toBe(2);
	expect(next.paused).toBe(true);
	expect(next.feedback).toBeNull();
	expect(fs.readFileSync(path.join(dir, "events.jsonl"), "utf8")).toContain(
		"Feedback was lost",
	);
});

test("an interrupted branch-only initialization is resumed without a second branch", () => {
	const { dir } = setup();
	const s = load(dir);
	git(s.repository, "branch", s.branch, s.base_commit);
	expect(initialize(dir).phase).toBe("implementing");
});

test("a truncated event tail is isolated from future events and never drives state", () => {
	const { dir } = setup();
	const before = load(dir);
	fs.appendFileSync(path.join(dir, "events.jsonl"), '{"event":"incomplete');
	event(dir, "diagnostic");
	const lines = fs
		.readFileSync(path.join(dir, "events.jsonl"), "utf8")
		.trim()
		.split("\n");
	expect(JSON.parse(lines.at(-1) ?? "").event).toBe("diagnostic");
	expect(load(dir)).toEqual(before);
});

test("checks evidence cannot be swapped after submission", () => {
	const { dir } = setup();
	let s = implementation(dir);
	s = update(dir, "review_start", (v) => {
		v.review_attempt = { id: "a", session: null };
	});
	fs.writeFileSync(runtimePath(dir, "checks.md"), "invented results");
	expect(() =>
		publishReview(
			dir,
			s.version,
			{
				round: 1,
				reviewed_commit: s.submitted_commit,
				outcome: "approved",
				content: "Approved",
			},
			"a",
		),
	).toThrow("checks report");
});

test("initialized worktree with wrong branch is not silently reset during recovery", () => {
	const { dir } = setup();
	const original = load(dir);
	initialize(dir);
	git(original.worktree, "checkout", "-b", "unexpected");
	atomicWrite(path.join(dir, "state.json"), json(original));
	expect(() => initialize(dir)).toThrow("branch changed");
	expect(git(original.worktree, "branch", "--show-current")).toBe("unexpected");
});
