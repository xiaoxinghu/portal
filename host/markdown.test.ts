// SPDX-License-Identifier: GPL-3.0-or-later
// Markdown previews and their local images, through the host's routes.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { respond } from "./app";
import { decodeAttribute, imageSource, linkTarget } from "./markdown";

const authority = "127.0.0.1:4321";
const token = "0123456789abcdef0123456789abcdef";

function get(path: string): Promise<Response> {
	return respond(
		new Request(`http://${authority}/${token}/${path}`, {
			headers: { Host: authority },
		}),
		authority,
		token,
	);
}

const preview = (path: string) => `markdown?path=${encodeURIComponent(path)}`;
const source = (path: string) => `image?path=${encodeURIComponent(path)}`;
const visit = (path: string) =>
	`file://${path.split("/").map(encodeURIComponent).join("/")}`;

// A pixel PNG, as written to disk and as served.
const png = Buffer.from(
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII=",
	"base64",
);

let directory: string;
let docs: string;
beforeEach(async () => {
	directory = await mkdtemp(join(tmpdir(), "portal-markdown-"));
	docs = join(directory, "docs é");
	await mkdir(join(docs, "img"), { recursive: true });
});
afterEach(async () => {
	await rm(directory, { recursive: true, force: true });
});

/** The first attribute value PATTERN captures in PAGE, as a browser reads it. */
function attribute(page: string, pattern: RegExp): string {
	const match = page.match(pattern);
	expect(match).not.toBeNull();
	return (match?.[1] ?? "").replaceAll("&amp;", "&");
}
const href = (page: string, text: string) =>
	attribute(
		page,
		new RegExp(`<a href="([^"]*)"[^>]*>${RegExp.escape(text)}</a>`),
	);
const src = (page: string, alt: string) =>
	attribute(page, new RegExp(`<img src="([^"]*)" alt="${RegExp.escape(alt)}"`));

test("saved files render as sanitised HTML and are reread on each request", async () => {
	const file = join(directory, "Résumé & <notes> #%?.md");
	await writeFile(
		file,
		"# Preview\n\n**Bold** and ~~old~~.\n\n" +
			"| Name | Value |\n| --- | --- |\n| One | Two |\n\n" +
			"- [x] Done\n\n```js\nconst value = 1 < 2;\n```\n",
	);
	const response = await get(preview(file));
	expect(response.status).toBe(200);
	expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
	expect(response.headers.get("content-security-policy")).toStartWith(
		"default-src 'none'",
	);
	expect(response.headers.get("cache-control")).toBe("no-store");
	expect(response.headers.get("referrer-policy")).toBe("no-referrer");
	const page = await response.text();
	for (const text of [
		'<h1 id="preview">Preview</h1>',
		"<strong>Bold</strong>",
		"<del>old</del>",
		"<table>",
		'type="checkbox"',
		"<pre><code",
		"1 &lt; 2",
		"<title>Résumé &amp; &lt;notes&gt; #%?.md</title>",
		"color-scheme: light dark",
		"@media print",
		// anywhere would let WebKit squeeze table columns to one character.
		"overflow-wrap: break-word",
	]) {
		expect(page).toContain(text);
	}

	await writeFile(file, "# Updated on disk\n");
	const updated = await (await get(preview(file))).text();
	expect(updated).toContain("Updated on disk</h1>");
	expect(updated).not.toContain("<strong>Bold</strong>");
});

