// SPDX-License-Identifier: GPL-3.0-or-later
// Presenting: the keys that move through the slides, in the console and in
// the slide window alike, and the messages between the two pages. The slide
// window's bundle includes this file and nothing of the editor's.

/** The drawing's page to the slide window: show this slide, the SVG of
 * slide INDEX, counting from 0, of COUNT. */
export type ShowMessage = {
	type: "show";
	svg: string;
	index: number;
	count: number;
};

/** The slide window to the drawing's page: "ready" once it has loaded, and
 * each presenting key pressed while it has the keyboard. */
export type AudienceMessage =
	| { type: "ready" }
	| { type: "key"; key: PresentKey };

/** What a key does while presenting. */
export type PresentKey = "next" | "previous" | "first" | "last" | "stop";

const keys: Record<string, PresentKey> = {
	ArrowRight: "next",
	ArrowDown: "next",
	" ": "next",
	PageDown: "next",
	ArrowLeft: "previous",
	ArrowUp: "previous",
	PageUp: "previous",
	Home: "first",
	End: "last",
	Escape: "stop",
};

/** What EVENT does while presenting, or undefined for a key that does
 * nothing there, such as any chord. A presentation clicker types Page Up
 * and Page Down, or the arrows. */
export function presentKey(event: {
	key: string;
	metaKey: boolean;
	ctrlKey: boolean;
	altKey: boolean;
	shiftKey: boolean;
}): PresentKey | undefined {
	if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey)
		return undefined;
	return Object.hasOwn(keys, event.key) ? keys[event.key] : undefined;
}

/** The slide index KEY moves to from INDEX among COUNT slides, or
 * undefined for "stop". It stays within the slides. */
export function stepSlide(
	key: PresentKey,
	index: number,
	count: number,
): number | undefined {
	const last = Math.max(0, count - 1);
	switch (key) {
		case "next":
			return Math.min(last, index + 1);
		case "previous":
			return Math.max(0, index - 1);
		case "first":
			return 0;
		case "last":
			return last;
		case "stop":
			return undefined;
	}
}
