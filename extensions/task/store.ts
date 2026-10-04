// SPDX-License-Identifier: GPL-3.0-or-later
// This module is also used by the Node-only Claude helper. No pi imports here.
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import * as fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { acquireLock } from "./lock.ts";

export { acquireLock } from "./lock.ts";

export type Phase =
	| "initializing"
	| "implementing"
	| "code_review"
	| "changes_required"
	| "approved"
	| "needs_human_decision";
export type Outcome = "approved" | "changes_required" | "needs_human_decision";
export interface Review {
	round: number;
	reviewed_commit: string;
	outcome: Outcome;
	content: string;
}
export interface State {
	schema: 1;
	version: number;
	id: string;
	phase: Phase;
	paused: boolean;
	repository: string;
	branch: string;
	base_commit: string;
	worktree: string;
	task_hash: string;
	submitted_commit: string | null;
	submitted_turn: string | null;
	checks_hash: string | null;
	review_round: number;
	feedback: string | null;
	feedback_hash: string | null;
	decision: string | null;
	question: string | null;
	implementor: {
		session: string;
		tmux: string;
		launched: boolean;
		wake: "pending" | "sent" | "accepted";
		wake_turn: string | null;
	};
	reviewer: { provider: string; model: string };
	review_attempt: { id: string; session: string | null } | null;
}
export interface ClaudeStatus {
	run?: string;
	session: string;
	status: "starting" | "working" | "idle" | "waiting" | "failed" | "exited";
	turn: string | null;
	prompt: string | null;
}
export class StateConflictError extends Error {}

export const phases: Phase[] = [
	"initializing",
	"implementing",
	"code_review",
	"changes_required",
	"approved",
	"needs_human_decision",
];
export const outcomes: Outcome[] = [
	"approved",
	"changes_required",
	"needs_human_decision",
];
const sha = /^[a-f0-9]{40,64}$/;
export const digest = (text: string) =>
	createHash("sha256").update(text).digest("hex");
