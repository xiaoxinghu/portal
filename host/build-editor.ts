// SPDX-License-Identifier: GPL-3.0-or-later
import { mkdir, rm } from "node:fs/promises";
import { join, relative, resolve } from "node:path";

const root = import.meta.dir;
const generated = join(root, ".generated");
const outdir = join(generated, "editor");
await rm(outdir, { recursive: true, force: true });
await mkdir(outdir, { recursive: true });
const result = await Bun.build({
	entrypoints: [join(root, "editor-bootstrap.ts")],
	outdir,
	target: "browser",
	conditions: ["production"],
	splitting: true,
	minify: true,
	naming: {
		entry: "[name].[ext]",
		chunk: "[name]-[hash].[ext]",
		asset: "[name]-[hash].[ext]",
	},
	define: { "process.env.NODE_ENV": JSON.stringify("production") },
	metafile: true,
});
if (!result.success)
	throw new AggregateError(result.logs, "Editor build failed");
// The license notices are derived from the files the bundle contains.
await Bun.write(
	join(generated, "editor-inputs.json"),
	JSON.stringify(
		Object.keys(result.metafile?.inputs ?? {})
			.map((input) => relative(root, resolve(input)))
			.sort(),
	),
);

// The slide window's page has its own small bundle, built apart so that it
// shares no chunk with the editor's and never loads Excalidraw.
const audienceDir = join(generated, "audience");
await rm(audienceDir, { recursive: true, force: true });
const audience = await Bun.build({
	entrypoints: [join(root, "audience.ts")],
	outdir: audienceDir,
	target: "browser",
	minify: true,
	naming: { entry: "[name].[ext]" },
});
if (!audience.success)
	throw new AggregateError(audience.logs, "Slide window build failed");

// Explicit file imports make Bun embed every lazy chunk and font in the host.
// The executable remains relocatable and needs no adjacent node_modules/assets.
const paths: [string, string][] = result.outputs.map((output) => [
	`/excalidraw/assets/${relative(outdir, output.path)}`,
	output.path,
]);
for (const output of audience.outputs)
	paths.push([
		`/excalidraw/${relative(audienceDir, output.path)}`,
		output.path,
	]);
const fonts = join(root, "node_modules/@excalidraw/excalidraw/dist/prod/fonts");
for await (const path of new Bun.Glob("**/*").scan({
	cwd: fonts,
	onlyFiles: true,
})) {
	paths.push([`/excalidraw/assets/fonts/${path}`, join(fonts, path)]);
}
for (const size of [32, 64, 256]) {
	const name = `portal-${size}.png`;
	paths.push([`/assets/${name}`, join(root, "icons", name)]);
}
paths.sort(([a], [b]) => a.localeCompare(b));
const imports = paths.map(
	([, path], i) =>
		`import asset${i} from ${JSON.stringify(path)} with { type: "file" };`,
);
const entries = paths.map(([path], i) => {
	const type = path.endsWith(".js")
		? "text/javascript; charset=utf-8"
		: path.endsWith(".css")
			? "text/css; charset=utf-8"
			: path.endsWith(".woff2")
				? "font/woff2"
				: path.endsWith(".wasm")
					? "application/wasm"
					: path.endsWith(".png")
						? "image/png"
						: "application/octet-stream";
	return `[${JSON.stringify(path)}, {file: asset${i}, type: ${JSON.stringify(type)}}]`;
});
await Bun.write(
	join(generated, "assets.ts"),
	`// @ts-nocheck -- Generated Bun file-loader imports, not JavaScript module imports.\n${imports.join("\n")}\nexport const assets = new Map<string, {file: string; type: string}>([${entries.join(",\n")}]);\n`,
);
console.log(`Bundled editor and ${paths.length} local assets`);
