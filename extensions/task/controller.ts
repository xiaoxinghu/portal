// SPDX-License-Identifier: GPL-3.0-or-later
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import path from "node:path";
import type { Reviewer } from "./reviewer.ts";
import {
	acquireLock,
	atomicWrite,
	event,
	feedbackPath,
	git,
	initialize,
	load,
	publishReview,
	readClaudeStatus,
	runtimePath,
	type State,
	StateConflictError,
	update,
	verifyCheckout,
	verifyEvidence,
} from "./store.ts";
import { type Implementor, prepareClaude, WAKE } from "./transport.ts";

export interface Observer {
	state(state: State, activity: string): void;
	error(error: Error): void;
}
export class TaskController {
	readonly directory: string;
	private implementor: Implementor;
	private review: Reviewer;
	private observer: Observer;
	private release?: () => void;
	private watchers: fs.FSWatcher[] = [];
	private pending = false;
	private running?: Promise<void>;
	private abort?: AbortController;
	private closed = false;

	constructor(
		directory: string,
		implementor: Implementor,
		review: Reviewer,
		observer: Observer,
	) {
		this.directory = fs.realpathSync(directory);
		this.implementor = implementor;
		this.review = review;
		this.observer = observer;
	}
	start() {
		if (this.release || this.closed)
			throw new Error("Controller already started or closed");
		load(this.directory);
		this.release = acquireLock(path.join(this.directory, ".coordinator.lock"));
		try {
			fs.mkdirSync(runtimePath(this.directory, ""), {
				recursive: true,
				mode: 0o700,
			});
			initialize(this.directory);
			const watch = (dir: string, file: string) => {
				const watcher = fs.watch(dir, (_event, filename) => {
					if (!filename || filename.toString() === file) this.kick();
				});
				watcher.on("error", (error) => this.fail(error));
				this.watchers.push(watcher);
			};
			watch(this.directory, "state.json");
			watch(runtimePath(this.directory, ""), "claude.json");
			this.kick();
		} catch (error) {
			for (const watcher of this.watchers) watcher.close();
			this.watchers = [];
			this.release();
			this.release = undefined;
			throw error;
		}
	}
	// Also the explicit reconciliation seam used by tests and /task resume.
	kick() {
		if (this.closed) return;
		this.pending = true;
		if (this.running) return;
		this.running = Promise.resolve()
			.then(async () => {
				while (this.pending && !this.closed) {
					this.pending = false;
					try {
						await this.step();
					} catch (error) {
						// A helper may advance state while Git checks are running. Re-read facts;
						// never retry a side effect using a stale snapshot.
						if (error instanceof StateConflictError) this.pending = true;
						else throw error;
					}
				}
			})
			.catch((error: unknown) =>
				this.fail(error instanceof Error ? error : new Error(String(error))),
			)
			.finally(() => {
				this.running = undefined;
				if (this.pending && !this.closed) this.kick();
			});
	}
	async idle() {
		await this.running;
	}
	private fail(error: Error) {
		if (this.closed) return;
		try {
			event(this.directory, "controller_failed", { message: error.message });
		} catch {
			/* Preserve original failure. */
		}
		this.closed = true;
		for (const watcher of this.watchers) watcher.close();
		this.watchers = [];
		this.abort?.abort();
		this.observer.error(error);
		// On a watcher error an active reviewer must settle before ownership is released.
		void Promise.resolve(this.running).finally(() => {
			this.release?.();
			this.release = undefined;
		});
	}
	async close() {
		this.closed = true;
		for (const watcher of this.watchers) watcher.close();
		this.watchers = [];
		this.abort?.abort();
		await this.running;
		this.release?.();
		this.release = undefined;
	}
	private announce(s: State, activity: string) {
		if (!this.closed) this.observer.state(s, activity);
	}

