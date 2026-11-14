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
	switch (key) {
		case "next":
			return slideBy(index, 1, count);
		case "previous":
			return slideBy(index, -1, count);
		case "first":
			return 0;
		case "last":
			return Math.max(0, count - 1);
		case "stop":
			return undefined;
	}
}

/** The slide index DELTA slides on from INDEX among COUNT, within them. */
export function slideBy(index: number, delta: number, count: number) {
	return Math.max(0, Math.min(Math.max(0, count - 1), index + delta));
}

/** MS milliseconds as minutes and seconds, "4:05"; past an hour the
 * minutes go on counting, "75:00". */
export function elapsed(ms: number) {
	const seconds = Math.max(0, Math.floor(ms / 1000));
	return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

// The laser: lines dragged on the console's current slide, shown in both
// pages over the slide, each fading away once the pointer lifts. Nothing of
// it is saved or sent to Emacs.

/** How long a line takes to fade once the pointer lifts, in milliseconds;
 * it is gone then. */
export const LASER_FADE = 2000;

/** The laser's one colour. */
export const LASER_COLOUR = "#e03131";

/** A line: its points as x, y pairs in the slide's own units, from 0 to its
 * frame's width and height, and whether it is fading. */
export type Stroke = { id: number; points: number[]; fading: boolean };

/** The drawing's page to the slide window: the lines of slide INDEX, whose
 * frame is WIDTH by HEIGHT, all of them, replacing those it shows. */
export type LaserMessage = {
	type: "laser";
	index: number;
	width: number;
	height: number;
	strokes: Stroke[];
};

export function isLaser(data: unknown): data is LaserMessage {
	const message = data as Partial<LaserMessage> | null;
	return (
		message?.type === "laser" &&
		typeof message.index === "number" &&
		typeof message.width === "number" &&
		typeof message.height === "number" &&
		Array.isArray(message.strokes)
	);
}

/** A line's width on a slide WIDTH by HEIGHT, so that it scales with it. */
export const laserWidth = (width: number, height: number) =>
	Math.max(width, height) / 160;

const tenth = (value: number) => Math.round(value * 10) / 10;

/** The point in slide units under CLIENT X and Y, for a slide WIDTH by
 * HEIGHT drawn as large as fits in BOX, centred, as an image's
 * `object-fit: contain` and an SVG's `xMidYMid meet` draw it; and whether
 * it is on the slide. */
export function slidePoint(
	x: number,
	y: number,
	box: { left: number; top: number; width: number; height: number },
	width: number,
	height: number,
) {
	const scale = Math.min(box.width / width, box.height / height);
	const point = [
		tenth((x - box.left - (box.width - width * scale) / 2) / scale),
		tenth((y - box.top - (box.height - height * scale) / 2) / scale),
	] as const;
	const inside =
		point[0] >= 0 && point[0] <= width && point[1] >= 0 && point[1] <= height;
	return { point, inside };
}

/** An SVG path through POINTS, x, y pairs, smoothed by curves through the
 * midpoints between them; one point is a dot. */
export function strokePath(points: readonly number[]) {
	const count = Math.floor(points.length / 2);
	if (!count) return "";
	const at = (i: number) => `${points[2 * i]} ${points[2 * i + 1]}`;
	if (count === 1) return `M${at(0)}l0 0`;
	let path = `M${at(0)}`;
	for (let i = 1; i < count - 1; i++) {
		const middle = [0, 1].map((axis) =>
			tenth(
				((points[2 * i + axis] ?? 0) + (points[2 * i + 2 + axis] ?? 0)) / 2,
			),
		);
		path += `Q${at(i)} ${middle[0]} ${middle[1]}`;
	}
	return `${path}L${at(count - 1)}`;
}

const svgNamespace = "http://www.w3.org/2000/svg";
const svgElement = <K extends keyof SVGElementTagNameMap>(name: K) =>
	document.createElementNS(svgNamespace, name);

/** Draw LASER's lines in LAYER, an <svg> laid over the slide image, or none
 * without it. A line it already shows keeps its path, so a fade that has
 * started goes on. The lines are clipped to the slide. */
export function drawLaser(layer: SVGSVGElement, laser?: LaserMessage) {
	let lines = layer.querySelector("g");
	if (!lines) {
		const clip = svgElement("clipPath");
		clip.id = "laser-clip";
		clip.append(svgElement("rect"));
		lines = svgElement("g");
		const attributes = {
			"clip-path": "url(#laser-clip)",
			fill: "none",
			stroke: LASER_COLOUR,
			"stroke-linecap": "round",
			"stroke-linejoin": "round",
		};
		for (const [name, value] of Object.entries(attributes))
			lines.setAttribute(name, value);
		layer.setAttribute("preserveAspectRatio", "xMidYMid meet");
		layer.append(clip, lines);
	}
	const strokes = laser?.strokes ?? [];
	if (laser) {
		const { width, height } = laser;
		layer.setAttribute("viewBox", `0 0 ${width} ${height}`);
		const rect = layer.querySelector("rect");
		rect?.setAttribute("width", String(width));
		rect?.setAttribute("height", String(height));
		lines.setAttribute("stroke-width", String(laserWidth(width, height)));
	}
	const paths = new Map<string, SVGPathElement>();
	for (const path of lines.querySelectorAll("path"))
		paths.set(path.dataset.id ?? "", path);
	const wanted = new Set(strokes.map((stroke) => String(stroke.id)));
	for (const [id, path] of paths) if (!wanted.has(id)) path.remove();
	for (const stroke of strokes) {
		const id = String(stroke.id);
		let path = paths.get(id);
		if (!path) {
			path = svgElement("path");
			path.dataset.id = id;
			lines.append(path);
		}
		const d = strokePath(stroke.points);
		if (path.getAttribute("d") !== d) path.setAttribute("d", d);
		if (stroke.fading && !path.dataset.fading) {
			path.dataset.fading = "1";
			path.animate([{ opacity: 1 }, { opacity: 0 }], {
				duration: LASER_FADE,
				easing: "ease-in",
				fill: "forwards",
			});
		}
	}
}
