// SPDX-License-Identifier: GPL-3.0-or-later
// Runs under macOS lockf. EOF releases ownership when the parent crashes.
import { existsSync, watch, writeFileSync } from "node:fs";
import path from "node:path";

const [ready, release] = process.argv.slice(2);
const finish = () => process.exit(0);
const check = () => {
	if (existsSync(release)) finish();
};
watch(path.dirname(release), check);
process.stdin.resume();
process.stdin.on("end", finish);
process.stdin.on("error", finish);
writeFileSync(ready, "ready\n", { mode: 0o600 });
check();
