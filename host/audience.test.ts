// SPDX-License-Identifier: GPL-3.0-or-later
// The slide window's page: served by the host, offline, and apart from the
// editor, whose bundle it never loads.
import { expect, test } from "bun:test";
import { assets } from "./.generated/assets";
import { respond } from "./app";
import { presentKey, stepSlide } from "./present";

const authority = "127.0.0.1:4321";
const token = "0123456789abcdef0123456789abcdef";

function get(path: string): Promise<Response> {
	return respond(
		new Request(`http://${authority}/${token}${path}`, {
			headers: { Host: authority },
		}),
		authority,
		token,
	);
}

test("the host serves the slide window's page beside the editor's", async () => {
	const response = await get("/excalidraw/audience");
	expect(response.status).toBe(200);
	expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
	expect(await response.text()).toContain('<img id="slide"');
	expect((await get("/excalidraw/audience/")).status).toBe(404);
});

test("the slide window's page loads its one script, which is not the editor's", async () => {
	const page = await (await get("/excalidraw/audience")).text();
	const references = [...page.matchAll(/(?:href|src)="([^"]+)"/g)].map(
		(match) => match[1],
	);
	expect(references).toEqual(["./audience.js"]);
	const script = await get("/excalidraw/audience.js");
	expect(script.status).toBe(200);
	expect(script.headers.get("content-type")).toBe(
		"text/javascript; charset=utf-8",
	);
	const text = await script.text();
	// One self-contained file: it imports no chunk, and nothing of Excalidraw
	// or React is in it.
	expect(text).not.toMatch(/\bimport\s*\(|\bfrom\s*["']|\bimport\s*["']/);
	expect(text).not.toMatch(/excalidraw|react/i);
	expect(text.length).toBeLessThan(4000);
	// The editor's bundle stays where it was, and the slide window's is
	// not among its files.
	expect(assets.has("/excalidraw/assets/audience.js")).toBe(false);
	expect(assets.has("/excalidraw/assets/editor-bootstrap.js")).toBe(true);
});

test("the slide window's page may load nothing from the network", async () => {
	const policy =
		(await get("/excalidraw/audience")).headers.get(
			"content-security-policy",
		) ?? "";
	const directives = policy
		.split(";")
		.map((directive) => directive.trim().split(/\s+/));
	expect(directives.map(([name]) => name)).toContain("default-src");
	expect(policy).toContain("default-src 'none'");
	expect(policy).not.toContain("connect-src");
	for (const [name, ...sources] of directives) {
		for (const source of sources) {
			expect([name, source]).toEqual([
				name,
				expect.stringMatching(
					/^(?:'none'|'self'|'unsafe-inline'|data:|blob:)$/,
				),
			]);
		}
	}
});

const plain = {
	metaKey: false,
	ctrlKey: false,
	altKey: false,
	shiftKey: false,
};

test("presenting keys: the arrows, Space and a clicker's pages move, Escape stops", () => {
	const keys = [
		"ArrowRight",
		"ArrowDown",
		" ",
		"PageDown",
		"ArrowLeft",
		"ArrowUp",
		"PageUp",
		"Home",
		"End",
		"Escape",
		"Enter",
		"a",
		"constructor",
	];
	expect(keys.map((key) => presentKey({ ...plain, key }))).toEqual([
		"next",
		"next",
		"next",
		"next",
		"previous",
		"previous",
		"previous",
		"first",
		"last",
		"stop",
		undefined,
		undefined,
		undefined,
	]);
	// A chord is never a presenting key, so Command-S still saves.
	for (const modifier of ["metaKey", "ctrlKey", "altKey", "shiftKey"])
		expect(
			presentKey({ ...plain, [modifier]: true, key: "ArrowRight" }),
		).toBeUndefined();
});

test("moving through slides stays within them", () => {
	expect(stepSlide("next", 0, 3)).toBe(1);
	expect(stepSlide("next", 2, 3)).toBe(2);
	expect(stepSlide("previous", 0, 3)).toBe(0);
	expect(stepSlide("previous", 2, 3)).toBe(1);
	expect(stepSlide("first", 2, 3)).toBe(0);
	expect(stepSlide("last", 0, 3)).toBe(2);
	expect(stepSlide("last", 0, 0)).toBe(0);
	expect(stepSlide("stop", 1, 3)).toBeUndefined();
});
