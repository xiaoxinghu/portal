// SPDX-License-Identifier: GPL-3.0-or-later
// The staged license notices cover what the build ships; see docs/licenses.md.
import { afterEach, expect, test } from "bun:test";
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
