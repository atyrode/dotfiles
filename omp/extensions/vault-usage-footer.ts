import { resolveUsedFraction, type UsageReport } from "@oh-my-pi/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { matchesKey, truncateToWidth, visibleWidth } from "@oh-my-pi/pi-tui";

/**
 * Multi-provider vault usage footer (issue #220).
 *
 * Renders one row riding directly on top of the editor's status border,
 * summarizing every provider usage window the launch vault's broker
 * reports, with the active model's provider first. The footer represents
 * the vault fixed at process launch; it never implies that changing the
 * globally selected `code` vault mutates this process.
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
 * same display-identity call the upstream status line makes). Display fields
 * are masked together with OMP's collision-aware `usage --redact` algorithm
 * before state assignment; raw values are never assigned to state, logged, or
 * rendered, and credentials, tokens, broker environment values, and raw report
 * metadata are never read.
 *
 * Layout contract: at supported widths `renderRow` produces one content
 * row (loading, data, stale, or unavailable) — or two when the complete
 * wide (bars) layout needs a second row — and the widget adds a dim `─`
 * rule above, tying the rows to the box's bottom border; only terminal
 * width may switch it to zero rows. Fetch completion changes text and may
 * switch a data layout between one and two rows, never anything larger.
 * Rows are inset LEFT_PAD/RIGHT_PAD columns from each edge (matching the
 * border's corner-to-π indent); on one-row wide layouts usage bars
 * stretch to fill the inset width (re-fit on every paint), while two-row
 * layouts column-align and stretch every bar to one shared uniform
 * width — the largest both rows fit.
 */

/**
 * Inside a managed herdr pane the usage display lives in herdr's sidebar
 * (fed by the machine's usage publisher), so the per-pane footer stays
 * fully inert there — moved, not duplicated. All three variables gate it,
 * matching herdr's own integration extension: a real managed pane always
 * carries the socket path and its pane id.
 */
export function inHerdrPane(env: Record<string, string | undefined>): boolean {
	return env.HERDR_ENV === "1" && !!env.HERDR_SOCKET_PATH && !!env.HERDR_PANE_ID;
}
const WIDGET_KEY = "vault-usage";
const REFRESH_KEY = "alt+u";
const BAR_CELLS = 10;
/** Columns reserved on each edge so the row sits inset within the editor
 * box footprint (matching the border's `╭── π` corner-to-π indent). */
const LEFT_PAD = 4;
const RIGHT_PAD = 4;
const PAD_TEXT = " ".repeat(LEFT_PAD);
const MIN_WIDTH = 40;
const MEDIUM_WIDTH = 64;
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

// All fitting, slack, and truncation math measures terminal cells through
// the TUI's own `visibleWidth` (UAX#11 + grapheme model, ANSI-stripping),
// so the footer can never disagree with how the engine lays out its rows —
// the reset glyph's U+FE0E is 2 UTF-16 units but 1 column, and
// provider-supplied labels may legally contain wide graphemes.

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

/**
 * Retention priority for responsive shedding. Exhausted limits remain first;
 * core duration buckets (5h/7d) then outrank named variants such as Fable or
 * Spark, with the summary risk order breaking ties inside each class.
 */
