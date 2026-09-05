import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { isAbsolute, join, resolve } from "node:path";

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
}
