import { resolveUsedFraction, type UsageReport } from "@oh-my-pi/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { matchesKey } from "@oh-my-pi/pi-tui";

/**
 * Multi-provider vault usage footer (issue #220).
 *
 * Renders one below-editor row summarizing every provider usage window the
 * launch vault's broker reports, with the active model's provider first. The
 * footer represents the vault fixed at process launch; it never implies that
 * changing the globally selected `code` vault mutates this process.
 *
 * Visual parity: colors, gradient bar math, window shortnames, provider
 * display names, reset glyph/urgency tinting, and cached-age vocabulary are
 * ported from `code` v0.1.0 (`barStr`, `shortWin`, `fmtReset`,
 * `formatCachedAge`, `usageRow` in main.go) and the shared cli-kit palette,
 * pinned by fixtures in the flake check.
 *
 * API discipline (issue #220, operator-approved surface): this extension
 * calls only read-only, non-mutating AuthStorage methods —
 * `fetchUsageReports()` (aggregate, broker-routed and coalesced upstream),
 * `hasAuth()` (non-secret boolean), and `getOAuthAccountIdentity()` (the
 * same display-identity call the upstream status line makes). The identity's
 * display field is masked to `x…@domain` form immediately at capture; raw
 * values are never stored, logged, or rendered, and credentials, tokens,
 * broker environment values, and raw report metadata are never read.
 *
 * Layout contract: at supported widths the component returns exactly one
 * physical row (loading, data, stale, or unavailable); only terminal width
 * may switch it to zero rows. Fetch completion changes text, never row
 * count, so network timing can never move the prompt.
 */

const WIDGET_KEY = "vault-usage";
const REFRESH_KEY = "alt+u";
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

/** cli-kit palette tokens (palette.go) shared by `code` and `atyrode`. */
export const PALETTE = {
	dim: "#78829b", // CDim
	red: "#d05c60", // CRed
	green: "#78c8aa", // CGreen
	warn: "#ff9f52", // CAcc — StWarn
	head: "#9aa4b1", // CHead — fallback provider heading
	group: "#69727e", // CGrp — provider-group delimiter
	reset: "#c8d0dc", // usageRow's near-reset emphasis tint
	codex: "#62a7ff", // providerHeading Codex
	claude: "#ff9f52", // providerHeading Claude
} as const;

/** Reset glyph with text-presentation selector, 1 cell wide (cli-kit GReset). */
export const RESET_GLYPH = "↻\uFE0E";

const COLOR_DEFAULT = process.env.NO_COLOR === undefined && process.env.TERM !== "dumb";

/** Truecolor SGR wrap; identity when color is off or text is empty. */
export function paint(text: string, hex: string, color: boolean, bold = false): string {
	if (!color || text.length === 0) return text;
	const r = Number.parseInt(hex.slice(1, 3), 16);
	const g = Number.parseInt(hex.slice(3, 5), 16);
	const b = Number.parseInt(hex.slice(5, 7), 16);
	return `\u001b[${bold ? "1;" : ""}38;2;${r};${g};${b}m${text}\u001b[0m`;
}

