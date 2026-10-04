// SPDX-License-Identifier: GPL-3.0-or-later

import path from "node:path";
import type {
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { TaskController } from "./controller.ts";
import { piReviewer } from "./reviewer.ts";
import {
	acquireLock,
	createTask,
	decide,
	event,
	load,
	parseInput,
	repair,
	update,
} from "./store.ts";
import { preflight, tmuxImplementor } from "./transport.ts";

export default function taskExtension(pi: ExtensionAPI) {
	let controller: TaskController | undefined;
	let directory: string | undefined;
	let executing = false;
	const stop = async () => {
		const previous = controller;
		controller = undefined;
		await previous?.close();
	};
	const report = (ctx: ExtensionContext, content: string) => {
		pi.sendMessage(
			{ customType: "task", content, display: true },
			{ triggerTurn: false },
		);
		if (ctx.hasUI) ctx.ui.notify(content, "info");
	};
	const start = (dir: string, ctx: ExtensionContext) => {
		directory = dir;
		controller = new TaskController(
			dir,
			tmuxImplementor,
			piReviewer(ctx.modelRegistry),
			{
				state: (s, activity) => {
					if (ctx.hasUI)
						ctx.ui.setStatus(
							"task",
							`${s.id}: ${activity.replace(/\p{Cc}/gu, " ").slice(0, 180)}`,
						);
					if (s.phase === "needs_human_decision" || s.phase === "approved") {
						const message = `${s.id}: ${s.phase}\n${s.question ?? s.feedback ?? ""}\nTask: ${dir}`;
						// Transition notifications, not every watcher callback or streaming token.
						if (lastNotice !== `${dir}:${s.version}`) {
							lastNotice = `${dir}:${s.version}`;
							report(ctx, message);
						}
					}
				},
				error: (error) => {
					if (ctx.hasUI) {
						ctx.ui.setStatus("task", "task stopped: repair required");
						ctx.ui.notify(error.message, "error");
					}
					pi.sendMessage(
						{
							customType: "task-error",
							display: true,
							content: `Cannot continue ${dir}: ${error.message}\nAutomatic management stopped; Claude may still be running. Inspect state.json and events.jsonl. Resume with /task ${dir} after resolving the issue.`,
						},
						{ triggerTurn: false },
					);
				},
			},
		);
		controller.start();
	};
	let lastNotice = "";
	pi.on("session_shutdown", async () => {
		await stop();
	});
	pi.registerTool({
		name: "repair_task",
		label: "Repair selected task",
		description:
			"Only for user-requested recovery after inspecting task files, Git and events.jsonl. Requires human confirmation. Discards an invalid result or retries implementation; never manufactures approval. Leaves management paused.",
		parameters: Type.Object({
			expected_version: Type.Integer({ minimum: 0 }),
			action: Type.Union([
				Type.Literal("retry_review"),
				Type.Literal("retry_implementation"),
			]),
			reason: Type.String({ minLength: 1 }),
		}),
		async execute(_id, args, signal, _onUpdate, ctx) {
			if (!directory)
				throw new Error("Select the task with /task DIRECTORY first");
			if (!ctx.hasUI)
				throw new Error("Repair requires an interactive human confirmation");
			if (executing) throw new Error("Another task operation is active");
			executing = true;
			try {
				if (
					!(await ctx.ui.confirm(
						"Repair task?",
						`${directory}\n${args.action}\n${args.reason}\nThis does not approve anything; the task remains paused.`,
					))
				)
					throw new Error("Repair declined");
				signal?.throwIfAborted();
				await stop();
				signal?.throwIfAborted();
				const release = acquireLock(path.join(directory, ".coordinator.lock"));
				try {
					const state = repair(
						directory,
						args.expected_version,
						args.action,
						args.reason,
					);
					return {
						content: [
							{
								type: "text",
								text: `Repair recorded at version ${state.version}. Inspect the result, then /task resume.`,
							},
						],
						details: state,
					};
				} finally {
					release();
				}
			} finally {
				executing = false;
			}
		},
	});
	pi.registerCommand("task", {
		description:
			"Start/resume a durable Claude → pi review loop: /task FILE|DIRECTORY|instruction. Also status, pause, resume, decide ANSWER, retry.",
		handler: async (raw, ctx) => {
			if (executing) {
				if (ctx.hasUI)
					ctx.ui.notify("Another /task command is still running", "warning");
				return;
			}
			executing = true;
			try {
				const args = raw.trim();
				if (!args) {
					report(
						ctx,
						"Usage: /task tasks/implement.md | /task Fix the bug | /task TASK_DIRECTORY\n/task status | pause | resume | decide ANSWER | retry\nQuotes are optional. --text forces a literal instruction.",
					);
					return;
				}
				if (
					["status", "pause", "resume", "retry"].includes(args) ||
					args.startsWith("decide ")
				) {
					if (!directory)
						throw new Error("No task selected; use /task TASK_DIRECTORY first");
					if (args === "status") {
						const s = load(directory);
						report(
							ctx,
							`${JSON.stringify(s, null, 2)}\nTask: ${directory}\nAttach: tmux attach-session -t ${s.implementor.tmux}`,
						);
						return;
					}
					await stop();
					if (args === "pause") {
						update(directory, "paused", (s) => {
							s.paused = true;
						});
						if (ctx.hasUI)
							ctx.ui.setStatus(
								"task",
								"paused; Claude remains available in tmux",
							);
						report(
							ctx,
							"Automatic handoffs paused. This does not interrupt Claude; attach to co-drive.",
						);
						return;
					}
					if (args.startsWith("decide ")) decide(directory, args.slice(7));
					else if (args === "retry") {
						update(directory, "human_wakeup_retry", (s) => {
							if (s.phase !== "implementing")
								throw new Error(
									"retry only reissues an implementor wake-up; it does not repair reviews",
								);
							s.implementor.wake = "pending";
						});
					}
					update(directory, "resumed", (s) => {
						s.paused = false;
					});
					start(directory, ctx);
					return;
				}
				const input = parseInput(args, ctx.cwd);
				if (input.kind === "resume") {
					await stop();
					start(input.directory, ctx);
					report(ctx, `Managing task: ${input.directory}`);
					return;
				}
				if (controller)
					throw new Error("Pause the current task before starting another");
				if (!ctx.model)
					throw new Error(
						"Select a reviewer model in pi before starting a task",
					);
				preflight();
				const dir = createTask(ctx.cwd, input.content, {
					provider: ctx.model.provider,
					model: ctx.model.id,
				});
				directory = dir;
				if (input.kind === "file")
					event(dir, "task_source", { file: input.file });
				start(dir, ctx);
				const s = load(dir);
				report(
					ctx,
					`Started ${s.id}\nTask: ${dir}\nWorktree: ${s.worktree}\nAttach: tmux attach-session -t ${s.implementor.tmux}\nReviewer: ${s.reviewer.provider}/${s.reviewer.model}`,
				);
			} catch (error) {
				const message = String(error);
				if (ctx.hasUI) ctx.ui.notify(message, "error");
				pi.sendMessage(
					{
						customType: "task-error",
						content: `${message}${directory ? `\nTask: ${directory}` : ""}`,
						display: true,
					},
					{ triggerTurn: false },
				);
			} finally {
				executing = false;
			}
		},
	});
}
