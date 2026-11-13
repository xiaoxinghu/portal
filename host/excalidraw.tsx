// SPDX-License-Identifier: GPL-3.0-or-later

import {
	CaptureUpdateAction,
	Excalidraw,
	exportToSvg,
	loadFromBlob,
	MainMenu,
	newElementWith,
	serializeAsJSON,
} from "@excalidraw/excalidraw";
import type {
	ExcalidrawElement,
	NonDeleted,
} from "@excalidraw/excalidraw/element/types";
import type {
	AppState,
	BinaryFiles,
	ExcalidrawImperativeAPI,
} from "@excalidraw/excalidraw/types";
import {
	type PointerEvent as ReactPointerEvent,
	useCallback,
	useEffect,
	useMemo,
	useRef,
	useState,
	useSyncExternalStore,
} from "react";
import { createRoot } from "react-dom/client";
import "@excalidraw/excalidraw/index.css";
import "./excalidraw.css";
import {
	type Frame,
	moveSlide,
	nearestSlide,
	type Scene,
	SlideImages,
	slideFrames,
	slideName,
	slideNotes,
	withNotes,
} from "./slides";

type Message = {
	type: string;
	json?: string;
	request?: number;
	name?: string;
	message?: string;
	mode?: string;
};

/** The page's screen: the editor, or Arrange covering it. */
type Mode = "draw" | "arrange";

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Missing editor root element");
const root = createRoot(rootElement);
const darkScheme = window.matchMedia("(prefers-color-scheme: dark)");
const prefersDarkScheme = () => darkScheme.matches;
function subscribeToColorScheme(onChange: () => void) {
	darkScheme.addEventListener("change", onChange);
	return () => darkScheme.removeEventListener("change", onChange);
}

let api: ExcalidrawImperativeAPI | undefined;
let lastJSON = "";
let savedJSON = "";
let initialized = false;
let dirtyPending = false;
let contentKey = "";
let previousFiles: BinaryFiles | undefined;
let changeTimer: ReturnType<typeof setTimeout> | undefined;
let setStatus: (value: string) => void = () => {};
let setMode: (mode: Mode) => void = () => {};
/** Arrange's keys, while it is shown; they come before the editor's. */
let arrangeKeys: ((event: KeyboardEvent) => void) | undefined;
/** Set while Arrange hands a key to the editor under it. */
let forwarding = false;
const post = (message: object) => window.portalBridge?.postMessage(message);

function currentJSON() {
	if (!api || !initialized) throw new Error("The drawing is still loading");
	return serializeAsJSON(
		api.getSceneElements(),
		api.getAppState(),
		api.getFiles(),
		"local",
	);
}

function publish(json = currentJSON()) {
	clearTimeout(changeTimer);
	if (json !== lastJSON || dirtyPending) {
		dirtyPending = false;
		lastJSON = json;
		setStatus(json === savedJSON ? "Saved" : "Modified");
		post({ type: "change", json });
	}
}

function onChange(
	elements: readonly ExcalidrawElement[],
	state: AppState,
	files: BinaryFiles,
) {
	if (!initialized) return;
	// Compare only exported data. Leave potentially large base64 image payloads
	// out of this per-interaction check; Excalidraw replaces its files map when
	// adding files. Full serialization and bridge traffic are debounced below.
	const key = serializeAsJSON(elements, state, {}, "local");
	if (key === contentKey && files === previousFiles) return;
	contentKey = key;
	previousFiles = files;
	if (!dirtyPending) {
		dirtyPending = true;
		post({ type: "dirty" });
	}
	// onChange also fires for selection and viewport changes. The local serializer
	// excludes transient UI state, so those changes do not dirty the document.
	clearTimeout(changeTimer);
	changeTimer = setTimeout(
		() => publish(serializeAsJSON(elements, state, files, "local")),
		150,
	);
}

function requestSave() {
	post({ type: "save" });
}

