// SPDX-License-Identifier: GPL-3.0-or-later
// The slide window's page: served by the host, offline, and apart from the
// editor, whose bundle it never loads.
import { expect, test } from "bun:test";
import { assets } from "./.generated/assets";
import { respond } from "./app";
import {
	elapsed,
	isLaser,
	LASER_FADE,
	laserFade,
	laserWidth,
	presentKey,
	slideBy,
	slidePoint,
	stepSlide,
	strokePath,
} from "./present";

const authority = "127.0.0.1:4321";
const token = "0123456789abcdef0123456789abcdef";

function get(path: string): Promise<Response> {
	return respond(
		new Request(`http://${authority}/${token}${path}`, {
			headers: { Host: authority },
		}),
		authority,
		token,
	);
}

test("the host serves the slide window's page beside the editor's", async () => {
	const response = await get("/excalidraw/audience");
	expect(response.status).toBe(200);
	expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
	expect(await response.text()).toContain('<img id="slide"');
	expect((await get("/excalidraw/audience/")).status).toBe(404);
});

test("the slide window's page loads its one script, which is not the editor's", async () => {
	const page = await (await get("/excalidraw/audience")).text();
	const references = [...page.matchAll(/(?:href|src)="([^"]+)"/g)].map(
		(match) => match[1],
	);
	expect(references).toEqual(["./audience.js"]);
	const script = await get("/excalidraw/audience.js");
	expect(script.status).toBe(200);
	expect(script.headers.get("content-type")).toBe(
		"text/javascript; charset=utf-8",
	);
	const text = await script.text();
	// One self-contained file: it imports no chunk, and nothing of Excalidraw
	// or React is in it.
	expect(text).not.toMatch(/\bimport\s*\(|\bfrom\s*["']|\bimport\s*["']/);
	expect(text).not.toMatch(/excalidraw|react/i);
	expect(text.length).toBeLessThan(4000);
	// The editor's bundle stays where it was, and the slide window's is
	// not among its files.
	expect(assets.has("/excalidraw/assets/audience.js")).toBe(false);
	expect(assets.has("/excalidraw/assets/editor-bootstrap.js")).toBe(true);
});

test("the slide window's page may load nothing from the network", async () => {
	const policy =
		(await get("/excalidraw/audience")).headers.get(
			"content-security-policy",
		) ?? "";
	const directives = policy
		.split(";")
		.map((directive) => directive.trim().split(/\s+/));
	expect(directives.map(([name]) => name)).toContain("default-src");
	expect(policy).toContain("default-src 'none'");
	expect(policy).not.toContain("connect-src");
	for (const [name, ...sources] of directives) {
		for (const source of sources) {
			expect([name, source]).toEqual([
				name,
				expect.stringMatching(
					/^(?:'none'|'self'|'unsafe-inline'|data:|blob:)$/,
				),
			]);
		}
	}
});

const plain = {
	metaKey: false,
	ctrlKey: false,
	altKey: false,
	shiftKey: false,
};

test("presenting keys: the arrows, Space and a clicker's pages move, Escape stops", () => {
	const keys = [
		"ArrowRight",
		"ArrowDown",
		" ",
		"PageDown",
		"ArrowLeft",
		"ArrowUp",
		"PageUp",
		"Home",
		"End",
		"Escape",
		"Enter",
		"a",
		"constructor",
	];
	expect(keys.map((key) => presentKey({ ...plain, key }))).toEqual([
		"next",
		"next",
		"next",
		"next",
		"previous",
		"previous",
		"previous",
		"first",
		"last",
		"stop",
		undefined,
		undefined,
		undefined,
	]);
	// A chord is never a presenting key, so Command-S still saves.
	for (const modifier of ["metaKey", "ctrlKey", "altKey", "shiftKey"])
		expect(
			presentKey({ ...plain, [modifier]: true, key: "ArrowRight" }),
		).toBeUndefined();
});

test("moving through slides stays within them", () => {
	expect(stepSlide("next", 0, 3)).toBe(1);
	expect(stepSlide("next", 2, 3)).toBe(2);
	expect(stepSlide("previous", 0, 3)).toBe(0);
	expect(stepSlide("previous", 2, 3)).toBe(1);
	expect(stepSlide("first", 2, 3)).toBe(0);
	expect(stepSlide("last", 0, 3)).toBe(2);
	expect(stepSlide("last", 0, 0)).toBe(0);
	expect(stepSlide("stop", 1, 3)).toBeUndefined();
});

test("Emacs's next and previous move by any number, within the slides", () => {
	expect(slideBy(1, 1, 3)).toBe(2);
	expect(slideBy(1, -1, 3)).toBe(0);
	expect(slideBy(1, 5, 3)).toBe(2);
	expect(slideBy(1, -5, 3)).toBe(0);
	expect(slideBy(0, 1, 0)).toBe(0);
});

test("the time presenting is minutes and seconds, the minutes going past an hour", () => {
	expect(elapsed(0)).toBe("0:00");
	expect(elapsed(999)).toBe("0:00");
	expect(elapsed(65_000)).toBe("1:05");
	expect(elapsed(75 * 60_000 + 3_000)).toBe("75:03");
	// A clock set back to zero a moment ago, before the next tick.
	expect(elapsed(-400)).toBe("0:00");
});

test("a laser line fades for 2 seconds and is as wide as its slide allows", () => {
	expect(LASER_FADE).toBe(2000);
	expect(laserFade()).toBe(2000);
	// Twice the slide, twice the line, so it looks the same at any size.
	expect(laserWidth(3200, 1800)).toBe(2 * laserWidth(1600, 900));
	expect(laserWidth(900, 1600)).toBe(laserWidth(1600, 900));
});

test("a point on the screen is in the slide's units wherever the slide is drawn", () => {
	// A 1600 by 900 slide in a box twice as wide as it is drawn: half its
	// size, with bars left and right.
	const wide = { left: 10, top: 20, width: 1600, height: 450 };
	expect(slidePoint(410, 20, wide, 1600, 900)).toEqual({
		point: [0, 0],
		inside: true,
	});
	expect(slidePoint(1210, 470, wide, 1600, 900)).toEqual({
		point: [1600, 900],
		inside: true,
	});
	expect(slidePoint(810, 245, wide, 1600, 900).point).toEqual([800, 450]);
	// The bars are not the slide.
	expect(slidePoint(400, 245, wide, 1600, 900)).toEqual({
		point: [-20, 450],
		inside: false,
	});
	// In a tall box the bars are above and below, and a point is a tenth
	// of a unit at most.
	const tall = { left: 0, top: 0, width: 300, height: 1000 };
	expect(slidePoint(150, 500, tall, 1600, 900).point).toEqual([800, 450]);
	expect(slidePoint(0, 415.625, tall, 1600, 900)).toEqual({
		point: [0, 0],
		inside: true,
	});
	expect(slidePoint(100, 400, tall, 1600, 900).inside).toBe(false);
	expect(slidePoint(100.01, 500, tall, 1600, 900).point).toEqual([533.4, 450]);
});

test("a line is a path through its points, smoothed through their midpoints", () => {
	expect(strokePath([])).toBe("");
	// One point is a dot, which round caps draw.
	expect(strokePath([5, 6])).toBe("M5 6l0 0");
	expect(strokePath([0, 0, 10, 10])).toBe("M0 0L10 10");
	expect(strokePath([0, 0, 10, 0, 10, 10, 20, 10.5])).toBe(
		"M0 0Q10 0 10 5Q10 10 15 10.3L20 10.5",
	);
});

test("the slide window takes a laser message only whole", () => {
	const laser = { type: "laser", index: 0, width: 16, height: 9, strokes: [] };
	expect(isLaser(laser)).toBe(true);
	expect(isLaser({ ...laser, strokes: undefined })).toBe(false);
	expect(isLaser({ ...laser, width: "16" })).toBe(false);
	expect(isLaser({ ...laser, type: "show" })).toBe(false);
	expect(isLaser(null)).toBe(false);
});
