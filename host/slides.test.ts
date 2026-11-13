// SPDX-License-Identifier: GPL-3.0-or-later
// The deck: which frames are slides, in what order, and which images a change
// makes stale.
import { expect, test } from "bun:test";
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import type { BinaryFiles } from "@excalidraw/excalidraw/types";
import {
	type Frame,
	nearestSlide,
	type Scene,
	SlideImages,
	slideFrames,
	slideName,
	slideNotes,
} from "./slides";

// Excalidraw fills in what a drawing's file leaves out; these carry what the
// deck reads.
function element(fields: Record<string, unknown>): ExcalidrawElement {
	return {
		type: "rectangle",
		x: 0,
		y: 0,
		width: 100,
		height: 100,
		strokeWidth: 1,
		version: 1,
		isDeleted: false,
		frameId: null,
		...fields,
	} as unknown as ExcalidrawElement;
}

const frame = (id: string, fields: Record<string, unknown> = {}) =>
	element({
		type: "frame",
		id,
		width: 800,
		height: 450,
		name: null,
		...fields,
	});

const ids = (frames: readonly Frame[]) => frames.map((each) => each.id);
const order = (slidesOrder: unknown) => ({ customData: { slidesOrder } });

test("slides follow their numbers, then the page, top to bottom then left to right", () => {
	expect(
		ids(
			slideFrames([
				frame("loose-low", { x: 0, y: 900 }),
				frame("third", { ...order(5), y: 2000 }),
				frame("loose-right", { x: 1000, y: 0 }),
				frame("first", order(-1)),
				frame("loose-left", { x: 0, y: 0 }),
				frame("second", { ...order(2), x: 3000, y: 3000 }),
			]),
		),
	).toEqual([
		"first",
		"second",
		"third",
		"loose-left",
		"loose-right",
		"loose-low",
	]);
});

test("slides with the same number go by position", () => {
	// Duplicating a frame copies its number.
	expect(
		ids(
			slideFrames([
				frame("below", { ...order(1), y: 500 }),
				frame("right", { ...order(1), x: 900 }),
				frame("left", order(1)),
				frame("zero", order(0)),
			]),
		),
	).toEqual(["zero", "left", "right", "below"]);
});

test("a number that is not a finite number counts as none", () => {
	expect(
		ids(
			slideFrames([
				frame("text", { ...order("1"), y: 100 }),
				frame("nan", { ...order(Number.NaN), y: 200 }),
				frame("numbered", { ...order(9), y: 300 }),
			]),
		),
	).toEqual(["numbered", "text", "nan"]);
});

test("deleted frames and other elements are not slides", () => {
	expect(
		ids(
			slideFrames([
				frame("deleted", { isDeleted: true }),
				element({ id: "box" }),
				element({ id: "magic", type: "magicframe" }),
				frame("kept"),
			]),
		),
	).toEqual(["kept"]);
});

test("a slide's name and notes", () => {
	expect(slideName(frame("a") as Frame)).toBe("Frame");
	expect(slideName(frame("a", { name: "Intro" }) as Frame)).toBe("Intro");
	expect(slideNotes(frame("a") as Frame)).toBe("");
	expect(
		slideNotes(
			frame("a", { customData: { presenterNotes: "Say hi" } }) as Frame,
		),
	).toBe("Say hi");
	expect(
		slideNotes(frame("a", { customData: { presenterNotes: 3 } }) as Frame),
	).toBe("");
});

test("the nearest slide is the one whose centre is closest", () => {
	const frames = slideFrames([
		frame("a", { x: 0, y: 0 }),
		frame("b", { x: 1000, y: 0 }),
	]);
	expect(nearestSlide(frames, { x: 400, y: 225 })).toBe(0);
	expect(nearestSlide(frames, { x: 1300, y: 900 })).toBe(1);
	expect(nearestSlide([], { x: 0, y: 0 })).toBe(-1);
});

// Two slides side by side, each with a child, and a loose box far from both.
const files: BinaryFiles = {};
function deck(changes: Record<string, Record<string, unknown>> = {}) {
	const parts = [
		frame("one", { x: 0, y: 0 }),
		frame("two", { x: 1000, y: 0 }),
		element({ id: "in-one", x: 100, y: 100, frameId: "one" }),
		element({ id: "in-two", x: 1100, y: 100, frameId: "two" }),
		element({ id: "far", x: 0, y: 5000 }),
	];
	return parts.map((part) =>
		changes[part.id] ? element({ ...part, ...changes[part.id] }) : part,
	);
}
const scene = (elements: readonly ExcalidrawElement[], more = {}): Scene => ({
	elements,
	files,
	background: "#ffffff",
	...more,
});

