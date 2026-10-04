// SPDX-License-Identifier: GPL-3.0-or-later
// A deterministic interactive CLI fixture, not an LLM. Uses the real helper protocol.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";

const dir = process.env.PI_TASK_DIRECTORY;
const helper = process.env.PI_TASK_TEST_HELPER;
const args = process.argv.slice(2);
const settings = JSON.parse(
	readFileSync(args[args.indexOf("--settings") + 1], "utf8"),
);
const load = () =>
	JSON.parse(readFileSync(path.join(dir, "state.json"), "utf8"));
const trace = (value) =>
	appendFileSync(
		path.join(dir, ".runtime", "mock-trace.jsonl"),
		`${JSON.stringify(value)}\n`,
	);
const invoke = (name, extra = {}) => {
	const hook = settings.hooks[name][0].hooks[0].command;
	execFileSync("/bin/sh", ["-c", hook], {
		input: JSON.stringify({
			hook_event_name: name,
			session_id: load().implementor.session,
			...extra,
		}),
	});
};
const git = (...argv) => execFileSync("git", argv, { encoding: "utf8" }).trim();
trace({ args });
invoke("SessionStart");
function turn(prompt) {
	trace({ prompt });
	invoke("UserPromptSubmit", { prompt });
	const s = load();
	if (s.phase === "implementing") {
		writeFileSync("source.txt", `fixed round ${s.review_round + 1}\n`);
		git("add", "source.txt");
		git("commit", "-m", `round ${s.review_round + 1}`);
		const checks = path.join(dir, ".runtime", "checks.md");
		writeFileSync(checks, "Fixture check passed.\n");
		for (let retry = 0; ; retry++) {
			try {
				execFileSync(
					"node",
					[
						helper,
						"submit",
						dir,
						String(load().version),
						git("rev-parse", "HEAD"),
						checks,
					],
					{ encoding: "utf8" },
				);
				break;
			} catch (error) {
				if (retry >= 3 || !String(error.stderr).includes("State changed"))
					throw error;
			}
		}
	}
	invoke("Stop");
}
readline
	.createInterface({ input: process.stdin })
	.on("line", (line) => turn(line));
turn(args.at(-1));