test("raw HTML such as inline SVG renders, without scripts or a refresh", async () => {
	const file = join(directory, "raw.md");
	await writeFile(
		file,
		'<svg width="40" height="20"><rect fill="currentColor"/>' +
			"<script>document.title = 'Injected';</script></svg>\n\n" +
			'A dot <svg width="8" height="8"><circle r="4"/></svg> inline.\n\n' +
			"<details><summary>More</summary>Hidden</details>\n\n" +
			"<script>document.title = 'Injected';</script>\n\n" +
			'<meta http-equiv="refresh" content="0; url=https://example.com/">\n\n' +
			"<img src=x onerror=alert(1)>\n",
	);
	const response = await get(preview(file));
	expect(response.status).toBe(200);
	// Scripts, inline handlers included, only run where a policy allows them.
	const policy = response.headers.get("content-security-policy") ?? "";
	expect(policy).toStartWith("default-src 'none'");
	expect(policy).not.toContain("script-src");
	const page = await response.text();
	for (const text of [
		'<svg width="40" height="20"><rect fill="currentColor"/>',
		'A dot <svg width="8" height="8"><circle r="4"/></svg> inline.',
		"<details><summary>More</summary>Hidden</details>",
		"&lt;script>",
	]) {
		expect(page).toContain(text);
	}
	expect(page).not.toContain("<script>");
	expect(page).not.toContain("refresh");
	// Raw images load local files from the host, as Markdown ones do.
	expect(page).toContain(
		`<img src="image?path=${encodeURIComponent(join(directory, "x"))}"`,
	);
});

test("local links open in the preview or in Emacs; others are left alone", async () => {
	const file = join(docs, "Guide.md");
	await writeFile(
		file,
		"# Top\n\n[same](#top) [other](other%20file.md#next-steps) " +
			"[up](../README.MD) [résumé](résumé.md) [amp](a&b.md) [missing](gone.md) " +
			"[code](<src/main file.ts#L42-L50>) [image](img/pic.png) [dir](src/) " +
			"[absolute](/tmp/abs.markdown#x) [file](file:///tmp/x%20y.ts#L3) " +
			"[web](https://example.com/a.md) [mail](mailto:a@example.com) " +
			// Bun writes the apostrophe as &#x27;.
			"[quote](it's.md) " +
			'<a href="raw&#32;file.md#a&#x26;b">raw</a> <a href="&#x27;q&apos;.txt">apos</a> ' +
			'<a href="&eacute;.md">named</a>\n',
	);
	const page = await (await get(preview(file))).text();
	const links: [string, string][] = [
		["quote", preview(join(docs, "it's.md"))],
		["raw", `${preview(join(docs, "raw file.md"))}#a&b`],
		["apos", visit(join(docs, "'q'.txt"))],
		// A named reference beyond the five stays as written.
		["named", preview(join(docs, "&eacute;.md"))],
		["same", "#top"],
		["other", `${preview(join(docs, "other file.md"))}#next-steps`],
		["up", preview(join(directory, "README.MD"))],
		["résumé", preview(join(docs, "résumé.md"))],
		["amp", preview(join(docs, "a&b.md"))],
		["missing", preview(join(docs, "gone.md"))],
		["code", `${visit(join(docs, "src/main file.ts"))}#L42-L50`],
		["image", visit(join(docs, "img/pic.png"))],
		["dir", visit(`${join(docs, "src")}/`)],
		["absolute", "markdown?path=%2Ftmp%2Fabs.markdown#x"],
		["file", "file:///tmp/x%20y.ts#L3"],
		["web", "https://example.com/a.md"],
		["mail", "mailto:a@example.com"],
	];
	for (const [text, target] of links) {
		expect([text, href(page, text)]).toEqual([text, target]);
	}
});

test("attribute values decode as a browser reads them", () => {
	const cases: [string, string][] = [
		["a&amp;b&lt;&gt;&quot;&apos;", "a&b<>\"'"],
		["&#32;&#x27;&#X41;&#128512;", " 'A😀"],
		["&#0;&#xD800;&#x110000;&#99999999999;", "�".repeat(4)],
		[
			"&eacute; &constructor; &AMP; & ;&#; &#x;",
			"&eacute; &constructor; &AMP; & ;&#; &#x;",
		],
	];
	for (const [value, decoded] of cases) {
		expect([value, decodeAttribute(value)]).toEqual([value, decoded]);
	}
});

