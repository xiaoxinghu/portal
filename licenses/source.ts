// SPDX-License-Identifier: GPL-3.0-or-later
// The corresponding source of the macOS native module, given as pointers:
// where to fetch each input that builds portal.bundle, and the revision or
// digest that identifies it. Portal hosts no copies. See docs/licenses.md.
//
//   bun licenses/source.ts stage <build-dir> <out-dir>
//       checks the build, an Apple Silicon one (pruned or not), against the
//       inputs and writes <out-dir>/SOURCE.md and <out-dir>/source.json;
//       fails, writing nothing, when an input is missing
//   bun licenses/source.ts refresh
//       rewrites licenses/source.json from the upstreams of Portal's pins
//
// licenses/source.json holds what Portal's own files do not: what the
// pinned libghostty-spm's prebuilt library was built from, and the archives
// that Ghostty's build.zig.zon files pin at that revision.
import { spawnSync } from "node:child_process";
import {
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	renameSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import type { Component } from "./notices";

const root = resolve(import.meta.dir, "..");
const lockPath = join(import.meta.dir, "source.json");
const ghosttyURL = "https://github.com/ghostty-org/ghostty.git";
const zigIndex = "https://ziglang.org/download/index.json";

type Download = { url: string; sha256: string };

// An archive a build.zig.zon file pins: Zig fetches it by URL and checks
// the package hash of its contents. ZON is OWNER:PATH, the package whose
// manifest pins it, ghostty for Ghostty's own.
export type Archive = { name: string; url: string; hash: string; zon: string };

// licenses/source.json.
export type Lock = {
	"libghostty-spm": {
		// The pin this was read from: native/libghostty-spm.json's revision.
		revision: string;
		// The wrapper commit whose release built the prebuilt library; its
		// Patches/, Script/ and Ghostty.ref are the pin's.
		built: string;
		// Ghostty.ref: the Ghostty revision the library is built from.
		ghostty: string;
		// The binaryTarget the pinned manifest downloads.
		xcframework: Download;
	};
	// The Zig the wrapper's release builds the library with: its source,
	// whose standard library and compiler-rt the library contains, and the
	// Apple Silicon compiler.
	zig: { version: string; source: Download; "aarch64-macos": Download };
	archives: Archive[];
	// Components whose code ships from inside an input, not from the
	// upstream their inventory entry names: component id to input id.
	vendored: Record<string, string>;
};

export type Input = {
	id: string;
	what: string;
	url: string;
	tag?: string;
	revision?: string;
	sha256?: string;
	// Zig's package hash.
	hash?: string;
	// Links an inventory component's source may name inside this input.
	browse: string[];
};

// The checkout the module is built from.
export type Checkout = {
	revision?: string;
	tags: string[];
	// Lines of git status --porcelain.
	changes: string[];
};

export type Manifest = {
	format: 1;
	module: string;
	platform: { os: "macos"; arch: string; minimum?: string };
	portal: { revision?: string; tags: string[] };
	inputs: Input[];
	// Inventory component id to the input that holds its source.
	components: Record<string, string>;
};

const read = (path: string) => readFileSync(path, "utf8");
const json = <T>(path: string): T => JSON.parse(read(path));

function git(args: string[], cwd?: string): string {
	const result = spawnSync("git", cwd ? ["-C", cwd, ...args] : args, {
		encoding: "utf8",
	});
	if (result.status !== 0)
		throw new Error(
			`git ${args.join(" ")} failed: ${(result.stderr || result.stdout).trim()}`,
		);
	return result.stdout;
}

// Browse links to a GitHub repository at REVISION.
function github(url: string, revision: string): string[] {
	const match = /^https:\/\/github\.com\/([^/]+\/[^/]+?)(?:\.git)?\/?$/.exec(
		url,
	);
	if (!match) return [];
	const base = `https://github.com/${match[1]}`;
	return [`${base}/tree/${revision}`, `${base}/blob/${revision}`];
}

// Portal's repository, from portal.el's URL header.
function portalURL(at: string): string {
	const header = /^;; URL: (\S+)$/m.exec(read(join(at, "portal.el")));
	if (!header?.[1]) throw new Error("portal.el has no URL header");
	return `${header[1].replace(/\/$/, "")}.git`;
}

export function checkout(at: string): Checkout {
	try {
		const revision = git(["rev-parse", "HEAD"], at).trim();
		const tags = git(["tag", "--points-at", "HEAD"], at)
			.split("\n")
			.filter(Boolean)
			.sort();
		const changes = git(["status", "--porcelain"], at)
			.split("\n")
			.filter(Boolean);
		return { revision, tags, changes };
	} catch {
		return { tags: [], changes: [] };
	}
}

// archive:NAME, or archive:PACKAGE/NAME when two packages pin a NAME:
// PACKAGE is Ghostty's pkg/ directory, or the package whose manifest pins it.
function archiveId(archive: Archive, all: Archive[]): string {
	if (all.filter((other) => other.name === archive.name).length < 2)
		return `archive:${archive.name}`;
	const [owner, zon] = archive.zon.split(":");
	const pkg = owner === "ghostty" ? (zon?.split("/")[1] ?? owner) : owner;
	return `archive:${pkg}/${archive.name}`;
}

// Everything that builds the module, in the order a rebuild fetches it.
export function inputs(at: string, lock: Lock, portal: Checkout): Input[] {
	const spm: { url: string; version: string; revision: string } = json(
		join(at, "native", "libghostty-spm.json"),
	);
	const resolved: {
		pins: {
			identity: string;
			location: string;
			state: { version?: string; revision: string };
		}[];
	} = json(join(at, "native", "Package.resolved"));
	const url = portalURL(at);
	const wrapper = lock["libghostty-spm"];
	const list: Input[] = [
		{
			id: "portal",
			what: "Portal: the C core, the Swift backend, the build and the patches it applies to libghostty-spm (native/patches/libghostty-spm)",
			url,
			tag: portal.tags[0],
			revision: portal.revision,
			browse: portal.revision ? github(url, portal.revision) : [],
		},
		{
			id: "libghostty-spm",
			what: "The Swift wrapper around Ghostty, built with Portal's patches; its Patches/ and Script/ build Ghostty's library",
			url: spm.url,
			tag: spm.version,
			revision: spm.revision,
			browse: github(spm.url, spm.revision),
		},
		...resolved.pins.map((pin) => ({
			id: pin.identity,
			what: `A Swift package libghostty-spm depends on, at native/Package.resolved's pin`,
			url: pin.location,
			tag: pin.state.version,
			revision: pin.state.revision,
			browse: github(pin.location, pin.state.revision),
		})),
		{
			id: "ghostty",
			what: `Ghostty, from which libghostty-spm's Script/build.sh builds the library with the wrapper's Patches/ghostty (its Ghostty.ref)`,
			url: ghosttyURL,
			revision: wrapper.ghostty,
			browse: github(ghosttyURL, wrapper.ghostty),
		},
		{
			id: "zig",
			what: `Zig ${lock.zig.version}'s source: the standard library and compiler-rt in the library`,
			url: lock.zig.source.url,
			sha256: lock.zig.source.sha256,
			browse: [`https://codeberg.org/ziglang/zig/src/tag/${lock.zig.version}`],
		},
		{
			id: "zig-aarch64-macos",
			what: `Zig ${lock.zig.version} for Apple Silicon, which builds the library`,
			url: lock.zig["aarch64-macos"].url,
			sha256: lock.zig["aarch64-macos"].sha256,
			browse: [],
		},
		...lock.archives.map((archive) => ({
			id: archiveId(archive, lock.archives),
			what: `Pinned by ${archive.zon.replace(/^ghostty:/, "Ghostty's ").replace(/^([^:]+):/, "$1's ")}`,
			url: archive.url,
			hash: archive.hash,
			browse: [],
		})),
		{
			id: "ghosttykit-xcframework",
			what: `The prebuilt library the wrapper's manifest downloads, which Portal links: built by libghostty-spm's build workflow at ${wrapper.built} from the inputs above. A rebuild may use it or replace it`,
			url: wrapper.xcframework.url,
			sha256: wrapper.xcframework.sha256,
			browse: [],
		},
	];
	return list;
}

// The component rows of a staged licenses/README.md: name, version, where.
export function indexRows(
	index: string,
): { name: string; version: string; shipped: string }[] {
	const section = index.split(/^## Components$/m)[1]?.split(/^## /m)[0] ?? "";
	return section
		.split("\n")
		.filter((line) => line.startsWith("| ") && !line.startsWith("| ---"))
		.slice(1)
		.map((line) => {
			const cells = line
				.slice(1, -1)
				.split(/(?<!\\)\|/)
				.map((cell) => cell.trim().replaceAll("\\|", "|"));
			return {
				name: cells[0] ?? "",
				version: cells[1] ?? "",
				shipped: cells[3] ?? "",
			};
		});
}

// The architecture and minimum macOS of a Mach-O file, if it is one.
export function machO(file: Uint8Array): { arch: string; minimum?: string } {
	const view = new DataView(file.buffer, file.byteOffset, file.byteLength);
	if (file.byteLength < 32) return { arch: "unknown" };
	const magic = view.getUint32(0, true);
	if (magic === 0xbebafeca) return { arch: "universal" };
	if (magic !== 0xfeedfacf) return { arch: "unknown" };
	const cpu = view.getUint32(4, true);
	const arch =
		cpu === 0x0100000c ? "arm64" : cpu === 0x01000007 ? "x86_64" : `cpu ${cpu}`;
	let minimum: string | undefined;
	const count = view.getUint32(16, true);
	let offset = 32;
	for (let n = 0; n < count && offset + 16 <= file.byteLength; n++) {
		const cmd = view.getUint32(offset, true);
		const size = view.getUint32(offset + 4, true);
		// LC_BUILD_VERSION: platform, then minos as xxxx.yy.zz.
		if (cmd === 0x32 && view.getUint32(offset + 8, true) === 1) {
			const v = view.getUint32(offset + 12, true);
			minimum = `${v >>> 16}.${(v >>> 8) & 0xff}${v & 0xff ? `.${v & 0xff}` : ""}`;
		}
		if (size < 8) break;
		offset += size;
	}
	return { arch, minimum };
}

// Inventory components the pins require in the macOS module.
export function required(at: string, inventory: Component[]): Component[] {
	const resolved: {
		pins: { identity: string; state: { version?: string; revision: string } }[];
	} = json(join(at, "native", "Package.resolved"));
	const spm: { version: string } = json(
		join(at, "native", "libghostty-spm.json"),
	);
	const shipped = new Set([
		`swift:libghostty-spm@${spm.version}`,
		...resolved.pins.map(
			(pin) =>
				`swift:${pin.identity}@${pin.state.version ?? pin.state.revision}`,
		),
	]);
	return inventory.filter((component) =>
		component.when.some((condition) => shipped.has(condition)),
	);
}

const module = "portal.bundle/Contents/MacOS/portal.dylib";

// The manifest for BUILD, or what keeps it from corresponding to the build.
export function plan(options: {
	build: string;
	at?: string;
	lock?: Lock;
	portal?: Checkout;
	inventory?: Component[];
}): { manifest?: Manifest; problems: string[] } {
	const at = options.at ?? root;
	const lock = options.lock ?? json<Lock>(lockPath);
	const portal = options.portal ?? checkout(at);
	const inventory =
		options.inventory ??
		json<{ components: Component[] }>(join(at, "licenses", "inventory.json"))
			.components;
	const problems: string[] = [];

	// The build: an Apple Silicon module and the notices staged with it.
	const dylib = join(options.build, module);
	let platform: Manifest["platform"] = { os: "macos", arch: "unknown" };
	if (!existsSync(dylib))
		problems.push(`${options.build} has no ${module}: build Portal on macOS`);
	else {
		const { arch, minimum } = machO(readFileSync(dylib));
		platform = { os: "macos", arch, minimum };
		if (arch !== "arm64")
			problems.push(`${module} is ${arch}, not an Apple Silicon (arm64) build`);
	}
	const indexPath = join(options.build, "licenses", "README.md");
	const rows = existsSync(indexPath) ? indexRows(read(indexPath)) : [];
	if (!existsSync(indexPath))
		problems.push(`${options.build} has no licenses/README.md: build Portal`);

	// Portal: a revision anyone can fetch, which is only the release's
	// committed state.
	if (!portal.revision)
		problems.push(
			`Portal at ${at} is not a Git checkout: its revision is unknown`,
		);
	else if (portal.changes.length)
		problems.push(
			`Portal's checkout has changes no revision holds, so ${portal.revision} is not the module's source:${portal.changes
				.slice(0, 10)
				.map((line) => `\n  ${line}`)
				.join("")}`,
		);

	// The lock must have been read from the pinned wrapper.
	const spm: { revision: string } = json(
		join(at, "native", "libghostty-spm.json"),
	);
	if (lock["libghostty-spm"].revision !== spm.revision)
		problems.push(
			`licenses/source.json was read from libghostty-spm ${lock["libghostty-spm"].revision}, but native/libghostty-spm.json pins ${spm.revision}: run bun licenses/source.ts refresh`,
		);

	const list = inputs(at, lock, portal);
	for (const input of list)
		if (!input.url || !(input.revision || input.sha256 || input.hash))
			problems.push(`input ${input.id} has no URL, revision or digest`);

	// Every component the build's notices list in the module needs the input
	// that holds its source; the pins' components must all be listed.
	const needed = required(at, inventory);
	const inModule = rows.filter((row) =>
		/portal\.(dylib|bundle)/.test(row.shipped),
	);
	const components: Record<string, string> = {};
	for (const row of inModule) {
		const component = inventory.find(
			(entry) => entry.name === row.name && entry.version === row.version,
		);
		if (!component) {
			problems.push(
				`the build's notices list ${row.name} ${row.version}, which licenses/inventory.json does not: the build is not of this checkout`,
			);
			continue;
		}
		const vendored = lock.vendored[component.id];
		const input = vendored
			? list.find((entry) => entry.id === vendored)
			: list.find(
					(entry) =>
						entry.url === component.source ||
						entry.browse.some(
							(link) =>
								component.source === link ||
								component.source.startsWith(`${link}/`),
						),
				);
		if (input) components[component.id] = input.id;
		else
			problems.push(
				`${component.name} ${component.version} ships in the module, but no input holds its source, ${component.source}: refresh licenses/source.json, or record the input it is vendored in`,
			);
	}
	for (const component of needed)
		if (
			!inModule.some(
				(row) =>
					row.name === component.name && row.version === component.version,
			)
		)
			problems.push(
				`the build's notices lack ${component.name} ${component.version}, which this checkout's pins require: the build is not of this checkout`,
			);

	if (problems.length) return { problems };
	return {
		manifest: {
			format: 1,
			module,
			platform,
			portal: { revision: portal.revision, tags: portal.tags },
			inputs: list,
			components,
		},
		problems,
	};
}

const cell = (text: string) => text.replaceAll("|", "\\|");

function identity(input: Input): string {
	if (input.revision)
		return `${input.tag ? `${input.tag}, ` : ""}commit \`${input.revision}\``;
	if (input.sha256) return `SHA-256 \`${input.sha256}\``;
	return `Zig hash \`${input.hash}\``;
}

export function markdown(manifest: Manifest, lock: Lock): string {
	const find = (id: string) =>
		manifest.inputs.find((input) => input.id === id) as Input;
	const portal = find("portal");
	const spm = find("libghostty-spm");
	const xcframework = find("ghosttykit-xcframework");
	const zig = find("zig-aarch64-macos");
	const archives = manifest.inputs.filter((input) =>
		input.id.startsWith("archive:"),
	);
	const others = manifest.inputs.filter(
		(input) => !input.id.startsWith("archive:"),
	);
	const at = portal.tag ?? portal.revision;
	return [
		"# Corresponding source of Portal's macOS native module",
		"",
		`Generated by \`bun licenses/source.ts stage\`; do not edit. \`${manifest.module}\`,`,
		`built for macOS ${manifest.platform.arch}${manifest.platform.minimum ? ` ${manifest.platform.minimum} or later` : ""} from Portal ${at},`,
		"is made from the inputs below. Each is named by where to fetch it and the",
		"revision or digest that identifies it; `source.json` beside this file has",
		"the same in JSON, with the input that holds each third-party component's",
		"source. Portal does not host copies of these inputs.",
		"",
		"## Inputs",
		"",
		"| Input | What it is | Where | Revision or digest |",
		"| --- | --- | --- | --- |",
		...others.map(
			(input) =>
				`| ${input.id} | ${cell(input.what)} | ${input.url} | ${identity(input)} |`,
		),
		"",
		"### Archives Ghostty's build fetches",
		"",
		`Zig fetches these while building Ghostty ${lock["libghostty-spm"].ghostty} and checks`,
		"each against its package hash. Ghostty's build.zig.zon files pin them, or",
		"the manifests of the packages they pin; a macOS build fetches the ones it uses.",
		"",
		"| Name | Pinned by | Where | Zig hash |",
		"| --- | --- | --- | --- |",
		...archives.map(
			(input) =>
				`| ${input.id.slice("archive:".length)} | ${input.what.replace("Pinned by ", "")} | ${input.url} | \`${input.hash}\` |`,
		),
		"",
		"## Rebuilding",
		"",
		"On an Apple Silicon Mac with Xcode (its macOS SDK and Swift 6.2 or later),",
		"CMake, Ninja, Bun, Git and GNU Emacs 31.1 with modules; Portal's",
		"CONTRIBUTING.md lists the build's prerequisites. Then:",
		"",
		"1. Fetch Portal and configure it. Configuration fetches libghostty-spm's",
		`   tag ${spm.tag}, checks that it is commit ${spm.revision} and applies Portal's`,
		"   patches to it, in `build/libghostty-spm`:",
		"",
		"   ```sh",
		`   git clone ${portal.url} portal && cd portal`,
		`   git checkout ${portal.revision}`,
		"   cmake --preset dev",
		"   ```",
		"",
		`2. Install ${zig.url.split("/").pop()} and put its \`zig\` first on \`PATH\`.`,
		"   Rebuild Ghostty's library inside the patched wrapper, from the Ghostty",
		"   revision its `Ghostty.ref` names, with its `Patches/ghostty`:",
		"",
		"   ```sh",
		"   cd build/libghostty-spm",
		"   touch .root",
		"   git init -q References/ghostty-upstream",
		`   git -C References/ghostty-upstream fetch --depth 1 ${ghosttyURL} "$(cat Ghostty.ref)"`,
		"   git -C References/ghostty-upstream checkout --detach FETCH_HEAD",
		"   ./build.sh --platforms macos --skip-tests",
		"   cp Package.local.swift Package.swift",
		"   cd ../..",
		"   ```",
		"",
		"   The last copy makes the wrapper link the library just built,",
		"   `BinaryTarget/GhosttyKit.xcframework`, instead of downloading",
		`   ${xcframework.url}.`,
		"   Skip this step to build with that prebuilt library.",
		"",
		"3. Build the module. The build keeps the changes made in",
		"   `build/libghostty-spm` and says so:",
		"",
		"   ```sh",
		"   ./build.sh --prune",
		"   ```",
		"",
		`   \`build/${manifest.module}\` is the rebuilt module.`,
		"",
	].join("\n");
}

export function stage(
	build: string,
	out: string,
	options: Omit<Parameters<typeof plan>[0], "build"> = {},
): string[] {
	const lock = options.lock ?? json<Lock>(lockPath);
	const { manifest, problems } = plan({ ...options, build, lock });
	if (!manifest) return problems;
	const staging = `${out}.staging`;
	rmSync(staging, { recursive: true, force: true });
	mkdirSync(staging, { recursive: true });
	writeFileSync(join(staging, "SOURCE.md"), markdown(manifest, lock));
	writeFileSync(
		join(staging, "source.json"),
		`${JSON.stringify(manifest, null, "\t")}\n`,
	);
	rmSync(out, { recursive: true, force: true });
	mkdirSync(dirname(out), { recursive: true });
	renameSync(staging, out);
	return [];
}

// The dependencies a build.zig.zon file fetches by URL.
export function zonDependencies(
	text: string,
): { name: string; url: string; hash: string }[] {
	// Drop line comments outside strings; URLs hold "//".
	const code = text
		.split("\n")
		.map((line) => {
			let quoted = false;
			for (let i = 0; i < line.length; i++) {
				if (quoted && line[i] === "\\") i++;
				else if (line[i] === '"') quoted = !quoted;
				else if (!quoted && line.startsWith("//", i)) return line.slice(0, i);
			}
			return line;
		})
		.join("\n");
	const found: { name: string; url: string; hash: string }[] = [];
	for (const match of code.matchAll(
		/\.(@"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)\s*=\s*\.\{([^{}]*)\}/g,
	)) {
		const body = match[2] ?? "";
		const url = /\.url\s*=\s*"([^"]+)"/.exec(body)?.[1];
		const hash = /\.hash\s*=\s*"([^"]+)"/.exec(body)?.[1];
		if (url && hash)
			found.push({
				name: (match[1] ?? "").replace(/^@"|"$/g, ""),
				url,
				hash,
			});
	}
	return found;
}

