// SPDX-License-Identifier: GPL-3.0-or-later
import { expect, test } from "bun:test";
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { acquireLock } from "../lock.ts";
import { until } from "./support.ts";

test("kernel ownership is exclusive across processes and releases after owner SIGKILL", async () => {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "pi-task-lock-test-"));
	const lock = path.join(root, "owner.lock");
	const ready = path.join(root, "parent-ready");
	const module = new URL("../lock.ts", import.meta.url).href;
	const child = spawn(
		"node",
		[
			"--input-type=module",
			"-e",
			`
    import { acquireLock } from ${JSON.stringify(module)};
    import { writeFileSync } from 'node:fs';
    acquireLock(${JSON.stringify(lock)});
    writeFileSync(${JSON.stringify(ready)}, 'ready');
    setInterval(() => {}, 1000);
  `,
		],
		{ stdio: "ignore" },
	);
	try {
		await until(() => fs.existsSync(ready));
		expect(() => acquireLock(lock)).toThrow("already owned");
		child.kill("SIGKILL");
		await new Promise<void>((resolve) => child.once("exit", () => resolve()));
		// Acquiring the same persistent inode waits for EOF to release the dead owner's holder.
		const release = acquireLock(lock, 3);
		release();
	} finally {
		child.kill("SIGKILL");
		fs.rmSync(root, { recursive: true, force: true });
	}
});
