import { resolveUsedFraction, type UsageReport } from "@oh-my-pi/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

/**
 * Multi-provider vault usage footer (issue #220 prototype).
 *
 * Renders one below-editor row summarizing every provider usage window the
 * launch vault's broker reports, with the active model's provider first. The
 * footer represents the vault fixed at process launch; it never implies that
 * changing the globally selected `code` vault mutates this process.
 *
 * API discipline (issue #220 Phase 0): this extension calls only
 * `AuthStorage.fetchUsageReports()` (read-only aggregate, broker-routed and
 * coalesced upstream) and `AuthStorage.hasAuth()` (non-secret boolean). It
 * never reads credentials, tokens, identity fields, broker environment
 * values, or raw report metadata, and it never logs or renders upstream
 * errors. Account identity display is deliberately out of scope until a
 * broker-owned redaction surface exists; nothing identity-shaped is read,
 * cached, or keyed here.
 *
 * Layout contract: at supported widths the component returns exactly one
 * physical row (loading, data, stale, or unavailable); only terminal width
 * may switch it to zero rows. Fetch completion changes text, never row
 * count, so network timing can never move the prompt.
 */

const WIDGET_KEY = "vault-usage";
const SEPARATOR = "   ";
const BAR_CELLS = 10;
const MIN_WIDTH = 40;
const MEDIUM_WIDTH = 64;
const WIDE_WIDTH = 100;
const FETCH_TIMEOUT_MS = 10_000;
const REFRESH_INTERVAL_MS = 5 * 60_000;
const REFRESH_JITTER = 0.1;
const FAILURE_BACKOFF_MS = [5, 10, 20, 30].map(minutes => minutes * 60_000);
const COUNTDOWN_TICK_MS = 60_000;
const STALE_AFTER_MS = 15 * 60_000;

/** One provider limit window, projected to a secret-free view model. */
export interface WindowView {
	limitId: string;
	/** Abbreviated window label for the one-line footer (e.g. "5h"). */
	windowLabel: string;
	/** Human label for the detail view (e.g. "5 Hour"). */
	fullLabel: string;
	usedFraction?: number;
	resetsAt?: number;
	exhausted: boolean;
	/** Non-secret scope descriptor (tier / model / shared), never identity. */
	scopeNote?: string;
}

export interface ProviderView {
	provider: string;
	windows: WindowView[];
	summary: WindowView;
}

export type FooterState =
	| { kind: "loading" }
	| { kind: "unavailable" }
	| { kind: "data"; providers: ProviderView[]; fetchedAt: number };

export interface ActiveProviderInfo {
	provider: string;
	authenticated: boolean;
}

export interface RenderOptions {
	width: number;
	now: number;
	active?: ActiveProviderInfo;
	staleAfterMs: number;
	/** True while the newest refresh attempt failed and old data is retained. */
	refreshFailed?: boolean;
}

/**
 * Summary priority per window: exhausted first, then greatest used fraction,
 * then nearest reset, then stable limit id. Windows are never aggregated.
 */
function summaryBefore(a: WindowView, b: WindowView): boolean {
	if (a.exhausted !== b.exhausted) return a.exhausted;
	const aUsed = a.usedFraction ?? -1;
	const bUsed = b.usedFraction ?? -1;
	if (aUsed !== bUsed) return aUsed > bUsed;
	const aReset = a.resetsAt ?? Number.MAX_SAFE_INTEGER;
	const bReset = b.resetsAt ?? Number.MAX_SAFE_INTEGER;
	if (aReset !== bReset) return aReset < bReset;
	return a.limitId.localeCompare(b.limitId) < 0;
}

export function pickSummary(windows: readonly WindowView[]): WindowView {
	let best = windows[0];
	for (const candidate of windows.slice(1)) {
		if (summaryBefore(candidate, best)) best = candidate;
	}
	return best;
}

/**
 * Project aggregate reports into the secret-free view model. Drops `raw`,
 * `metadata`, notes, endpoint details, and every identity field immediately;
 * only provider names, window labels, fractions, resets, and non-secret
 * scope descriptors survive.
 */
