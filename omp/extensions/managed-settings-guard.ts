import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import {
	existsSync,
	readFileSync,
	renameSync,
	statSync,
	unlinkSync,
	unwatchFile,
	watchFile,
	writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";

export const MANAGED_PATHS = [
	"providers.webSearch",
	"providers.anthropic.serverSideFallback",
	"symbolPreset",
	"colorBlindMode",
	"modelRoles",
	"retry.enabled",
	"retry.modelFallback",
	"retry.fallbackRevertPolicy",
	"retry.fallbackChains",
	"personality",
	"advisor.enabled",
	"advisor.subagents",
	"advisor.syncBacklog",
	"stt.enabled",
	"branchSummary.enabled",
	"autolearn.enabled",
	"autolearn.autoContinue",
	"github.enabled",
	"checkpoint.enabled",
	"statusLine.preset",
	"statusLine.compactThinkingLevel",
	"statusLine.transparent",
	"terminal.showProgress",
	"tui.tight",
	"display.shimmer",
	"display.showTokenUsage",
	"display.cacheMissMarker",
	"codexResets.autoRedeem",
	"task.showResolvedModelBadge",
	"task.agentModelOverrides",
	"task.disabledAgents",
	"memory.backend",
	"theme.dark",
	"browser.headless",
	"browser.enabled",
	"proseOnlyThinking",
	"defaultThinkingLevel",
	"tools.approvalMode",
	"secrets.enabled",
] as const;

type ConfigRecord = Record<string, unknown>;

interface ManagedPathNode {
	terminal: boolean;
	children: Map<string, ManagedPathNode>;
}

interface ConfigSlot {
	hasValue: boolean;
	value?: unknown;
}

export interface RestoreResult {
	config: unknown;
	changed: boolean;
}

function isConfigRecord(value: unknown): value is ConfigRecord {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function cloneConfig<T>(value: T): T {
	return structuredClone(value);
}

function configEquals(left: unknown, right: unknown): boolean {
	return Bun.deepEquals(left, right, true);
}

function buildManagedPathTree(paths: readonly string[]): ManagedPathNode {
	const root: ManagedPathNode = { terminal: false, children: new Map() };

	for (const path of paths) {
		let node = root;
		for (const segment of path.split(".")) {
			let child = node.children.get(segment);
			if (!child) {
				child = { terminal: false, children: new Map() };
				node.children.set(segment, child);
			}
			node = child;
		}
		node.terminal = true;
	}

	return root;
}

function restoreSlot(
	current: ConfigSlot,
	baseline: ConfigSlot,
	node: ManagedPathNode,
): ConfigSlot {
	if (node.terminal) {
		return baseline.hasValue
			? { hasValue: true, value: cloneConfig(baseline.value) }
			: { hasValue: false };
	}

	if (baseline.hasValue && !isConfigRecord(baseline.value)) {
		// A scalar or sequence at an ancestor owns the effective value of every
		// descendant. Restore it wholesale rather than trying to descend through it.
		return { hasValue: true, value: cloneConfig(baseline.value) };
	}

	const currentWasRecord = current.hasValue && isConfigRecord(current.value);
	const restored: ConfigRecord = currentWasRecord
		? cloneConfig(current.value as ConfigRecord)
		: {};
	const baselineRecord =
		baseline.hasValue && isConfigRecord(baseline.value)
			? baseline.value
			: undefined;

	for (const [segment, child] of node.children) {
		const currentHasChild = Object.hasOwn(restored, segment);
		const baselineHasChild =
			baselineRecord !== undefined && Object.hasOwn(baselineRecord, segment);
		const childResult = restoreSlot(
			{
				hasValue: currentHasChild,
				value: currentHasChild ? restored[segment] : undefined,
			},
			{
				hasValue: baselineHasChild,
				value: baselineHasChild ? baselineRecord?.[segment] : undefined,
			},
			child,
		);

		if (childResult.hasValue) {
			restored[segment] = childResult.value;
		} else {
			delete restored[segment];
		}
	}

	if (currentWasRecord) return { hasValue: true, value: restored };
	if (Object.keys(restored).length > 0) {
		return { hasValue: true, value: restored };
	}
	if (baseline.hasValue) return { hasValue: true, value: restored };
	return { hasValue: false };
}

/**
 * Restore Nix-owned paths from a startup snapshot while retaining edits outside
 * those paths. The function is side-effect free and intentionally accepts
 * unknown YAML roots so malformed ancestor shapes can be repaired safely.
 */
export function restoreManagedPaths(
	currentConfig: unknown,
	baselineConfig: unknown,
	managedPaths: readonly string[] = MANAGED_PATHS,
): RestoreResult {
	const tree = buildManagedPathTree(managedPaths);
	const restored = restoreSlot(
		{ hasValue: true, value: currentConfig },
		{ hasValue: true, value: baselineConfig },
		tree,
	);
	const config = restored.hasValue ? restored.value : {};

	return {
		config,
		changed: !configEquals(config, currentConfig),
	};
}

function machineConfigCandidates(
	env: NodeJS.ProcessEnv = process.env,
	cwd = process.cwd(),
): [string, string] {
	const home = env.HOME || cwd;
	const configuredAgentDir = env.PI_CODING_AGENT_DIR?.trim();
	const agentDir = configuredAgentDir
		? isAbsolute(configuredAgentDir)
			? configuredAgentDir
			: resolve(cwd, configuredAgentDir)
		: join(home, env.PI_CONFIG_DIR || ".omp", "agent");

	return [join(agentDir, "config.yml"), join(agentDir, "config.yaml")];
}

/** Resolve the same writable machine configuration fallback used by OMP. */
export function resolveMachineConfigPath(
	env: NodeJS.ProcessEnv = process.env,
	cwd = process.cwd(),
): string {
	const [ymlPath, yamlPath] = machineConfigCandidates(env, cwd);
	return existsSync(ymlPath) || !existsSync(yamlPath) ? ymlPath : yamlPath;
}

function localOverridePath(env: NodeJS.ProcessEnv = process.env): string {
	const home = env.HOME || process.cwd();
	const configHome = env.XDG_CONFIG_HOME
		? isAbsolute(env.XDG_CONFIG_HOME)
			? env.XDG_CONFIG_HOME
			: resolve(home, env.XDG_CONFIG_HOME)
		: join(home, ".config");
	return join(configHome, "omp", "local.yml");
}

function settingsMessage(): string {
	return `Nix-managed settings are locked for this session. Use \`omp config managed\` to inspect effective values, \`${localOverridePath()}\` for machine-only defaults, or edit the dotfiles policy.`;
}

function parseConfigFile(path: string): unknown {
	if (!existsSync(path)) return {};
	const parsed = Bun.YAML.parse(readFileSync(path, "utf8"));
	return isConfigRecord(parsed) ? parsed : {};
}

function writeConfigFile(path: string, config: unknown): void {
	const tempPath = join(
		dirname(path),
		`.${path.split("/").at(-1)}.managed-guard-${process.pid}-${Date.now()}`,
	);
	const mode = existsSync(path) ? statSync(path).mode & 0o777 : 0o600;

	try {
		writeFileSync(tempPath, Bun.YAML.stringify(config), {
			encoding: "utf8",
			mode,
			flag: "wx",
		});
		renameSync(tempPath, path);
	} finally {
		try {
			unlinkSync(tempPath);
		} catch {
			// The atomic rename normally consumes the temporary file.
		}
	}
}

export default function managedSettingsGuard(pi: ExtensionAPI) {
	const candidates = machineConfigCandidates();
	const snapshotPath = resolveMachineConfigPath();
	let baseline: unknown;
	let baselineError = false;
	let notify: ((message: string, level: "warning") => void) | undefined;
	let pendingNotice: "restored" | "error" | undefined;
	let lastNotice = "";
	let lastNoticeAt = 0;

	try {
		baseline = parseConfigFile(snapshotPath);
	} catch {
		baseline = {};
		baselineError = true;
	}

	const sendNotice = (kind: "restored" | "error") => {
		const message =
			kind === "restored"
				? "A command tried to change Nix-managed OMP settings. Those paths were restored; unmanaged edits were kept."
				: "The managed-settings guard could not safely read or restore the writable OMP configuration. Fix its YAML before changing settings.";
		if (!notify) {
			pendingNotice = kind;
			return;
		}
		const now = Date.now();
		if (message === lastNotice && now - lastNoticeAt < 1_000) return;
		lastNotice = message;
		lastNoticeAt = now;
		notify(message, "warning");
	};

	let protecting = false;
	const protectManagedPaths = () => {
		if (protecting) return;
		protecting = true;
		try {
			if (baselineError) {
				sendNotice("error");
				return;
			}

			const activePath = resolveMachineConfigPath();
			const current = parseConfigFile(activePath);
			const restored = restoreManagedPaths(current, baseline);
			if (!restored.changed) return;

			writeConfigFile(activePath, restored.config);
			sendNotice("restored");
		} catch {
			sendNotice("error");
		} finally {
			protecting = false;
		}
	};

	const watcher = () => protectManagedPaths();
	for (const candidate of candidates) {
		watchFile(candidate, { interval: 500, persistent: false }, watcher);
	}

	pi.on("session_start", (_event, ctx) => {
		notify = (message, level) => ctx.ui.notify(message, level);
		if (pendingNotice) {
			const notice = pendingNotice;
			pendingNotice = undefined;
			sendNotice(notice);
		}
	});

	pi.on("input", (event, ctx) => {
		const command = event.text.trim().split(/\s+/, 1)[0]?.toLowerCase();
		if (command !== "/settings") return;

		ctx.ui.notify(settingsMessage(), "warning");
		return { handled: true };
	});

	pi.on("session_shutdown", () => {
		protectManagedPaths();
		for (const candidate of candidates) unwatchFile(candidate, watcher);
		notify = undefined;
	});
}