function retentionBefore(a: WindowView, b: WindowView): boolean {
	if (a.exhausted !== b.exhausted) return a.exhausted;
	const aVariant = shortWindowLabel(a.fullLabel, a.windowLabel).includes(" ");
	const bVariant = shortWindowLabel(b.fullLabel, b.windowLabel).includes(" ");
	if (aVariant !== bVariant) return !aVariant;
	return summaryBefore(a, b);
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
 * OMP usage CLI redaction parity (`buildRedactionMap`, usage-cli.ts).
 * Every value keeps a two-character anchor. Colliding anchors gain the
 * shortest middle-out differentiator; residual collisions extend the prefix.
 * The full set must be supplied together so masks remain distinguishable.
 */
export function buildRedactionMap(values: Iterable<string>): Map<string, string> {
	const unique = [...new Set(values)];
	const masks = new Map<string, string>();
	const byAnchor = new Map<string, string[]>();
	for (const value of unique) {
		const anchor = value.slice(0, 2);
		const peers = byAnchor.get(anchor) ?? [];
		peers.push(value);
		byAnchor.set(anchor, peers);
	}
	for (const value of unique) {
		const anchor = value.slice(0, 2);
		const peers = (byAnchor.get(anchor) ?? []).filter(other => other !== value);
		if (peers.length === 0) {
			masks.set(value, `${anchor}*`);
			continue;
		}
		const infix = findDistinguishingInfix(value, peers);
		masks.set(value, infix === undefined ? `${anchor}*` : `${anchor}*${infix}*`);
	}
	const byMask = new Map<string, string[]>();
	for (const value of unique) {
		const mask = masks.get(value)!;
		const collided = byMask.get(mask) ?? [];
		collided.push(value);
		byMask.set(mask, collided);
	}
	for (const collided of byMask.values()) {
		if (collided.length < 2) continue;
		for (const value of collided) {
			let length = Math.min(2, value.length);
			while (
				length < value.length &&
				collided.some(other => other !== value && other.startsWith(value.slice(0, length)))
			) {
				length += 1;
			}
			masks.set(value, `${value.slice(0, length)}*`);
		}
	}
	return masks;
}

function findDistinguishingInfix(value: string, peers: readonly string[]): string | undefined {
	const start = Math.min(2, value.length);
	const center = value.length / 2;
	for (let length = 1; length <= value.length - start; length += 1) {
		let best: { infix: string; distance: number } | undefined;
		for (let position = start; position + length <= value.length; position += 1) {
			const candidate = value.slice(position, position + length);
			if (peers.some(peer => peer.includes(candidate))) continue;
			const distance = Math.abs(position + length / 2 - center);
			if (!best || distance < best.distance) best = { infix: candidate, distance };
		}
		if (best) return best.infix;
	}
	return undefined;
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

/** Provider chunk head: `*name` for the active provider, painted. */
function providerHead(view: ProviderView, isActive: boolean, color: boolean): Cell {
	const name = `${isActive ? "*" : ""}${displayProvider(view.provider)}`;
	return { plain: name, ansi: paint(name, providerColor(view.provider), color, isActive) };
}

/** Dim `·` delimiter between a provider's window cells. */
function windowJoiner(color: boolean): Cell {
	return { plain: " · ", ansi: ` ${paint("·", PALETTE.dim, color)} ` };
}

const EMPTY_SLOT: Cell = { plain: "", ansi: "" };

/**
 * One window as fixed slots — label, bar, pct, reset, note — so callers
 * can either join the populated slots with spaces (one-row cells) or pad
 * each slot to a shared column width (two-row aligned cells). Absent
 * slots are empty cells.
 */
function windowSlots(
	window: WindowView,
	level: DetailLevel,
	now: number,
	color: boolean,
	barCells: number,
): [Cell, Cell, Cell, Cell, Cell] {
	const wide = level === "wide";
	const label = shortWindowLabel(window.fullLabel, window.windowLabel);
	const pct = window.usedFraction === undefined ? undefined : usedPercent(window.usedFraction);
	const bar: Cell = wide
		? {
				plain: renderBar(window.usedFraction, barCells),
				ansi: renderBarAnsi(window.usedFraction, barCells, color),
		  }
		: EMPTY_SLOT;
	const exhaustedMark = !wide && (window.exhausted || (pct ?? 0) >= 100) ? "!" : "";
	const pctText = formatPercent(window.usedFraction) + exhaustedMark;
	let reset: Cell = EMPTY_SLOT;
	if (window.resetsAt !== undefined && window.resetsAt > now) {
		const left = window.resetsAt - now;
		const resetText = `${RESET_GLYPH}${formatCountdown(left)}`;
		const emphasis = resetEmphasis(left, window.durationMs);
		reset = {
			plain: resetText,
			ansi:
				emphasis === "dim"
					? paint(resetText, PALETTE.dim, color)
					: paint(resetText, PALETTE.reset, color, emphasis === "imminent"),
		};
	}
	let note: Cell = EMPTY_SLOT;
	if (wide) {
		if (window.exhausted || (pct ?? 0) >= 100) {
			note = { plain: "maxed", ansi: paint("maxed", PALETTE.red, color) };
		} else if ((pct ?? 0) >= 80) {
			note = { plain: "tight", ansi: paint("tight", PALETTE.warn, color) };
		}
	}
	return [{ plain: label, ansi: label }, bar, { plain: pctText, ansi: pctText }, reset, note];
}

function windowCell(
	window: WindowView,
	level: DetailLevel,
	now: number,
	color: boolean,
	barCells: number,
): Cell {
	return joinCells(
		windowSlots(window, level, now, color, barCells).filter(slot => slot.plain !== ""),
		{ plain: " ", ansi: " " },
	);
}

function providerChunk(
	view: ProviderView,
	windows: readonly WindowView[],
	isActive: boolean,
	level: DetailLevel,
	now: number,
	color: boolean,
	identity: string | undefined,
	sizeBar: () => number,
): Cell {
	const head = providerHead(view, isActive, color);
	const cells: Cell[] = [head];
	if (identity !== undefined) {
		cells.push({ plain: identity, ansi: paint(identity, PALETTE.dim, color) });
	}
	const windowCells = windows.map(window => windowCell(window, level, now, color, sizeBar()));
	cells.push(joinCells(windowCells, windowJoiner(color)));
	return joinCells(cells, { plain: " ", ansi: " " });
}

/**
 * Elastic bar sizer: hands out `BAR_CELLS` plus an even share of `slack`
 * to each bar in render order, leftmost bars absorbing the remainder, so a
 * stretched row fills its budget exactly.
 */
function makeBarSizer(slack: number, count: number): () => number {
	if (count <= 0 || slack <= 0) return () => BAR_CELLS;
	const base = BAR_CELLS + Math.floor(slack / count);
	const remainder = slack % count;
	let index = 0;
	return () => base + (index++ < remainder ? 1 : 0);
}

/** Provider render order: active first; pseudo chunk when active is unreported. */
function chunkOrder(
	state: Extract<FooterState, { kind: "data" }>,
	active: ActiveProviderInfo | undefined,
): { pseudo: boolean; entries: ProviderView[] } {
	const entries = [...state.providers];
	if (active) {
		const index = entries.findIndex(entry => entry.provider === active.provider);
		if (index > 0) entries.unshift(...entries.splice(index, 1));
	}
	return {
		pseudo: active !== undefined && !entries.some(entry => entry.provider === active.provider),
		entries,
	};
}

/** Active-first provider chunks; the active-but-unreported chunk leads. */
function buildChunks(
	state: Extract<FooterState, { kind: "data" }>,
	options: RenderOptions,
	level: DetailLevel,
	color: boolean,
	windowLists: ReadonlyMap<string, readonly WindowView[]>,
	withIdentity: boolean,
	sizeBar: () => number = () => BAR_CELLS,
): Cell[] {
	const active = options.active;
	const { pseudo, entries } = chunkOrder(state, active);
	const chunks: Cell[] = [];
	if (pseudo && active) {
		// Distinct states: unauthenticated vs authenticated-but-unreported.
		const name = `*${displayProvider(active.provider)}`;
		const status = active.authenticated ? "usage n/a" : "unauthenticated";
		chunks.push({
			plain: `${name} ${status}`,
			ansi: `${paint(name, providerColor(active.provider), color, true)} ${paint(status, PALETTE.dim, color)}`,
		});
	}
	for (const entry of entries) {
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
				sizeBar,
			),
		);
	}
	return chunks;
}

