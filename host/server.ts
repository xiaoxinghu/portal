// SPDX-License-Identifier: GPL-3.0-or-later

import { respond } from "./app";

// A private URL capability, passed only through the parent's readiness pipe.
const token = crypto.randomUUID().replaceAll("-", "");

const server = Bun.serve({
	hostname: "127.0.0.1",
	port: 0,
	fetch: (request): Promise<Response> =>
		respond(request, `127.0.0.1:${server.port}`, token),
});

let stopping = false;
async function shutdown() {
	if (stopping) return;
	stopping = true;
	// Bound shutdown even if a client keeps a request open.
	setTimeout(() => process.exit(0), 1000);
	await server.stop();
	process.exit(0);
}

// The parent's pipe is also our lifetime: EOF covers an abrupt Emacs exit.
process.stdin.on("end", shutdown);
process.stdin.on("error", shutdown);
process.stdin.resume();
for (const signal of ["SIGHUP", "SIGTERM", "SIGINT"] as const) {
	process.on(signal, shutdown);
}
process.stdout.on("error", shutdown);

// stdout is a protocol channel. Send diagnostics to stderr instead.
process.stdout.write(
	JSON.stringify({ type: "ready", protocol: 3, port: server.port, token }) +
		"\n",
);