export function projectReports(reports: readonly UsageReport[]): {
	providers: ProviderView[];
	fetchedAt: number;
} {
	const byProvider = new Map<string, WindowView[]>();
	let fetchedAt = 0;
	for (const report of reports) {
		if (typeof report.fetchedAt === "number" && report.fetchedAt > fetchedAt) {
			fetchedAt = report.fetchedAt;
		}
		const provider = String(report.provider);
		const windows = byProvider.get(provider) ?? [];
		for (const limit of report.limits) {
			const scopeParts: string[] = [];
			if (limit.scope.tier) scopeParts.push(limit.scope.tier);
			if (limit.scope.modelId) scopeParts.push(limit.scope.modelId);
			if (limit.scope.shared) scopeParts.push("shared");
			windows.push({
				limitId: limit.id,
				windowLabel: limit.window?.id ?? limit.id,
				fullLabel: limit.label,
				usedFraction: resolveUsedFraction(limit),
				resetsAt: limit.window?.resetsAt,
				exhausted: limit.status === "exhausted",
				scopeNote: scopeParts.length > 0 ? scopeParts.join(" ") : undefined,
			});
		}
		byProvider.set(provider, windows);
	}
	const providers: ProviderView[] = [];
	const sorted = [...byProvider.entries()].sort((a, b) => a[0].localeCompare(b[0]));
	for (const [provider, windows] of sorted) {
		if (windows.length === 0) continue;
		providers.push({ provider, windows, summary: pickSummary(windows) });
	}
	return { providers, fetchedAt: fetchedAt > 0 ? fetchedAt : Date.now() };
}

/**
 * Reset countdown with `code` v0.1.0 parity (`fmtReset`, main.go): floor
 * arithmetic, `Xm` under an hour, `XhYm` under a day, `XdYh` beyond,
 * negative clamped to "0m".
 */
export function formatCountdown(ms: number): string {
	let seconds = Math.floor(ms / 1000);
	if (seconds < 0) seconds = 0;
	if (seconds >= 86_400) {
		return `${Math.floor(seconds / 86_400)}d${Math.floor((seconds % 86_400) / 3600)}h`;
	}
	if (seconds >= 3600) {
		return `${Math.floor(seconds / 3600)}h${Math.floor((seconds % 3600) / 60)}m`;
	}
	return `${Math.floor(seconds / 60)}m`;
}

/** Integer percent with `code` v0.1.0 parity: `int(usedFraction*100 + 0.5)`. */
export function usedPercent(fraction: number): number {
	return Math.floor(Math.max(0, fraction) * 100 + 0.5);
}

export function formatPercent(fraction: number | undefined): string {
	if (fraction === undefined) return "?%";
	return `${usedPercent(fraction)}%`;
}

/**
 * Ten-cell usage bar with `code` v0.1.0 fill parity (`barStr`, main.go):
 * `fill = (pct*10 + 50) / 100` in integer arithmetic, clamped to 10 cells.
 * The green-to-red color ramp is deliberately omitted here (monochrome
 * cells) until theme integration lands.
 */
export function renderBar(fraction: number | undefined, cells: number): string {
	const pct = fraction === undefined ? 0 : usedPercent(fraction);
	let filled = Math.floor((pct * cells + 50) / 100);
	if (filled > cells) filled = cells;
	return "█".repeat(filled) + "░".repeat(cells - filled);
}

type DetailLevel = "wide" | "medium" | "narrow";

function providerChunk(view: ProviderView, isActive: boolean, level: DetailLevel, now: number): string {
	const summary = view.summary;
	const parts = [`${isActive ? "*" : ""}${view.provider}`, summary.windowLabel];
	if (level === "wide") parts.push(renderBar(summary.usedFraction, BAR_CELLS));
	parts.push(formatPercent(summary.usedFraction) + (summary.exhausted ? "!" : ""));
	if (summary.resetsAt !== undefined && summary.resetsAt > now) {
		parts.push(`~${formatCountdown(summary.resetsAt - now)}`);
	}
	return parts.join(" ");
}