/**
 * Dim `─` rule tying the row to the editor box's bottom border (the
 * "light" separator). Spans the same inset budget the bars fill and is
 * re-fit on every paint; the widget emits it only above a rendered row,
 * so it inherits the row's width gate.
 */
export function renderRule(width: number, color: boolean = COLOR_DEFAULT): string {
	return PAD_TEXT + paint("─".repeat(Math.max(0, width - LEFT_PAD - RIGHT_PAD)), PALETTE.dim, color);
}

/**
 * Render the footer as zero rows (below MIN_WIDTH), one row, or — when
 * one row cannot hold every labeled window with bars — two rows. Rows
 * are inset LEFT_PAD columns from the left edge and reserve RIGHT_PAD
 * columns on the right, mirroring the editor border's corner-to-π
 * indent on both sides. Levels: wide (bars + notes), medium (compact
 * windows), narrow (active provider's best window), hidden below
 * MIN_WIDTH. Wide starts from every labeled window per provider and
 * degrades deterministically: identities render only when the complete
 * single row fits with them; when one wide row overflows, the complete
 * layout is retried across two rows (bars intact) before any downgrade
 * to compact medium cells. Only then are named variant buckets shed
 * before core duration buckets (never a provider's last window),
 * followed by whole trailing providers. When one-row wide content fits,
 * leftover columns stretch its bars (leftmost first) so the row fills
 * the inset width exactly; the fit is recomputed every paint, so resizes
 * adapt. Two-row layouts instead column-align the rows and stretch every
 * bar to one shared uniform width (the largest both rows fit).
 * Provider chunks are delimited by a dim `│`. A one-row result is
 * truncated to the inset width as the final guard and never wraps.
 */
