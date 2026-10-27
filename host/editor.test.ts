// SPDX-License-Identifier: GPL-3.0-or-later
// The drawing editor works offline: everything it loads comes from the host.
import { expect, test } from "bun:test";
import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { assets } from "./.generated/assets";
import { respond } from "./app";

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

test("the host serves every file of the editor bundle", async () => {
	const outdir = join(import.meta.dir, ".generated", "editor");
	for (const name of await readdir(outdir)) {
		expect(assets.has(`/excalidraw/assets/${name}`)).toBe(true);
	}
});

test("everything the editor page loads is served by the host", async () => {
	const page = await (await get("/excalidraw/")).text();
	const references = [...page.matchAll(/(?:href|src)="([^"]+)"/g)].map(
		(match) => match[1] ?? "",
	);
	expect(references).toContain("./assets/editor-bootstrap.js");
	expect(references).toContain("./assets/editor-bootstrap.css");
	for (const reference of references) {
		const path = new URL(reference, "http://host/excalidraw/").pathname;
		expect([path, (await get(path)).status]).toEqual([path, 200]);
	}
});

test("the bundle's lazy modules and fonts are served by the host", async () => {
	// The bootstrap sets the bundle's asset path to /excalidraw/assets/.
	const references = new Set<string>();
	for (const [path, asset] of assets) {
		if (!/^\/excalidraw\/assets\/[^/]+\.(?:js|css)$/.test(path)) continue;
		const text = await Bun.file(asset.file).text();
		for (const match of text.matchAll(
			/["'`(]\.\/([\w./-]+\.(?:js|css|woff2))["'`)]/g,
		)) {
			references.add(`/excalidraw/assets/${match[1]}`);
		}
	}
	const fonts = [...references].filter((path) => path.endsWith(".woff2"));
	expect(fonts).toContain(
		"/excalidraw/assets/fonts/Excalifont/Excalifont-Regular-a88b72a24fb54c9f94e3b5fdaa7481c9.woff2",
	);
	for (const path of references) {
		expect([path, assets.has(path)]).toEqual([path, true]);
	}
	for (const path of fonts) {
		const response = await get(path);
		expect(response.headers.get("content-type")).toBe("font/woff2");
		expect((await response.arrayBuffer()).byteLength).toBeGreaterThan(0);
	}
	expect(
		(await get("/excalidraw/assets/editor-bootstrap.js")).headers.get(
			"content-type",
		),
	).toBe("text/javascript; charset=utf-8");
});

test("the editor may load nothing from the network", async () => {
	// Excalidraw falls back to a CDN for fonts it cannot load; the policy
	// must refuse that and any other remote request.
	const policy = (await get("/excalidraw/")).headers.get(
		"content-security-policy",
	);
	expect(policy).not.toBeNull();
	const directives = (policy ?? "")
		.split(";")
		.map((directive) => directive.trim().split(/\s+/));
	expect(directives.map(([name]) => name)).toContain("default-src");
	expect(policy).toContain("font-src 'self' data:");
	expect(policy).toContain("connect-src 'self'");
	for (const [name, ...sources] of directives) {
		for (const source of sources) {
			expect([name, source]).toEqual([
				name,
				expect.stringMatching(
					/^(?:'none'|'self'|'unsafe-inline'|'wasm-unsafe-eval'|data:|blob:)$/,
				),
			]);
		}
	}
});