/** One provider limit window, projected to a secret-free view model. */
export interface WindowView {
	limitId: string;
	/** Stable window id used for grouping and compact labels (e.g. "5h"). */
	windowLabel: string;
	/** Human label for the detail view (e.g. "Claude 5 Hour"). */
	fullLabel: string;
	usedFraction?: number;
	resetsAt?: number;
	/** Window duration when known; drives reset-urgency tinting. */
	durationMs?: number;
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
	| {
			kind: "data";
			providers: ProviderView[];
			fetchedAt: number;
			/** Pre-masked display identity per provider; raw values never stored. */
			identities?: Readonly<Record<string, string>>;
	  };

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
	/** Next scheduled fetch; renders a live minute-granular row suffix. */
	nextRefreshAt?: number;
	/** Hotkey label (e.g. "alt+u"); decorates the suffix when nothing is sacrificed. */
	refreshHint?: string;
	/** Explicit for tests; defaults to NO_COLOR/TERM-derived behavior. */
	color?: boolean;
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
 * Every distinct labeled window — one winner per short label by summary
 * priority — ordered shortest window first, then label. Claude therefore
 * shows 5h, 7d, and 7d fable side by side when width permits.
 */
export function labelGroups(windows: readonly WindowView[]): WindowView[] {
	const groups = new Map<string, WindowView>();
	for (const window of windows) {
		const key = shortWindowLabel(window.fullLabel, window.windowLabel);
		const current = groups.get(key);
		if (!current || summaryBefore(window, current)) groups.set(key, window);
	}
	return [...groups.values()].sort(
		(a, b) =>
			(a.durationMs ?? Number.MAX_SAFE_INTEGER) - (b.durationMs ?? Number.MAX_SAFE_INTEGER) ||
			shortWindowLabel(a.fullLabel, a.windowLabel).localeCompare(shortWindowLabel(b.fullLabel, b.windowLabel)),
	);
}

/**
 * Project aggregate reports into the secret-free view model. Drops `raw`,
 * `metadata`, notes, endpoint details, and every identity field immediately;
 * only provider names, window labels, fractions, resets, durations, and
 * non-secret scope descriptors survive.
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
				durationMs: limit.window?.durationMs,
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

/** Provider display names as `code` shows them (providerHeading, main.go). */
export function displayProvider(provider: string): string {
	if (provider === "anthropic") return "claude";
	if (provider === "openai-codex") return "codex";
	return provider;
}

export function providerColor(provider: string): string {
	if (provider === "anthropic") return PALETTE.claude;
	if (provider === "openai-codex") return PALETTE.codex;
	return PALETTE.head;
}

/** Window shortnames with `code` v0.1.0 parity (`shortWin`, main.go). */
export function shortWindowLabel(fullLabel: string, windowId: string): string {
	switch (fullLabel) {
		case "5 hours":
		case "Claude 5 Hour":
			return "5h";
		case "7 days":
		case "Claude 7 Day":
			return "7d";
		case "5 hours (Spark)":
			return "5h spark";
		case "7 days (Spark)":
			return "7d spark";
		case "Claude 7 Day (Fable)":
			return "7d fable";
	}
	return windowId || fullLabel;
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

/** Cached-data age with `code` v0.1.0 parity (`formatCachedAge`, main.go). */
export function formatCachedAge(ageMs: number): string {
	let seconds = Math.floor(ageMs / 1000);
	if (seconds < 0) seconds = 0;
	if (seconds < 60) return "<1m ago";
	if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
	if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h ago`;
	if (seconds < 604_800) return `${Math.floor(seconds / 86_400)}d ago`;
	if (seconds < 31_536_000) return `${Math.floor(seconds / 604_800)}w ago`;
	return `${Math.floor(seconds / 31_536_000)}y ago`;
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
 * Gradient bar fill color with `code` v0.1.0 parity (`barStr`, main.go):
 * green→red as usage climbs, blue channel fixed at 0x46.
 * p<=50: r=90+3p, g=200; p>50: r=235, g=200-3(p-50); r<=235, g>=60.
 */
export function barFillColor(pct: number): string {
	let r: number;
	let g: number;
	if (pct <= 50) {
		r = 90 + pct * 3;
		g = 200;
	} else {
		r = 235;
		g = 200 - (pct - 50) * 3;
	}
	if (r > 235) r = 235;
	if (g < 60) g = 60;
	const byte = (value: number): string =>
		Math.max(0, Math.min(255, Math.round(value)))
			.toString(16)
			.padStart(2, "0");
	return `#${byte(r)}${byte(g)}46`;
}

/**
 * Usage bar with `code` v0.1.0 fill parity (`barStr`, main.go):
 * `fill = (pct*cells + 50) / 100` in integer arithmetic, clamped. Plain
 * cells; color is applied by renderBarAnsi so tests can pin both layers.
 */
export function renderBar(fraction: number | undefined, cells: number): string {
	const pct = fraction === undefined ? 0 : usedPercent(fraction);
	let filled = Math.floor((pct * cells + 50) / 100);
	if (filled > cells) filled = cells;
	return "█".repeat(filled) + "░".repeat(cells - filled);
}

/** Gradient-filled bar: filled cells in barFillColor(pct), empty cells dim. */
export function renderBarAnsi(fraction: number | undefined, cells: number, color: boolean): string {
	const pct = fraction === undefined ? 0 : usedPercent(fraction);
	let filled = Math.floor((pct * cells + 50) / 100);
	if (filled > cells) filled = cells;
	return (
		paint("█".repeat(filled), barFillColor(pct), color) +
		paint("░".repeat(cells - filled), PALETTE.dim, color)
	);
}

/**
 * Masked display identity: first character of the local part, `…@`, domain.
 * Broker-redacted inputs (already `x…@domain`) pass through unchanged;
 * non-email identity keys keep at most two leading characters.
 */
export function maskEmail(identity: string): string {
	const at = identity.indexOf("@");
	if (at <= 0) return identity.length <= 3 ? identity : `${identity.slice(0, 2)}…`;
	return `${identity[0]}…@${identity.slice(at + 1)}`;
}

/**
 * Reset-countdown emphasis with `code` v0.1.0 parity (`usageRow`, main.go):
 * bold bright under 10% of the window remaining, bright under 25%, dim
 * otherwise or when the duration is unknown.
 */
export function resetEmphasis(msLeft: number, durationMs: number | undefined): "imminent" | "soon" | "dim" {
	if (durationMs === undefined || durationMs <= 0) return "dim";
	if (msLeft * 10 < durationMs) return "imminent";
	if (msLeft * 4 < durationMs) return "soon";
	return "dim";
}

type DetailLevel = "wide" | "medium" | "narrow";

/** A rendered fragment: plain text for width math, ansi for display. */
interface Cell {
	plain: string;
	ansi: string;
}

const joinCells = (cells: readonly Cell[], separator: Cell): Cell => {
	let plain = "";
	let ansi = "";
	for (const [index, cell] of cells.entries()) {
		if (index > 0) {
			plain += separator.plain;
			ansi += separator.ansi;
		}
		plain += cell.plain;
		ansi += cell.ansi;
	}
	return { plain, ansi };
};

function windowCell(window: WindowView, level: DetailLevel, now: number, color: boolean): Cell {
	const wide = level === "wide";
	const label = shortWindowLabel(window.fullLabel, window.windowLabel);
	const pct = window.usedFraction === undefined ? undefined : usedPercent(window.usedFraction);
	const plainParts: string[] = [label];
	const ansiParts: string[] = [label];
	if (wide) {
		plainParts.push(renderBar(window.usedFraction, BAR_CELLS));
		ansiParts.push(renderBarAnsi(window.usedFraction, BAR_CELLS, color));
	}
	const exhaustedMark = !wide && (window.exhausted || (pct ?? 0) >= 100) ? "!" : "";
	const pctText = formatPercent(window.usedFraction) + exhaustedMark;
	plainParts.push(pctText);
	ansiParts.push(pctText);
	if (window.resetsAt !== undefined && window.resetsAt > now) {
		const left = window.resetsAt - now;
		const resetText = `${RESET_GLYPH}${formatCountdown(left)}`;
		const emphasis = resetEmphasis(left, window.durationMs);
		plainParts.push(resetText);
		ansiParts.push(
			emphasis === "dim"
				? paint(resetText, PALETTE.dim, color)
				: paint(resetText, PALETTE.reset, color, emphasis === "imminent"),
		);
	}
	if (wide) {
		if (window.exhausted || (pct ?? 0) >= 100) {
			plainParts.push("maxed");
			ansiParts.push(paint("maxed", PALETTE.red, color));
		} else if ((pct ?? 0) >= 80) {
			plainParts.push("tight");
			ansiParts.push(paint("tight", PALETTE.warn, color));
		}
	}
	return { plain: plainParts.join(" "), ansi: ansiParts.join(" ") };
}

function providerChunk(
	view: ProviderView,
	windows: readonly WindowView[],
	isActive: boolean,
	level: DetailLevel,
	now: number,
	color: boolean,
	identity: string | undefined,
): Cell {
	const name = `${isActive ? "*" : ""}${displayProvider(view.provider)}`;
	const head: Cell = {
		plain: name,
		ansi: paint(name, providerColor(view.provider), color, isActive),
	};
	const cells: Cell[] = [head];
	if (identity !== undefined) {
		cells.push({ plain: identity, ansi: paint(identity, PALETTE.dim, color) });
	}
	const windowCells = windows.map(window => windowCell(window, level, now, color));
	const windowSeparator: Cell = { plain: " · ", ansi: ` ${paint("·", PALETTE.dim, color)} ` };
	cells.push(joinCells(windowCells, windowSeparator));
	return joinCells(cells, { plain: " ", ansi: " " });
}

/** Active-first provider chunks; the active-but-unreported chunk leads. */
function buildChunks(
	state: Extract<FooterState, { kind: "data" }>,
	options: RenderOptions,
	level: DetailLevel,
	color: boolean,
	windowLists: ReadonlyMap<string, readonly WindowView[]>,
	withIdentity: boolean,
): Cell[] {
	const active = options.active;
	const ordered = [...state.providers];
	if (active) {
		const index = ordered.findIndex(entry => entry.provider === active.provider);
		if (index > 0) ordered.unshift(...ordered.splice(index, 1));
	}
	const chunks: Cell[] = [];
	if (active && !ordered.some(entry => entry.provider === active.provider)) {
		// Distinct states: unauthenticated vs authenticated-but-unreported.
		const name = `*${displayProvider(active.provider)}`;
		const status = active.authenticated ? "usage n/a" : "unauthenticated";
		chunks.push({
			plain: `${name} ${status}`,
			ansi: `${paint(name, providerColor(active.provider), color, true)} ${paint(status, PALETTE.dim, color)}`,
		});
	}
	for (const entry of ordered) {
		const windows = windowLists.get(entry.provider) ?? [];
		if (windows.length === 0) continue;
		chunks.push(
			providerChunk(
				entry,
				windows,
				entry.provider === active?.provider,
				level,
				options.now,
				color,
				withIdentity ? state.identities?.[entry.provider] : undefined,
			),
		);
	}
	return chunks;
}

/**
 * Render the footer as zero rows (below MIN_WIDTH) or exactly one row.
 * Levels: wide (bars + notes), medium (compact windows), narrow (active
 * provider's best window), hidden below MIN_WIDTH. Wide and medium start
 * from every labeled window per provider and degrade deterministically:
 * identities render only when the complete row fits with them; otherwise
 * the lowest-priority window is shed (summary order — exhausted and
 * high-usage windows survive longest; never a provider's last window)
 * until the row fits, and whole trailing provider chunks go last.
 * Provider chunks are delimited by a dim `│`. The row is truncated to the
 * physical width as the final guard and never wraps.
 */
export function renderRow(state: FooterState, options: RenderOptions): string[] {
	const width = options.width;
	if (width < MIN_WIDTH) return [];
	const color = options.color ?? COLOR_DEFAULT;
	if (state.kind === "loading") return [paint("usage: loading…", PALETTE.dim, color)];
	if (state.kind === "unavailable") return [paint("usage: unavailable", PALETTE.dim, color)];

	const level: DetailLevel = width >= WIDE_WIDTH ? "wide" : width >= MEDIUM_WIDTH ? "medium" : "narrow";

	// Stale parity with `code`: a failed refresh marks retained data stale
	// immediately (`cached <age> ago`); the age threshold additionally covers
	// timer gaps after suspend/resume, where no failure was recorded but the
	// data aged out.
	const staleFor = options.now - state.fetchedAt;
	const isStale = options.refreshFailed === true || staleFor > options.staleAfterMs;
	const staleText = isStale ? `cached ${formatCachedAge(staleFor)}` : "";
	// Healthy rows carry the next-fetch countdown instead (minute-granular,
	// ticked live by the widget's repaint interval); staleness outranks it.
	const refreshText =
		staleText === "" &&
		level !== "narrow" &&
		options.nextRefreshAt !== undefined &&
		options.nextRefreshAt > options.now
			? `refresh in ${formatCountdown(options.nextRefreshAt - options.now)}`
			: "";
	const suffixText = staleText !== "" ? staleText : refreshText;
	const paintSuffix = (text: string): Cell =>
		text === ""
			? { plain: "", ansi: "" }
			: {
					plain: ` · ${text}`,
					ansi: ` ${paint("·", PALETTE.dim, color)} ${paint(text, staleText !== "" ? PALETTE.warn : PALETTE.dim, color)}`,
			  };
	const suffix = paintSuffix(suffixText);
	// The manual-refresh cue decorates a populated suffix one tier below
	// identities: like them, it may never cost a window.
	const cueSuffix =
		options.refreshHint !== undefined && suffixText !== "" && level !== "narrow"
			? paintSuffix(`${suffixText} (${options.refreshHint})`)
			: undefined;
	const budget = width - suffix.plain.length;

	const providerSeparator: Cell = { plain: " │ ", ansi: ` ${paint("│", PALETTE.group, color)} ` };
	const rowWidth = (chunks: readonly Cell[]): number =>
		chunks.reduce(
			(sum, chunk, index) => sum + chunk.plain.length + (index > 0 ? providerSeparator.plain.length : 0),
			0,
		);

	const windowLists = new Map<string, readonly WindowView[]>(
		state.providers.map(view => [
			view.provider,
			level === "narrow" ? [view.summary] : labelGroups(view.windows),
		]),
	);

	// Tier ladder — monotonic as width shrinks, so no decoration blinks back
	// in during a resize: identities+cue → cue → plain → shedding (when the
	// hotkey is armed the identity tier always carries the cue).
	if (level === "wide" && state.identities !== undefined) {
		const withIdentities = buildChunks(state, options, level, color, windowLists, true);
		if (withIdentities.length > 0) {
			const idSuffix = cueSuffix ?? suffix;
			if (rowWidth(withIdentities) <= width - idSuffix.plain.length) {
				return [joinCells(withIdentities, providerSeparator).ansi + idSuffix.ansi];
			}
		}
	}

	// No identities: try the cue tier, then shed the lowest-priority window
	// (never a provider's last) until the row fits.
	let chunks = buildChunks(state, options, level, color, windowLists, false);
	if (chunks.length === 0) return [paint("usage: none reported", PALETTE.dim, color)];
	if (cueSuffix !== undefined && rowWidth(chunks) <= width - cueSuffix.plain.length) {
		return [joinCells(chunks, providerSeparator).ansi + cueSuffix.ansi];
	}
	while (rowWidth(chunks) > budget) {
		let worstProvider: string | undefined;
		let worst: WindowView | undefined;
		for (const [provider, windows] of windowLists) {
			if (windows.length < 2) continue;
			for (const candidate of windows) {
				if (worst === undefined || summaryBefore(worst, candidate)) {
					worst = candidate;
					worstProvider = provider;
				}
			}
		}
		if (worst === undefined || worstProvider === undefined) break;
		const remaining = windowLists.get(worstProvider) ?? [];
		windowLists.set(
			worstProvider,
			remaining.filter(candidate => candidate !== worst),
		);
		chunks = buildChunks(state, options, level, color, windowLists, false);
	}

	// Pass 3: drop whole trailing provider chunks as the last resort.
	const kept: Cell[] = [];
	let used = 0;
	for (const chunk of chunks) {
		const cost = kept.length === 0 ? chunk.plain.length : chunk.plain.length + providerSeparator.plain.length;
		if (used + cost > budget) break;
		kept.push(chunk);
		used += cost;
		if (level === "narrow") break;
	}
	if (kept.length === 0) kept.push(chunks[0]);
	const row = joinCells(kept, providerSeparator);
	const plain = row.plain + suffix.plain;
	// Final guard: an overflowing row degrades to plain text so truncation
	// can never slice an SGR sequence.
	if (plain.length > width) return [plain.slice(0, width)];
	return [row.ansi + suffix.ansi];
}

/** Every original window/scope for the /vault-usage detail view. */
export function detailLines(state: FooterState, now: number): string[] {
	if (state.kind !== "data") return [];
	const lines: string[] = [];
	for (const view of state.providers) {
		const identity = state.identities?.[view.provider];
		for (const window of view.windows) {
			const parts = [
				displayProvider(view.provider) + (identity !== undefined ? ` ${identity}` : ""),
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
	let nextRefreshAt: number | undefined;
	let unhookInput: (() => void) | undefined;

	const activeInfo = (): ActiveProviderInfo | undefined => {
		const ctx = latestContext;
		const model = ctx?.models.current();
		if (!ctx || !model) return undefined;
		return {
			provider: model.provider,
			authenticated: ctx.modelRegistry.authStorage.hasAuth(model.provider),
		};
	};

	/**
	 * Masked display identity per reported provider via the supported
	 * read-only lookup, session-scoped exactly as the upstream status line
	 * performs it so multi-account providers resolve this session's account.
	 * Masking happens before assignment; the raw value's lifetime is this
	 * function. Identity failures never affect usage data.
	 */
	const collectIdentities = (
		ctx: ExtensionContext,
		providers: readonly ProviderView[],
	): Record<string, string> | undefined => {
		let identities: Record<string, string> | undefined;
		for (const view of providers) {
			try {
				const info = ctx.modelRegistry.authStorage.getOAuthAccountIdentity(
					view.provider,
					ctx.sessionManager.getSessionId(),
				);
				const display = info?.email ?? info?.accountId;
				if (typeof display === "string" && display.length > 0) {
					(identities ??= {})[view.provider] = maskEmail(display);
				}
			} catch {
				// Identity is optional decoration; never let it break usage.
			}
		}
		return identities;
	};

	const scheduleNext = (): void => {
		if (shutdown || !polling) return;
		clearTimeout(refreshTimer);
		const base =
			failures === 0
				? REFRESH_INTERVAL_MS
				: FAILURE_BACKOFF_MS[Math.min(failures - 1, FAILURE_BACKOFF_MS.length - 1)];
		const jitter = 1 + (Math.random() * 2 - 1) * REFRESH_JITTER;
		const delay = Math.round(base * jitter);
		nextRefreshAt = Date.now() + delay;
		refreshTimer = setTimeout(() => void refresh(), delay);
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
					state = {
						kind: "data",
						providers: projected.providers,
						fetchedAt: projected.fetchedAt,
						identities: collectIdentities(ctx, projected.providers),
					};
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
		nextRefreshAt = undefined;
		clearInterval(tickTimer);
		tickTimer = undefined;
	};

	const startPolling = (): void => {
		if (shutdown || polling) return;
		generation += 1;
		polling = true;
		// Local countdown/age repaint only; no network is involved in ticks.
		tickTimer = setInterval(() => repaint?.(), COUNTDOWN_TICK_MS);
		void refresh();
	};

	const manualRefresh = (ctx: ExtensionContext): void => {
		if (shutdown || !polling) return;
		// Manual refresh parity with code's usage panel: pull the next poll
		// forward; the in-flight guard dedupes concurrent fetches.
		clearTimeout(refreshTimer);
		refreshTimer = undefined;
		void refresh();
		if (ctx.hasUI) ctx.ui.notify("Vault usage: refreshing…", "info");
	};

	// A raw-input listener sees every chord before the editor and consumes
	// only the refresh key. `newSession` clears extension listeners, so each
	// `session_start` re-arms; the cue in the row renders only while armed.
	const armHotkey = (ctx: ExtensionContext): void => {
		if (!ctx.hasUI || typeof ctx.ui.onTerminalInput !== "function") return;
		unhookInput?.();
		unhookInput = ctx.ui.onTerminalInput(data => {
			if (!matchesKey(data, REFRESH_KEY)) return undefined;
			const current = latestContext;
			if (current) manualRefresh(current);
			return { consume: true };
		});
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
					nextRefreshAt,
					refreshHint: unhookInput !== undefined ? REFRESH_KEY : undefined,
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
		// Above the editor: the row rides flush on top of the status border,
		// reading as part of the box stack instead of a stray line below it.
		ctx.ui.setWidget(WIDGET_KEY, componentFactory, { placement: "aboveEditor" });
		armHotkey(ctx);
		startPolling();
	});

	pi.on("session_switch", (_event, ctx) => {
		latestContext = ctx;
		armHotkey(ctx);
		repaint?.();
	});

	pi.on("session_shutdown", () => {
		shutdown = true;
		stopPolling();
		unhookInput?.();
		unhookInput = undefined;
		if (latestContext?.hasUI) latestContext.ui.setWidget(WIDGET_KEY, undefined);
		repaint = undefined;
	});

	pi.registerCommand("vault-usage", {
		description: "List every provider usage window; 'refresh' or alt+u forces a fetch now",
		handler: async (args, ctx) => {
			if (!ctx.hasUI) return;
			if (typeof args === "string" && args.trim().toLowerCase() === "refresh") {
				manualRefresh(ctx);
				return;
			}
			const now = Date.now();
			const lines = detailLines(state, now);
			if (lines.length === 0) {
				ctx.ui.notify("Vault usage: no report data yet.", "info");
				return;
			}
			if (state.kind === "data") {
				let status = `fetched ${formatCachedAge(now - state.fetchedAt)}`;
				if (nextRefreshAt !== undefined && nextRefreshAt > now) {
					status += ` · next refresh ~${formatCountdown(nextRefreshAt - now)}`;
				}
				lines.unshift(status + ` · alt+u or "/vault-usage refresh" fetches now`);
			}
			// Read-only viewer: nothing here is selectable, so a select dialog
			// would misleadingly invite a choice. esc/enter/q just close it.
			await ctx.ui.custom<undefined>((_tui, theme, _keybindings, done) => {
				const rows = [
					theme.bold("Vault usage"),
					"",
					...lines,
					"",
					theme.fg("muted", "enter/esc/q closes"),
				];
				return {
					focused: false,
					render(): readonly string[] {
						return rows;
					},
					handleInput(data: string): void {
						if (matchesKey(data, "escape") || matchesKey(data, "enter") || data === "q") {
							done(undefined);
						}
					},
				};
			});
		},
	});
}
