// SPDX-License-Identifier: GPL-3.0-or-later
// The compiled host runs on its own: no Bun, sources or assets beside it.
import { expect, test } from "bun:test";
import { copyFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const build = process.env.PORTAL_BUILD ?? join(import.meta.dir, "..", "build");

test("a relocated host serves its pages and bundled assets", async () => {
	const directory = await mkdtemp(join(tmpdir(), "portal-standalone-"));
	const program = join(directory, "host");
	await copyFile(join(build, "portal-host"), program);
	const host = Bun.spawn([program], {
		cwd: directory,
		env: { PATH: "/nonexistent" },
		stdin: "pipe",
		stdout: "pipe",
		stderr: "inherit",
	});
	try {
		let line = "";
		const decoder = new TextDecoder();
		for await (const chunk of host.stdout) {
			line += decoder.decode(chunk, { stream: true });
			if (line.includes("\n")) break;
		}
		const ready = JSON.parse(line);
		expect(ready).toEqual({
			type: "ready",
			protocol: 3,
			port: expect.any(Number),
			token: expect.stringMatching(/^[0-9a-f]{32}$/),
		});
		const base = `http://127.0.0.1:${ready.port}/${ready.token}`;
		for (const path of [
			"/hello",
			"/excalidraw/",
			"/excalidraw/assets/editor-bootstrap.js",
			"/excalidraw/assets/editor-bootstrap.css",
			"/excalidraw/assets/fonts/Excalifont/Excalifont-Regular-a88b72a24fb54c9f94e3b5fdaa7481c9.woff2",
			"/assets/portal-256.png",
		]) {
			const response = await fetch(base + path);
			expect([path, response.status]).toEqual([path, 200]);
			expect(response.headers.get("cache-control")).toBe("no-store");
			await response.arrayBuffer();
		}
		expect((await fetch(`${base}/missing`)).status).toBe(404);
		// Closing its stdin is the host's signal to stop.
		host.stdin.end();
		expect(await host.exited).toBe(0);
	} finally {
		host.kill();
		await rm(directory, { recursive: true, force: true });
	}
});
