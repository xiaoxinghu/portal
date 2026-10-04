// SPDX-License-Identifier: GPL-3.0-or-later
import { afterEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import path from "node:path";
import { TaskController } from "../controller.ts";
import type { Reviewer } from "../reviewer.ts";
import {
	atomicWrite,
	decide,
	feedbackPath,
	git,
	initialize,
	json,
	load,
	runtimePath,
	update,
} from "../store.ts";
import { type Implementor, WAKE } from "../transport.ts";
import { fixture, hook, implementation, until } from "./support.ts";

const roots: string[] = [];
const controllers: TaskController[] = [];
const setup = () => {
	const f = fixture();
	roots.push(f.root);
	return f;
};
afterEach(async () => {
	for (const c of controllers.splice(0)) await c.close();
	for (const root of roots.splice(0))
		fs.rmSync(root, { recursive: true, force: true });
});
function manage(dir: string, reviewer: Reviewer, implementor?: Implementor) {
	const errors: Error[] = [];
	const activity: string[] = [];
	const calls: string[] = [];
	const fake: Implementor = implementor ?? {
		alive: () => true,
		start: () => {
			calls.push("start");
		},
		wake: () => {
			calls.push("wake");
			hook(dir, "UserPromptSubmit", { prompt: WAKE });
		},
	};
	const controller = new TaskController(dir, fake, reviewer, {
		state: (_s, a) => activity.push(a),
		error: (e) => errors.push(e),
	});
	controllers.push(controller);
	controller.start();
	return { controller, errors, activity, calls };
}
const approve: Reviewer = async ({ state }) => ({
	round: state.review_round,
	reviewed_commit: state.submitted_commit ?? "",
	outcome: "approved",
	content: "No required changes.",
});

test("automatic rejection → same implementor → fresh review → approval uses the full fixed range", async () => {
	const { dir, repo } = setup();
	const first = implementation(dir);
	const requests: string[] = [];
	let count = 0;
	const h = manage(dir, async (r) => {
		requests.push(r.state.review_attempt?.id ?? "");
		r.started(`/saved/reviewer-${count}.jsonl`);
		expect(git(r.checkout, "rev-parse", "HEAD")).toBe(
			r.state.submitted_commit ?? "",
		);
		expect(r.state.base_commit).toBe(first.base_commit);
		expect(fs.readFileSync(runtimePath(dir, "change.diff"), "utf8")).toContain(
			"-base",
		);
		count++;
		return {
			...(await approve(r)),
			outcome: count === 1 ? "changes_required" : "approved",
			content: count === 1 ? "## R1 · P1\nImprove source." : "Approved.",
		};
	});
	await until(() => load(dir).phase === "implementing", "fix handoff");
	await until(() => h.calls.length === 1, "implementor wake");
	const second = implementation(dir, "fixed twice\n");
	h.controller.kick();
	await until(
		() => load(dir).phase === "approved" || h.errors.length > 0,
		"approval",
	);
	expect(h.errors).toEqual([]);
	expect(requests.length).toBe(2);
	expect(requests[0]).not.toBe(requests[1]);
	expect(load(dir).submitted_commit).toBe(second.submitted_commit);
	expect(load(dir).implementor.session).toBe(first.implementor.session);
	expect(fs.existsSync(path.join(dir, feedbackPath(1)))).toBe(true);
	expect(fs.existsSync(path.join(dir, feedbackPath(2)))).toBe(true);
	expect(git(repo, "rev-parse", "HEAD")).toBe(first.base_commit);
});

test("Stop without a submission never starts a reviewer; repeated reconciliation does not duplicate a nudge", async () => {
	const { dir } = setup();
	initialize(dir);
	hook(dir, "UserPromptSubmit", { prompt: WAKE });
	hook(dir, "Stop");
	let reviews = 0;
	const h = manage(dir, async (r) => {
		reviews++;
		return approve(r);
	});
	await h.controller.idle();
	for (let i = 0; i < 5; i++) {
		h.controller.kick();
		await h.controller.idle();
	}
	expect(reviews).toBe(0);
	expect(h.calls).toEqual(["wake"]);
});

test("a recorded submission waits for its own turn, not a previous Stop or permission prompt", async () => {
	const { dir } = setup();
	const s = implementation(dir);
	const status = JSON.parse(
		fs.readFileSync(runtimePath(dir, "claude.json"), "utf8"),
	);
	atomicWrite(
		runtimePath(dir, "claude.json"),
		json({ ...status, turn: "old-turn" }),
	);
	let reviews = 0;
	const h = manage(dir, async (r) => {
		reviews++;
		return approve(r);
	});
	await h.controller.idle();
	expect(reviews).toBe(0);
	atomicWrite(
		runtimePath(dir, "claude.json"),
		json({ ...status, turn: s.submitted_turn, status: "waiting" }),
	);
	h.controller.kick();
	await h.controller.idle();
	expect(reviews).toBe(0);
	atomicWrite(runtimePath(dir, "claude.json"), json(status));
	h.controller.kick();
	await until(() => load(dir).phase === "approved");
	expect(reviews).toBe(1);
});

test("provider failure leaves code_review resumable with a fresh attempt", async () => {
	const { dir } = setup();
	implementation(dir);
	const first = manage(dir, async () => {
		throw new Error("provider failed");
	});
	await first.controller.idle();
	expect(first.errors[0]?.message).toBe("provider failed");
	const attempt = load(dir).review_attempt?.id;
	await first.controller.close();
	const next = manage(dir, async (r) => {
		expect(r.state.review_attempt?.id).not.toBe(attempt);
		return approve(r);
	});
	await next.controller.idle();
	expect(next.errors).toEqual([]);
	expect(load(dir).phase).toBe("approved");
});

test("shutdown aborts an SDK review, releases ownership after settlement, and cannot publish approval", async () => {
	const { dir } = setup();
	implementation(dir);
	let began = false;
	let aborted = false;
	const h = manage(dir, async (r) => {
		began = true;
		await new Promise<void>((resolve) =>
			r.signal.addEventListener(
				"abort",
				() => {
					aborted = true;
					resolve();
				},
				{ once: true },
			),
		);
		return approve(r);
	});
	await until(() => began);
	expect(() => manage(dir, approve)).toThrow();
	await h.controller.close();
	expect(aborted).toBe(true);
	expect(load(dir).phase).toBe("code_review");
	expect(fs.existsSync(path.join(dir, feedbackPath(1)))).toBe(false);
	const resumed = manage(dir, approve);
	await resumed.controller.idle();
	expect(load(dir).phase).toBe("approved");
});

test("human verdict pauses until an explicit decision; decision returns through the implementor", async () => {
	const { dir } = setup();
	implementation(dir);
	const h = manage(dir, async (r) => ({
		...(await approve(r)),
		outcome: "needs_human_decision",
		content: "Keep backward compatibility?",
	}));
	await h.controller.idle();
	expect(load(dir).phase).toBe("needs_human_decision");
	expect(h.calls).toEqual([]);
	decide(dir, "Yes, preserve compatibility.");
	h.controller.kick();
	await h.controller.idle();
	expect(load(dir).phase).toBe("implementing");
	expect(h.calls).toEqual(["wake"]);
});

test("missing or orphan feedback fails closed and leaves state unapproved", async () => {
	const { dir } = setup();
	implementation(dir);
	atomicWrite(path.join(dir, feedbackPath(1)), "unfinished");
	const h = manage(dir, approve);
	await h.controller.idle();
	expect(h.errors[0]?.message).toContain("repair");
	expect(load(dir).phase).toBe("code_review");
});

test("human edits or another turn during review invalidate the result", async () => {
	const { dir } = setup();
	implementation(dir);
	const h = manage(dir, async (r) => {
		hook(dir, "UserPromptSubmit", { prompt: "I am changing something" });
		hook(dir, "Stop");
		return approve(r);
	});
	await h.controller.idle();
	expect(h.errors[0]?.message).toContain("became active");
	expect(load(dir).phase).toBe("code_review");
});

test("existing implementor is reused; a missing terminal resumes the recorded Claude UUID", async () => {
	const { dir } = setup();
	initialize(dir);
	const id = load(dir).implementor.session;
	let alive = false;
	const launches: boolean[] = [];
	const fake: Implementor = {
		alive: () => alive,
		start: (_dir, s, resume) => {
			expect(s.implementor.session).toBe(id);
			launches.push(resume);
			alive = true;
		},
		wake: () => {},
	};
	const h = manage(dir, approve, fake);
	await h.controller.idle();
	h.controller.kick();
	await h.controller.idle();
	expect(launches).toEqual([false]);
	await h.controller.close();
	alive = false;
	const resumed = manage(dir, approve, fake);
	await resumed.controller.idle();
	expect(launches).toEqual([false, true]);
});

test("pause survives restart and does not stop or wake Claude", async () => {
	const { dir } = setup();
	initialize(dir);
	update(dir, "paused", (s) => {
		s.paused = true;
	});
	const h = manage(dir, approve);
	await h.controller.idle();
	expect(h.calls).toEqual([]);
	expect(h.activity.at(-1)).toContain("paused");
});
