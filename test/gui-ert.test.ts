// SPDX-License-Identifier: GPL-3.0-or-later
import { expect, test } from "bun:test";
import {
	chmodSync,
	copyFileSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = new URL("./gui-ert.sh", import.meta.url).pathname;

// Run gui-ert.sh from a scratch checkout whose Emacs is EMACS, a shell
// script. xcrun and sample are stubs, so no window opens. The watchdog's
// budget is 2 s, or TIMEOUT for runWithin; it counts whole seconds from its
// stamps, so it can run out a second early.
function run(emacs: string, ...args: string[]) {
	return runWithin("2", emacs, ...args);
}

function runWithin(timeout: string, emacs: string, ...args: string[]) {
	const root = mkdtempSync(join(tmpdir(), "gui-ert-"));
	for (const directory of ["test", "build", "bin"]) {
		mkdirSync(join(root, directory));
	}
	copyFileSync(script, join(root, "test", "gui-ert.sh"));
	writeFileSync(join(root, "build", "emacs-include.txt"), root);
	const stubs = {
		xcrun: "exit 0",
		sample: 'echo "sampled $1" >"$4"',
		emacs: `printf '%s\\n' "$@" >"$PORTAL_GUI_ROOT/args"\n${emacs}`,
	};
	for (const [name, body] of Object.entries(stubs)) {
		writeFileSync(join(root, "bin", name), `#!/bin/sh\n${body}\n`);
		chmodSync(join(root, "bin", name), 0o755);
	}
	const result = Bun.spawnSync(
		["/bin/sh", join(root, "test", "gui-ert.sh"), ...args],
		{
			env: {
				PATH: `${join(root, "bin")}:/usr/bin:/bin`,
				EMACS: join(root, "bin", "emacs"),
				PORTAL_GUI_TEST_TIMEOUT: timeout,
			},
		},
	);
	const file = (name: string) => {
		const path = join(root, name);
		return existsSync(path) ? readFileSync(path, "utf8") : "";
	};
	return { result, stderr: result.stderr.toString(), file, root };
}

test("Emacs's arguments come first and its exit status passes through", () => {
	// Nothing times out here: a budget that a loaded machine cannot use up.
	const { result, file, root } = runWithin(
		"30",
		`echo "$(date +%s) start a-test" >>"$PORTAL_GUI_PROGRESS"
		echo "$(date +%s) end a-test" >>"$PORTAL_GUI_PROGRESS"
		exit 3`,
		"-l",
		"suite with spaces.el",
		"--eval",
		'(portal-gui-ert-start "^a-")',
	);
	try {
		expect(result.exitCode).toBe(3);
		const args = file("args").trimEnd().split("\n");
		expect(args[0]).toBe("-Q");
		expect(args).toContain(join(root, "portal.el"));
		expect(args.slice(-4)).toEqual([
			"-l",
			"suite with spaces.el",
			"--eval",
			'(portal-gui-ert-start "^a-")',
		]);
		expect(file("build/gui-progress.log")).toContain("end a-test");
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});

test("a stalled test is sampled, named, and its Emacs and subprocesses killed", () => {
	// Emacs starts each subprocess in a process group of its own.
	const { result, stderr, file, root } = run(
		`echo $$ >"$PORTAL_GUI_ROOT/pid"
		set -m; sleep 60 & echo $! >"$PORTAL_GUI_ROOT/child"; set +m
		echo "$(date +%s) start stuck-test" >>"$PORTAL_GUI_PROGRESS"
		exec sleep 60`,
	);
	try {
		expect(result.exitCode).toBe(124);
		expect(stderr).toContain(
			"GUI checks timed out: stuck-test did not finish within 2s",
		);
		const pid = Number(file("pid"));
		expect(file("build/emacs-sample.log")).toBe(`sampled ${pid}\n`);
		expect(() => process.kill(pid, 0)).toThrow();
		expect(() => process.kill(Number(file("child")), 0)).toThrow();
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});

test("Emacs that never loads its suites times out too", () => {
	const { result, stderr, root } = run("exec sleep 60");
	try {
		expect(result.exitCode).toBe(124);
		expect(stderr).toContain("the suites did not load within 2s");
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});
