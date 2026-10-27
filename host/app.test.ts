// SPDX-License-Identifier: GPL-3.0-or-later
// Routing and headers, through the same function the listener calls.
import { expect, test } from "bun:test";
import { respond } from "./app";

const authority = "127.0.0.1:4321";
const token = "0123456789abcdef0123456789abcdef";

function get(
	path: string,
	{ method = "GET", host = authority, prefix = `/${token}` } = {},
): Promise<Response> {
	return respond(
		new Request(`http://${authority}${prefix}${path}`, {
			method,
			headers: { Host: host },
		}),
		authority,
		token,
	);
}

test("pages are HTML that is never cached, sniffed or referred", async () => {
	for (const path of ["/hello", "/dialogs", "/about", "/excalidraw/"]) {
		const response = await get(path);
		expect(response.status).toBe(200);
		expect(response.headers.get("content-type")).toBe(
			"text/html; charset=utf-8",
		);
		expect(response.headers.get("cache-control")).toBe("no-store");
		expect(response.headers.get("referrer-policy")).toBe("no-referrer");
		expect(response.headers.get("x-content-type-options")).toBe("nosniff");
	}
	expect(await (await get("/hello")).text()).toContain(
		"<h1>Hello, world!</h1>",
	);
	expect(await (await get("/dialogs")).text()).toContain(
		"<title>Dialogs</title>",
	);
});

test("unknown routes are not found", async () => {
	for (const path of ["/missing", "/", "/excalidraw", "/assets/missing.png"]) {
		expect((await get(path)).status).toBe(404);
	}
});

test("a wrong capability or Host header never reaches a route", async () => {
	expect((await get("/markdown", { prefix: `/${token}wrong` })).status).toBe(
		404,
	);
	expect((await get("/markdown", { prefix: "" })).status).toBe(404);
	expect((await get("/hello", { host: "example.invalid" })).status).toBe(404);
	expect((await get("/hello", { host: "localhost:4321" })).status).toBe(404);
	expect((await get("/hello", { host: "127.0.0.1:1" })).status).toBe(404);
});

test("only GET and HEAD are allowed", async () => {
	const response = await get("/markdown", { method: "POST" });
	expect(response.status).toBe(405);
	expect(response.headers.get("allow")).toBe("GET, HEAD");
	const head = await get("/hello", { method: "HEAD" });
	expect(head.status).toBe(200);
	expect(head.headers.get("content-type")).toBe("text/html; charset=utf-8");
	expect(head.headers.get("cache-control")).toBe("no-store");
	expect(await head.text()).toBe("");
});

test("the about page names versions as text", async () => {
	const response = await get(
		`/about?portal=1.2.3&emacs=${encodeURIComponent("31.1<script>alert(1)</script>")}`,
	);
	expect(response.headers.get("content-security-policy")).toStartWith(
		"default-src 'none'",
	);
	const page = await response.text();
	expect(page).toMatch(/portal \.+ 1\.2\.3</);
	// Emacs supplies the versions; the page shows them, never runs them.
	expect(page).toMatch(/emacs \.+ 31\.1&lt;script&gt;/);
	expect(page).not.toContain("<script>alert");
	expect(page).toMatch(/bun \.+ \d+\.\d+\.\d+</);
	expect(page).not.toContain("{{");
	const bare = await (await get("/about")).text();
	expect(bare).toMatch(/portal \.+ unknown</);
	expect(bare).toMatch(/emacs \.+ unknown</);
});

test("the icons are served as PNG", async () => {
	for (const size of [32, 64, 256]) {
		const response = await get(`/assets/portal-${size}.png`);
		expect(response.status).toBe(200);
		expect(response.headers.get("content-type")).toBe("image/png");
	}
});