export const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`;

export function command(
	executable: string,
	args: string[],
	cwd?: string,
): string {
	const result = spawnSync(executable, args, {
		cwd,
		encoding: "utf8",
		timeout: 30_000,
		maxBuffer: 16 * 1024 * 1024,
	});
	if (result.error) throw result.error;
	if (result.status !== 0)
		throw new Error(
			`${executable} ${args[0]} failed: ${result.stderr.trim() || result.stdout.trim() || result.status}`,
		);
	return result.stdout.trim();
}
export const git = (cwd: string, ...args: string[]) =>
	command("git", ["-C", cwd, ...args]);

function object(value: unknown): Record<string, unknown> {
	if (!value || typeof value !== "object" || Array.isArray(value))
		throw new Error("Expected an object");
	return value as Record<string, unknown>;
}
function text(value: unknown): asserts value is string {
	if (typeof value !== "string" || !value.trim())
		throw new Error("Expected nonempty text");
}
function integer(value: unknown): asserts value is number {
	if (!Number.isSafeInteger(value) || Number(value) < 0)
		throw new Error("Expected nonnegative integer");
}
export function validateReview(value: unknown): Review {
	const r = object(value);
	integer(r.round);
	text(r.reviewed_commit);
	text(r.content);
	if (
		!sha.test(r.reviewed_commit) ||
		!outcomes.includes(r.outcome as Outcome) ||
		r.content.length > 200_000
	)
		throw new Error("Invalid review");
	return r as unknown as Review;
}
export function validateState(value: unknown): State {
	const s = object(value);
	if (
		s.schema !== 1 ||
		!phases.includes(s.phase as Phase) ||
		typeof s.paused !== "boolean"
	)
		throw new Error("Unsupported task state");
	integer(s.version);
	integer(s.review_round);
	for (const key of [
		"id",
		"repository",
		"branch",
		"base_commit",
		"worktree",
		"task_hash",
	])
		text(s[key]);
	if (
		!sha.test(String(s.base_commit)) ||
		!/^[a-f0-9]{64}$/.test(String(s.task_hash))
	)
		throw new Error("Invalid task hashes");
	if (
		!/^[a-z0-9-]+$/.test(String(s.id)) ||
		!String(s.branch).startsWith("task/")
	)
		throw new Error("Invalid task identity");
	for (const key of ["repository", "worktree"])
		if (!path.isAbsolute(String(s[key])))
			throw new Error("Task paths must be absolute");
	for (const key of [
		"submitted_commit",
		"submitted_turn",
		"checks_hash",
		"feedback",
		"feedback_hash",
		"decision",
		"question",
	]) {
		if (s[key] !== null) text(s[key]);
	}
	if (s.submitted_commit !== null && !sha.test(String(s.submitted_commit)))
		throw new Error("Invalid submitted commit");
	if (
		s.feedback !== null &&
		s.feedback !== feedbackPath(Number(s.review_round))
	)
		throw new Error("Invalid feedback reference");
	if ((s.feedback === null) !== (s.feedback_hash === null))
		throw new Error("Incomplete feedback reference");
	if (
		s.feedback_hash !== null &&
		!/^[a-f0-9]{64}$/.test(String(s.feedback_hash))
	)
		throw new Error("Invalid feedback hash");
	if (s.checks_hash !== null && !/^[a-f0-9]{64}$/.test(String(s.checks_hash)))
		throw new Error("Invalid checks hash");
	const implementor = object(s.implementor);
	text(implementor.session);
	text(implementor.tmux);
	if (
		!/^[a-f0-9-]{36}$/.test(implementor.session) ||
		implementor.tmux !== `pi-task-${s.id}` ||
		typeof implementor.launched !== "boolean" ||
		!["pending", "sent", "accepted"].includes(String(implementor.wake))
	)
		throw new Error("Invalid implementor identity");
	if (implementor.wake_turn !== null) text(implementor.wake_turn);
	const reviewer = object(s.reviewer);
	text(reviewer.provider);
	text(reviewer.model);
	if (s.review_attempt !== null) {
		const attempt = object(s.review_attempt);
		text(attempt.id);
		if (attempt.session !== null) text(attempt.session);
	}
	if (
		["code_review", "changes_required", "approved"].includes(String(s.phase)) &&
		(!s.submitted_commit ||
			!s.submitted_turn ||
			!s.checks_hash ||
			!s.review_round)
	)
		throw new Error("Missing submission");
	if (["changes_required", "approved"].includes(String(s.phase)) && !s.feedback)
		throw new Error("Missing feedback reference");
	if (s.phase === "needs_human_decision" && !s.question)
		throw new Error("Missing human question");
	return s as unknown as State;
}

export function atomicWrite(file: string, content: string) {
	fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
	const temporary = `${file}.${randomUUID()}.tmp`;
	try {
		const fd = fs.openSync(temporary, "wx", 0o600);
		try {
			fs.writeFileSync(fd, content);
			fs.fsyncSync(fd);
		} finally {
			fs.closeSync(fd);
		}
		fs.renameSync(temporary, file);
		const dir = fs.openSync(path.dirname(file), "r");
		try {
			fs.fsyncSync(dir);
		} finally {
			fs.closeSync(dir);
		}
	} finally {
		fs.rmSync(temporary, { force: true });
	}
}

export function event(
	dir: string,
	kind: string,
	detail: Record<string, unknown> = {},
) {
	const file = path.join(dir, "events.jsonl");
	// One append per record. A damaged trailing record is diagnostic, never authority.
	const fd = fs.openSync(file, "a+", 0o600);
	try {
		const size = fs.fstatSync(fd).size;
		const last = Buffer.alloc(1);
		if (size) fs.readSync(fd, last, 0, 1, size - 1);
		const separator = size && last[0] !== 10 ? "\n" : "";
		fs.writeFileSync(
			fd,
			`${separator}${JSON.stringify({ at: new Date().toISOString(), event: kind, ...detail })}\n`,
		);
		fs.fsyncSync(fd);
	} finally {
		fs.closeSync(fd);
	}
}
export function load(dir: string, validateArtifacts = true): State {
	const s = validateState(
		JSON.parse(fs.readFileSync(path.join(dir, "state.json"), "utf8")),
	);
	if (
		digest(fs.readFileSync(path.join(dir, "task.md"), "utf8")) !== s.task_hash
	)
		throw new Error("task.md changed; explicit repair is required");
	if (validateArtifacts && s.feedback) {
		const file = path.join(dir, s.feedback);
		if (
			!fs.existsSync(file) ||
			digest(fs.readFileSync(file, "utf8")) !== s.feedback_hash
		)
			throw new Error(`Feedback missing or modified: ${file}`);
	}
	return s;
}
export function update(
	dir: string,
	kind: string,
	change: (s: State) => void,
	expected?: number,
	validateArtifacts = true,
): State {
	const release = acquireLock(path.join(dir, ".mutation.lock"), 3);
	try {
		const current = load(dir, validateArtifacts);
		if (expected !== undefined && expected !== current.version)
			throw new StateConflictError("State changed; reload before retrying");
		const next = structuredClone(current);
		change(next);
		next.version++;
		validateState(next);
		event(dir, `${kind}_intended`, {
			from_version: current.version,
			to_version: next.version,
		});
		atomicWrite(path.join(dir, "state.json"), json(next));
		event(dir, kind, { version: next.version, phase: next.phase, state: next });
		return next;
	} finally {
		release();
	}
}
export const feedbackPath = (round: number) =>
	`review/feedback/${String(round).padStart(3, "0")}.md`;
export const runtimePath = (dir: string, name: string) =>
	path.join(dir, ".runtime", name);

export function readClaudeStatus(dir: string): ClaudeStatus | null {
	const file = runtimePath(dir, "claude.json");
	if (!fs.existsSync(file)) return null;
	const value = object(JSON.parse(fs.readFileSync(file, "utf8")));
	text(value.session);
	if (value.run !== undefined) text(value.run);
	if (
		!["starting", "working", "idle", "waiting", "failed", "exited"].includes(
			String(value.status),
		)
	)
		throw new Error("Invalid Claude status");
	for (const key of ["turn", "prompt"])
		if (value[key] !== null) text(value[key]);
	return value as unknown as ClaudeStatus;
}

export function verifyCheckout(s: State, commit?: string, clean = false) {
	if (
		fs.realpathSync(git(s.worktree, "rev-parse", "--show-toplevel")) !==
		fs.realpathSync(s.worktree)
	)
		throw new Error("Wrong implementation worktree");
	const common = (cwd: string) =>
		fs.realpathSync(
			git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"),
		);
	if (
		common(s.worktree) !== common(s.repository) ||
		git(s.worktree, "branch", "--show-current") !== s.branch
	)
		throw new Error("Worktree repository or branch changed");
	if (
		git(s.worktree, "rev-parse", `${s.base_commit}^{commit}`) !== s.base_commit
	)
		throw new Error("Base commit missing");
	if (commit && git(s.worktree, "rev-parse", "HEAD") !== commit)
		throw new Error("Submission no longer matches HEAD");
	if (
		clean &&
		git(s.worktree, "status", "--porcelain", "--untracked-files=all")
	)
		throw new Error("Worktree has unsubmitted changes");
}
export function verifyEvidence(dir: string, s: State) {
	if (
		!s.checks_hash ||
		digest(fs.readFileSync(runtimePath(dir, "checks.md"), "utf8")) !==
			s.checks_hash
	)
		throw new Error("Submission checks report missing or modified");
}
export function submit(
	dir: string,
	expected: number,
	commit: string,
	checks: string,
): State {
	text(checks);
	const status = readClaudeStatus(dir);
	return update(
		dir,
		"implementation_submitted",
		(s) => {
			if (s.paused || s.phase !== "implementing")
				throw new Error("Task is not accepting implementation submissions");
			if (
				!status ||
				status.session !== s.implementor.session ||
				status.status !== "working" ||
				!status.turn
			)
				throw new Error("No active implementor turn");
			if (!sha.test(commit)) throw new Error("Use the full commit SHA");
			verifyCheckout(s, commit, true);
			git(s.worktree, "merge-base", "--is-ancestor", s.base_commit, commit);
			s.phase = "code_review";
			s.submitted_commit = commit;
			s.submitted_turn = status.turn;
			atomicWrite(runtimePath(dir, "checks.md"), checks);
			s.checks_hash = digest(checks);
			s.review_round++;
			s.feedback = null;
			s.feedback_hash = null;
			s.review_attempt = null;
			event(dir, "checks_reported", { commit, checks });
		},
		expected,
	);
}
export function publishReview(
	dir: string,
	expected: number,
	input: unknown,
	attempt: string,
): State {
	const review = validateReview(input);
	return update(
		dir,
		"review_completed",
		(s) => {
			if (
				s.paused ||
				s.phase !== "code_review" ||
				s.review_attempt?.id !== attempt ||
				review.round !== s.review_round ||
				review.reviewed_commit !== s.submitted_commit
			)
				throw new Error("Stale review submission");
			verifyCheckout(s, review.reviewed_commit, true);
			verifyEvidence(dir, s);
			const relative = feedbackPath(review.round);
			const file = path.join(dir, relative);
			if (fs.existsSync(file))
				throw new Error(`Unpublished feedback requires repair: ${file}`);
			const markdown = `---\nround: ${review.round}\nbase_commit: ${s.base_commit}\nreviewed_commit: ${review.reviewed_commit}\noutcome: ${review.outcome}\n---\n\n${review.content.trim()}\n`;
			atomicWrite(file, markdown);
			s.feedback = relative;
			s.feedback_hash = digest(markdown);
			s.phase = review.outcome;
			s.review_attempt = null;
			s.question =
				review.outcome === "needs_human_decision" ? review.content : null;
		},
		expected,
	);
}
export function askHuman(dir: string, expected: number, question: string) {
	text(question);
	return update(
		dir,
		"human_decision_requested",
		(s) => {
			if (s.phase !== "implementing" || s.paused)
				throw new Error("Implementor is not active");
			s.phase = "needs_human_decision";
			s.question = question;
		},
		expected,
	);
}
export function decide(dir: string, answer: string) {
	text(answer);
	return update(dir, "human_decision_recorded", (s) => {
		if (s.phase !== "needs_human_decision")
			throw new Error("No pending human decision");
		event(dir, "human_decision", { question: s.question, answer });
		s.decision = answer;
		s.question = null;
		s.phase = "implementing";
		s.implementor.wake = "pending";
	});
}

// An explicitly human-confirmed repair can discard an invalid result, never invent approval.
export function repair(
	dir: string,
	expected: number,
	action: "retry_review" | "retry_implementation",
	reason: string,
): State {
	text(reason);
	return update(
		dir,
		"human_repair",
		(s) => {
			verifyCheckout(s);
			if (s.phase === "needs_human_decision")
				throw new Error(
					"Record the human decision instead of bypassing it with repair",
				);
			if (action === "retry_review") {
				if (!s.submitted_commit)
					throw new Error("No committed submission to review");
				verifyCheckout(s, s.submitted_commit, true);
				verifyEvidence(dir, s);
				const status = readClaudeStatus(dir);
				if (
					!status ||
					status.session !== s.implementor.session ||
					!status.turn ||
					!["idle", "exited"].includes(status.status)
				)
					throw new Error("Implementor must finish before retrying review");
				s.submitted_turn = status.turn;
				s.review_round++;
				s.phase = "code_review";
				s.feedback = null;
				s.feedback_hash = null;
			} else if (action === "retry_implementation") {
				s.phase = "implementing";
				s.implementor.wake = "pending";
				if (s.feedback) {
					const file = path.join(dir, s.feedback);
					if (
						!fs.existsSync(file) ||
						digest(fs.readFileSync(file, "utf8")) !== s.feedback_hash
					) {
						s.feedback = null;
						s.feedback_hash = null;
					}
				}
			} else throw new Error("Unsupported repair action");
			s.paused = true;
			s.review_attempt = null;
			event(dir, "repair_requested", {
				action,
				reason,
				expected_version: expected,
			});
		},
		expected,
		false,
	);
}

export type TaskInput =
	| { kind: "text"; content: string }
	| { kind: "file"; file: string; content: string }
	| { kind: "resume"; directory: string };
export function parseInput(raw: string, cwd: string): TaskInput {
	let input = raw.trim();
	if (input.startsWith("--text ")) {
		input = input.slice(7).trim();
		text(input);
		return { kind: "text", content: input };
	}
	if (
		(input.startsWith('"') && input.endsWith('"')) ||
		(input.startsWith("'") && input.endsWith("'"))
	)
		input = input.slice(1, -1);
	text(input);
	const file = path.resolve(
		cwd,
		input.startsWith("~/") ? path.join(os.homedir(), input.slice(2)) : input,
	);
	if (fs.existsSync(file)) {
		if (fs.statSync(file).isDirectory()) {
			for (const name of ["state.json", "task.md"]) {
				if (!fs.statSync(path.join(file, name)).isFile())
					throw new Error(`Not a task directory: ${file}`);
			}
			return { kind: "resume", directory: fs.realpathSync(file) };
		}
		if (!fs.statSync(file).isFile())
			throw new Error("Task source must be a regular file");
		const content = fs.readFileSync(file, "utf8");
		text(content);
		return { kind: "file", file, content };
	}
	const first = input.split(/\s+/)[0] ?? "";
	if (
		/^(\.?\.?\/|~\/)/.test(input) ||
		/^\S*\/\S+$/.test(input) ||
		/^\S+\.(md|org|txt)(\s|$)/.test(input) ||
		fs.existsSync(path.resolve(cwd, first))
	)
		throw new Error(
			`Task path does not exist, or has trailing arguments: ${input}. Use --text for a literal instruction.`,
		);
	return { kind: "text", content: input };
}
export function createTask(
	cwd: string,
	content: string,
	reviewer: State["reviewer"],
): string {
	text(content);
	const repository = fs.realpathSync(git(cwd, "rev-parse", "--show-toplevel"));
	const common = git(
		repository,
		"rev-parse",
		"--path-format=absolute",
		"--git-common-dir",
	);
	const base = git(repository, "rev-parse", "main^{commit}");
	const label =
		content
			.toLowerCase()
			.replace(/[^a-z0-9]+/g, "-")
			.replace(/^-|-$/g, "")
			.slice(0, 36)
			.replace(/-$/, "") || "task";
	const id = `${label}-${randomUUID().slice(0, 8)}`;
	const dir = path.join(common, "pi-tasks", id);
	fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	atomicWrite(path.join(dir, "task.md"), content);
	const s: State = {
		schema: 1,
		version: 0,
		id,
		phase: "initializing",
		paused: false,
		repository,
		branch: `task/${id}`,
		base_commit: base,
		worktree: path.join(
			path.dirname(repository),
			`${path.basename(repository)}.worktrees`,
			id,
		),
		task_hash: digest(content),
		submitted_commit: null,
		submitted_turn: null,
		checks_hash: null,
		review_round: 0,
		feedback: null,
		feedback_hash: null,
		decision: null,
		question: null,
		implementor: {
			session: randomUUID(),
			tmux: `pi-task-${id}`,
			launched: false,
			wake: "pending",
			wake_turn: null,
		},
		reviewer,
		review_attempt: null,
	};
	atomicWrite(path.join(dir, "state.json"), json(validateState(s)));
	event(dir, "task_created", { version: 0, state: s });
	return dir;
}
export function initialize(dir: string): State {
	const s = load(dir);
	if (s.phase !== "initializing") return s;
	event(dir, "worktree_create_intended", {
		worktree: s.worktree,
		branch: s.branch,
	});
	if (!fs.existsSync(s.worktree)) {
		let branch: string | undefined;
		try {
			branch = git(
				s.repository,
				"rev-parse",
				"--verify",
				`refs/heads/${s.branch}`,
			);
		} catch {
			/* Branch creation may not have happened yet. */
		}
		if (branch && branch !== s.base_commit)
			throw new Error(
				"Initialization branch has unexpected commits; repair required",
			);
		if (branch) git(s.repository, "worktree", "add", s.worktree, s.branch);
		else
			git(
				s.repository,
				"worktree",
				"add",
				"-b",
				s.branch,
				s.worktree,
				s.base_commit,
			);
	}
	verifyCheckout(s, s.base_commit, true);
	return update(
		dir,
		"initialized",
		(next) => {
			next.phase = "implementing";
		},
		s.version,
	);
}