function buildChunks(providers: readonly ProviderView[], options: RenderOptions, level: DetailLevel): string[] {
	const active = options.active;
	const ordered = [...providers];
	if (active) {
		const index = ordered.findIndex(entry => entry.provider === active.provider);
		if (index > 0) ordered.unshift(...ordered.splice(index, 1));
	}
	const chunks: string[] = [];
	if (active && !ordered.some(entry => entry.provider === active.provider)) {
		// Distinct states: unauthenticated vs authenticated-but-unreported.
		chunks.push(`*${active.provider} ${active.authenticated ? "usage n/a" : "unauthenticated"}`);
	}
	for (const entry of ordered) {
		chunks.push(providerChunk(entry, entry.provider === active?.provider, level, options.now));
	}
	return chunks;
}

/**
 * Render the footer as zero rows (below MIN_WIDTH) or exactly one row.
 * Responsive levels: wide = all fitting providers with bars, medium = no
 * bars, narrow = active provider only, too small = hidden. The row is
 * truncated to the physical width as the final guard and never wraps.
 */
export function renderRow(state: FooterState, options: RenderOptions): string[] {
	const width = options.width;
	if (width < MIN_WIDTH) return [];
	if (state.kind === "loading") return ["usage: loading…"];
	if (state.kind === "unavailable") return ["usage: unavailable"];

	const level: DetailLevel = width >= WIDE_WIDTH ? "wide" : width >= MEDIUM_WIDTH ? "medium" : "narrow";
	const chunks = buildChunks(state.providers, options, level);
	if (chunks.length === 0) return ["usage: none reported"];

	// Stale parity with `code`: a failed refresh marks retained data stale
	// immediately; the age threshold additionally covers timer gaps after
	// suspend/resume, where no failure was recorded but the data aged out.
	const staleFor = options.now - state.fetchedAt;
	const isStale = options.refreshFailed === true || staleFor > options.staleAfterMs;
	const staleSuffix = isStale ? ` ·stale ${formatCountdown(staleFor)}` : "";
	const budget = width - staleSuffix.length;

	const kept: string[] = [];
	let used = 0;
	for (const chunk of chunks) {
		const cost = kept.length === 0 ? chunk.length : chunk.length + SEPARATOR.length;
		if (used + cost > budget) break;
		kept.push(chunk);
		used += cost;
		if (level === "narrow") break;
	}
	if (kept.length === 0) kept.push(chunks[0]);
	let row = kept.join(SEPARATOR) + staleSuffix;
	if (row.length > width) row = row.slice(0, width);
	return [row];
}

/** Every original window/scope for the /vault-usage detail view. */
export function detailLines(state: FooterState, now: number): string[] {
	if (state.kind !== "data") return [];
	const lines: string[] = [];
	for (const view of state.providers) {
		for (const window of view.windows) {
			const parts = [
				view.provider,
				window.fullLabel,
				`${formatPercent(window.usedFraction)} used${window.exhausted ? " (exhausted)" : ""}`,
			];
			if (window.resetsAt !== undefined && window.resetsAt > now) {
				parts.push(`resets ${formatCountdown(window.resetsAt - now)}`);
			}
			if (window.scopeNote) parts.push(window.scopeNote);
			lines.push(parts.join(" · "));
		}
	}
	return lines;
}

