// SPDX-License-Identifier: GPL-3.0-or-later
// The corresponding source's pointers cover what the macOS module ships; see
// docs/licenses.md.
import { afterEach, expect, test } from "bun:test";
import {
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Component } from "../licenses/notices";
import {
	type Checkout,
	indexRows,
	type Lock,
	machO,
	plan,
	required,
	stage,
	zonDependencies,
} from "../licenses/source";

const root = join(import.meta.dir, "..");
const build = process.env.PORTAL_BUILD ?? join(root, "build");
const inventory: Component[] = JSON.parse(
	readFileSync(join(root, "licenses", "inventory.json"), "utf8"),
).components;
const lock = (): Lock =>
	JSON.parse(readFileSync(join(root, "licenses", "source.json"), "utf8"));
const clean: Checkout = {
	revision: "0123456789abcdef0123456789abcdef01234567",
	tags: ["v9.9.9"],
	changes: [],
};

let scratch: string | undefined;
afterEach(() => {
	if (scratch) rmSync(scratch, { recursive: true, force: true });
	scratch = undefined;
});

// A 64-bit Mach-O header for CPU with LC_BUILD_VERSION for macOS MINOS.
function header(cpu: number, minos = 0x000d0000): Uint8Array {
	const bytes = new Uint8Array(32 + 24);
	const view = new DataView(bytes.buffer);
	view.setUint32(0, 0xfeedfacf, true);
	view.setUint32(4, cpu, true);
	view.setUint32(12, 6, true); // MH_DYLIB
	view.setUint32(16, 1, true);
	view.setUint32(20, 24, true);
	view.setUint32(32, 0x32, true);
	view.setUint32(36, 24, true);
	view.setUint32(40, 1, true); // PLATFORM_MACOS
	view.setUint32(44, minos, true);
	return bytes;
}

// A pruned build's layout: the module and the notices its pins require,
// as licenses/notices.ts indexes them.
function fakeBuild(options: { cpu?: number; omit?: string } = {}): string {
	scratch = mkdtempSync(join(tmpdir(), "portal-source-"));
	const dir = join(scratch, "build");
	mkdirSync(join(dir, "portal.bundle", "Contents", "MacOS"), {
		recursive: true,
	});
	writeFileSync(
		join(dir, "portal.bundle", "Contents", "MacOS", "portal.dylib"),
		header(options.cpu ?? 0x0100000c),
	);
	mkdirSync(join(dir, "licenses"));
	const rows = required(root, inventory)
		.filter((component) => component.id !== options.omit)
		.map(
			(component) =>
				`| ${component.name} | ${component.version} | ${component.license.replaceAll("|", "\\|")} | ${component.shipped} | [LICENSE](x/LICENSE) |`,
		);
	writeFileSync(
		join(dir, "licenses", "README.md"),
		[
			"# Portal licenses and third-party notices",
			"",
			"## Components",
			"",
			"| Component | Version | License | Shipped in | Notices |",
			"| --- | --- | --- | --- | --- |",
			"| Bun | 1.3.14 | MIT | portal-host | [LICENSE.md](bun/LICENSE.md) |",
			...rows,
			"",
			"## npm packages bundled into portal-host",
			"",
		].join("\n"),
	);
	return dir;
}

test("a clean staging run writes pointers for every component the module ships", () => {
	const dir = fakeBuild();
	const out = join(scratch as string, "source");
	expect(stage(dir, out, { portal: clean })).toEqual([]);
	const manifest = JSON.parse(readFileSync(join(out, "source.json"), "utf8"));
	expect(manifest.platform).toEqual({
		os: "macos",
		arch: "arm64",
		minimum: "13.0",
	});
	expect(manifest.portal).toEqual({
		revision: clean.revision,
		tags: clean.tags,
	});
	const ids = required(root, inventory).map((component) => component.id);
	expect(Object.keys(manifest.components).sort()).toEqual(ids.sort());
	expect(manifest.components.z2d).toBe("archive:z2d");
	expect(manifest.components.ghostty).toBe("ghostty");
	expect(manifest.components["bash-preexec"]).toBe("libghostty-spm");
	const text = readFileSync(join(out, "SOURCE.md"), "utf8");
	for (const input of manifest.inputs) {
		expect(text).toContain(input.url);
		expect(input.revision ?? input.sha256 ?? input.hash).toBeTruthy();
	}
	expect(text).toContain(`git checkout ${clean.revision}`);
	// Two packages pin a wayland_protocols; translate_c pins aro.
	const what = (id: string) =>
		manifest.inputs.find((input: { id: string }) => input.id === id)?.what;
	expect(what("archive:ghostty/wayland_protocols")).toBe(
		"Pinned by Ghostty's build.zig.zon",
	);
	expect(what("archive:gtk4-layer-shell/wayland_protocols")).toBe(
		"Pinned by Ghostty's pkg/gtk4-layer-shell/build.zig.zon",
	);
	expect(what("archive:aro")).toBe("Pinned by translate_c's build.zig.zon");
});