	private async step() {
		const dir = this.directory;
		let s = load(dir);
		if (s.paused) {
			this.announce(s, "paused; Claude is not stopped");
			return;
		}
		verifyCheckout(s);
		if (s.phase === "approved") {
			verifyCheckout(s, s.submitted_commit ?? undefined, true);
			verifyEvidence(dir, s);
			this.announce(s, `approved ${s.submitted_commit}`);
			return;
		}
		if (s.phase === "needs_human_decision") {
			this.announce(s, s.question ?? "human decision required");
			return;
		}
		if (s.phase === "changes_required") {
			s = update(
				dir,
				"fix_requested",
				(next) => {
					next.phase = "implementing";
					next.implementor.wake = "pending";
				},
				s.version,
			);
		}
		const status = readClaudeStatus(dir);
		if (status && status.session !== s.implementor.session)
			throw new Error("Claude lifecycle record belongs to another session");
		if (s.phase === "implementing") {
			prepareClaude(dir, s);
			if (!this.implementor.alive(s)) {
				const resume = s.implementor.launched;
				s = update(
					dir,
					"implementor_launch",
					(next) => {
						next.implementor.launched = true;
						next.implementor.wake = "sent";
						next.implementor.wake_turn = status?.turn ?? null;
					},
					s.version,
				);
				this.implementor.start(dir, s, resume);
				this.announce(
					s,
					resume ? "resuming Claude conversation" : "starting Claude",
				);
				return;
			}
			if (
				status?.turn &&
				status.turn !== s.implementor.wake_turn &&
				status.prompt?.trim() === WAKE &&
				s.implementor.wake === "sent"
			) {
				s = update(
					dir,
					"implementor_acknowledged",
					(next) => {
						next.implementor.wake = "accepted";
					},
					s.version,
				);
			}
			if (s.implementor.wake === "pending") {
				if (status?.status !== "idle") {
					this.announce(
						s,
						`feedback pending; Claude ${status?.status ?? "status unknown"}`,
					);
					return;
				}
				s = update(
					dir,
					"implementor_wakeup",
					(next) => {
						next.implementor.wake = "sent";
						next.implementor.wake_turn = status.turn;
					},
					s.version,
				);
				this.implementor.wake(s);
				this.announce(s, "short wake-up sent; awaiting Claude acknowledgment");
			} else
				this.announce(
					s,
					s.implementor.wake === "sent"
						? "awaiting wake-up acknowledgment; inspect Claude if stalled"
						: `Claude ${status?.status ?? "status unknown"}`,
				);
			return;
		}
		if (s.phase !== "code_review")
			throw new Error(`Cannot reconcile phase ${s.phase}`);
		const feedback = path.join(dir, feedbackPath(s.review_round));
		if (fs.existsSync(feedback))
			throw new Error(
				`Unpublished feedback requires explicit repair: ${feedback}`,
			);
		// Stop is only a lifecycle hint. A validated submission for that exact turn is also required.
		if (
			!status ||
			status.turn !== s.submitted_turn ||
			!["idle", "exited"].includes(status.status)
		) {
			this.announce(
				s,
				`submission recorded; waiting for its Claude turn to finish (${status?.status ?? "unknown"})`,
			);
			return;
		}
		verifyCheckout(s, s.submitted_commit ?? undefined, true);
		const checkout = runtimePath(dir, `review-checkout-${s.review_round}`);
		if (!fs.existsSync(checkout))
			git(
				s.repository,
				"worktree",
				"add",
				"--detach",
				checkout,
				s.submitted_commit ?? "",
			);
		if (
			fs.realpathSync(git(checkout, "rev-parse", "--show-toplevel")) !==
				fs.realpathSync(checkout) ||
			git(
				checkout,
				"rev-parse",
				"--path-format=absolute",
				"--git-common-dir",
			) !==
				git(
					s.repository,
					"rev-parse",
					"--path-format=absolute",
					"--git-common-dir",
				) ||
			git(checkout, "rev-parse", "HEAD") !== s.submitted_commit ||
			git(checkout, "status", "--porcelain", "--untracked-files=all")
		)
			throw new Error("Review checkout is not the clean pinned submission");
		atomicWrite(
			runtimePath(dir, "change.diff"),
			`${git(checkout, "diff", "--no-ext-diff", "--no-textconv", s.base_commit, s.submitted_commit ?? "")}\n`,
		);
		verifyEvidence(dir, s);
		const attempt = randomUUID();
		s = update(
			dir,
			"review_start",
			(next) => {
				next.review_attempt = { id: attempt, session: null };
			},
			s.version,
		);
		let expected = s.version;
		const abort = new AbortController();
		this.abort = abort;
		try {
			this.announce(s, `reviewing round ${s.review_round}`);
			const result = await this.review({
				directory: dir,
				checkout,
				state: s,
				signal: abort.signal,
				progress: (text) => this.announce(s, text),
				started: (session) => {
					expected = update(
						dir,
						"review_session",
						(next) => {
							if (next.review_attempt?.id !== attempt)
								throw new Error("Review attempt changed");
							next.review_attempt.session = session;
						},
						expected,
					).version;
				},
			});
			abort.signal.throwIfAborted();
			if (this.closed) return;
			const latest = readClaudeStatus(dir);
			if (
				!latest ||
				latest.turn !== s.submitted_turn ||
				!["idle", "exited"].includes(latest.status)
			)
				throw new Error(
					"Claude became active during review; inspect before resuming",
				);
			if (
				git(checkout, "rev-parse", "HEAD") !== s.submitted_commit ||
				git(checkout, "status", "--porcelain", "--untracked-files=all")
			)
				throw new Error("Reviewer checkout changed");
			s = publishReview(dir, expected, result, attempt);
			this.announce(s, `review: ${s.phase}`);
			this.pending = true;
		} finally {
			this.abort = undefined;
		}
	}
}
