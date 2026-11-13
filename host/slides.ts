// SPDX-License-Identifier: GPL-3.0-or-later
// The deck: a drawing's slides, which are its frames, and their images.
// Nothing here touches the page or React, so Bun tests it directly.

import type {
	ExcalidrawElement,
	ExcalidrawFrameElement,
} from "@excalidraw/excalidraw/element/types";
import type { BinaryFiles } from "@excalidraw/excalidraw/types";

export type Frame = ExcalidrawFrameElement;

function slidesOrder(frame: Frame): number | undefined {
	const order: unknown = frame.customData?.slidesOrder;
	return typeof order === "number" && Number.isFinite(order)
		? order
		: undefined;
}

/** The frames that are not deleted, in slide order. Frames with a number in
 * `customData.slidesOrder` come first, by that number; ties, and then the
 * frames without one, go top to bottom, then left to right. */
export function slideFrames(elements: readonly ExcalidrawElement[]): Frame[] {
	const frames = elements.filter(
		(element): element is Frame =>
			element.type === "frame" && !element.isDeleted,
	);
	const position = (a: Frame, b: Frame) => a.y - b.y || a.x - b.x;
	return frames.sort((a, b) => {
		const first = slidesOrder(a);
		const second = slidesOrder(b);
		if (first === undefined && second === undefined) return position(a, b);
		if (first === undefined) return 1;
		if (second === undefined) return -1;
		return first - second || position(a, b);
	});
}

/** A slide's name, as Excalidraw shows an unnamed frame's. */
export const slideName = (frame: Frame) => frame.name ?? "Frame";

/** A slide's presenter notes, or "" without any. */
export function slideNotes(frame: Frame): string {
	const notes: unknown = frame.customData?.presenterNotes;
	return typeof notes === "string" ? notes : "";
}

/** The index of the slide whose frame's centre is nearest POINT, a point on
 * the canvas, or -1 without slides. */
export function nearestSlide(
	frames: readonly Frame[],
	point: { x: number; y: number },
): number {
	let nearest = -1;
	let best = Number.POSITIVE_INFINITY;
	frames.forEach((frame, index) => {
		const distance = Math.hypot(
			frame.x + frame.width / 2 - point.x,
			frame.y + frame.height / 2 - point.y,
		);
		if (distance < best) {
			best = distance;
			nearest = index;
		}
	});
	return nearest;
}

/** Bounds that hold ELEMENT: its box, or the circle around it when rotated,
 * padded for strokes and arrowheads. Generous, never short. */
function outerBounds(element: ExcalidrawElement) {
	let [left, top, right, bottom] = [0, 0, element.width, element.height];
	if ("points" in element)
		for (const [x, y] of element.points) {
			left = Math.min(left, x);
			top = Math.min(top, y);
			right = Math.max(right, x);
			bottom = Math.max(bottom, y);
		}
	const pad = Math.max(4 * element.strokeWidth, 16);
	const x = element.x + (left + right) / 2;
	const y = element.y + (top + bottom) / 2;
	const [width, height] = element.angle
		? Array(2).fill(Math.hypot(right - left, bottom - top))
		: [right - left, bottom - top];
	return {
		left: x - width / 2 - pad,
		top: y - height / 2 - pad,
		right: x + width / 2 + pad,
		bottom: y + height / 2 + pad,
	};
}

function overlaps(element: ExcalidrawElement, frame: Frame) {
	const bounds = outerBounds(element);
	return (
		bounds.left <= frame.x + frame.width &&
		bounds.right >= frame.x &&
		bounds.top <= frame.y + frame.height &&
		bounds.bottom >= frame.y
	);
}

/** What FRAME's image is made of, as text that changes when its image may:
 * the frame's version, then each element drawn in it, in scene order, with
 * its version. Those are its children, by `frameId`, and the elements in no
 * frame that reach into it, which an export of the frame draws too. */
export function frameStamp(
	frame: Frame,
	elements: readonly ExcalidrawElement[],
): string {
	const parts = [`${frame.id}:${frame.version}`];
	for (const element of elements) {
		if (element.isDeleted || element.id === frame.id) continue;
		if (
			element.frameId === frame.id ||
			(!element.frameId && overlaps(element, frame))
		)
			parts.push(`${element.id}:${element.version}`);
	}
	return parts.join(" ");
}

/** What a slide image is made from. */
export type Scene = {
	elements: readonly ExcalidrawElement[];
	files: BinaryFiles;
	background: string;
};

export type Render<Image> = (frame: Frame, scene: Scene) => Promise<Image>;

/** The slides' images, kept per frame. An update makes again only the images
 * of frames whose stamp changed, or every image when the files map or the
 * background did. ON_IMAGE hears of each new image; ON_ERROR of each frame
 * whose image failed, which stays stale for the next update to try again. */
export class SlideImages<Image> {
	#render: Render<Image>;
	#onImage: (id: string, image: Image) => void;
	#onError: (id: string, error: unknown) => void;
	#images = new Map<string, { stamp: string; image: Image }>();
	#files: BinaryFiles | undefined;
	#background: string | undefined;
	#next: Scene | undefined;
	#running: Promise<void> | undefined;

	constructor(
		render: Render<Image>,
		onImage: (id: string, image: Image) => void = () => {},
		onError: (id: string, error: unknown) => void = () => {},
	) {
		this.#render = render;
		this.#onImage = onImage;
		this.#onError = onError;
	}

	image(id: string): Image | undefined {
		return this.#images.get(id)?.image;
	}

	/** The slides of SCENE whose images are missing or out of date. */
	stale(scene: Scene): Frame[] {
		const all =
			scene.files !== this.#files || scene.background !== this.#background;
		return slideFrames(scene.elements).filter(
			(frame) =>
				all ||
				this.#images.get(frame.id)?.stamp !== frameStamp(frame, scene.elements),
		);
	}

	/** Bring the images up to date with SCENE. While an update runs, a new
	 * one waits for it, and only the latest scene asked for is rendered. */
	update(scene: Scene): Promise<void> {
		this.#next = scene;
		this.#running ??= this.#drain();
		return this.#running;
	}

	async #drain() {
		try {
			while (this.#next) {
				const scene = this.#next;
				this.#next = undefined;
				await this.#refresh(scene);
			}
		} finally {
			this.#running = undefined;
		}
	}

	async #refresh(scene: Scene) {
		const stale = this.stale(scene);
		const live = new Set(slideFrames(scene.elements).map((frame) => frame.id));
		for (const id of this.#images.keys())
			if (!live.has(id)) this.#images.delete(id);
		this.#files = scene.files;
		this.#background = scene.background;
		for (const frame of stale) {
			const stamp = frameStamp(frame, scene.elements);
			try {
				const image = await this.#render(frame, scene);
				this.#images.set(frame.id, { stamp, image });
				this.#onImage(frame.id, image);
			} catch (error) {
				this.#images.delete(frame.id);
				this.#onError(frame.id, error);
			}
		}
	}
}