test("an input missing from licenses/source.json fails, staging nothing", () => {
	const dir = fakeBuild();
	const out = join(scratch as string, "source");
	const damaged = lock();
	damaged.archives = damaged.archives.filter(
		(archive) => archive.name !== "z2d",
	);
	const problems = stage(dir, out, { portal: clean, lock: damaged });
	expect(problems).toHaveLength(1);
	expect(problems[0]).toContain("z2d 8787d71bac42d9aab00428ccb37a4fd453418761");
	expect(problems[0]).toContain("no input holds its source");
	expect(existsSync(out)).toBe(false);
});

test("an input without a digest fails", () => {
	const damaged = lock();
	damaged["libghostty-spm"].xcframework.sha256 = "";
	expect(
		plan({ build: fakeBuild(), portal: clean, lock: damaged }).problems,
	).toEqual(["input ghosttykit-xcframework has no URL, revision or digest"]);
});

test("a lock read from another libghostty-spm fails", () => {
	const damaged = lock();
	damaged["libghostty-spm"].revision = "0".repeat(40);
	const [problem] = plan({
		build: fakeBuild(),
		portal: clean,
		lock: damaged,
	}).problems;
	expect(problem).toContain("run bun licenses/source.ts refresh");
});

test("an Intel module fails", () => {
	expect(
		plan({ build: fakeBuild({ cpu: 0x01000007 }), portal: clean }).problems,
	).toEqual([
		"portal.bundle/Contents/MacOS/portal.dylib is x86_64, not an Apple Silicon (arm64) build",
	]);
});

test("a checkout with changes fails", () => {
	const [problem] = plan({
		build: fakeBuild(),
		portal: { ...clean, changes: [" M native/Views.swift"] },
	}).problems;
	expect(problem).toContain("has changes no revision holds");
	expect(problem).toContain("native/Views.swift");
});

test("notices of another build fail", () => {
	expect(
		plan({ build: fakeBuild({ omit: "z2d" }), portal: clean }).problems,
	).toEqual([
		"the build's notices lack z2d 8787d71bac42d9aab00428ccb37a4fd453418761 (0.13.2), which this checkout's pins require: the build is not of this checkout",
	]);
});

test("a build without the module or notices fails", () => {
	const empty = mkdtempSync(join(tmpdir(), "portal-source-"));
	scratch = empty;
	const problems = plan({ build: empty, portal: clean }).problems;
	expect(problems.some((p) => p.includes("has no portal.bundle"))).toBe(true);
	expect(problems.some((p) => p.includes("has no licenses/README.md"))).toBe(
		true,
	);
});

test("the build's own notices are covered", () => {
	if (
		process.platform !== "darwin" ||
		!existsSync(join(build, "licenses", "README.md"))
	)
		return;
	expect(plan({ build, portal: clean }).problems).toEqual([]);
});

test("index rows unescape pipes", () => {
	expect(
		indexRows(
			"## Components\n\n| Component | Version | License | Shipped in | Notices |\n| --- | --- | --- | --- | --- |\n| a | 1 | MIT \\| Apache | portal.dylib | x |\n",
		),
	).toEqual([{ name: "a", version: "1", shipped: "portal.dylib" }]);
});

test("Mach-O minimums read as versions", () => {
	expect(machO(header(0x0100000c, 0x000e0100))).toEqual({
		arch: "arm64",
		minimum: "14.1",
	});
	expect(machO(new Uint8Array(4)).arch).toBe("unknown");
});

test("build.zig.zon dependencies with URLs are read, comments and paths skipped", () => {
	const zon = `.{
    .name = .ghostty,
    .dependencies = .{
        // .old = .{ .url = "https://example.org/old.tar.gz", .hash = "x" },
        .libxev = .{
            // Comment with "quotes" and https://example.org
            .url = "https://deps.files.ghostty.org/libxev.tar.gz",
            .hash = "libxev-0.0.0-abc",
            .lazy = true,
        },
        .@"name-with-dash" = .{ .url = "https://example.org/a.tgz", .hash = "N-V-1" }, // trailing
        .freetype = .{ .path = "./pkg/freetype", .lazy = true },
    },
    .paths = .{ "build.zig", "src" },
}`;
	expect(zonDependencies(zon)).toEqual([
		{
			name: "libxev",
			url: "https://deps.files.ghostty.org/libxev.tar.gz",
			hash: "libxev-0.0.0-abc",
		},
		{ name: "name-with-dash", url: "https://example.org/a.tgz", hash: "N-V-1" },
	]);
});
