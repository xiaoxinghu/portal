// SPDX-License-Identifier: GPL-3.0-or-later
// Stages Portal's license and the third-party notices for what a build ships,
// and checks a staged copy. The required set comes from the build itself: the
// Swift pins, the Bun inside portal-host and the files Bun bundled into it.
// See docs/licenses.md.
//
//   bun licenses/notices.ts stage <build-dir>   writes <build-dir>/licenses
//   bun licenses/notices.ts check <build-dir> [staged-dir]
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { mkdir, rename, rm } from "node:fs/promises";
import { basename, dirname, join, relative, resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const host = join(root, "host");
const texts = join(import.meta.dir, "texts");

// An entry of licenses/inventory.json.
type Component = {
	id: string;
	name: string;
	version: string;
	source: string;
	license: string;
	shipped: string;
	// Required when any condition holds: swift:IDENTITY@VERSION, bun@VERSION
	// or npm:NAME@VERSION.
	when: string[];
	// Relative to licenses/texts, or swift:IDENTITY/PATH inside that Swift
	// package's source: its SwiftPM checkout, or the patched copy for
	// libghostty-spm.
	texts: string[];
	// Packages compiled into a bundled npm package, as its source maps name them.
	embeds?: string[];
	// Font family directories of a bundled npm package.
	fonts?: string[];
	// Notices upstream already placed in the build, relative to the build.
	retain?: string[];
	credit?: string;
	note?: string;
	blocker?: string;
};

export type Notice = Pick<
	Component,
	"name" | "version" | "license" | "shipped"
> &
	Pick<Component, "credit" | "note" | "blocker"> & {
		npm: boolean;
		// FROM is the source file; TO its path in the staged directory.
		files: { from: string; to: string }[];
	};

type Package = {
	name: string;
	version: string;
	dir: string;
	license: string;
	inputs: string[];
};

const read = (path: string) => readFileSync(path, "utf8");
const isFile = (path: string) => existsSync(path) && statSync(path).isFile();
const escapeRegExp = (text: string) =>
	text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// The innermost npm package directory containing PATH.
function packageDir(path: string): string | undefined {
	return path.match(/^(.*\/node_modules\/(?:@[^/]+\/)?[^/]+)\//)?.[1];
}

// License files a package ships at its top level.
function licenseFiles(dir: string): string[] {
	return readdirSync(dir)
		.filter(
			(name) =>
				/^(licen[cs]e|copying|notice)/i.test(name) &&
				!/\.(c?m?[jt]s|json)$/i.test(name) &&
				isFile(join(dir, name)),
		)
		.sort();
}

// Packages a bundled file's source map says were compiled into it: NAME@VERSION
// when the source path records a version (pnpm layouts do), NAME otherwise.
function embedded(file: string): string[] {
	if (!isFile(`${file}.map`)) return [];
	const sources: string[] = JSON.parse(read(`${file}.map`)).sources ?? [];
	const found = new Set<string>();
	for (const source of sources) {
		const name = source.match(
			/^.*node_modules\/((?:@[^/]+\/)?[^/.][^/]*)\//,
		)?.[1];
		if (!name) continue;
		const pnpm = new RegExp(
			`\\.pnpm/${escapeRegExp(name.replace("/", "+"))}@([^_/]+)`,
		);
		const version = source.match(pnpm)?.[1];
		found.add(version ? `${name}@${version}` : name);
	}
	return [...found];
}

function bunVersion(build: string, problems: string[]): string | undefined {
	const executable = join(build, "portal-host");
	if (!isFile(executable)) {
		problems.push("portal-host is missing; build Portal first");
		return undefined;
	}
	// A compiled Bun executable acts as Bun itself when BUN_BE_BUN is set.
	const result = Bun.spawnSync([executable, "--version"], {
		env: { ...process.env, BUN_BE_BUN: "1" },
	});
	const version = result.stdout.toString().trim();
	if (result.exitCode === 0 && /^\d+\.\d+\.\d+$/.test(version)) return version;
	problems.push("portal-host did not report its Bun version");
	return undefined;
}

// Every file Bun bundled into portal-host: the host's module graph and the
// browser editor bundle it embeds.
function bundledInputs(build: string, problems: string[]): string[] {
	const hostInputs = join(build, "portal-host.meta.json");
	const editorInputs = join(host, ".generated", "editor-inputs.json");
	if (!isFile(hostInputs) || !isFile(editorInputs)) {
		problems.push("the bundler records are missing; build Portal first");
		return [];
	}
	// CMake compiles the host from the build directory.
	return [
		...Object.keys(JSON.parse(read(hostInputs)).inputs).map((input) =>
			resolve(build, input),
		),
		...(JSON.parse(read(editorInputs)) as string[]).map((input) =>
			resolve(host, input),
		),
	];
}

// IDENTITY/PATH in a Swift package's source, as the build has it.
function swiftSource(build: string, path: string): string {
	return path.startsWith("libghostty-spm/")
		? join(build, path)
		: join(build, "swift", "checkouts", path);
}

export function inspect(build: string): {
	notices: Notice[];
	problems: string[];
	bun?: string;
} {
	const problems: string[] = [];
	const inventory: Component[] = JSON.parse(
		read(join(import.meta.dir, "inventory.json")),
	).components;
	const reviewed = read(join(import.meta.dir, "npm-reviewed.txt"))
		.split("\n")
		.filter((line) => line && !line.startsWith("#"));

	// What this build contains, as KIND:NAME@VERSION, and the KIND:NAME parts.
	const shipped = new Set<string>();
	const names = new Set<string>();
	const ship = (name: string, version: string) => {
		shipped.add(`${name}@${version}`);
		names.add(name);
	};
	// SwiftPM pins every Swift package but libghostty-spm, which the build
	// patches: native/libghostty-spm.json pins that one.
	const pins: {
		identity: string;
		state: { version?: string; revision: string };
	}[] = JSON.parse(read(join(root, "native", "Package.resolved"))).pins;
	const patched: { version: string; revision: string } = JSON.parse(
		read(join(root, "native", "libghostty-spm.json")),
	);
	pins.push({ identity: "libghostty-spm", state: patched });
	for (const pin of pins)
		ship(`swift:${pin.identity}`, pin.state.version ?? pin.state.revision);
	const bun = bunVersion(build, problems);
	if (bun) ship("bun", bun);
	const packages = new Map<string, Package>();
	for (const input of bundledInputs(build, problems)) {
		const dir = packageDir(input);
		if (!dir) continue;
		const manifest = JSON.parse(read(join(dir, "package.json")));
		const key = `${manifest.name}@${manifest.version}`;
		const license = manifest.license ?? manifest.licenses ?? "none declared";
		const pkg: Package = packages.get(key) ?? {
			name: manifest.name,
			version: manifest.version,
			dir,
			license: typeof license === "string" ? license : JSON.stringify(license),
			inputs: [],
		};
		pkg.inputs.push(input);
		packages.set(key, pkg);
		ship(`npm:${manifest.name}`, manifest.version);
	}

	const required = inventory.filter((component) =>
		component.when.some((condition) => shipped.has(condition)),
	);
	const covers = (condition: string) =>
		required.some((component) => component.when.includes(condition));

	// A component written for another version of something this build ships
	// is stale: that version's contents need a fresh review. Bun keeps one
	// component per supported version.
	for (const component of inventory)
		for (const condition of component.when) {
			const name = condition.slice(0, condition.lastIndexOf("@"));
			if (name !== "bun" && names.has(name) && !shipped.has(condition))
				problems.push(
					`inventory component ${component.id} is for ${condition}, which the build no longer ships; review the shipped version and update licenses/inventory.json`,
				);
		}
	for (const pin of pins) {
		const condition = `swift:${pin.identity}@${pin.state.version ?? pin.state.revision}`;
		if (!covers(condition))
			problems.push(
				`native/Package.resolved or native/libghostty-spm.json pins ${condition}, which no inventory component covers`,
			);
	}
	if (bun && !covers(`bun@${bun}`))
		problems.push(
			`portal-host embeds Bun ${bun}; add licenses/texts/bun/${bun}/LICENSE.md from https://github.com/oven-sh/bun/blob/bun-v${bun}/LICENSE.md and an inventory component for bun@${bun}`,
		);

	const keys = [...packages.keys()].sort();
	const added = keys.filter((key) => !reviewed.includes(key));
	const removed = reviewed.filter((key) => !packages.has(key));
	if (added.length || removed.length)
		problems.push(
			"the bundled npm packages differ from licenses/npm-reviewed.txt; check the new ones for embedded third-party code (docs/licenses.md) and update the list:" +
				added.map((key) => `\n  + ${key}`).join("") +
				removed.map((key) => `\n  - ${key}`).join(""),
		);

	const notices: Notice[] = [];
	const embeds = new Set(
		required.flatMap((component) => component.embeds ?? []),
	);
	const fonts = new Set(required.flatMap((component) => component.fonts ?? []));
	for (const key of keys) {
		const pkg = packages.get(key) as Package;
		const files = licenseFiles(pkg.dir);
		if (files.length)
			notices.push({
				npm: true,
				name: pkg.name,
				version: pkg.version,
				license: pkg.license,
				shipped: "portal-host",
				files: files.map((name) => ({
					from: join(pkg.dir, name),
					to: `npm/${key}/${name}`,
				})),
			});
		else if (!covers(`npm:${key}`))
			problems.push(
				`npm package ${key} ships no license file; add an inventory component for npm:${key}`,
			);
		const found = new Set(pkg.inputs.flatMap(embedded));
		for (const name of [...found].sort())
			if (
				name !== pkg.name &&
				!name.startsWith(`${pkg.name}@`) &&
				!packages.has(name) &&
				!embeds.has(name)
			)
				problems.push(
					`${key} embeds ${name} (per its source maps), which no inventory component lists in embeds`,
				);
		const families = new Set(
			pkg.inputs
				.filter((input) => /\.(woff2?|ttf|otf)$/.test(input))
				.map((input) => basename(dirname(input))),
		);
		for (const family of [...families].sort())
			if (!fonts.has(family))
				problems.push(
					`${key} ships font family ${family}, which no inventory component lists in fonts`,
				);
	}

	const ids = new Set<string>();
	for (const component of required) {
		if (ids.has(component.id))
			problems.push(`inventory requires component ${component.id} twice`);
		ids.add(component.id);
		const files = component.texts.map((text) =>
			text.startsWith("swift:")
				? {
						from: swiftSource(build, text.slice(6)),
						to: `${component.id}/${basename(text)}`,
					}
				: { from: join(texts, text), to: text },
		);
		for (const file of files)
			if (!isFile(file.from))
				problems.push(
					`component ${component.id} notice ${file.to} has no source`,
				);
		for (const path of component.retain ?? [])
			if (!isFile(join(build, path)))
				problems.push(
					`component ${component.id} notice ${path} is missing from the build`,
				);
		notices.push({ ...component, npm: false, files });
	}
	return { notices, problems, bun };
}

function index(notices: Notice[], bun?: string): string {
	const cell = (text: string) =>
		text.replaceAll("|", "\\|").replaceAll("\n", " ");
	const links = (notice: Notice) =>
		notice.files.map((file) => `[${basename(file.to)}](${file.to})`).join(", ");
	const components = notices
		.filter((notice) => !notice.npm)
		.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
	const npm = notices.filter((notice) => notice.npm);
	const lines = [
		"# Portal licenses and third-party notices",
		"",
		"Generated from `licenses/inventory.json` and the build's own records; do",
		"not edit. Portal is licensed under GPL-3.0-or-later; see [LICENSE](LICENSE).",
		"The components below are part of `portal.bundle` or `portal-host` and keep",
		`their own licenses. portal-host embeds the Bun ${bun ?? "(unknown)"} runtime.`,
		"",
	];
	const blockers = components.filter((notice) => notice.blocker);
	if (blockers.length)
		lines.push(
			"## Unresolved before a binary release",
			"",
			...blockers.map((notice) => `- ${notice.name}: ${notice.blocker}`),
			"",
		);
	const credits = components.filter((notice) => notice.credit);
	if (credits.length)
		lines.push(
			"## Credits",
			"",
			...credits.map((notice) => `- ${notice.credit}`),
			"",
		);
	lines.push(
		"## Components",
		"",
		"| Component | Version | License | Shipped in | Notices |",
		"| --- | --- | --- | --- | --- |",
		...components.map(
			(notice) =>
				`| ${cell(notice.name)} | ${cell(notice.version)} | ${cell(notice.license)} | ${cell(notice.shipped)} | ${links(notice)}${notice.note ? `. ${cell(notice.note)}` : ""} |`,
		),
		"",
		"## npm packages bundled into portal-host",
		"",
		"License files are copied from each installed package.",
		"",
		"| Package | Version | Declared license | Notices |",
		"| --- | --- | --- | --- |",
		...npm.map(
			(notice) =>
				`| ${cell(notice.name)} | ${cell(notice.version)} | ${cell(notice.license)} | ${links(notice)} |`,
		),
		"",
	);
	return lines.join("\n");
}

// The staged directory's exact contents.
function expected(build: string): {
	files: Map<string, Uint8Array | string>;
	problems: string[];
} {
	const { notices, problems, bun } = inspect(build);
	const files = new Map<string, Uint8Array | string>();
	files.set("LICENSE", readFileSync(join(root, "LICENSE")));
	files.set("README.md", index(notices, bun));
	for (const notice of notices)
		for (const file of notice.files)
			if (isFile(file.from)) files.set(file.to, readFileSync(file.from));
	return { files, problems };
}

export async function stage(build: string): Promise<string[]> {
	const { files, problems } = expected(build);
	const staging = join(build, ".licenses");
	await rm(staging, { recursive: true, force: true });
	for (const [path, content] of files) {
		await mkdir(dirname(join(staging, path)), { recursive: true });
		await Bun.write(join(staging, path), content);
	}
	await rm(join(build, "licenses"), { recursive: true, force: true });
	await rename(staging, join(build, "licenses"));
	return problems;
}

export function check(
	build: string,
	staged = join(build, "licenses"),
): string[] {
	const { files, problems } = expected(build);
	for (const [path, content] of files) {
		const file = join(staged, path);
		if (!isFile(file)) problems.push(`staged notice ${path} is missing`);
		else if (!Buffer.from(content).equals(readFileSync(file)))
			problems.push(`staged notice ${path} is out of date`);
	}
	const walk = (dir: string): string[] =>
		readdirSync(dir).flatMap((name) =>
			statSync(join(dir, name)).isDirectory()
				? walk(join(dir, name))
				: [relative(staged, join(dir, name))],
		);
	if (existsSync(staged))
		for (const path of walk(staged))
			if (!files.has(path))
				problems.push(`staged file ${path} is not a required notice`);
	return problems;
}

if (import.meta.main) {
	const [command, build, staged] = process.argv.slice(2);
	if (!build || (command !== "stage" && command !== "check")) {
		console.error(
			"usage: bun licenses/notices.ts stage|check <build-dir> [staged-dir]",
		);
		process.exit(2);
	}
	if (command === "stage") {
		// Development builds stage what they can; the licenses test fails on gaps.
		for (const problem of await stage(resolve(build)))
			console.warn(`warning: licenses: ${problem}`);
	} else {
		const problems = check(resolve(build), staged && resolve(staged));
		for (const problem of problems) console.error(`licenses: ${problem}`);
		if (problems.length) process.exit(1);
		console.log("All required license notices are staged");
	}
}