export function renderRow(state: FooterState, options: RenderOptions): string[] {
	if (options.width < MIN_WIDTH) return [];
	const emit = (text: string): string[] => [PAD_TEXT + text];
	const color = options.color ?? COLOR_DEFAULT;
	if (state.kind === "loading") return emit(paint("usage: loading…", PALETTE.dim, color));
	if (state.kind === "unavailable") return emit(paint("usage: unavailable", PALETTE.dim, color));

	// The wide (bars) presentation is attempted at every width above the
	// narrow breakpoint — one row first, then two — and medium is reached
	// only by downgrade when neither fits. Fitting math uses the inset
	// budget.
	let level: DetailLevel = options.width >= MEDIUM_WIDTH ? "wide" : "narrow";
	const width = options.width - LEFT_PAD - RIGHT_PAD;

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
	const budget = width - visibleWidth(suffix.plain);

	const providerSeparator: Cell = { plain: " │ ", ansi: ` ${paint("│", PALETTE.group, color)} ` };
	const rowWidth = (chunks: readonly Cell[]): number =>
		chunks.reduce(
			(sum, chunk, index) =>
				sum + visibleWidth(chunk.plain) + (index > 0 ? providerSeparator.plain.length : 0),
			0,
		);

	const windowLists = new Map<string, readonly WindowView[]>(
		state.providers.map(view => [
			view.provider,
			level === "narrow" ? [view.summary] : labelGroups(view.windows),
		]),
	);

	const barCount = (lists: ReadonlyMap<string, readonly WindowView[]>): number => {
		if (level !== "wide") return 0;
		let count = 0;
		for (const windows of lists.values()) count += windows.length;
		return count;
	};

	// Tier ladder — monotonic as width shrinks, so no decoration blinks back
	// in during a resize: identities+cue → cue → plain → shedding (when the
	// hotkey is armed the identity tier always carries the cue).
	if (level === "wide" && state.identities !== undefined) {
		const withIdentities = buildChunks(state, options, level, color, windowLists, true);
		if (withIdentities.length > 0) {
			const idSuffix = cueSuffix ?? suffix;
			const slack = width - visibleWidth(idSuffix.plain) - rowWidth(withIdentities);
			if (slack >= 0) {
				const stretched = buildChunks(
					state,
					options,
					level,
					color,
					windowLists,
					true,
					makeBarSizer(slack, barCount(windowLists)),
				);
				return emit(joinCells(stretched, providerSeparator).ansi + idSuffix.ansi);
			}
		}
	}

	// No identities: try the cue tier, then shed the lowest-priority window
	// (never a provider's last) until the row fits.
	let chunks = buildChunks(state, options, level, color, windowLists, false);
	if (chunks.length === 0) return emit(paint("usage: none reported", PALETTE.dim, color));
	if (cueSuffix !== undefined) {
		const slack = width - visibleWidth(cueSuffix.plain) - rowWidth(chunks);
		if (slack >= 0) {
			const stretched = buildChunks(
				state,
				options,
				level,
				color,
				windowLists,
				false,
				makeBarSizer(slack, barCount(windowLists)),
			);
			return emit(joinCells(stretched, providerSeparator).ansi + cueSuffix.ansi);
		}
	}

	// Two-line wide tier: bars carry more information than compact text,
	// so before degrading to text the complete wide layout is retried
	// across two rows. Splits prefer provider boundaries; when a single
	// provider's windows are what overflow, the split lands between window
	// cells instead and the continuation row repeats the provider head so
	// ownership stays legible. The suffix rides the bottom row. All bars
	// share one uniform width — the largest for which both rows fit their
	// budgets — and, in the dominant one-provider-per-row shape, the rows
	// column-align into a table.
	// Greedy first fit is complete for two rows: the top row packs
	// maximally, so the bottom row is as narrow as any two-row split can
	// make it.
	const renderTwoLineWide = (): string[] | undefined => {
		const { entries } = chunkOrder(state, options.active);
		const providers = entries.filter(
			entry => (windowLists.get(entry.provider) ?? []).length > 0,
		);
		// buildChunks over empty window lists yields exactly the pseudo
		// chunk (active-but-unreported), or nothing.
		const pseudoCell: Cell | undefined = buildChunks(state, options, "wide", color, new Map(), false)[0];
		const totalWindows = providers.reduce(
			(sum, entry) => sum + (windowLists.get(entry.provider) ?? []).length,
			0,
		);
		if (totalWindows + (pseudoCell !== undefined ? 1 : 0) < 2) return undefined;
		interface Segment {
			view: ProviderView;
			windows: readonly WindowView[];
		}
		const segmentCell = (segment: Segment, sizeBar: () => number): Cell =>
			providerChunk(
				segment.view,
				segment.windows,
				segment.view.provider === options.active?.provider,
				"wide",
				options.now,
				color,
				undefined,
				sizeBar,
			);
		const lineCells = (line: readonly Segment[], withPseudo: boolean, sizeBar: () => number): Cell[] => {
			const cells: Cell[] = [];
			if (withPseudo && pseudoCell !== undefined) cells.push(pseudoCell);
			for (const segment of line) cells.push(segmentCell(segment, sizeBar));
			return cells;
		};
		const lineWidth = (line: readonly Segment[], withPseudo: boolean): number =>
			rowWidth(lineCells(line, withPseudo, () => BAR_CELLS));
		// Largest uniform per-bar growth both rows can absorb within their
		// budgets; undefined when a base row already overflows.
		const sharedStretch = (
			base: readonly [Cell, Cell],
			bars: readonly [number, number],
			budgets: readonly [number, number],
		): number | undefined => {
			let extra = Number.POSITIVE_INFINITY;
			for (const row of [0, 1] as const) {
				const slack = budgets[row] - visibleWidth(base[row].plain);
				if (slack < 0) return undefined;
				if (bars[row] > 0) extra = Math.min(extra, Math.floor(slack / bars[row]));
			}
			return Number.isFinite(extra) ? extra : 0;
		};
		// Table alignment for the one-segment-per-row shape: the head plus
		// each window column's label/bar/pct/reset/note slots pad to the
		// width of their widest counterpart (percent right-aligned), so the
		// two rows read as one table. Skipped when a row carries several
		// provider chunks or the padding would overflow a budget.
		const alignedPair = (
			rows: readonly [readonly Segment[], readonly Segment[]],
			budgets: readonly [number, number],
		): [Cell, Cell] | undefined => {
			if (rows[0].length !== 1 || rows[1].length !== 1) return undefined;
			const segments = [rows[0][0], rows[1][0]] as const;
			const heads = segments.map(segment =>
				providerHead(segment.view, segment.view.provider === options.active?.provider, color),
			);
			const headWidth = Math.max(...heads.map(head => visibleWidth(head.plain)));
			const pad = (cell: Cell, target: number, alignRight: boolean): Cell => {
				const fill = " ".repeat(Math.max(0, target - visibleWidth(cell.plain)));
				return alignRight
					? { plain: fill + cell.plain, ansi: fill + cell.ansi }
					: { plain: cell.plain + fill, ansi: cell.ansi + fill };
			};
			const build = (barCells: number): [Cell, Cell] => {
				const slots = segments.map(segment =>
					segment.windows.map(window => windowSlots(window, "wide", options.now, color, barCells)),
				);
				const lines = segments.map((_, row) => {
					const cells = slots[row].map((windowParts, column) => {
						const peer = slots[1 - row][column];
						const parts: Cell[] = [];
						for (const [slot, part] of windowParts.entries()) {
							const target = Math.max(
								visibleWidth(part.plain),
								peer === undefined ? 0 : visibleWidth(peer[slot].plain),
							);
							if (target === 0) continue;
							parts.push(pad(part, target, slot === 2));
						}
						return joinCells(parts, { plain: " ", ansi: " " });
					});
					const body = joinCells(cells, windowJoiner(color));
					const line = joinCells([pad(heads[row], headWidth, false), body], {
						plain: " ",
						ansi: " ",
					});
					// Trailing pad from the last column is dead weight.
					return { plain: line.plain.trimEnd(), ansi: line.ansi.trimEnd() };
				});
				return [lines[0], lines[1]];
			};
			const base = build(BAR_CELLS);
			const extra = sharedStretch(
				base,
				[segments[0].windows.length, segments[1].windows.length],
				budgets,
			);
			if (extra === undefined) return undefined;
			return extra > 0 ? build(BAR_CELLS + extra) : base;
		};
		const layout = (tail: Cell, granular: boolean): string[] | undefined => {
			const budgets: readonly [number, number] = [width, width - visibleWidth(tail.plain)];
			const atoms: Segment[] = [];
			for (const view of providers) {
				const windows = windowLists.get(view.provider) ?? [];
				if (granular) for (const window of windows) atoms.push({ view, windows: [window] });
				else atoms.push({ view, windows });
			}
			const lines: [Segment[], Segment[]] = [[], []];
			let index: 0 | 1 = 0;
			for (const atom of atoms) {
				for (;;) {
					const line = lines[index];
					const last = line[line.length - 1];
					const candidate: Segment[] =
						last !== undefined && last.view.provider === atom.view.provider
							? [
									...line.slice(0, -1),
									{ view: last.view, windows: [...last.windows, ...atom.windows] },
							  ]
							: [...line, atom];
					if (lineWidth(candidate, index === 0) <= budgets[index]) {
						lines[index] = candidate;
						break;
					}
					if (index === 1) return undefined;
					index = 1;
				}
			}
			// The bottom row never sits empty under a full top row (a true
			// one-line fit does not reach this tier; only the suffix pushed
			// it over): pull the last window down beside the suffix.
			if (lines[1].length === 0) {
				const top = lines[0];
				const last = top[top.length - 1];
				if (last === undefined) return undefined;
				const kept: Segment = { view: last.view, windows: last.windows.slice(0, -1) };
				lines[0] = kept.windows.length > 0 ? [...top.slice(0, -1), kept] : top.slice(0, -1);
				lines[1] = [{ view: last.view, windows: last.windows.slice(-1) }];
				if (lineWidth(lines[1], false) > budgets[1]) return undefined;
			}
			// All bars share one uniform width — the largest for which both
			// rows (bottom including its suffix) still fit — so the two rows
			// never disagree on bar size.
			const barsOn = (line: readonly Segment[]): number =>
				line.reduce((sum, segment) => sum + segment.windows.length, 0);
			const plainPair = (): [Cell, Cell] => {
				const build = (barCells: number): [Cell, Cell] => [
					joinCells(lineCells(lines[0], true, () => barCells), providerSeparator),
					joinCells(lineCells(lines[1], false, () => barCells), providerSeparator),
				];
				const base = build(BAR_CELLS);
				// The greedy fit guarantees the base rows fit their budgets.
				const extra = sharedStretch(base, [barsOn(lines[0]), barsOn(lines[1])], budgets) ?? 0;
				return extra > 0 ? build(BAR_CELLS + extra) : base;
			};
			const rendered =
				(pseudoCell === undefined ? alignedPair(lines, budgets) : undefined) ?? plainPair();
			return [PAD_TEXT + rendered[0].ansi, PAD_TEXT + rendered[1].ansi + tail.ansi];
		};
		const attempt = (tail: Cell): string[] | undefined => layout(tail, false) ?? layout(tail, true);
		return (cueSuffix !== undefined ? attempt(cueSuffix) : undefined) ?? attempt(suffix);
	};

	// Bars outrank compact text: only when even two rows cannot hold every
	// labeled window does the row degrade to compact cells. The medium
	// retry also prevents shrinking width from making information
	// disappear before the shedding ladder runs.
	if (level === "wide" && rowWidth(chunks) > budget) {
		const twoLine = renderTwoLineWide();
		if (twoLine !== undefined) return twoLine;
		level = "medium";
		chunks = buildChunks(state, options, level, color, windowLists, false);
		if (cueSuffix !== undefined && rowWidth(chunks) + visibleWidth(cueSuffix.plain) <= width) {
			return emit(joinCells(chunks, providerSeparator).ansi + cueSuffix.ansi);
		}
	}
	while (rowWidth(chunks) > budget) {
		let worstProvider: string | undefined;
		let worst: WindowView | undefined;
		for (const [provider, windows] of windowLists) {
			if (windows.length < 2) continue;
			for (const candidate of windows) {
				if (worst === undefined || retentionBefore(worst, candidate)) {
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
		const cost =
			kept.length === 0
				? visibleWidth(chunk.plain)
				: visibleWidth(chunk.plain) + providerSeparator.plain.length;
		if (used + cost > budget) break;
		kept.push(chunk);
		used += cost;
		if (level === "narrow") break;
	}
	if (kept.length === 0) kept.push(chunks[0]);
	let row = joinCells(kept, providerSeparator);
	// Elastic bars: stretch the kept bars into the leftover budget so the
	// row fills the line; recomputed per paint, so resizes adapt.
	const slack = budget - rowWidth(kept);
	if (level === "wide" && slack > 0) {
		const { pseudo, entries } = chunkOrder(state, options.active);
		const keptLists = new Map<string, readonly WindowView[]>();
		let remaining = kept.length - (pseudo ? 1 : 0);
		for (const entry of entries) {
			if (remaining <= 0) break;
			const windows = windowLists.get(entry.provider) ?? [];
			if (windows.length === 0) continue;
			keptLists.set(entry.provider, windows);
			remaining -= 1;
		}
		const bars = barCount(keptLists);
		if (bars > 0) {
			const stretched = buildChunks(
				state,
				options,
				level,
				color,
				keptLists,
				false,
				makeBarSizer(slack, bars),
			);
			if (stretched.length === kept.length) row = joinCells(stretched, providerSeparator);
		}
	}
	const plain = PAD_TEXT + row.plain + suffix.plain;
	const maxCols = options.width - RIGHT_PAD;
	// Final guard: an overflowing row degrades to plain text so truncation
	// can never slice an SGR sequence (cell-accurate, no ellipsis, no pad).
	if (visibleWidth(plain) > maxCols) return [truncateToWidth(plain, maxCols, "", false)];
	return emit(row.ansi + suffix.ansi);
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
	if (inHerdrPane(process.env)) return;
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
		const raw: Array<{ provider: string; value: string }> = [];
		for (const view of providers) {
			try {
				const info = ctx.modelRegistry.authStorage.getOAuthAccountIdentity(
					view.provider,
					ctx.sessionManager.getSessionId(),
				);
				const display = info?.email ?? info?.accountId;
				if (typeof display === "string" && display.length > 0) {
					raw.push({ provider: view.provider, value: display });
				}
			} catch {
				// Identity is optional decoration; never let it break usage.
			}
		}
		if (raw.length === 0) return undefined;
		const masks = buildRedactionMap(raw.map(entry => entry.value));
		return Object.fromEntries(raw.map(entry => [entry.provider, masks.get(entry.value)!]));
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
		let cachedKey: string | undefined;
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
				if (rows.length === 0) {
					if (cachedRows.length > 0) {
						cachedRows = [];
						cachedKey = undefined;
					}
					return cachedRows;
				}
				// Width keys the cache too: the rule resizes even when the
				// row text does not (e.g. loading/unavailable states).
				const key = width + "\u0000" + rows.join("\u0000");
				if (key !== cachedKey) {
					cachedKey = key;
					// A dim rule line between the editor box and the rows
					// ties the footer to the border instead of floating
					// below it.
					cachedRows = [renderRule(width), ...rows];
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
		// Below the editor: the row hangs under the box (where `code` shows
		// usage), never abutting the chat transcript above the editor.
		ctx.ui.setWidget(WIDGET_KEY, componentFactory, { placement: "belowEditor" });
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
