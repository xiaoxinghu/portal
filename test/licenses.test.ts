// SPDX-License-Identifier: GPL-3.0-or-later
// The staged license notices cover what the build ships; see docs/licenses.md.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { cp, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { check, swift } from "../licenses/notices";

const build = process.env.PORTAL_BUILD ?? join(import.meta.dir, "..", "build");
let copy: string | undefined;

afterEach(async () => {
	if (copy) await rm(copy, { recursive: true, force: true });
	copy = undefined;
});

// A copy of the staged notices that a test may damage.
async function staged(): Promise<string> {
	copy = await mkdtemp(join(tmpdir(), "portal-licenses-"));
	await cp(join(build, "licenses"), copy, { recursive: true });
	return copy;
}

test("the build stages every required notice", () => {
	expect(check(build)).toEqual([]);
});

// The Swift packages' notices are the macOS module's; Linux's are those of
// Portal's own build of Ghostty. Ghostty's own license is in both.
const ofSwift = [
	"libghostty-spm/LICENSE",
	"bash-preexec/LICENSE-bash-preexec.md",
];
const ofGhosttyLinux = [
	"ghostty-shell-integration/bash-NOTICE",
	"llvm/libcxx/LICENSE.TXT",
];
// One in every build, for the tests that damage a notice.
const everywhere = "fonts/xiaolai/OFL.txt";

test.each([
	"LICENSE",
	...(swift ? ofSwift : ofGhosttyLinux),
	"ghostty/LICENSE",
	everywhere,
	"npm/react@19.2.4/LICENSE",
	"README.md",
])("a missing %s fails the check", async (path) => {
	const directory = await staged();
	await rm(join(directory, path));
	expect(check(build, directory)).toContain(`staged notice ${path} is missing`);
});

test("the staged Bun license matches the Bun inside portal-host", async () => {
	const directory = await staged();
	const bun = Bun.spawnSync([join(build, "portal-host"), "--version"], {
		env: { ...process.env, BUN_BE_BUN: "1" },
	})
		.stdout.toString()
		.trim();
	await rm(join(directory, "bun", bun, "LICENSE.md"));
	expect(check(build, directory)).toContain(
		`staged notice bun/${bun}/LICENSE.md is missing`,
	);
});

test("an edited notice fails the check", async () => {
	const directory = await staged();
	await writeFile(join(directory, everywhere), "edited\n");
	expect(check(build, directory)).toContain(
		`staged notice ${everywhere} is out of date`,
	);
});

test("a stray file fails the check", async () => {
	const directory = await staged();
	await writeFile(join(directory, "extra.txt"), "\n");
	expect(check(build, directory)).toContain(
		"staged file extra.txt is not a required notice",
	);
});

// MPL-2.0 section 3.2(a): a binary release tells recipients where the source
// is. The index names Portal's tag, its pins and z2d's source.
test("the index says where the source is", () => {
	const index = readFileSync(join(build, "licenses", "README.md"), "utf8");
	const section = index.split("## Source\n")[1]?.split("\n## ")[0] ?? "";
	expect(section).toContain("https://github.com/xiaoxinghu/portal");
	const pin = JSON.parse(
		readFileSync(
			join(
				import.meta.dir,
				"..",
				"native",
				swift ? "libghostty-spm.json" : "ghostty.json",
			),
			"utf8",
		),
	);
	expect(section).toContain(pin.revision);
	const z2d = swift
		? "https://github.com/vancluever/z2d/archive/8787d71bac42d9aab00428ccb37a4fd453418761.tar.gz"
		: "https://deps.files.ghostty.org/z2d-40af3e84a4e15a9f31d126b3f281f23ce6a3dae5.tar.gz";
	expect(section).toContain(z2d);
	expect(index).not.toContain("MPL-2.0 code in executable form");
});
