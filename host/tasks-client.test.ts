// SPDX-License-Identifier: GPL-3.0-or-later
// The task browser's page script in a real headless browser: Playwright's
// WebKit, pinned in bun.lock and installed by CMake into the directory that
// PLAYWRIGHT_BROWSERS_PATH names (docs/testing.md). Pages come from the real
// task routes and actions; the test plays Emacs, answering the app host's
// requests, and the editor bridge, sending refreshes. Browser WebKit is not
// Portal's WKWebView: the graphical suites keep the embedded checks.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import {
	mkdir,
	mkdtemp,
	readFile,
	realpath,
	rm,
	writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { type Browser, type Page, webkit } from "playwright-core";
import { HostActions } from "./actions";
import { statusEdit, TaskActions, tasks } from "./tasks";

let browser: Browser;
beforeAll(async () => {
	browser = await webkit.launch({ headless: true });
});
afterAll(async () => {
	await browser?.close();
});

const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => {
	for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

type Request = {
	id: string;
	operation: string;
	arguments: { file: string; start: number; end: number; text: string };
};

/** A task root served by the real task routes, a page showing it, and Emacs's
 * side of the app host's requests. Page loads can be held to order them. */
async function browse(files: Record<string, string>, query = "") {
	const directory = await realpath(
		await mkdtemp(join(tmpdir(), "portal tasks page ")),
	);
	const root = join(directory, "tasks");
	cleanups.push(() => rm(directory, { recursive: true, force: true }));
	const write = async (name: string, text: string) => {
		await mkdir(dirname(join(root, name)), { recursive: true });
		await writeFile(join(root, name), text);
	};
	for (const [name, text] of Object.entries(files)) await write(name, text);
	const sent: Request[] = [];
	const host = new HostActions((record) => sent.push(record as Request));
	host.receive({
		type: "context",
		id: "web:1",
		properties: { app: "tasks", root },
	});
	const actions = new TaskActions(host);
	const loads: string[] = [];
	let hold: Promise<void> | null = null;
	let broken = false;
	const server = Bun.serve({
		hostname: "127.0.0.1",
		port: 0,
		async fetch(request) {
			const url = new URL(request.url);
			if (url.pathname === "/t/tasks") loads.push(url.search);
			if (hold && url.pathname === "/t/tasks") await hold;
			// An app host that restarted no longer knows the page's token.
			if (broken) return new Response("Not found", { status: 404 });
			if (url.pathname === "/t/tasks/action") return actions.act(request);
			if (url.pathname === "/t/tasks") return tasks(url.searchParams, actions);
			return new Response("Not found", { status: 404 });
		},
	});
	cleanups.push(async () => {
		await server.stop(true);
	});
	const context = await browser.newContext();
	cleanups.push(() => context.close());
	const page = await context.newPage();
	// Portal defines the bridge before the page's scripts run.
	await page.addInitScript(() => {
		(window as unknown as { portalBridge: object }).portalBridge = {
			postMessage() {},
		};
	});
	const url = `http://127.0.0.1:${server.port}/t/tasks?root=${encodeURIComponent(root)}&context=web:1${query}`;
	await page.goto(url);
	loads.length = 0;
	/** Answer the next request as Emacs does, applying a status edit. */
	const answer = async (error?: string) => {
		for (let n = 0; n < 400 && sent.length === 0; n++) await Bun.sleep(5);
		const request = sent.shift();
		if (!request) throw new Error("No request reached Emacs");
		const args = request.arguments;
		if (!error && request.operation === "task.status") {
			const bytes = await readFile(args.file);
			await writeFile(
				args.file,
				Buffer.concat([
					bytes.subarray(0, args.start),
					Buffer.from(args.text),
					bytes.subarray(args.end),
				]),
			);
		}
		host.receive({
			type: "result",
			id: request.id,
			...(error ? { error } : { value: {} }),
		});
		return request;
	};
	return {
		root,
		page,
		url,
		write,
		sent,
		loads,
		answer,
		/** Hold page loads until the returned function releases them. */
		hold() {
			let release = () => {};
			hold = new Promise((resolve) => {
				release = () => {
					hold = null;
					resolve();
				};
			});
			return release;
		},
		breakHost(value: boolean) {
			broken = value;
		},
	};
}

const todo = (title: string) => `---\nstatus: todo\n---\n# ${title}\n`;

function manyTasks(count = 40): Record<string, string> {
	const files: Record<string, string> = {};
	for (let n = 0; n < count; n++)
		files[`task-${String(n).padStart(2, "0")}.md`] = todo(`Task ${n}`);
	return files;
}

/** Ask the page to refresh, as Emacs does after saving a task file. */
function refresh(page: Page) {
	return page.evaluate(() =>
		(
			window as unknown as {
				portalBridge: { receive: (message: object) => Promise<void> };
			}
		).portalBridge.receive({ type: "refresh" }),
	);
}

const shown = (page: Page, title: string) =>
	page.evaluate(
		(title) =>
			[...document.querySelectorAll(".title")].some(
				(element) =>
					element.textContent === title &&
					(element as HTMLElement).checkVisibility(),
			),
		title,
	);

const focused = (page: Page) =>
	page.evaluate(() => {
		const element = document.activeElement as HTMLElement;
		return element.dataset.op
			? `${element.dataset.op} ${element.dataset.task} ${element.textContent}`
			: (element.querySelector(".title")?.textContent ??
					element.getAttribute("aria-label") ??
					element.tagName);
	});

const notice = (page: Page) =>
	page.evaluate(() => {
		const element = document.querySelector(".task-notice");
		return element
			? {
					text: element.textContent,
					error: element.classList.contains("action-error"),
				}
			: null;
	});

test("a refresh replaces content in place, keeping URL, history, folds, scroll and focus", async () => {
	const f = await browse({
		...manyTasks(),
		"group/one.md": todo("Grouped one"),
		"group/two.md": todo("Grouped two"),
	});
	const { page } = f;
	const entries = await page.evaluate(() => window.history.length);
	// Close the group's fold, scroll, and focus a row by keyboard.
	await page.locator("li.group > details > summary").click();
	expect(await shown(f.page, "Grouped one")).toBe(false);
	await page.locator("a.row", { hasText: "Task 30" }).focus();
	await page.evaluate(() => window.scrollTo(0, 600));
	await f.write("task-05.md", todo("Task 5 renamed"));
	await refresh(page);
	expect(await shown(page, "Task 5 renamed")).toBe(true);
	expect(await shown(page, "Task 5")).toBe(false);
	expect(f.loads).toHaveLength(1);
	expect(page.url()).toBe(f.url);
	expect(await page.evaluate(() => window.history.length)).toBe(entries);
	expect(
		await page.evaluate(() =>
			document.querySelector("li.group > details")?.hasAttribute("open"),
		),
	).toBe(false);
	expect(await shown(page, "Grouped one")).toBe(false);
	expect(await page.evaluate(() => Math.round(window.scrollY))).toBe(600);
	expect(await focused(page)).toBe("Task 30");
	// The new content is live: a fold summary keeps focus across a refresh too.
	await page.locator("li.group > details > summary").focus();
	await f.write("task-06.md", todo("Task 6 renamed"));
	await refresh(page);
	expect(await shown(page, "Task 6 renamed")).toBe(true);
	expect(
		await page.evaluate(() =>
			document.activeElement?.matches("li.group > details > summary"),
		),
	).toBe(true);
}, 30_000);

test("refreshes run one at a time: one waiting refresh serves every request made meanwhile", async () => {
	const f = await browse(manyTasks(5));
	const { page } = f;
	const release = f.hold();
	await f.write("task-01.md", todo("First save"));
	const first = refresh(page);
	for (let n = 0; n < 200 && f.loads.length === 0; n++) await Bun.sleep(5);
	expect(f.loads).toHaveLength(1);
	// Saves while that load is held: their refreshes share one later load.
	await f.write("task-02.md", todo("Second save"));
	const waiting = [refresh(page), refresh(page), refresh(page)];
	await Bun.sleep(100);
	expect(f.loads).toHaveLength(1);
	release();
	await Promise.all([first, ...waiting]);
	expect(f.loads).toHaveLength(2);
	// The later load's content wins; the earlier one never replaces it.
	expect(await shown(page, "First save")).toBe(true);
	expect(await shown(page, "Second save")).toBe(true);
	await refresh(page);
	expect(f.loads).toHaveLength(3);
}, 30_000);

test("a hidden page refreshes once when shown again, and a page from history checks again", async () => {
	const f = await browse(manyTasks(3));
	const { page } = f;
	await page.evaluate(() => {
		let state = "visible";
		Object.defineProperty(document, "visibilityState", {
			configurable: true,
			get: () => state,
		});
		(
			window as unknown as { setVisibility: (value: string) => void }
		).setVisibility = (value) => {
			state = value;
			document.dispatchEvent(new Event("visibilitychange"));
		};
	});
	const visibility = (value: string) =>
		page.evaluate(
			(value) =>
				(
					window as unknown as { setVisibility: (value: string) => void }
				).setVisibility(value),
			value,
		);
	await visibility("hidden");
	await f.write("task-00.md", todo("Saved while hidden"));
	await refresh(page);
	await refresh(page);
	expect(f.loads).toHaveLength(0);
	expect(await shown(page, "Saved while hidden")).toBe(false);
	await visibility("visible");
	await page.waitForFunction(() =>
		document.body.innerText.includes("Saved while hidden"),
	);
	expect(f.loads).toHaveLength(1);
	// Showing it again with nothing pending loads nothing.
	await visibility("hidden");
	await visibility("visible");
	await Bun.sleep(100);
	expect(f.loads).toHaveLength(1);
	// A page that history restores from its cache checks for changes.
	await f.write("task-01.md", todo("Saved while away"));
	await page.evaluate(() =>
		window.dispatchEvent(
			new PageTransitionEvent("pageshow", { persisted: true }),
		),
	);
	await page.waitForFunction(() =>
		document.body.innerText.includes("Saved while away"),
	);
	expect(f.loads).toHaveLength(2);
}, 30_000);

test("Complete hides the row in place, moves focus to the next row and says so", async () => {
	const f = await browse(manyTasks());
	const { page } = f;
	const entries = await page.evaluate(() => window.history.length);
	const complete = page.locator(
		'button[data-op="status"][data-task="task-10"]',
	);
	await complete.focus();
	await page.evaluate(() => window.scrollBy(0, 40));
	const scroll = await page.evaluate(() => Math.round(window.scrollY));
	expect(scroll).toBeGreaterThan(0);
	await page.keyboard.press("Enter");
	// While Emacs works, the button says so and ignores another press.
	await page.waitForFunction(() =>
		document
			.querySelector('button[data-task="task-10"][data-op="status"]')
			?.textContent?.startsWith("Completing"),
	);
	expect(await complete.getAttribute("aria-disabled")).toBe("true");
	await complete.dispatchEvent("click");
	await Bun.sleep(100);
	expect(f.sent).toHaveLength(1);
	const request = await f.answer();
	expect(request.operation).toBe("task.status");
	await page.waitForFunction(
		() =>
			!document.querySelector('button[data-task="task-10"]') &&
			!!document.querySelector(".task-notice"),
	);
	expect(f.sent).toHaveLength(0);
	expect(await readFile(join(f.root, "task-10.md"), "utf8")).toContain(
		"status: done",
	);
	expect(await focused(page)).toBe("Task 11");
	expect((await notice(page))?.text).toBe(
		"Completed “Task 10”. Completed tasks are hidden; Show completed lists them.",
	);
	expect(page.url()).toBe(f.url);
	expect(await page.evaluate(() => window.history.length)).toBe(entries);
	expect(await page.evaluate(() => Math.round(window.scrollY))).toBe(scroll);
}, 30_000);

test("Reopen on a task page keeps focus on its button, which now completes", async () => {
	const f = await browse(
		{ "shipped.md": "---\nstatus: done\n---\n# Shipped\n" },
		"&task=shipped&show=all",
	);
	const { page } = f;
	await page.locator('button[data-op="status"]').focus();
	expect(await focused(page)).toBe("status shipped Reopen");
	await page.keyboard.press("Enter");
	await f.answer();
	await page.waitForFunction(
		() => document.querySelector(".task-state .status")?.textContent === "todo",
	);
	expect(await focused(page)).toBe("status shipped Complete");
	expect((await notice(page))?.text).toBe("Reopened “Shipped”.");
	expect(await readFile(join(f.root, "shipped.md"), "utf8")).toContain(
		"status: todo",
	);
}, 30_000);

test("Edit in Emacs asks Emacs to open the source, then restores the button", async () => {
	const f = await browse({ "fix-search.md": todo("Fix search") });
	const { page } = f;
	const edit = page.locator('button[data-op="edit"][data-task="fix-search"]');
	await edit.click();
	const request = await f.answer();
	expect(request.operation).toBe("task.edit");
	expect(request.arguments.file).toBe(join(f.root, "fix-search.md"));
	await page.waitForFunction(
		() =>
			document.querySelector(".task-notice")?.textContent ===
			"Opened “Fix search” in Emacs.",
	);
	expect(await edit.textContent()).toBe("Edit");
	expect(await edit.getAttribute("aria-disabled")).toBeNull();
	expect(f.loads).toHaveLength(0);
}, 30_000);

test("a refused action restores the button and says why, changing nothing", async () => {
	const f = await browse(manyTasks(3));
	const { page } = f;
	const complete = page.locator(
		'button[data-op="status"][data-task="task-01"]',
	);
	await complete.click();
	await f.answer(
		"Save or revert task-01.md in Emacs first: it has unsaved changes.",
	);
	await page.waitForFunction(() =>
		document.querySelector(".task-notice")?.classList.contains("action-error"),
	);
	expect((await notice(page))?.text).toBe(
		"Could not complete “Task 1”: Save or revert task-01.md in Emacs first: it has unsaved changes.",
	);
	expect(await complete.textContent()).toBe("Complete");
	expect(await complete.getAttribute("aria-disabled")).toBeNull();
	expect(f.loads).toHaveLength(0);
	expect(await readFile(join(f.root, "task-01.md"), "utf8")).toContain(
		"status: todo",
	);
	// The page works again: the next action goes through.
	await complete.click();
	await f.answer();
	await page.waitForFunction(
		() => !document.querySelector('button[data-task="task-01"]'),
	);
}, 30_000);

test("a restarted app host is reported, and the page recovers on the next refresh", async () => {
	const f = await browse(manyTasks(3));
	const { page } = f;
	f.breakHost(true);
	await f.write("task-02.md", todo("After the restart"));
	await refresh(page);
	expect(await notice(page)).toEqual({
		text: "Could not refresh the page: the app host has restarted. Press g to reload.",
		error: true,
	});
	expect(await shown(page, "Task 0")).toBe(true);
	// So is an action, whose answer is no longer the app host's JSON.
	await page.locator('button[data-op="edit"][data-task="task-00"]').click();
	await page.waitForFunction(() =>
		document
			.querySelector(".task-notice")
			?.textContent?.startsWith("Could not open"),
	);
	expect((await notice(page))?.text).toBe(
		"Could not open “Task 0”: The app host has restarted. Press g to reload.",
	);
	expect(f.sent).toHaveLength(0);
	f.breakHost(false);
	await refresh(page);
	expect(await shown(page, "After the restart")).toBe(true);
	expect(
		await page.evaluate(() => document.querySelectorAll("main").length),
	).toBe(1);
}, 30_000);

test("status edits the page asks for are the planner's, applied by Emacs", async () => {
	// The page posts only the action; the host plans the edit from the bytes.
	const f = await browse({
		"styled.md": "---\nstatus: todo # keep\n---\n# Styled\n",
	});
	await f.page.locator('button[data-op="status"][data-task="styled"]').click();
	const request = await f.answer();
	expect(request.arguments).toMatchObject(
		statusEdit(
			Buffer.from("---\nstatus: todo # keep\n---\n# Styled\n"),
			"done",
		),
	);
	expect(await readFile(join(f.root, "styled.md"), "utf8")).toBe(
		"---\nstatus: done # keep\n---\n# Styled\n",
	);
}, 30_000);
