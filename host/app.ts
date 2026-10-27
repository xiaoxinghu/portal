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

async function dispatch(
	request: Request,
	authority: string,
	token: string,
): Promise<Response> {
	const url = new URL(request.url);
	if (
		request.headers.get("host") !== authority ||
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

/** The host's response to REQUEST, made to its listener at AUTHORITY, such
 * as 127.0.0.1:8080. Only paths under the private TOKEN reach a page or file. */
export async function respond(
	request: Request,
	authority: string,
	token: string,
): Promise<Response> {
	const response = await dispatch(request, authority, token);
	response.headers.set("Cache-Control", "no-store");
	response.headers.set("Referrer-Policy", "no-referrer");
	response.headers.set("X-Content-Type-Options", "nosniff");
	return request.method === "HEAD"
		? new Response(null, {
				status: response.status,
				headers: response.headers,
			})
		: response;
}
