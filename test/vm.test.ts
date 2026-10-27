// SPDX-License-Identifier: GPL-3.0-or-later
import { expect, test } from "bun:test";
import {
	copyFileSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readdirSync,
	readFileSync,
	rmSync,
	symlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = new URL("./vm.sh", import.meta.url).pathname;
const desktop = new URL("./gui-desktop.sh", import.meta.url).pathname;
const guiAll = new URL("./gui-all.sh", import.meta.url).pathname;
const buildLisp = new URL("../portal-build.el", import.meta.url).pathname;
const emacs =
	process.env.EMACS || "/Applications/Emacs.app/Contents/MacOS/Emacs";
// Only the scratch clone's own configuration counts.
const gitEnv = {
	...process.env,
	GIT_CONFIG_GLOBAL: "/dev/null",
	GIT_CONFIG_NOSYSTEM: "1",
};

function shell(cwd: string, command: string, ...args: string[]) {
	return Bun.spawnSync(
		[
			"/bin/bash",
			"-c",
			`source "$1"; shift; ${command}`,
			"test",
			script,
			...args,
		],
		{
			cwd,
		},
	);
}

test("sync includes working changes and unusual paths, excluding deleted and ignored files", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-sync-"));
	try {
		Bun.spawnSync(["git", "init", "-q"], { cwd });
		await Bun.write(join(cwd, ".gitignore"), "build/\ntarget/\n");
		await Bun.write(join(cwd, "tracked"), "original");
		await Bun.write(join(cwd, "deleted"), "deleted");
		Bun.spawnSync(["git", "add", "."], { cwd });
		await Bun.write(join(cwd, "tracked"), "uncommitted");
		rmSync(join(cwd, "deleted"));
		await Bun.write(join(cwd, "new\nfile"), "new");
		await Bun.write(join(cwd, "build", "host.dylib"), "wrong machine");
		symlinkSync("tracked", join(cwd, "link"));
		const result = shell(
			cwd,
			"source_files | rsync -a --from0 --files-from=- ./ target/",
		);
		expect(result.exitCode).toBe(0);
		expect(readdirSync(join(cwd, "target")).sort()).toEqual([
			".gitignore",
			"link",
			"new\nfile",
			"tracked",
		]);
		expect(readFileSync(join(cwd, "target", "tracked"), "utf8")).toBe(
			"uncommitted",
		);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("remote-shell quoting preserves literal arguments and command exit status", () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-args-"));
	try {
		const argument = "quote ' spaces\n$(not-a-command)";
		const quoted = shell(
			cwd,
			'quote /bin/bash -c \'printf "%s" "$1"; exit 7\' test "$1"',
			argument,
		);
		const result = shell(
			cwd,
			'timeout=5; run_stage test.log /bin/zsh -c "$1"',
			quoted.stdout.toString(),
		);
		expect(result.exitCode).toBe(7);
		expect(readFileSync(join(cwd, "test.log"), "utf8")).toBe(argument);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("unlaunchable commands record a failure", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-launch-"));
	try {
		await Bun.write(join(cwd, "not-executable"), "#!/bin/sh\nexit 0\n");
		const result = shell(cwd, "timeout=5; run_stage test.log ./not-executable");
		expect(result.exitCode).not.toBe(0);
		expect(readFileSync(join(cwd, "test.log"), "utf8")).toContain(
			"Permission denied",
		);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("a command that fails at once leaves no watchdog holding the output", async () => {
	// Killing the watchdog as it forks its sleep left the sleep running in
	// about one run in six; the output stayed open until the limit.
	const cwd = mkdtempSync(join(tmpdir(), "vm-launch-"));
	try {
		await Bun.write(join(cwd, "not-executable"), "#!/bin/sh\nexit 0\n");
		for (let run = 0; run < 20; run++) {
			const start = performance.now();
			shell(cwd, "timeout=3; run_stage test.log ./not-executable");
			expect(performance.now() - start).toBeLessThan(2000);
		}
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("timeout kills the command's process group and releases its desktop lock", () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-timeout-"));
	try {
		const result = shell(
			cwd,
			`exec 9>desktop.lock; lockf 9
			timeout=1; run_stage test.log /bin/bash -c 'echo $$ >pid; sleep 60 & wait'`,
		);
		expect(result.exitCode).toBe(124);
		const pid = Number(readFileSync(join(cwd, "pid"), "utf8"));
		expect(() => process.kill(-pid, 0)).toThrow();
		expect(shell(cwd, "lockf -k -t 0 desktop.lock true").exitCode).toBe(0);
		expect(readFileSync(join(cwd, "test.log"), "utf8")).toContain("Timed out");
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

// Files below ROOT, relative to it, with directories marked by a final slash.
function tree(root: string): string[] {
	return readdirSync(root, { recursive: true, withFileTypes: true })
		.map((entry) => {
			const path = join(entry.parentPath, entry.name).slice(root.length + 1);
			return entry.isDirectory() ? `${path}/` : path;
		})
		.sort();
}

async function writeFiles(root: string, files: Record<string, string>) {
	for (const [file, text] of Object.entries(files)) {
		await Bun.write(join(root, file), text);
	}
}

test("a run takes the previous build only when it is current for its sources", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-work-"));
	try {
		// Sources as the runner syncs them: no build outputs.
		const sources = async (
			swift: string,
			{ notice = "notice", test = "test" } = {},
		) => {
			rmSync(join(cwd, "sources"), { recursive: true, force: true });
			await writeFiles(join(cwd, "sources"), {
				LICENSE: "license",
				"licenses/texts/notice": notice,
				"host/package.json": "{}",
				"native/Package.swift": swift,
				"portal.el": ";; Version: 1.0\n",
				"test/new.el": "",
				"test/portal-core-tests.c": test,
			});
			copyFileSync(buildLisp, join(cwd, "sources", "portal-build.el"));
		};
		await sources("one");
		const identity = Bun.spawnSync([
			emacs,
			"--batch",
			"-Q",
			"-l",
			join(cwd, "sources", "portal-build.el"),
			"--eval",
			"(princ (portal-build-source-identity))",
		]).stdout.toString();
		expect(identity).toMatch(/^[0-9a-f]{64}$/);
		// The previous run's tree, its build recorded from the same native
		// sources, its Lisp tests older.
		const artifacts = [
			"portal.bundle/Contents/Info.plist",
			"portal.bundle/Contents/MacOS/portal.dylib",
			"portal.bundle/Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/terminfo/78/xterm-ghostty",
			"portal.bundle/Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/Ghostty/shell-integration",
			"portal-host",
		];
		const previous = async () => {
			rmSync(join(cwd, "work"), { recursive: true, force: true });
			await writeFiles(join(cwd, "work"), {
				...Object.fromEntries(artifacts.map((file) => [`build/${file}`, ""])),
				"build/portal-build.eld": `(:identity "${identity}" :version "1.0")`,
				"host/node_modules/package/index.js": "",
				LICENSE: "license",
				"licenses/texts/notice": "notice",
				"native/Package.swift": "one",
				"test/old.el": "",
				"test/portal-core-tests.c": "test",
			});
		};
		const take = () => {
			const result = shell(
				cwd,
				'EMACS="$1"; take_work_tree sources work; echo "reused=$reused"',
				emacs,
			);
			expect(result.exitCode).toBe(0);
			expect(existsSync(join(cwd, "sources"))).toBe(false);
			return result.stdout.toString();
		};
		await previous();
		expect(take()).toBe("reused=1\n");
		const kept = tree(join(cwd, "work"));
		expect(kept).toContain("build/portal-build.eld");
		expect(kept).toContain("host/node_modules/package/index.js");
		expect(kept).toContain("test/new.el");
		expect(kept).not.toContain("test/old.el");

		// Changed native sources build afresh.
		await previous();
		await sources("two");
		expect(take()).toBe("reused=\n");
		expect(
			tree(join(cwd, "work")).filter((file) =>
				/^(build|host\/node_modules)\//.test(file),
			),
		).toEqual([]);
		expect(existsSync(join(cwd, "work", "test", "new.el"))).toBe(true);

		// So do changed license files, whose notices the build stages, and
		// changed C tests, which it compiles.
		await previous();
		await sources("one", { notice: "another notice" });
		expect(take()).toBe("reused=\n");
		await previous();
		await sources("one", { test: "another test" });
		expect(take()).toBe("reused=\n");

		// So does an incomplete build, and no previous tree at all.
		await previous();
		await sources("one");
		rmSync(join(cwd, "work", "build", "portal-host"));
		expect(take()).toBe("reused=\n");
		rmSync(join(cwd, "work"), { recursive: true });
		await sources("one");
		expect(take()).toBe("reused=\n");
		expect(existsSync(join(cwd, "work", "portal-build.el"))).toBe(true);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("a run copies back its logs and each suite's, not its tree", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-logs-"));
	try {
		await writeFiles(join(cwd, "run"), {
			"build.log": "",
			"test.log": "",
			"exit-status": "1",
			"gui-progress.log": "",
			"views/test.log": "",
			"views/gui-progress.log": "",
			"views/emacs-sample.log": "",
			"views/exit-status": "124",
			"views/deep/nested.log": "",
			"package/test.log": "",
			"screenshots/panel.png": "",
			"repo/build/portal-build.log": "",
			"repo/test.log": "",
		});
		const result = shell(cwd, `rsync -a "\${log_files[@]}" run/ logs/`);
		expect(result.exitCode).toBe(0);
		expect(tree(join(cwd, "logs"))).toEqual([
			"build.log",
			"exit-status",
			"gui-progress.log",
			"package/",
			"package/test.log",
			"test.log",
			"views/",
			"views/emacs-sample.log",
			"views/exit-status",
			"views/gui-progress.log",
			"views/test.log",
		]);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("every graphical suite runs, each logging to its own directory", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "vm-gui-all-"));
	try {
		// A copy without Git metadata, as in the VM: the suites run here.
		const suite = (body: string) =>
			`echo "$(basename "$0") logs to $PORTAL_TEST_LOGS"\n${body}\n`;
		await writeFiles(join(cwd, "repo", "test"), {
			"views-gui.sh": suite(': >"$PORTAL_TEST_LOGS/gui-progress.log"'),
			"input-gui.sh": suite("echo 'stalled' >&2; exit 124"),
			"launcher-gui.sh": suite(""),
			"terminal-shell-startup.sh": suite(""),
			"package-gui.sh": suite(""),
		});
		copyFileSync(guiAll, join(cwd, "repo", "test", "gui-all.sh"));
		copyFileSync(desktop, join(cwd, "repo", "test", "gui-desktop.sh"));
		const logs = join(cwd, "logs");
		const result = Bun.spawnSync(
			["/bin/sh", join(cwd, "repo", "test", "gui-all.sh")],
			{ cwd, env: { ...gitEnv, PORTAL_TEST_LOGS: logs, PORTAL_TEST_VM: "" } },
		);
		expect(result.exitCode).toBe(1);
		const output = result.stdout.toString();
		expect(output).toMatch(/^views: passed in \d+ s$/m);
		expect(output).toMatch(/^input: failed \(124\) in \d+ s$/m);
		expect(output).toMatch(/^package: passed in \d+ s$/m);
		const suites = [
			"views",
			"input",
			"launcher",
			"terminal-shell-startup",
			"package",
		];
		expect(tree(logs).filter((file) => file.endsWith("/"))).toEqual(
			suites.map((name) => `${name}/`).sort(),
		);
		expect(readFileSync(join(logs, "input", "test.log"), "utf8")).toBe(
			`input-gui.sh logs to ${join(logs, "input")}\nstalled\n`,
		);
		expect(readFileSync(join(logs, "input", "exit-status"), "utf8")).toBe(
			"124\n",
		);
		expect(readFileSync(join(logs, "package", "exit-status"), "utf8")).toBe(
			"0\n",
		);
		expect(existsSync(join(logs, "views", "gui-progress.log"))).toBe(true);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

// A clone with a graphical test script that sources gui-desktop.sh, and a
// stand-in test/vm.sh that reports how it was called.
async function guiClone() {
	const cwd = mkdtempSync(join(tmpdir(), "vm-desktop-"));
	mkdirSync(join(cwd, "test"));
	copyFileSync(desktop, join(cwd, "test", "gui-desktop.sh"));
	await Bun.write(
		join(cwd, "test", "vm.sh"),
		'printf "vm %s:" "$PORTAL_TEST_VM"; printf " %s" "$@"; echo\n',
	);
	await Bun.write(
		join(cwd, "test", "check.sh"),
		`set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/test/gui-desktop.sh"
echo "here $*"
`,
	);
	Bun.spawnSync(["git", "init", "-q"], { cwd, env: gitEnv });
	return cwd;
}

function runCheck(cwd: string, env: Record<string, string | undefined>) {
	const result = Bun.spawnSync(
		["/bin/sh", join(cwd, "test", "check.sh"), "a b", "c"],
		{ cwd: tmpdir(), env: { ...gitEnv, ...env } },
	);
	expect(result.exitCode).toBe(0);
	return result.stdout.toString();
}

test("graphical checks run in a VM only when one is named", async () => {
	const cwd = await guiClone();
	try {
		const here = "here a b c\n";
		expect(runCheck(cwd, { PORTAL_TEST_VM: "" })).toBe(here);
		// Only this clone's own setting counts, not the user's global one.
		const global = join(cwd, "gitconfig");
		await Bun.write(global, "[portal]\n\ttestVm = guest\n");
		expect(runCheck(cwd, { GIT_CONFIG_GLOBAL: global })).toBe(here);
		// The variable alone names a VM for one run; the runner picks the alias.
		expect(runCheck(cwd, { PORTAL_TEST_VM: "other" })).toBe(
			"vm other: sh test/check.sh a b c\n",
		);
		Bun.spawnSync(["git", "config", "portal.testVm", "guest"], {
			cwd,
			env: gitEnv,
		});
		expect(runCheck(cwd, { PORTAL_TEST_VM: "" })).toBe(
			"vm : sh test/check.sh a b c\n",
		);
		expect(runCheck(cwd, { PORTAL_TEST_VM: "other" })).toBe(
			"vm other: sh test/check.sh a b c\n",
		);
		// The VM's copy has no Git metadata, so it never delegates again,
		// even when the guest's own Git configuration names a VM.
		rmSync(join(cwd, ".git"), { recursive: true });
		expect(runCheck(cwd, { GIT_CONFIG_GLOBAL: global })).toBe(here);
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("the runner's alias comes from PORTAL_TEST_VM, then portal.testVm", async () => {
	const cwd = await guiClone();
	try {
		copyFileSync(script, join(cwd, "test", "vm.sh"));
		// A stand-in ssh records the host it was asked for, then fails.
		mkdirSync(join(cwd, "bin"));
		await Bun.write(
			join(cwd, "bin", "ssh"),
			'#!/bin/sh\nprintf "%s\\n" "$4" >>"$SSH_LOG"; exit 1\n',
		);
		Bun.spawnSync(["chmod", "+x", join(cwd, "bin", "ssh")]);
		const log = join(cwd, "ssh.log");
		const global = join(cwd, "gitconfig");
		await Bun.write(global, "[portal]\n\ttestVm = everywhere\n");
		const runner = (vm: string) =>
			Bun.spawnSync(["/bin/bash", join(cwd, "test", "vm.sh"), "true"], {
				cwd,
				env: {
					...gitEnv,
					// A global setting does not name this clone's VM.
					GIT_CONFIG_GLOBAL: global,
					PATH: `${join(cwd, "bin")}:${process.env.PATH}`,
					PORTAL_TEST_VM: vm,
					SSH_LOG: log,
				},
			});
		const missing = runner("");
		expect(missing.exitCode).toBe(2);
		expect(missing.stderr.toString()).toContain("git config portal.testVm");
		Bun.spawnSync(["git", "config", "--local", "portal.testVm", "guest"], {
			cwd,
			env: gitEnv,
		});
		runner("");
		runner("other");
		expect(readFileSync(log, "utf8")).toBe("guest\nother\n");
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});

test("the runner passes the tests' tier to the guest", async () => {
	const cwd = await guiClone();
	try {
		copyFileSync(script, join(cwd, "test", "vm.sh"));
		// Stand-ins: ssh makes the run directory, then records the guest
		// command; rsync copies nothing.
		mkdirSync(join(cwd, "bin"));
		await Bun.write(
			join(cwd, "bin", "ssh"),
			`#!/bin/sh
case $5 in
*mkdir*) echo /guest/portal-test-runs/run.test ;;
*) printf "%s\\n" "$5" >>"$SSH_LOG" ;;
esac
`,
		);
		await Bun.write(join(cwd, "bin", "rsync"), "#!/bin/sh\n");
		Bun.spawnSync([
			"chmod",
			"+x",
			join(cwd, "bin", "ssh"),
			join(cwd, "bin", "rsync"),
		]);
		const log = join(cwd, "ssh.log");
		const runner = (expensive: string) => {
			rmSync(join(cwd, ".cache"), { recursive: true, force: true });
			const result = Bun.spawnSync(
				["/bin/bash", join(cwd, "test", "vm.sh"), "true"],
				{
					cwd,
					env: {
						...gitEnv,
						PATH: `${join(cwd, "bin")}:${process.env.PATH}`,
						PORTAL_TEST_VM: "guest",
						PORTAL_TEST_EXPENSIVE: expensive,
						SSH_LOG: log,
					},
				},
			);
			expect(result.exitCode).toBe(0);
		};
		runner("");
		runner("1");
		const commands = readFileSync(log, "utf8").trimEnd().split("\n");
		expect(commands).toHaveLength(2);
		expect(commands[0]).not.toContain("PORTAL_TEST_EXPENSIVE");
		expect(commands[1]).toContain("PORTAL_TEST_EXPENSIVE=1 /bin/bash");
	} finally {
		rmSync(cwd, { recursive: true, force: true });
	}
});
