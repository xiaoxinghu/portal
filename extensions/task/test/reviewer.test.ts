// SPDX-License-Identifier: GPL-3.0-or-later
import { afterEach, expect, test } from "bun:test";
import { rmSync } from "node:fs";
import {
	type CreateAgentSessionOptions,
	createAgentSession,
	type ExtensionContext,
	SessionManager,
	type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { piReviewer, reviewerResources } from "../reviewer.ts";
import { fixture, implementation } from "./support.ts";

const roots: string[] = [];
afterEach(() => {
	for (const root of roots.splice(0))
		rmSync(root, { recursive: true, force: true });
});
const registry = {
	find: () => ({ provider: "test", id: "reviewer" }),
} as unknown as ExtensionContext["modelRegistry"];

test("SDK reviews have independent sessions, explicit tools/resources and only file-pointer prompts", async () => {
	const f = fixture();
	roots.push(f.root);
	const state = implementation(f.dir);
	const sessionIds: string[] = [];
	let disposed = 0;
	let bound = 0;
	const reviewer = piReviewer(registry, (async (
		options: CreateAgentSessionOptions | undefined,
	) => {
		if (!options) throw new Error("Options required");
		expect(options.tools).toEqual([
			"read",
			"grep",
			"find",
			"ls",
			"submit_review",
		]);
		expect(options.resourceLoader?.getExtensions().extensions).toEqual([]);
		expect(options.resourceLoader?.getSkills().skills).toEqual([]);
		expect(options.resourceLoader?.getAgentsFiles().agentsFiles).toEqual([]);
		const id = options.sessionManager?.getSessionId() ?? "";
		sessionIds.push(id);
		const tool = options.customTools?.[0] as ToolDefinition;
		const session = {
			sessionFile: `/saved/${id}.jsonl`,
			messages: [{ role: "assistant", stopReason: "stop" }],
			bindExtensions: async () => {
				bound++;
			},
			subscribe: () => () => {},
			prompt: async (prompt: string) => {
				expect(prompt).toBe(
					`Read and execute ${f.dir}/.runtime/review-request.md`,
				);
				expect(prompt).not.toContain("Fix source");
				await tool.execute(
					"tool-1",
					{
						round: state.review_round,
						reviewed_commit: state.submitted_commit,
						outcome: "approved",
						content: "Reviewed.",
					},
					new AbortController().signal,
					undefined,
					{} as Parameters<ToolDefinition["execute"]>[4],
				);
			},
			abort: async () => {},
			dispose: () => {
				disposed++;
			},
		};
		return { session, extensionsResult: { extensions: [], errors: [] } };
	}) as unknown as typeof createAgentSession);
	for (let i = 0; i < 2; i++) {
		const result = await reviewer({
			directory: f.dir,
			checkout: state.worktree,
			state,
			signal: new AbortController().signal,
			progress: () => {},
			started: () => {},
		});
		expect(result.outcome).toBe("approved");
	}
	expect(sessionIds[0]).not.toBe(sessionIds[1]);
	expect(disposed).toBe(2);
	expect(bound).toBe(2);
});

test("a candidate followed by provider failure, abort, or missing submission is not a completed review", async () => {
	const f = fixture();
	roots.push(f.root);
	const state = implementation(f.dir);
	for (const mode of [
		"error",
		"aborted",
		"missing",
		"wrong-commit",
		"conflict",
	]) {
		let disposed = false;
		const reviewer = piReviewer(registry, (async (
			options: CreateAgentSessionOptions | undefined,
		) => {
			const tool = options?.customTools?.[0] as ToolDefinition;
			return {
				session: {
					sessionFile: "/saved/session.jsonl",
					messages: [
						{
							role: "assistant",
							stopReason: ["missing", "conflict"].includes(mode)
								? "stop"
								: mode,
						},
					],
					bindExtensions: async () => {},
					subscribe: () => () => {},
					abort: async () => {},
					prompt: async () => {
						if (mode !== "missing")
							await tool.execute(
								"id",
								{
									round: state.review_round,
									reviewed_commit:
										mode === "wrong-commit"
											? "a".repeat(40)
											: state.submitted_commit,
									outcome: "approved",
									content: "Candidate.",
								},
								new AbortController().signal,
								undefined,
								{} as Parameters<ToolDefinition["execute"]>[4],
							);
						if (mode === "conflict") {
							try {
								await tool.execute(
									"second",
									{
										round: state.review_round,
										reviewed_commit: state.submitted_commit,
										outcome: "changes_required",
										content: "Actually, fix this.",
									},
									new AbortController().signal,
									undefined,
									{} as Parameters<ToolDefinition["execute"]>[4],
								);
							} catch {
								/* Simulate the model receiving a tool error and then stopping. */
							}
						}
					},
					dispose: () => {
						disposed = true;
					},
				},
			};
		}) as unknown as typeof createAgentSession);
		await expect(
			reviewer({
				directory: f.dir,
				checkout: state.worktree,
				state,
				signal: new AbortController().signal,
				progress: () => {},
				started: () => {},
			}),
		).rejects.toThrow();
		expect(disposed).toBe(true);
	}
});

test("real installed SDK creates and binds an isolated read-only session without a model request", async () => {
	const f = fixture();
	roots.push(f.root);
	const { session } = await createAgentSession({
		cwd: f.repo,
		sessionManager: SessionManager.create(f.repo, `${f.root}/sessions`),
		resourceLoader: reviewerResources("Independent reviewer"),
		tools: ["read", "grep", "find", "ls"],
	});
	try {
		await session.bindExtensions({});
		expect(session.getActiveToolNames()).toEqual([
			"read",
			"grep",
			"find",
			"ls",
		]);
		expect(session.messages).toEqual([]);
		expect(session.sessionFile).toBeTruthy();
	} finally {
		session.dispose();
	}
});