function Editor({
	initialData,
	name,
}: {
	initialData: Awaited<ReturnType<typeof loadFromBlob>> & {
		scrollToContent: boolean;
	};
	name: string;
}) {
	const isDark = useSyncExternalStore(
		subscribeToColorScheme,
		prefersDarkScheme,
	);
	const [status, updateStatus] = useState("Saved");
	setStatus = updateStatus;
	const [mode, updateMode] = useState<Mode>("draw");
	setMode = updateMode;
	const shownMode = useRef(mode);
	useEffect(() => {
		if (shownMode.current === mode) return;
		shownMode.current = mode;
		post({ type: "mode", mode });
		// The editor was inert under Arrange, which took its focus.
		if (mode === "draw")
			document.querySelector<HTMLElement>(".excalidraw-container")?.focus();
	}, [mode]);
	const editSlide = (frame: Frame) => {
		updateMode("draw");
		api?.scrollToContent(frame, { fitToViewport: true });
	};
	return (
		<>
			<div className="portal-editor" inert={mode === "arrange"}>
				<Excalidraw
					theme={isDark ? "dark" : "light"}
					initialData={initialData}
					name={name}
					excalidrawAPI={(value) => {
						api = value;
						// Initial data is applied after the imperative API becomes available.
						// The first onChange below establishes the normalized document baseline.
					}}
					onChange={(elements, state, files) => {
						if (state.isLoading) return;
						if (!initialized) {
							initialized = true;
							contentKey = serializeAsJSON(elements, state, {}, "local");
							previousFiles = files;
							savedJSON = lastJSON = serializeAsJSON(
								elements,
								state,
								files,
								"local",
							);
							post({ type: "loaded", json: lastJSON });
						} else onChange(elements, state, files);
					}}
					autoFocus
					validateEmbeddable={false}
					onLinkOpen={(_element, event) => event.preventDefault()}
					UIOptions={{
						canvasActions: {
							loadScene: false,
							saveToActiveFile: false,
							export: false,
							saveAsImage: false,
						},
						welcomeScreen: false,
					}}
					renderTopRightUI={() => (
						<div className="portal-save">
							<span role="status">{status}</span>
							<button type="button" onClick={requestSave}>
								Save
							</button>
						</div>
					)}
				>
					<MainMenu>
						<MainMenu.Item onSelect={requestSave}>Save drawing</MainMenu.Item>
						<MainMenu.Item onSelect={() => updateMode("arrange")}>
							Slides
						</MainMenu.Item>
						<MainMenu.DefaultItems.ClearCanvas />
						<MainMenu.DefaultItems.ChangeCanvasBackground />
					</MainMenu>
				</Excalidraw>
			</div>
			{mode === "arrange" && api && (
				<Arrange
					editor={api}
					status={status}
					onDraw={() => updateMode("draw")}
					onEdit={editSlide}
				/>
			)}
		</>
	);
}

/** The scene's slides are made of, as the editor has it now. */
function currentScene(editor: ExcalidrawImperativeAPI): Scene {
	return {
		elements: editor.getSceneElements(),
		files: editor.getFiles(),
		background: editor.getAppState().viewBackgroundColor,
	};
}

/** A slide's image: the frame alone, on the scene's background, never in
 * dark mode, so it looks the same whichever Emacs shows it. */