function renderer() {
	const made: string[] = [];
	const images = new SlideImages<string>(async (each) => {
		made.push(each.id);
		return `${each.id}@${each.version}`;
	});
	const update = async (next: Scene) => {
		made.length = 0;
		await images.update(next);
		return [...made].sort();
	};
	return { images, update };
}

test("the first update renders every slide", async () => {
	const { images, update } = renderer();
	expect(await update(scene(deck()))).toEqual(["one", "two"]);
	expect(images.image("one")).toBe("one@1");
	expect(await update(scene(deck()))).toEqual([]);
});

test("a change renders again only the slides it touches", async () => {
	const { update } = renderer();
	await update(scene(deck()));
	// A child changed.
	expect(await update(scene(deck({ "in-two": { version: 2 } })))).toEqual([
		"two",
	]);
	// The frame itself changed.
	expect(
		await update(
			scene(deck({ "in-two": { version: 2 }, one: { version: 2 } })),
		),
	).toEqual(["one"]);
	// Something outside every slide changed.
	expect(
		await update(
			scene(
				deck({
					"in-two": { version: 2 },
					one: { version: 2 },
					far: { version: 2 },
				}),
			),
		),
	).toEqual([]);
});

test("a child that leaves a slide, or is deleted, makes it stale", async () => {
	const { update } = renderer();
	await update(scene(deck()));
	expect(
		await update(
			scene(deck({ "in-one": { frameId: "two", x: 1100, version: 2 } })),
		),
	).toEqual(["one", "two"]);
	expect(
		await update(
			scene(
				deck({
					"in-one": { frameId: "two", x: 1100, version: 2 },
					"in-two": { isDeleted: true, version: 2 },
				}),
			),
		),
	).toEqual(["two"]);
});

test("an element in no frame that reaches into a slide is part of its image", async () => {
	const { update } = renderer();
	await update(scene(deck()));
	// The far box moves to straddle the second slide's left edge.
	expect(
		await update(scene(deck({ far: { x: 950, y: 100, version: 2 } }))),
	).toEqual(["two"]);
	// An arrow whose points reach into the first slide from below it.
	const arrow = element({
		id: "arrow",
		type: "arrow",
		x: 400,
		y: 900,
		width: 0,
		height: 500,
		points: [
			[0, 0],
			[0, -500],
		],
	});
	expect(
		await update(
			scene([...deck({ far: { x: 950, y: 100, version: 2 } }), arrow]),
		),
	).toEqual(["one"]);
});

test("new files or a new background render every slide again", async () => {
	const { update } = renderer();
	await update(scene(deck()));
	expect(await update(scene(deck(), { files: {} }))).toEqual(["one", "two"]);
	expect(await update(scene(deck(), { background: "#000000" }))).toEqual([
		"one",
		"two",
	]);
});

test("a new slide is rendered and a removed one forgotten", async () => {
	const { images, update } = renderer();
	await update(scene(deck()));
	expect(
		await update(
			scene([
				...deck({ two: { isDeleted: true, version: 2 } }),
				frame("three", { y: 600 }),
			]),
		),
	).toEqual(["three"]);
	expect(images.image("two")).toBeUndefined();
});

test("updates asked for while one runs render the latest scene once", async () => {
	const made: string[] = [];
	let release: () => void = () => {};
	const held = new Promise<void>((resolve) => {
		release = resolve;
	});
	const images = new SlideImages<string>(async (each, from) => {
		const child = from.elements.find((part) => part.id === "in-one");
		made.push(`${each.id}@${child?.version}`);
		await held;
		return each.id;
	});
	const first = images.update(scene(deck()));
	const second = images.update(scene(deck({ "in-one": { version: 2 } })));
	const third = images.update(scene(deck({ "in-one": { version: 3 } })));
	release();
	await Promise.all([first, second, third]);
	expect(made).toEqual(["one@1", "two@1", "one@3"]);
});

test("a slide whose image fails stays stale and the others are rendered", async () => {
	const failed: string[] = [];
	let fail = true;
	const images = new SlideImages<string>(
		async (each) => {
			if (each.id === "one" && fail) throw new Error("no fonts");
			return each.id;
		},
		undefined,
		(id) => failed.push(id),
	);
	await images.update(scene(deck()));
	expect(failed).toEqual(["one"]);
	expect(images.image("two")).toBe("two");
	expect(ids(images.stale(scene(deck())))).toEqual(["one"]);
	fail = false;
	await images.update(scene(deck()));
	expect(images.image("one")).toBe("one");
});
