// SPDX-License-Identifier: GPL-3.0-or-later
// The slide window's page: it shows the slide the drawing's page, its
// opener, sends it, and passes that page the presenting keys pressed here.
// It loads nothing else, and has no bridge to Emacs.

import { type AudienceMessage, presentKey, type ShowMessage } from "./present";

const opener = window.opener as Window | null;
const image = document.getElementById("slide") as HTMLImageElement;
let shown: string | undefined;
let latest = 0;

function tell(message: AudienceMessage) {
	opener?.postMessage(message, location.origin);
}

function isShow(data: unknown): data is ShowMessage {
	const message = data as Partial<ShowMessage> | null;
	return (
		message?.type === "show" &&
		typeof message.svg === "string" &&
		typeof message.index === "number" &&
		typeof message.count === "number"
	);
}

// Decode a slide before it replaces the one on screen, so a large one never
// shows half drawn, and only the latest of several sent quickly is shown.
window.addEventListener("message", async (event) => {
	if (event.origin !== location.origin || event.source !== opener) return;
	if (!isShow(event.data)) return;
	const { svg, index, count } = event.data;
	const turn = ++latest;
	const url = URL.createObjectURL(new Blob([svg], { type: "image/svg+xml" }));
	const next = new Image();
	next.src = url;
	try {
		await next.decode();
	} catch {
		// A slide that does not decode shows as the browser shows it.
	}
	if (turn !== latest) return URL.revokeObjectURL(url);
	image.src = url;
	image.alt = `Slide ${index + 1} of ${count}`;
	document.title = image.alt;
	if (shown) URL.revokeObjectURL(shown);
	shown = url;
});

window.addEventListener("keydown", (event) => {
	const key = presentKey(event);
	if (!key) return;
	event.preventDefault();
	tell({ type: "key", key });
});

tell({ type: "ready" });