async function renderSlide(frame: Frame, scene: Scene) {
	const svg = await exportToSvg({
		elements: scene.elements.filter(
			(element): element is NonDeleted<ExcalidrawElement> => !element.isDeleted,
		),
		appState: {
			exportBackground: true,
			exportWithDarkMode: false,
			viewBackgroundColor: scene.background,
		},
		files: scene.files,
		exportingFrame: frame,
	});
	return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg.outerHTML)}`;
}

// Images last as long as the page, so a slide that did not change since
// Arrange was last shown is not drawn again.
let imagesVersion = 0;
const imageListeners = new Set<() => void>();
const failedSlides = new Set<string>();
function imagesChanged() {
	imagesVersion++;
	for (const listener of imageListeners) listener();
}
const slideImages = new SlideImages<string>(
	renderSlide,
	(id) => {
		failedSlides.delete(id);
		imagesChanged();
	},
	(id, error) => {
		console.error(`Slide ${id}:`, error);
		failedSlides.add(id);
		imagesChanged();
	},
);
function subscribeToImages(listener: () => void) {
	imageListeners.add(listener);
	return () => imageListeners.delete(listener);
}

function SlideImage({ frame, alt }: { frame: Frame; alt: string }) {
	const image = slideImages.image(frame.id);
	// Not dragged as an image: dragging a slide moves it in the filmstrip.
	if (image) return <img src={image} alt={alt} draggable={false} />;
	return (
		<span className="portal-slide-pending">
			{failedSlides.has(frame.id) ? "Could not draw this slide" : ""}
		</span>
	);
}

/** What Arrange writes to a frame. */
type FrameFields = Pick<Frame, "name" | "customData">;

/** Write FIELDS to the frames they name, as one step of the editor's undo
 * history. The editor reports it as it does any change, so it reaches the
 * buffer. No frame moves on the canvas. */
function writeFrames(
	editor: ExcalidrawImperativeAPI,
	fields: ReadonlyMap<string, Partial<FrameFields>>,
) {
	if (!fields.size) return;
	editor.updateScene({
		elements: editor.getSceneElementsIncludingDeleted().map((element) => {
			const change = fields.get(element.id);
			return change ? newElementWith(element, change) : element;
		}),
		captureUpdate: CaptureUpdateAction.IMMEDIATELY,
	});
}

/** Hand EVENT, a key pressed in Arrange, to the editor under it, as if it
 * were pressed there. True when the editor used it. */
function forwardToEditor(event: KeyboardEvent) {
	const container = document.querySelector(".excalidraw-container");
	if (!container) return false;
	const copy = new KeyboardEvent("keydown", {
		key: event.key,
		code: event.code,
		metaKey: event.metaKey,
		ctrlKey: event.ctrlKey,
		altKey: event.altKey,
		shiftKey: event.shiftKey,
		bubbles: true,
		cancelable: true,
	});
	forwarding = true;
	try {
		container.dispatchEvent(copy);
	} finally {
		forwarding = false;
	}
	return copy.defaultPrevented;
}

const isField = (target: EventTarget | null) =>
	target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement;

/** Notes write after this long without typing, and when the box loses the
 * keyboard. */
const NOTES_DELAY = 500;

/** A slide being dragged in the filmstrip: where it was, where it would go,
 * and whether the pointer has moved far enough to be a drag yet. */
type Drag = {
	id: string;
	pointer: number;
	startY: number;
	from: number;
	to: number;
	moving: boolean;
};

/** The Arrange screen: the slides in order, the selected one large, and its
 * notes. It covers the editor, which stays loaded under it. Its edits,
 * order, names and notes, are written to the frames in the editor's scene. */
function Arrange({
	editor,
	status,
	onDraw,
	onEdit,
}: {
	editor: ExcalidrawImperativeAPI;
	status: string;
	onDraw: () => void;
	onEdit: (frame: Frame) => void;
}) {
	const [scene, setScene] = useState(() => currentScene(editor));
	const frames = useMemo(() => slideFrames(scene.elements), [scene.elements]);
	const [selectedId, setSelectedId] = useState(() => {
		const view = editor.getAppState();
		const zoom = view.zoom.value;
		const index = nearestSlide(frames, {
			x: view.width / 2 / zoom - view.scrollX,
			y: view.height / 2 / zoom - view.scrollY,
		});
		return frames[index]?.id;
	});
	useSyncExternalStore(subscribeToImages, () => imagesVersion);
	const found = frames.findIndex((frame) => frame.id === selectedId);
	const index = found < 0 ? 0 : found;
	const selected = frames[index];
	const list = useRef<HTMLDivElement>(null);

	// Draw images now, and again a moment after each change to the scene.
	useEffect(() => {
		slideImages.update(scene);
	}, [scene]);
	useEffect(() => {
		let timer: ReturnType<typeof setTimeout> | undefined;
		const stop = editor.onChange(() => {
			clearTimeout(timer);
			timer = setTimeout(() => setScene(currentScene(editor)), 150);
		});
		return () => {
			clearTimeout(timer);
			stop();
		};
	}, [editor]);

	/** Write to the frames, then show the scene at once, so that the next
	 * edit starts from this one. */
	const write = useCallback(
		(fields: ReadonlyMap<string, Partial<FrameFields>>) => {
			if (!fields.size) return;
			writeFrames(editor, fields);
			setScene(currentScene(editor));
		},
		[editor],
	);
	const move = useCallback(
		(from: number, to: number) =>
			write(
				new Map(
					moveSlide(frames, from, to).map(({ frame, order }) => [
						frame.id,
						{ customData: { ...frame.customData, slidesOrder: order } },
					]),
				),
			),
		[frames, write],
	);

	// The notes being typed, until they are written.
	const [notes, setNotes] = useState<{ id: string; text: string }>();
	const notesRef = useRef(notes);
	notesRef.current = notes;
	const notesTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
	const writeNotes = useCallback(() => {
		clearTimeout(notesTimer.current);
		const typed = notesRef.current;
		if (!typed) return;
		notesRef.current = undefined;
		setNotes(undefined);
		const frame = slideFrames(editor.getSceneElements()).find(
			(each) => each.id === typed.id,
		);
		if (frame && slideNotes(frame) !== typed.text)
			write(
				new Map([[frame.id, { customData: withNotes(frame, typed.text) }]]),
			);
	}, [editor, write]);
	// Notes typed for one slide are written before another is shown, and
	// before Arrange goes.
	useEffect(() => writeNotes, [writeNotes]);
	useEffect(() => {
		if (notesRef.current && notesRef.current.id !== selected?.id) writeNotes();
	}, [selected, writeNotes]);

	// A name being typed, until it is written; Escape drops it. Like notes,
	// it is written before Arrange goes, which takes the field away without
	// its losing the keyboard.
	const name = useRef<{ id: string; text: string }>(undefined);
	const [, renamed] = useState(0);
	const writeName = useCallback(() => {
		const typed = name.current;
		if (!typed) return;
		name.current = undefined;
		renamed((count) => count + 1);
		const frame = slideFrames(editor.getSceneElements()).find(
			(each) => each.id === typed.id,
		);
		const text = typed.text.trim() || null;
		if (frame && text !== frame.name)
			write(new Map([[frame.id, { name: text }]]));
	}, [editor, write]);
	useEffect(() => writeName, [writeName]);

	useEffect(() => {
		list.current?.focus();
	}, []);
	useEffect(() => {
		if (selected)
			document
				.getElementById(`portal-slide-${selected.id}`)
				?.scrollIntoView({ block: "nearest" });
	}, [selected]);

	useEffect(() => {
		arrangeKeys = (event) => {
			const plain =
				!event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
			const option =
				event.altKey && !event.metaKey && !event.ctrlKey && !event.shiftKey;
			const undo =
				(event.metaKey || event.ctrlKey) &&
				!event.altKey &&
				event.key.toLowerCase() === "z";
			const field = isField(event.target)
				? (event.target as HTMLElement)
				: undefined;
			if (field) {
				// Fields take their keys, and an input method its own; Return in
				// a name and Escape leave them. Undo and redo are the field's:
				// WebKit leaves those keys to the app, which would give them to
				// Emacs.
				if (event.isComposing) return;
				if (undo) document.execCommand(event.shiftKey ? "redo" : "undo");
				else if (plain && event.key === "Escape") {
					if (field instanceof HTMLInputElement) {
						name.current = undefined;
						renamed((count) => count + 1);
					}
				} else if (
					!(plain && event.key === "Enter" && field instanceof HTMLInputElement)
				)
					return;
				event.preventDefault();
				if (!undo) list.current?.focus();
				return;
			}
			const step = (by: number) => {
				const next =
					frames[Math.max(0, Math.min(frames.length - 1, index + by))];
				if (next) setSelectedId(next.id);
			};
			if (plain && event.key === "ArrowUp") step(-1);
			else if (plain && event.key === "ArrowDown") step(1);
			else if (option && event.key === "ArrowUp") move(index, index - 1);
			else if (option && event.key === "ArrowDown") move(index, index + 1);
			else if (plain && event.key === "Enter" && selected) onEdit(selected);
			else if (plain && event.key === "Escape") onDraw();
			else if (!(undo && forwardToEditor(event))) return;
			event.preventDefault();
		};
		return () => {
			arrangeKeys = undefined;
		};
	}, [frames, index, selected, move, onDraw, onEdit]);

	// Dragging a slide: the pointer goes down on it and moves; where it lets
	// go, between which two slides, is where the slide goes.
	const [drag, setDrag] = useState<Drag>();
	const dragged = useRef(false);
	const dropAt = (y: number) => {
		const options = [
			...(list.current?.querySelectorAll<HTMLElement>("[role=option]") ?? []),
		];
		const before = options.findIndex((option) => {
			const box = option.getBoundingClientRect();
			return y < box.top + box.height / 2;
		});
		return before < 0 ? options.length : before;
	};
	const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
		const option = (event.target as Element).closest<HTMLElement>(
			"[role=option]",
		);
		if (event.button !== 0 || !option || isField(event.target)) return;
		const from = frames.findIndex((frame) => frame.id === option.dataset.id);
		if (from < 0) return;
		setDrag({
			id: option.dataset.id ?? "",
			pointer: event.pointerId,
			startY: event.clientY,
			from,
			to: from,
			moving: false,
		});
	};
	const onPointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
		if (!drag || event.pointerId !== drag.pointer) return;
		if (!drag.moving && Math.abs(event.clientY - drag.startY) < 5) return;
		if (!drag.moving) list.current?.setPointerCapture(event.pointerId);
		// Near either end, the filmstrip scrolls.
		const box = list.current?.getBoundingClientRect();
		if (box && event.clientY < box.top + 24) list.current?.scrollBy(0, -12);
		else if (box && event.clientY > box.bottom - 24)
			list.current?.scrollBy(0, 12);
		const before = dropAt(event.clientY);
		setDrag({
			...drag,
			moving: true,
			to: before > drag.from ? before - 1 : before,
		});
	};
	const onPointerUp = (event: ReactPointerEvent<HTMLDivElement>) => {
		if (!drag || event.pointerId !== drag.pointer) return;
		setDrag(undefined);
		if (!drag.moving) return;
		// The click that ends a drag does not select.
		dragged.current = true;
		setTimeout(() => {
			dragged.current = false;
		});
		setSelectedId(drag.id);
		move(drag.from, drag.to);
	};
	const dropMark = (at: number) => {
		if (!drag?.moving || drag.to === drag.from) return undefined;
		if (at !== drag.to) return undefined;
		return drag.to > drag.from ? "after" : "before";
	};

	return (
		<div className="portal-arrange">
			<header>
				<h1>Slides</h1>
				<span className="portal-arrange-count">
					{frames.length === 1 ? "1 slide" : `${frames.length} slides`}
				</span>
				<span className="portal-arrange-status" role="status">
					{status}
				</span>
				<button type="button" onClick={onDraw}>
					Draw
				</button>
			</header>
			{selected ? (
				<div className="portal-arrange-body">
					<div
						ref={list}
						className="portal-filmstrip"
						role="listbox"
						aria-label="Slides"
						aria-activedescendant={`portal-slide-${selected.id}`}
						tabIndex={0}
						onPointerDown={onPointerDown}
						onPointerMove={onPointerMove}
						onPointerUp={onPointerUp}
						onPointerCancel={() => setDrag(undefined)}
					>
						{frames.map((frame, at) => (
							// biome-ignore lint/a11y/useKeyWithClickEvents: the list takes the keys.
							<div
								key={frame.id}
								id={`portal-slide-${frame.id}`}
								data-id={frame.id}
								data-drop={dropMark(at)}
								data-dragging={
									drag?.moving && drag.id === frame.id ? "" : undefined
								}
								role="option"
								tabIndex={-1}
								aria-selected={frame === selected}
								onClick={() => {
									if (!dragged.current) setSelectedId(frame.id);
								}}
								onDoubleClick={(event) => {
									if (!isField(event.target)) onEdit(frame);
								}}
							>
								<span className="portal-slide-number">{at + 1}</span>
								<span className="portal-slide-image">
									<SlideImage frame={frame} alt="" />
								</span>
								<input
									className="portal-slide-name"
									aria-label={`Name of slide ${at + 1}`}
									value={
										name.current?.id === frame.id
											? name.current.text
											: (frame.name ?? "")
									}
									placeholder={slideName(frame)}
									onFocus={() => setSelectedId(frame.id)}
									onChange={(event) => {
										name.current = { id: frame.id, text: event.target.value };
										renamed((count) => count + 1);
									}}
									onBlur={writeName}
								/>
							</div>
						))}
					</div>
					<main className="portal-stage">
						<div className="portal-stage-image">
							<SlideImage
								frame={selected}
								alt={`Slide ${index + 1}: ${slideName(selected)}`}
							/>
						</div>
						<section className="portal-notes">
							<label htmlFor="portal-notes-text">Notes</label>
							<textarea
								id="portal-notes-text"
								placeholder="No notes."
								value={
									notes?.id === selected.id ? notes.text : slideNotes(selected)
								}
								onChange={(event) => {
									const typed = { id: selected.id, text: event.target.value };
									notesRef.current = typed;
									setNotes(typed);
									clearTimeout(notesTimer.current);
									notesTimer.current = setTimeout(writeNotes, NOTES_DELAY);
								}}
								onBlur={writeNotes}
							/>
						</section>
					</main>
				</div>
			) : (
				<p className="portal-arrange-empty">
					This drawing has no slides. Draw a frame for each slide.
				</p>
			)}
		</div>
	);
}

async function receive(message: Message) {
	try {
		if (message.type === "load") {
			if (api) throw new Error("This editor already has a document");
			const scene = await loadFromBlob(
				new Blob([message.json ?? ""]),
				null,
				null,
			);
			root.render(
				<Editor
					initialData={{ ...scene, scrollToContent: true }}
					name={message.name ?? "Drawing"}
				/>,
			);
		} else if (message.type === "snapshot") {
			// Commit an active text editor before serializing. A timeout also works
			// while the webview is hidden, where animation frames can be suspended.
			(document.activeElement as HTMLElement | null)?.blur();
			await new Promise((resolve) => setTimeout(resolve, 0));
			const json = currentJSON();
			publish(json);
			post({ type: "snapshot", request: message.request, json });
		} else if (message.type === "mode") {
			if (!api || !initialized) throw new Error("The drawing is still loading");
			if (message.mode !== "draw" && message.mode !== "arrange")
				throw new Error(`No such screen: ${message.mode}`);
			setMode(message.mode);
		} else if (message.type === "saved") {
			savedJSON = message.json?.trim() ?? "";
			setStatus(currentJSON() === savedJSON ? "Saved" : "Modified");
		} else if (message.type === "error") {
			setStatus(message.message ?? "Save failed");
		}
	} catch (error) {
		const text = error instanceof Error ? error.message : String(error);
		if (!api)
			root.render(
				<div className="portal-error">Unable to open drawing: {text}</div>,
			);
		post({ type: "error", message: text, request: message.request });
	}
}

if (window.portalBridge) window.portalBridge.receive = receive;

// Registered before the editor mounts, so these run before its own window
// listeners. While Arrange is shown, no key reaches the editor but the undo and
// redo keys Arrange hands it; a chord Arrange leaves alone is not prevented, so
// it still reaches Emacs.
window.addEventListener(
	"keydown",
	(event) => {
		if (forwarding) return;
		if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
			event.preventDefault();
			event.stopImmediatePropagation();
			requestSave();
		} else if (arrangeKeys) {
			event.stopImmediatePropagation();
			arrangeKeys(event);
		}
	},
	true,
);
window.addEventListener(
	"keyup",
	(event) => {
		if (arrangeKeys) event.stopImmediatePropagation();
	},
	true,
);
// Flush promptly before focus returns to Emacs or the editor becomes hidden.
window.addEventListener("blur", () => {
	if (initialized) publish();
});
post({ type: "ready" });