// A Git directory holding REVISION of URL: CLONE when it has it, otherwise a
// shallow, blobless fetch into a temporary directory.
function fetchRevision(url: string, revision: string, clone?: string): string {
	if (clone) {
		const has = spawnSync("git", [
			"-C",
			clone,
			"cat-file",
			"-e",
			`${revision}^{commit}`,
		]);
		if (has.status === 0) return clone;
	}
	const dir = mkdtempSync(join(tmpdir(), "portal-source-"));
	git(["init", "-q"], dir);
	git(["remote", "add", "origin", url], dir);
	git(
		["fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", revision],
		dir,
	);
	return dir;
}

// The build.zig.zon at the top of the package archive at URL, if any. Zig
// strips one leading directory, as tar's archives usually have.
async function packageZon(url: string): Promise<string | undefined> {
	// git+https://HOST/PATH#COMMIT, which Zig fetches with Git.
	const gitURL = /^git\+(https:\/\/[^#]+)#([0-9a-f]{40})$/.exec(url);
	if (gitURL?.[1] && gitURL[2]) {
		const dir = fetchRevision(gitURL[1], gitURL[2]);
		try {
			return spawnSync(
				"git",
				["-C", dir, "show", `${gitURL[2]}:build.zig.zon`],
				{
					encoding: "utf8",
				},
			).stdout;
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	}
	if (!/^https:\/\//.test(url))
		throw new Error(
			`cannot read a package from ${url}: not https or git+https`,
		);
	const response = await fetch(url);
	if (!response.ok) throw new Error(`cannot fetch ${url}: ${response.status}`);
	let bytes: Uint8Array = new Uint8Array(await response.arrayBuffer());
	// macOS's tar reads gzip and xz, not zstd.
	if (/\.zst$/.test(url)) bytes = Bun.zstdDecompressSync(bytes);
	const dir = mkdtempSync(join(tmpdir(), "portal-package-"));
	try {
		const file = join(dir, "archive");
		writeFileSync(file, bytes);
		const entry = spawnSync("tar", ["-tf", file], { encoding: "utf8" })
			.stdout.split("\n")
			.filter((path) => /^(\.\/)?([^/]+\/)?build\.zig\.zon$/.test(path))
			.sort((a, b) => a.length - b.length)[0];
		if (!entry) return undefined;
		const zon = spawnSync("tar", ["-xOf", file, entry], { encoding: "utf8" });
		if (zon.status !== 0)
			throw new Error(`cannot read ${entry} in ${url}: ${zon.stderr}`);
		return zon.stdout;
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

export async function refresh(): Promise<Lock> {
	const previous: Partial<Lock> = existsSync(lockPath) ? json(lockPath) : {};
	const spm: { url: string; version: string; revision: string } = json(
		join(root, "native", "libghostty-spm.json"),
	);
	const spmClone = fetchRevision(
		spm.url,
		spm.revision,
		process.env.PORTAL_LIBGHOSTTY_SPM_CLONE,
	);
	const show = (dir: string, revision: string, path: string) =>
		git(["show", `${revision}:${path}`], dir);
	const manifest = show(spmClone, spm.revision, "Package.swift");
	const binary =
		/\.binaryTarget\(\s*name:\s*"libghostty",\s*url:\s*"([^"]+)",\s*checksum:\s*"([0-9a-f]{64})"/.exec(
			manifest,
		);
	if (!binary?.[1] || !binary[2])
		throw new Error(
			`libghostty-spm ${spm.version}'s Package.swift downloads no libghostty binaryTarget`,
		);
	const ghostty = show(spmClone, spm.revision, "Ghostty.ref").trim();

	// The release that built the library: its tag's commit must carry the
	// pin's patches and scripts, so the pin's source is the library's.
	const tag = /\/releases\/download\/([^/]+)\//.exec(binary[1])?.[1];
	if (!tag) throw new Error(`cannot read a release tag from ${binary[1]}`);
	const refs = git([
		"ls-remote",
		spm.url,
		`refs/tags/${tag}`,
		`refs/tags/${tag}^{}`,
	])
		.split("\n")
		.filter(Boolean)
		.map((line) => line.split("\t") as [string, string]);
	const built = (refs.find(([, ref]) => ref.endsWith("^{}")) ?? refs[0])?.[0];
	if (!built) throw new Error(`libghostty-spm has no tag ${tag}`);
	const builtClone = fetchRevision(spm.url, built, spmClone);
	for (const path of ["Patches", "Script", "Ghostty.ref"])
		if (
			git(["rev-parse", `${built}:${path}`], builtClone) !==
			git(["rev-parse", `${spm.revision}:${path}`], spmClone)
		)
			throw new Error(
				`libghostty-spm's ${path} at ${built}, which built the library (${tag}), differs from the pin's ${spm.revision}: the pin's source is not the library's`,
			);
	const workflow = show(builtClone, built, ".github/workflows/build.yml");
	const zigVersions = new Set(
		[
			...workflow.matchAll(
				/setup-zig@\S+\s*\n\s*with:\s*\n\s*version:\s*([0-9][^\s]*)/g,
			),
		].map((match) => match[1]),
	);
	const version = [...zigVersions][0];
	if (zigVersions.size !== 1 || !version)
		throw new Error(
			`libghostty-spm's build workflow at ${built} names Zig ${[...zigVersions].join(", ") || "nowhere"}`,
		);
	const index = (await (await fetch(zigIndex)).json()) as Record<
		string,
		Record<string, { tarball: string; shasum: string }>
	>;
	const release = index[version];
	const download = (key: string): Download => {
		const entry = release?.[key];
		if (!entry) throw new Error(`${zigIndex} has no ${key} for Zig ${version}`);
		return { url: entry.tarball, sha256: entry.shasum };
	};

	// Ghostty's archives, from every build.zig.zon its build reaches.
	const ghosttyClone = fetchRevision(
		ghosttyURL,
		ghostty,
		process.env.PORTAL_GHOSTTY_CLONE,
	);
	const zons = git(["ls-tree", "-r", "--name-only", ghostty], ghosttyClone)
		.split("\n")
		.filter((path) =>
			/^(build\.zig\.zon|pkg\/[^/]+\/build\.zig\.zon)$/.test(path),
		)
		.sort();
	const archives = new Map<string, Archive>();
	for (const zon of zons)
		for (const dep of zonDependencies(show(ghosttyClone, ghostty, zon)))
			if (!archives.has(dep.hash))
				archives.set(dep.hash, { ...dep, zon: `ghostty:${zon}` });
	// And what those packages pin in turn. A hash starting N-V- names a plain
	// archive, which has no build.zig.zon.
	const queue = [...archives.values()];
	for (let archive = queue.shift(); archive; archive = queue.shift()) {
		if (archive.hash.startsWith("N-V-")) continue;
		const zon = await packageZon(archive.url);
		for (const dep of zon ? zonDependencies(zon) : [])
			if (!archives.has(dep.hash)) {
				const entry = { ...dep, zon: `${archive.name}:build.zig.zon` };
				archives.set(dep.hash, entry);
				queue.push(entry);
			}
	}

	const lock: Lock = {
		"libghostty-spm": {
			revision: spm.revision,
			built,
			ghostty,
			xcframework: { url: binary[1], sha256: binary[2] },
		},
		zig: {
			version,
			source: download("src"),
			"aarch64-macos": download("aarch64-macos"),
		},
		archives: [...archives.values()].sort((a, b) =>
			a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
		),
		vendored: previous.vendored ?? {},
	};
	for (const dir of new Set([spmClone, builtClone, ghosttyClone]))
		if (
			dir !== process.env.PORTAL_LIBGHOSTTY_SPM_CLONE &&
			dir !== process.env.PORTAL_GHOSTTY_CLONE
		)
			rmSync(dir, { recursive: true, force: true });
	writeFileSync(lockPath, `${JSON.stringify(lock, null, "\t")}\n`);
	return lock;
}

if (import.meta.main) {
	const [command, build, out] = process.argv.slice(2);
	if (command === "refresh") {
		const lock = await refresh();
		console.log(
			`Wrote licenses/source.json: libghostty-spm ${lock["libghostty-spm"].revision}, Ghostty ${lock["libghostty-spm"].ghostty}, Zig ${lock.zig.version}, ${lock.archives.length} archives`,
		);
	} else if (command === "stage" && build && out) {
		const problems = stage(resolve(build), resolve(out));
		for (const problem of problems) console.error(`source: ${problem}`);
		if (problems.length) process.exit(1);
		console.log(`Staged the corresponding source's pointers in ${out}`);
	} else {
		console.error(
			"usage: bun licenses/source.ts stage <build-dir> <out-dir> | refresh",
		);
		process.exit(2);
	}
}
