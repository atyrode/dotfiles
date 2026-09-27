import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { isAbsolute, join, resolve } from "node:path";
import managedPaths from "./managed-paths.json";

const managedKeys = managedPaths.map(path => path.toLowerCase());

function isManagedCfgWrite(rawPath: unknown): boolean {
	if (typeof rawPath !== "string") return false;
	// write accepts a read-style [URL#TAG] header and read selectors, while
	// cfg accepts both dotted and slash-separated, case-insensitive keys.
	const target = rawPath.trim().replace(/^\[(cfg:\/\/.*)#[0-9a-f]{4}\]$/i, "$1");
	if (!target.toLowerCase().startsWith("cfg://")) return false;
	const key = target
		.slice("cfg://".length)
		.split(/[?#:]/, 1)[0]!
		.split(/[/.]/)
		.filter(Boolean)
		.join(".")
		.toLowerCase();
	return managedKeys.some(owner => key === owner || key.startsWith(`${owner}.`) || owner.startsWith(`${key}.`));
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

export default function managedSettingsGuard(pi: ExtensionAPI) {
	// Managed launch layers own effective session settings, not the writable
	// machine file. Rolling that file back to a startup snapshot undoes seed
	// resets and edits made by other sessions, including legitimate deletions.
	pi.on("input", (event, ctx) => {
		const command = event.text.trim().split(/\s+/, 1)[0]?.toLowerCase();
		if (command !== "/settings") return;

		ctx.ui.notify(settingsMessage(), "warning");
		return { handled: true };
	});

	pi.on("tool_call", event => {
		if (event.toolName !== "write" || !isManagedCfgWrite(event.input.path)) return;
		return { block: true, reason: settingsMessage() };
	});
}
