// SPDX-License-Identifier: GPL-3.0-or-later

/** The password the sign-in page accepts, with any user name. */
export const password = "portal";

function page(status: number, title: string, headers = {}): Response {
	const text = Bun.escapeHTML(title);
	return new Response(
		`<!doctype html>
<html lang="en">
	<head>
		<meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<title>${text}</title>
		<style>:root { color-scheme: light dark; font-family: system-ui, sans-serif; }</style>
	</head>
	<body><main><h1>${text}</h1></main></body>
</html>
`,
		{
			status,
			headers: {
				"Content-Type": "text/html; charset=utf-8",
				"Content-Security-Policy":
					"default-src 'none'; style-src 'unsafe-inline'",
				...headers,
			},
		},
	);
}

/** ENCODED, Base64 of UTF-8 text, as that text, or "" if it is not Base64. */
function decode(encoded: string): string {
	try {
		return new TextDecoder().decode(
			Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0)),
		);
	} catch {
		return "";
	}
}

/** A page behind HTTP Basic authentication, which tries a web view's
 * answer to it: any user name with `password` signs in. */
export function signIn(request: Request): Response {
	const [scheme, encoded] = (request.headers.get("authorization") ?? "").split(
		" ",
	);
	const pair =
		scheme?.toLowerCase() === "basic" && encoded ? decode(encoded) : "";
	const colon = pair.indexOf(":");
	if (colon > 0 && pair.slice(colon + 1) === password)
		return page(200, `Signed in as ${pair.slice(0, colon)}`);
	return page(401, "Not signed in", {
		"WWW-Authenticate": 'Basic realm="Portal", charset="UTF-8"',
	});
}
