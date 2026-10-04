// SPDX-License-Identifier: GPL-3.0-or-later
import { expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
	DefaultResourceLoader,
	type ExtensionAPI,
	type ExtensionCommandContext,
	SettingsManager,
	type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import taskExtension from "../index.ts";
import { initialize, load, update } from "../store.ts";
import { fixture } from "./support.ts";

test("slash command registration is inert; resumption/status/errors do not invoke the parent model", async () => {
	const f = fixture();
	initialize(f.dir);
	update(f.dir, "paused", (s) => {
		s.paused = true;
	});
	let handler:
		| ((args: string, ctx: ExtensionCommandContext) => Promise<void>)
		| undefined;
	let shutdown: (() => Promise<void>) | undefined;
	let repairTool: ToolDefinition | undefined;
	let consent = false;
	const messages: { content: string; triggerTurn: boolean | undefined }[] = [];
	taskExtension({
		registerTool: (tool: ToolDefinition) => {
			repairTool = tool;
		},
		on: (name: string, fn: () => Promise<void>) => {
			if (name === "session_shutdown") shutdown = fn;
		},
		registerCommand: (name: string, cmd: { handler: typeof handler }) => {
			expect(name).toBe("task");
			handler = cmd.handler;
		},
		sendMessage: (
			message: { content: string },
			options: { triggerTurn?: boolean },
		) => {
			messages.push({
				content: message.content,
				triggerTurn: options.triggerTurn,
			});
		},
	} as unknown as ExtensionAPI);
	const ctx = {
		cwd: f.repo,
		hasUI: true,
		modelRegistry: {},
		ui: { notify: () => {}, setStatus: () => {}, confirm: async () => consent },
	} as unknown as ExtensionCommandContext;
	const toolContext = ctx as unknown as Parameters<
		ToolDefinition["execute"]
	>[4];
	try {
		expect(messages).toEqual([]);
		if (!handler) throw new Error("Command not registered");
		await handler("", ctx);
		expect(messages.at(-1)?.content).toContain("Usage:");
		await handler("./nonexistent.md", ctx);
		expect(messages.at(-1)?.content).toContain("does not exist");
		await handler(f.dir, ctx);
		await handler("status", ctx);
		expect(messages.at(-1)?.content).toContain("Attach: tmux");
		await handler("pause", ctx);
		if (!repairTool) throw new Error("Repair tool not registered");
		const before = load(f.dir);
		const args = {
			expected_version: before.version,
			action: "retry_implementation",
			reason: "Explicit recovery test",
		};
		await expect(
			repairTool.execute(
				"repair",
				args,
				new AbortController().signal,
				undefined,
				toolContext,
			),
		).rejects.toThrow("declined");
		expect(load(f.dir)).toEqual(before);
		consent = true;
		await repairTool.execute(
			"repair",
			args,
			new AbortController().signal,
			undefined,
			toolContext,
		);
		expect(load(f.dir).paused).toBe(true);
		expect(load(f.dir).version).toBe(before.version + 1);
		expect(messages.every((message) => message.triggerTurn === false)).toBe(
			true,
		);
	} finally {
		await shutdown?.();
		rmSync(f.root, { recursive: true, force: true });
	}
});

test("the installed pi resource loader loads the opt-in package without agent requests or ambient resources", async () => {
	const f = fixture();
	try {
		const loader = new DefaultResourceLoader({
			cwd: f.repo,
			agentDir: `${f.root}/agent`,
			settingsManager: SettingsManager.inMemory(),
			noExtensions: true,
			noSkills: true,
			noPromptTemplates: true,
			noThemes: true,
			noContextFiles: true,
			additionalExtensionPaths: [
				fileURLToPath(new URL("../index.ts", import.meta.url)),
			],
		});
		await loader.reload();
		expect(loader.getExtensions().errors).toEqual([]);
		expect(loader.getExtensions().extensions).toHaveLength(1);
	} finally {
		rmSync(f.root, { recursive: true, force: true });
	}
});