export default function vaultUsageFooter(pi: ExtensionAPI): void {
	let latestContext: ExtensionContext | undefined;
	let state: FooterState = { kind: "loading" };
	let generation = 0;
	let fetchGeneration: number | undefined;
	let aborter: AbortController | undefined;
	let refreshTimer: Timer | undefined;
	let tickTimer: Timer | undefined;
	let failures = 0;
	let repaint: (() => void) | undefined;
	let shutdown = false;
	let polling = false;

	const activeInfo = (): ActiveProviderInfo | undefined => {
		const ctx = latestContext;
		const model = ctx?.models.current();
		if (!ctx || !model) return undefined;
		return {
			provider: model.provider,
			authenticated: ctx.modelRegistry.authStorage.hasAuth(model.provider),
		};
	};

	const scheduleNext = (): void => {
		if (shutdown || !polling) return;
		clearTimeout(refreshTimer);
		const base =
			failures === 0
				? REFRESH_INTERVAL_MS
				: FAILURE_BACKOFF_MS[Math.min(failures - 1, FAILURE_BACKOFF_MS.length - 1)];
		const jitter = 1 + (Math.random() * 2 - 1) * REFRESH_JITTER;
		refreshTimer = setTimeout(() => void refresh(), Math.round(base * jitter));
	};

	const refresh = async (): Promise<void> => {
		const ctx = latestContext;
		if (shutdown || !polling || !ctx) return;
		const gen = generation;
		if (fetchGeneration === gen) return;
		fetchGeneration = gen;
		// Per-request controller: an aborted previous generation unwinding in
		// its finally block must never clear the current generation's handle,
		// swallow its initial refresh, or schedule against it.
		const controller = new AbortController();
		aborter = controller;
		const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
		try {
			const reports = await ctx.modelRegistry.authStorage.fetchUsageReports({
				signal: controller.signal,
			});
			if (gen === generation && polling) {
				if (reports) {
					const projected = projectReports(reports);
					state = { kind: "data", providers: projected.providers, fetchedAt: projected.fetchedAt };
					failures = 0;
				} else {
					failures += 1;
					if (state.kind === "loading") state = { kind: "unavailable" };
				}
			}
		} catch {
			// Retain last-known-good and back off; raw errors never reach the
			// footer, the logs, or the session. Aborts from our own cleanup
			// belong to a stale generation and never count as failures.
			if (gen === generation && polling) {
				failures += 1;
				if (state.kind === "loading") state = { kind: "unavailable" };
			}
		} finally {
			clearTimeout(timeout);
			if (fetchGeneration === gen) fetchGeneration = undefined;
			if (aborter === controller) aborter = undefined;
			if (gen === generation && !shutdown && polling) {
				scheduleNext();
				repaint?.();
			}
		}
	};

	// Idempotent cleanup shared by component dispose and session shutdown:
	// abort the in-flight fetch and release every timer (Component.dispose
	// contract). startPolling re-arms when the controller re-creates the
	// widget from the retained factory (e.g. after a transcript reset).
	const stopPolling = (): void => {
		generation += 1;
		polling = false;
		aborter?.abort();
		clearTimeout(refreshTimer);
		refreshTimer = undefined;
		clearInterval(tickTimer);
		tickTimer = undefined;
	};

	const startPolling = (): void => {
		if (shutdown || polling) return;
		generation += 1;
		polling = true;
		// Local countdown repaint only; no network is involved in ticks.
		tickTimer = setInterval(() => repaint?.(), COUNTDOWN_TICK_MS);
		void refresh();
	};

	const componentFactory = (tui: { requestRender(): void }) => {
		let cachedRows: string[] = [];
		let cachedRow: string | undefined;
		repaint = () => tui.requestRender();
		startPolling();
		return {
			render(width: number): readonly string[] {
				const rows = renderRow(state, {
					width,
					now: Date.now(),
					active: activeInfo(),
					staleAfterMs: STALE_AFTER_MS,
					refreshFailed: failures > 0,
				});
				const row = rows[0];
				if (row === undefined) {
					if (cachedRows.length > 0) {
						cachedRows = [];
						cachedRow = undefined;
					}
					return cachedRows;
				}
				if (row !== cachedRow) {
					cachedRow = row;
					cachedRows = [row];
				}
				return cachedRows;
			},
			dispose(): void {
				repaint = undefined;
				stopPolling();
			},
		};
	};

	pi.on("session_start", (_event, ctx) => {
		latestContext = ctx;
		// Print/RPC mode: no widget surface, so stay fully inert (no polling).
		if (!ctx.hasUI) return;
		ctx.ui.setWidget(WIDGET_KEY, componentFactory, { placement: "belowEditor" });
		startPolling();
	});

	pi.on("session_switch", (_event, ctx) => {
		latestContext = ctx;
		repaint?.();
	});

	pi.on("session_shutdown", () => {
		shutdown = true;
		stopPolling();
		if (latestContext?.hasUI) latestContext.ui.setWidget(WIDGET_KEY, undefined);
		repaint = undefined;
	});

	pi.registerCommand("vault-usage", {
		description: "List every provider usage window for the launch vault",
		handler: async (_args, ctx) => {
			if (!ctx.hasUI) return;
			const lines = detailLines(state, Date.now());
			if (lines.length === 0) {
				ctx.ui.notify("Vault usage: no report data yet.", "info");
				return;
			}
			await ctx.ui.select("Vault usage windows", lines);
		},
	});
}