test("link and image targets need a local file", () => {
	const file = "/notes/Guide.md";
	for (const href of [
		"#top",
		"//example.com/a.md",
		"https://example.com/a.md",
		"mailto:a@example.com",
		"data:image/png;base64,AAAA",
	]) {
		expect(linkTarget(href, file)).toBeNull();
		expect(imageSource(href, file)).toBeNull();
	}
	expect(linkTarget("Other.MARKDOWN", file)).toBe(
		"markdown?path=%2Fnotes%2FOther.MARKDOWN",
	);
	expect(imageSource("a.png#x", file)).toBe("image?path=%2Fnotes%2Fa.png#x");
});

test("local images load from the host, relative to the page", async () => {
	const file = join(docs, "Guide.md");
	const pic = join(docs, "img/a&b pic.PNG");
	await writeFile(pic, png);
	await writeFile(
		file,
		"# Pictures\n\n![relative](<img/a&b pic.PNG>) ![encoded](img/a%26b%20pic.PNG#x) " +
			"![up](../top.svg) ![absolute](/tmp/abs.gif) ![file](file:///tmp/x%20y.jpg) " +
			"![web](https://example.com/a.png) ![data](data:image/png;base64,AAAA)\n\n" +
			'<img src="img/a&#38;b&#x20;pic.PNG" alt="raw">\n',
	);
	const response = await get(preview(file));
	expect(response.headers.get("content-security-policy")).toContain(
		"img-src 'self'",
	);
	const page = await response.text();
	const images: [string, string][] = [
		["relative", source(pic)],
		["encoded", `${source(pic)}#x`],
		["up", source(join(directory, "top.svg"))],
		["absolute", "image?path=%2Ftmp%2Fabs.gif"],
		["file", "image?path=%2Ftmp%2Fx%20y.jpg"],
		["web", "https://example.com/a.png"],
		["data", "data:image/png;base64,AAAA"],
		["raw", source(pic)],
	];
	for (const [alt, target] of images) {
		expect([alt, src(page, alt)]).toEqual([alt, target]);
	}

	const image = await get(source(pic));
	expect(image.status).toBe(200);
	expect(image.headers.get("content-type")).toBe("image/png");
	// An SVG opened as a page must not run its scripts.
	expect(image.headers.get("content-security-policy")).toContain("sandbox");
	expect(image.headers.get("cache-control")).toBe("no-store");
	expect(Buffer.from(await image.arrayBuffer())).toEqual(png);
});

test("images are served only from absolute paths to readable image files", async () => {
	const file = join(docs, "Guide.md");
	const pic = join(docs, "img/pic.png");
	await writeFile(file, "# Guide\n");
	await writeFile(pic, png);
	await mkdir(join(docs, "folder.png"));
	for (const path of [
		"image",
		"image?path=relative.png",
		"image?path=%2Ftmp%2Fbad%00.png",
		source(file),
		source(join(docs, "img")),
		source(join(docs, "folder.png")),
	]) {
		expect([path, (await get(path)).status]).toEqual([path, 400]);
	}
	expect((await get(source(join(docs, "missing.png")))).status).toBe(404);
	expect((await get(source(join(file, "inside.png")))).status).toBe(404);
	await chmod(pic, 0);
	expect((await get(source(pic))).status).toBe(403);
});

test("invalid previews explain themselves", async () => {
	await writeFile(join(docs, "secret.md"), "# Secret\n");
	for (const path of [
		"markdown",
		"markdown?path=relative.md",
		"markdown?path=%2Ftmp%2Fbad%00.md",
		preview(directory),
	]) {
		const response = await get(path);
		expect([path, response.status]).toEqual([path, 400]);
		expect(await response.text()).toContain("Cannot preview this file");
	}
	const missing = await get(preview(join(directory, "missing.md")));
	expect(missing.status).toBe(404);
	expect(await missing.text()).toContain("could not be found");
	await chmod(join(docs, "secret.md"), 0);
	const unreadable = await get(preview(join(docs, "secret.md")));
	expect(unreadable.status).toBe(403);
	expect(await unreadable.text()).not.toContain("Secret");
});
