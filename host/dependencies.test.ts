// SPDX-License-Identifier: GPL-3.0-or-later
// The editor bundle holds the dependency releases docs/dependency-security.md
// chose. Reads the build's record of the bundle's inputs.
import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const host = import.meta.dir;

async function bundled(): Promise<string[]> {
	return JSON.parse(
		await readFile(join(host, ".generated", "editor-inputs.json"), "utf8"),
	);
}

// Excalidraw pins nanoid 3.3.3, and mermaid-to-excalidraw, which turns
// pasted Mermaid text into a drawing, pins 4.0.2; the override replaces both.
test("one nanoid, the overriding release, serves Excalidraw and its Mermaid import", async () => {
	const inputs = await bundled();
	expect(inputs.filter((input) => /(^|\/)nanoid\//.test(input))).toEqual([
		"node_modules/nanoid/index.browser.js",
	]);
	expect(
		inputs.some((input) =>
			input.startsWith("node_modules/@excalidraw/mermaid-to-excalidraw/"),
		),
	).toBe(true);
	const manifest = JSON.parse(
		await readFile(
			join(host, "node_modules", "nanoid", "package.json"),
			"utf8",
		),
	);
	expect(manifest.version).toBe("3.3.20");
});

test("the bundled nanoid makes the IDs its callers ask for", async () => {
	const { nanoid } = await import(
		join(host, "node_modules", "nanoid", "index.browser.js")
	);
	for (const [size, length] of [
		[undefined, 21],
		[40, 40],
	]) {
		const id = nanoid(size);
		expect(id).toMatch(/^[A-Za-z0-9_-]+$/);
		expect(id).toHaveLength(length);
	}
});
