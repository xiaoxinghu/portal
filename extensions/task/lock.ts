// SPDX-License-Identifier: GPL-3.0-or-later
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const localLocks = new Set<string>();
const holder = fileURLToPath(new URL("./lock-holder.mjs", import.meta.url));
const sleepCell = new Int32Array(new SharedArrayBuffer(4));
// Bounded local I/O handshake only; elapsed time never advances a task phase.
function waitFor(predicate: () => boolean) {
	const deadline = Date.now() + 5000;
	while (!predicate()) {
		if (Date.now() >= deadline)
			throw new Error(
				"Native lock handshake timed out; inspect the task before retrying",
			);
		Atomics.wait(sleepCell, 0, 0, 5);
	}
}
export function acquireLock(file: string, waitSeconds = 0): () => void {
	file = path.resolve(file);
	if (localLocks.has(file)) throw new Error(`Task is already owned: ${file}`);
	fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
	const prefix = `${file}.${randomUUID()}`;
	const ready = `${prefix}.ready`,
		release = `${prefix}.release`,
		exit = `${prefix}.exit`;
	// Keep the inode (-k). Deleting lock files would let two owners lock different inodes.
	const child = spawn(
		"/bin/sh",
		[
			"-c",
			'lockf -k -t "$6" "$1" node "$2" "$3" "$4"; printf "%s" "$?" > "$5"',
			"pi-task-lock",
			file,
			holder,
			ready,
			release,
			exit,
			String(waitSeconds),
		],
		{ stdio: ["pipe", "ignore", "ignore"] },
	);
	child.on("error", () => {}); // Failure is reported by the bounded handshake below.
	const cleanup = () => {
		child.stdin.destroy();
		for (const p of [ready, release, exit]) fs.rmSync(p, { force: true });
	};
	try {
		waitFor(() => fs.existsSync(ready) || fs.existsSync(exit));
		if (!fs.existsSync(ready))
			throw new Error(`Task is already owned or lockf failed: ${file}`);
	} catch (error) {
		fs.writeFileSync(release, "release\n", { mode: 0o600 });
		child.stdin.destroy();
		// Do not remove a release request until the holder has actually exited.
		if (fs.existsSync(exit)) cleanup();
		throw error;
	}
	localLocks.add(file);
	let released = false;
	return () => {
		if (released) return;
		fs.writeFileSync(release, "release\n", { mode: 0o600 });
		waitFor(() => fs.existsSync(exit));
		released = true;
		localLocks.delete(file);
		cleanup();
	};
}
