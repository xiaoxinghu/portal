// SPDX-License-Identifier: GPL-3.0-or-later

import { assets } from "./.generated/assets";
import { about } from "./about";
import dialogs from "./dialogs.html" with { type: "text" };
import editor from "./excalidraw.html" with { type: "text" };
import hello from "./hello.html" with { type: "text" };
import { image, markdown } from "./markdown";

// Applies only to the local editor. Fonts, images and lazy modules cannot fall
// back to a CDN; user-authored URLs cannot embed remote pages or run scripts.
const editorPolicy =
	"default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; " +
	"style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data: blob:; " +
	"connect-src 'self'; worker-src 'self' blob:; base-uri 'none'; form-action 'none'; frame-src 'none'";

// A private URL capability, passed only through the parent's readiness pipe.
const token = crypto.randomUUID().replaceAll("-", "");

async function respond(request: Request): Promise<Response> {
	const url = new URL(request.url);
	if (
		request.headers.get("host") !== `127.0.0.1:${server.port}` ||
		!url.pathname.startsWith(`/${token}/`)
	) {
		return new Response("Not found", { status: 404 });
	}
	const route = url.pathname.slice(token.length + 1);
	const asset = assets.get(route);
	if (
		route !== "/hello" &&
		route !== "/about" &&
		route !== "/dialogs" &&
		route !== "/markdown" &&
		route !== "/image" &&
		route !== "/excalidraw/" &&
		!asset
	) {
		return new Response("Not found", { status: 404 });
	}
	if (request.method !== "GET" && request.method !== "HEAD") {
		return new Response("Method not allowed", {
			status: 405,
			headers: { Allow: "GET, HEAD" },
		});
	}
	if (route === "/markdown") return markdown(url.searchParams.get("path"));
	if (route === "/image") return image(url.searchParams.get("path"));
	if (route === "/about") return about(url.searchParams);
	if (route === "/dialogs")
		return new Response(dialogs, {
			headers: { "Content-Type": "text/html; charset=utf-8" },
		});
	if (asset)
		return new Response(Bun.file(asset.file), {
			headers: { "Content-Type": asset.type },
		});
	if (route === "/excalidraw/")
		return new Response(editor, {
			headers: {
				"Content-Type": "text/html; charset=utf-8",
				"Content-Security-Policy": editorPolicy,
			},
		});
	return new Response(hello, {
		headers: { "Content-Type": "text/html; charset=utf-8" },
	});
}

const server = Bun.serve({
	hostname: "127.0.0.1",
	port: 0,
	async fetch(request) {
		const response = await respond(request);
		response.headers.set("Cache-Control", "no-store");
		response.headers.set("Referrer-Policy", "no-referrer");
		response.headers.set("X-Content-Type-Options", "nosniff");
		return request.method === "HEAD"
			? new Response(null, {
					status: response.status,
					headers: response.headers,
				})
			: response;
	},
});

let stopping = false;
async function shutdown() {
	if (stopping) return;
	stopping = true;
	// Bound shutdown even if a client keeps a request open.
	setTimeout(() => process.exit(0), 1000);
	await server.stop();
	process.exit(0);
}

// The parent's pipe is also our lifetime: EOF covers an abrupt Emacs exit.
process.stdin.on("end", shutdown);
process.stdin.on("error", shutdown);
process.stdin.resume();
for (const signal of ["SIGHUP", "SIGTERM", "SIGINT"] as const) {
	process.on(signal, shutdown);
}
process.stdout.on("error", shutdown);

// stdout is a protocol channel. Send diagnostics to stderr instead.
process.stdout.write(
	JSON.stringify({ type: "ready", protocol: 3, port: server.port, token }) +
		"\n",
);
