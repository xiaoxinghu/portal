// SPDX-License-Identifier: GPL-3.0-or-later
// Fixture tests for test/vm-retention.sh: HOME is a scratch directory, so
// its portal-test-runs stands in for the VM's.
import { afterEach, beforeEach, expect, test } from "bun:test";
import {
	copyFileSync,
	existsSync,
	lstatSync,
	mkdirSync,
	mkdtempSync,
	readdirSync,
	readFileSync,
	rmSync,
	symlinkSync,
	utimesSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = new URL("./vm-retention.sh", import.meta.url).pathname;
const runner = new URL("./vm.sh", import.meta.url).pathname;
const day = 86400;
const gitEnv = {
	...process.env,
	GIT_CONFIG_GLOBAL: "/dev/null",
	GIT_CONFIG_NOSYSTEM: "1",
};

let home: string;
let root: string;

beforeEach(() => {
	home = mkdtempSync(join(tmpdir(), "vm-retention-"));
	root = join(home, "portal-test-runs");
	mkdirSync(root);
	// The runner's lock file, which every run opens.
	writeFileSync(join(root, ".desktop.lock"), "");
});

afterEach(() => {
	// Clear any immutable flag a test set, then remove everything.
	Bun.spawnSync(["chflags", "-R", "nouchg", home]);
	rmSync(home, { recursive: true, force: true });
});

const now = () => Math.floor(Date.now() / 1000);

// A run directory with logs, a top-level exit-status written AGE seconds
// ago when STATUS is given, and a repo/ snapshot unless told otherwise.
function run(
	name: string,
	{
		status,
		age = 0,
		repo = true,
	}: { status?: string; age?: number; repo?: boolean } = {},
) {
	const dir = join(root, name);
	mkdirSync(dir);
	writeFileSync(join(dir, "test.log"), "log\n");
	if (repo) {
		mkdirSync(join(dir, "repo", "build"), { recursive: true });
		writeFileSync(join(dir, "repo", "build", "portal.dylib"), "");
	}
	if (status !== undefined) {
		writeFileSync(join(dir, "exit-status"), status);
		const time = now() - age;
		utimesSync(join(dir, "exit-status"), time, time);
	}
	return dir;
}

function retention(...args: string[]) {
	const result = Bun.spawnSync(["/bin/bash", script, "--guest", ...args], {
		env: { ...process.env, HOME: home },
	});
	return {
		code: result.exitCode,
		out: result.stdout.toString(),
		err: result.stderr.toString(),
	};
}

// Paths below ROOT, directories marked by a final slash; symbolic links
// are not followed.
function tree(dir = root): string[] {
	return readdirSync(dir, { recursive: true, withFileTypes: true })
		.map((entry) => {
			const path = join(entry.parentPath, entry.name).slice(dir.length + 1);
			return entry.isDirectory() ? `${path}/` : path;
		})
		.sort();
}

const hasRepo = (name: string) => existsSync(join(root, name, "repo"));

test("the five newest failures keep their snapshots, counting every failure", () => {
	// Oldest first: f1 … f8 failed a day apart, two runs passing between.
	for (let n = 1; n <= 8; n++)
		run(`run.f${n}`, { status: "1\n", age: (10 - n) * day });
	run("run.ok1", { status: "0\n", age: 1.5 * day, repo: false });
	run("run.ok2", { status: "0\n", age: 0.5 * day, repo: false });
	// The newest failure, f9, failed before its build: its repo/ holds
	// unbuilt sources, and it counts. f7's snapshot is already gone; it
	// counts too.
	run("run.f9", { status: "1\n", age: 0 });
	rmSync(join(root, "run.f7", "repo"), { recursive: true });
	// A suite's newer exit-status does not make f1 recent.
	mkdirSync(join(root, "run.f1", "views"));
	writeFileSync(join(root, "run.f1", "views", "exit-status"), "124\n");
	const result = retention("prune");
	expect(result.code).toBe(0);
	const kept = ["run.f9", "run.f8", "run.f6", "run.f5"];
	for (const name of kept) expect(hasRepo(name)).toBe(true);
	for (const name of ["run.f1", "run.f2", "run.f3", "run.f4"]) {
		expect(hasRepo(name)).toBe(false);
		// Only the snapshot goes; the logs and status stay.
		expect(existsSync(join(root, name, "test.log"))).toBe(true);
		expect(existsSync(join(root, name, "exit-status"))).toBe(true);
	}
	expect(existsSync(join(root, "run.f1", "views", "exit-status"))).toBe(true);
	expect(result.out).toContain("Removed run.f4/repo: failed");
	expect(result.out).toContain("Kept run.f9/repo: failed");
	expect(result.out).toMatch(
		/^Retention: removed 0 runs over 30 days old and 4 snapshots beyond the 5 newest failures; kept 4 snapshots, 0 pinned runs and 0 incomplete runs$/m,
	);
	// Removals newest first.
	const removed = result.out.match(/run\.f\d(?=\/repo: failed)/g);
	expect(removed).toEqual([...kept, "run.f4", "run.f3", "run.f2", "run.f1"]);
});

test("runs go 30 days after completion, snapshots and all", () => {
	run("run.young", { status: "1\n", age: 30 * day - 60 });
	run("run.old", { status: "1\n", age: 30 * day + 60 });
	run("run.oldpass", { status: "0\n", age: 40 * day, repo: false });
	const result = retention("prune");
	expect(result.code).toBe(0);
	expect(readdirSync(root).sort()).toEqual([".desktop.lock", "run.young"]);
	// Within the five newest failures, the age limit still wins.
	expect(hasRepo("run.young")).toBe(true);
	expect(result.out).toContain("Removed run.old: completed");
	expect(result.out).toMatch(/removed 2 runs over 30 days old and 0 snapshots/);
});

test("a pinned run stays whole and takes no snapshot's place", () => {
	run("run.pinned", { status: "1\n", age: 0 });
	for (let n = 1; n <= 6; n++)
		run(`run.f${n}`, { status: "1\n", age: n * day });
	run("run.ancient", { status: "1\n", age: 90 * day });
	expect(retention("pin", "run.pinned").out).toBe(
		"Pinned run.pinned: retention keeps it until unpin\n",
	);
	expect(retention("pin", "run.ancient").code).toBe(0);
	expect(retention("pin", "run.ancient").out).toBe(
		"run.ancient was already pinned\n",
	);
	const result = retention("prune");
	expect(result.code).toBe(0);
	expect(hasRepo("run.pinned")).toBe(true);
	expect(hasRepo("run.ancient")).toBe(true);
	for (let n = 1; n <= 5; n++) expect(hasRepo(`run.f${n}`)).toBe(true);
	expect(hasRepo("run.f6")).toBe(false);
	expect(result.out).toContain("Pinned run.ancient: kept until unpinned");
	expect(result.out).toContain("2 pinned runs");
	// Unpinned, it is a failure like any other: the newest, a snapshot kept.
	expect(retention("unpin", "run.pinned").out).toBe("Unpinned run.pinned\n");
	expect(retention("unpin", "run.pinned").out).toBe(
		"run.pinned was not pinned\n",
	);
	retention("unpin", "run.ancient");
	retention("prune");
	expect(hasRepo("run.pinned")).toBe(true);
	expect(hasRepo("run.f5")).toBe(false);
	expect(existsSync(join(root, "run.ancient"))).toBe(false);
});

test("runs without a valid exit-status stay and are reported, the current one not", () => {
	const statuses: Record<string, string> = {
		"run.empty": "",
		"run.high": "256\n",
		"run.two": "1\n2\n",
		"run.blank": "1\n\n",
		"run.blanks": "1\n\n\n",
		"run.word": "fail\n",
		"run.zero": "00\n",
		"run.long": `1${" ".repeat(100)}\n`,
	};
	for (const [name, status] of Object.entries(statuses))
		run(name, { status, age: 60 * day });
	run("run.missing");
	run("run.dir");
	mkdirSync(join(root, "run.dir", "exit-status"));
	run("run.link");
	writeFileSync(join(home, "status"), "1\n");
	symlinkSync(join(home, "status"), join(root, "run.link", "exit-status"));
	run("run.bare", { status: "255", age: 60 * day });
	const before = tree();
	const result = retention("prune");
	expect(result.code).toBe(0);
	// Only the valid status, without a final newline, counted.
	expect(existsSync(join(root, "run.bare"))).toBe(false);
	expect(tree().filter((path) => !path.startsWith("run.bare"))).toEqual(
		before.filter((path) => !path.startsWith("run.bare")),
	);
	for (const name of [...Object.keys(statuses), "run.dir", "run.link"])
		expect(result.out).toContain(
			`Incomplete ${name}: malformed exit-status, kept`,
		);
	expect(result.out).toContain("Incomplete run.missing: no exit-status, kept");
	expect(result.out).toContain("11 incomplete runs");

	// Called by the runner, its own run goes unmentioned.
	const fd = Bun.spawnSync(
		[
			"/bin/bash",
			"-c",
			'exec 9>>"$HOME/portal-test-runs/.desktop.lock"; exec /bin/bash "$1" --runner run.missing',
			"test",
			script,
		],
		{ env: { ...process.env, HOME: home } },
	);
	expect(fd.exitCode).toBe(0);
	const out = fd.stdout.toString();
	expect(out).not.toContain("run.missing");
	expect(out).toContain("10 incomplete runs");
});

test("nothing outside the run directories is touched, nor followed", () => {
	const outside = join(home, "outside");
	mkdirSync(join(outside, "run.away", "repo"), { recursive: true });
	writeFileSync(join(outside, "run.away", "exit-status"), "1\n");
	utimesSync(join(outside, "run.away", "exit-status"), 0, 0);
	writeFileSync(join(outside, "kept"), "");
	mkdirSync(join(root, "work", "build"), { recursive: true });
	writeFileSync(join(root, "run.file"), "");
	mkdirSync(join(root, "other"));
	writeFileSync(join(root, "other", "exit-status"), "1\n");
	symlinkSync(join(outside, "run.away"), join(root, "run.away"));
	// An old failure whose repo/ and a log are links out of it.
	const old = run("run.old", { status: "1\n", age: 60 * day, repo: false });
	symlinkSync(outside, join(old, "repo"));
	symlinkSync(join(outside, "kept"), join(old, "link.log"));
	for (let n = 1; n <= 6; n++)
		run(`run.f${n}`, { status: "1\n", age: n * day });
	symlinkSync(outside, join(root, "run.f6", "repo", "out"));
	const outsideBefore = tree(outside);
	const result = retention("prune");
	expect(result.code).toBe(0);
	expect(tree(outside)).toEqual(outsideBefore);
	expect(readdirSync(root).sort()).toEqual([
		".desktop.lock",
		"other",
		"run.away",
		"run.f1",
		"run.f2",
		"run.f3",
		"run.f4",
		"run.f5",
		"run.f6",
		"run.file",
		"work",
	]);
	expect(lstatSync(join(root, "run.away")).isSymbolicLink()).toBe(true);
	expect(existsSync(join(root, "work", "build"))).toBe(true);
	expect(hasRepo("run.f6")).toBe(false);
	expect(result.out).toContain("Skipped run.away: not a run directory");
	expect(result.out).toContain("Skipped run.file: not a run directory");
	expect(result.out).not.toContain("other");
	expect(result.out).not.toContain("work");
});

test("pin and unpin name one run directory", () => {
	run("run.real", { status: "1\n" });
	mkdirSync(join(root, "work"));
	symlinkSync(join(root, "run.real"), join(root, "run.alias"));
	for (const name of ["run.real/repo", "../run.real", "run.", "work", ""]) {
		const result = retention("pin", name);
		expect(result.code).toBe(2);
		expect(result.err).toContain("Name a run as the runner prints it");
	}
	for (const name of ["run.none", "run.alias"]) {
		const result = retention("unpin", name);
		expect(result.code).toBe(1);
		expect(result.err).toContain(`No run directory ${root}/${name}`);
	}
	expect(retention("pin").code).toBe(2);
	expect(retention("pin", "run.real", "run.real").code).toBe(2);
	expect(retention("prune", "now").code).toBe(2);
	expect(retention("remove").code).toBe(2);
	expect(tree()).not.toContain("run.real/.keep");
});

test("a preview changes nothing and repeated prunes find nothing more", () => {
	for (let n = 1; n <= 7; n++)
		run(`run.f${n}`, { status: "1\n", age: n * day });
	run("run.old", { status: "0\n", age: 31 * day, repo: false });
	const before = tree();
	const preview = retention("preview");
	expect(preview.code).toBe(0);
	expect(tree()).toEqual(before);
	expect(preview.out).toContain("Would remove run.f6/repo: failed");
	expect(preview.out).toContain("Would remove run.old: completed");
	expect(preview.out).toMatch(
		/^Retention preview: would remove 1 run over 30 days old and 2 snapshots beyond the 5 newest failures; kept 5 snapshots, 0 pinned runs and 0 incomplete runs$/m,
	);
	const first = retention("prune");
	expect(
		first.out
			.replaceAll("Removed", "Would remove")
			.replace("Retention: removed", "Retention preview: would remove"),
	).toBe(preview.out);
	const after = tree();
	const second = retention("prune");
	expect(second.code).toBe(0);
	expect(tree()).toEqual(after);
	expect(second.out).toMatch(
		/^Retention: removed 0 runs over 30 days old and 0 snapshots/m,
	);
	expect(second.out).not.toContain("Removed");
	// With no runs directory at all, there is nothing to do.
	rmSync(root, { recursive: true });
	expect(retention("prune")).toMatchObject({
		code: 0,
		out: `No test runs in ${root}\n`,
	});
	expect(existsSync(root)).toBe(false);
});

test("a cleanup error fails the command but not the run", () => {
	for (let n = 1; n <= 7; n++)
		run(`run.f${n}`, { status: "1\n", age: n * day });
	// An immutable file stops rm; f7's snapshot cannot go, f6's can.
	Bun.spawnSync([
		"chflags",
		"uchg",
		join(root, "run.f7", "repo", "build", "portal.dylib"),
	]);
	const manual = retention("prune");
	expect(manual.code).toBe(1);
	expect(manual.out).toMatch(/^Could not remove run\.f7\/repo: .+$/m);
	expect(manual.out).toContain("Removed run.f6/repo");
	expect(manual.out).toMatch(/; 1 cleanup error$/m);

	// The runner warns and goes on, under its set -e, the list in its log.
	const current = run("run.current");
	const result = Bun.spawnSync(
		[
			"/bin/bash",
			"-c",
			`source "$1"
			run=$2
			exec 9>>"$HOME/portal-test-runs/.desktop.lock"; lockf 9
			prune_runs
			echo "went on"`,
			"test",
			runner,
			current,
		],
		{ env: { ...process.env, HOME: home } },
	);
	expect(result.exitCode).toBe(0);
	expect(result.stdout.toString()).toBe("went on\n");
	expect(result.stderr.toString()).toMatch(
		/^Warning: pruning earlier runs failed \(1\); the run goes on\. Retention: removed .+; 1 cleanup error; the list is in retention\.log\n$/,
	);
	const log = readFileSync(join(current, "retention.log"), "utf8");
	expect(log).toMatch(/^Could not remove run\.f7\/repo: /m);
	expect(log).not.toContain("run.current");
});

test("the runner prints one line and keeps the list in its run's log", () => {
	for (let n = 1; n <= 6; n++)
		run(`run.f${n}`, { status: "1\n", age: n * day });
	const current = run("run.current");
	const result = Bun.spawnSync(
		[
			"/bin/bash",
			"-c",
			'source "$1"; run=$2; exec 9>>"$HOME/portal-test-runs/.desktop.lock"; lockf 9; prune_runs',
			"test",
			runner,
			current,
		],
		{ env: { ...process.env, HOME: home } },
	);
	expect(result.exitCode).toBe(0);
	expect(result.stdout.toString()).toBe(
		"Retention: removed 0 runs over 30 days old and 1 snapshot beyond the 5 newest failures; kept 5 snapshots, 0 pinned runs and 0 incomplete runs; the list is in retention.log\n",
	);
	const log = readFileSync(join(current, "retention.log"), "utf8");
	expect(log).toContain("Removed run.f6/repo");
	expect(hasRepo("run.current")).toBe(true);
	// Without the runner's lock it refuses.
	const unlocked = Bun.spawnSync(
		["/bin/bash", script, "--runner", "run.current"],
		{
			env: { ...process.env, HOME: home },
		},
	);
	expect(unlocked.exitCode).toBe(2);
});

test("prune, pin and unpin wait for a test run's lock; preview does not", async () => {
	for (let n = 1; n <= 6; n++)
		run(`run.f${n}`, { status: "1\n", age: n * day });
	const lock = join(root, ".desktop.lock");
	// A test run holding the desktop, as the runner holds it.
	const holder = Bun.spawn(
		[
			"/bin/bash",
			"-c",
			'exec 9>>"$1"; lockf 9; echo held; sleep 1.5',
			"test",
			lock,
		],
		{ stdout: "pipe" },
	);
	const reader = holder.stdout.getReader();
	await reader.read();
	let start = performance.now();
	const preview = retention("preview");
	expect(performance.now() - start).toBeLessThan(1000);
	expect(preview.out).toContain("Would remove run.f6/repo");
	start = performance.now();
	const prune = Bun.spawn(["/bin/bash", script, "--guest", "prune"], {
		env: { ...process.env, HOME: home },
		stdout: "pipe",
	});
	const out = await new Response(prune.stdout).text();
	expect(await prune.exited).toBe(0);
	expect(performance.now() - start).toBeGreaterThan(1000);
	expect(out).toMatch(/^Waiting for the VM desktop: a test run holds it…\n/);
	expect(hasRepo("run.f6")).toBe(false);
	await holder.exited;
	// Free, it does not say it waits.
	expect(retention("pin", "run.f1").out).toBe(
		"Pinned run.f1: retention keeps it until unpin\n",
	);
});

test("the host command pipes the script to the VM the runner would use", async () => {
	// A clone with both scripts and a stand-in ssh that records the host and
	// runs the remote command here, its input the piped script.
	const clone = join(home, "clone");
	mkdirSync(join(clone, "test"), { recursive: true });
	mkdirSync(join(clone, "bin"));
	copyFileSync(script, join(clone, "test", "vm-retention.sh"));
	copyFileSync(runner, join(clone, "test", "vm.sh"));
	writeFileSync(
		join(clone, "bin", "ssh"),
		'#!/bin/sh\nprintf "%s\\n" "$4" >>"$SSH_LOG"\nexec /bin/sh -c "$5"\n',
	);
	Bun.spawnSync(["chmod", "+x", join(clone, "bin", "ssh")]);
	Bun.spawnSync(["git", "init", "-q"], { cwd: clone, env: gitEnv });
	run("run.f1", { status: "1\n", age: 31 * day });
	run("run.f2", { status: "1\n" });
	const log = join(home, "ssh.log");
	const host = (vm: string, ...args: string[]) => {
		const result = Bun.spawnSync(
			["/bin/bash", join(clone, "test", "vm-retention.sh"), ...args],
			{
				cwd: tmpdir(),
				env: {
					...gitEnv,
					HOME: home,
					PATH: `${join(clone, "bin")}:${process.env.PATH}`,
					PORTAL_TEST_VM: vm,
					SSH_LOG: log,
				},
			},
		);
		return {
			code: result.exitCode,
			out: result.stdout.toString(),
			err: result.stderr.toString(),
		};
	};
	const missing = host("", "preview");
	expect(missing.code).toBe(2);
	expect(missing.err).toContain("git config portal.testVm");
	Bun.spawnSync(["git", "config", "--local", "portal.testVm", "guest"], {
		cwd: clone,
		env: gitEnv,
	});
	expect(host("", "preview").out).toContain("Would remove run.f1: completed");
	expect(host("other", "pin", "run.f2").out).toBe(
		"Pinned run.f2: retention keeps it until unpin\n",
	);
	expect(host("", "prune").out).toContain("Removed run.f1: completed");
	expect(readFileSync(log, "utf8")).toBe("guest\nother\nguest\n");
	// Usage and run names are checked before any connection.
	expect(host("", "status").code).toBe(2);
	expect(host("", "unpin", "run.f2/repo").code).toBe(2);
	const unknown = host("", "unpin", "run.none");
	expect(unknown.code).toBe(1);
	expect(unknown.err).toContain("No run directory");
	expect(readFileSync(log, "utf8")).toBe("guest\nother\nguest\nguest\n");
	expect(existsSync(join(root, "run.f2", ".keep"))).toBe(true);
});
