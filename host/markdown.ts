// SPDX-License-Identifier: GPL-3.0-or-later
import { access, constants, stat } from "node:fs/promises";
import { basename, extname, isAbsolute } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import styles from "./markdown.css" with { type: "text" };

function page(title: string, body: string, status = 200): Response {
	return new Response(
		`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${Bun.escapeHTML(title)}</title>
  <link rel="icon" type="image/png" sizes="32x32" href="assets/portal-32.png">
  <link rel="icon" type="image/png" sizes="64x64" href="assets/portal-64.png">
  <style>${styles}</style>
</head>
<body><main>${body}</main></body>
</html>`,
		{
			status,
			headers: {
				"Content-Type": "text/html; charset=utf-8",
				// Markdown is a document, not executable application code.
				"Content-Security-Policy":
					"default-src 'none'; style-src 'unsafe-inline'; img-src 'self' https: http: data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
			},
		},
	);
}

function errorPage(message: string, status: number): Response {
	return page(
		"Markdown preview unavailable",
		`<h1>Cannot preview this file</h1><p>${Bun.escapeHTML(message)}</p>`,
		status,
	);
}

// The extensions `portal-render-markdown' accepts, in any case.
const markdownFile = /\.(?:md|markdown|mdown|mkd|mkdn)$/i;

// The image types `image' serves, by extension in any case.
const imageTypes: Record<string, string> = {
	".apng": "image/apng",
	".avif": "image/avif",
	".bmp": "image/bmp",
	".gif": "image/gif",
	".ico": "image/x-icon",
	".jpeg": "image/jpeg",
	".jpg": "image/jpeg",
	".png": "image/png",
	".svg": "image/svg+xml",
	".webp": "image/webp",
};

// The named character references `decodeAttribute' knows: those Bun writes,
// and &apos;. A Map, so a name such as `constructor' finds nothing.
const namedReferences = new Map([
	["amp", "&"],
	["lt", "<"],
	["gt", ">"],
	["quot", '"'],
	["apos", "'"],
]);

/** The attribute VALUE, as written in HTML, as a browser reads it.
 * HTMLRewriter returns values as written: Bun's own output writes &#x27;,
 * and raw HTML may use any numeric reference. Other named references, such
 * as &eacute;, are rare in URLs and stay as written. */
export function decodeAttribute(value: string): string {
	return value.replace(
		/&(?:#(\d+)|#[xX]([\da-fA-F]+)|([a-zA-Z]+));/g,
		(reference, decimal?: string, hex?: string, name?: string) => {
			if (name) return namedReferences.get(name) ?? reference;
			const code = decimal ? Number(decimal) : Number.parseInt(hex ?? "", 16);
			// As HTML does: NUL, surrogates and beyond Unicode read as U+FFFD.
			const valid =
				code > 0 && code <= 0x10ffff && (code < 0xd800 || code > 0xdfff);
			return valid ? String.fromCodePoint(code) : "�";
		},
	);
}

/** The local file that HREF in the Markdown file at PATH names, with its
 * fragment, or null when HREF is a fragment or not a local file. */
function localFile(
	href: string,
	path: string,
): { file: string; hash: string } | null {
	if (href.startsWith("#") || href.startsWith("//")) return null;
	if (/^[a-z][a-z\d+.-]*:/i.test(href) && !/^file:/i.test(href)) return null;
	try {
		const url = new URL(href, pathToFileURL(path));
		if (url.protocol !== "file:") return null;
		return { file: fileURLToPath(url), hash: url.hash };
	} catch {
		return null;
	}
}

/** Where a link in the Markdown file at PATH should go, or null to leave it.
 * Local Markdown files open in this preview, as a URL relative to it; other
 * local files and directories become file: URLs, which Emacs visits. */
export function linkTarget(href: string, path: string): string | null {
	const local = localFile(href, path);
	if (!local) return null;
	if (markdownFile.test(local.file)) {
		return `markdown?path=${encodeURIComponent(local.file)}${local.hash}`;
	}
	return pathToFileURL(local.file).href + local.hash;
}

/** Where the preview loads an image in the Markdown file at PATH from, or
 * null to leave it. Local images load from this host, relative to the page. */
export function imageSource(src: string, path: string): string | null {
	const local = localFile(src, path);
	return local && `image?path=${encodeURIComponent(local.file)}${local.hash}`;
}

function rewrite(
	element: HTMLRewriterTypes.Element,
	name: string,
	target: (value: string) => string | null,
) {
	const value = target(decodeAttribute(element.getAttribute(name) ?? ""));
	// HTMLRewriter escapes only quotes in the values it writes.
	if (value !== null)
		element.setAttribute(name, value.replaceAll("&", "&amp;"));
}

/** The rendered body of the Markdown file at PATH, with local paths made to
 * load in the preview and raw `<meta>` elements dropped: the page's Content
 * Security Policy blocks scripts in raw HTML, but not a refresh that leaves. */
function rewriteBody(html: string, path: string): string {
	return new HTMLRewriter()
		.on("meta", {
			element(meta) {
				meta.remove();
			},
		})
		.on("a[href]", {
			element(link) {
				rewrite(link, "href", (href) => linkTarget(href, path));
			},
		})
		.on("img[src]", {
			element(image) {
				rewrite(image, "src", (src) => imageSource(src, path));
			},
		})
		.transform(html);
}

/** The local image file at PATH, for a preview to show inline. */
export async function image(path: string | null): Promise<Response> {
	const type = path && imageTypes[extname(path).toLowerCase()];
	if (!path || !isAbsolute(path) || path.includes("\0") || !type) {
		return new Response("Not an image path", { status: 400 });
	}
	try {
		if (!(await stat(path)).isFile()) {
			return new Response("Not a file", { status: 400 });
		}
		// Fail here, not mid-stream, when the file is unreadable.
		await access(path, constants.R_OK);
		return new Response(Bun.file(path), {
			headers: {
				"Content-Type": type,
				// An SVG opened as a page must not run its scripts here.
				"Content-Security-Policy":
					"default-src 'none'; style-src 'unsafe-inline'; sandbox",
			},
		});
	} catch (error) {
		const code = (error as NodeJS.ErrnoException).code;
		if (code === "ENOENT" || code === "ENOTDIR") {
			return new Response("Not found", { status: 404 });
		}
		if (code === "EACCES" || code === "EPERM") {
			return new Response("Not readable", { status: 403 });
		}
		console.error("Markdown image failed:", error);
		return new Response("Not readable", { status: 500 });
	}
}

export async function markdown(path: string | null): Promise<Response> {
	if (!path || !isAbsolute(path) || path.includes("\0")) {
		return errorPage("Provide an absolute local file path.", 400);
	}
	try {
		if (!(await stat(path)).isFile()) {
			return errorPage("Choose a regular file.", 400);
		}
		const source = await Bun.file(path).text();
		const body = Bun.markdown.html(source, {
			tables: true,
			tasklists: true,
			strikethrough: true,
			headings: { ids: true },
			// Raw HTML, such as inline <svg>, renders; GFM's tag filter
			// escapes <script>, <style>, <iframe> and the like.
			tagFilter: true,
		});
		return page(basename(path), rewriteBody(body, path));
	} catch (error) {
		const code = (error as NodeJS.ErrnoException).code;
		if (code === "ENOENT" || code === "ENOTDIR") {
			return errorPage("The file could not be found.", 404);
		}
		if (code === "EACCES" || code === "EPERM") {
			return errorPage("The file is not readable.", 403);
		}
		console.error("Markdown preview failed:", error);
		return errorPage("The file could not be rendered.", 500);
	}
}
