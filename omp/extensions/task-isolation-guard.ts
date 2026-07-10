import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

type TaskInput = {
	isolated?: unknown;
	tasks?: Array<{ isolated?: unknown }>;
};

/** Return null only when every spawn represented by a task call is isolated. */
export function taskIsolationViolation(input: TaskInput): string | null {
	if (Array.isArray(input.tasks)) {
		if (input.tasks.length === 0 || input.tasks.some(task => task?.isolated !== true)) {
			return "Every task batch item must set isolated: true under the managed security policy.";
		}
		return null;
	}

	if (input.isolated !== true) {
		return "Task spawning requires isolated: true under the managed security policy.";
	}
	return null;
}

export default function taskIsolationGuard(pi: ExtensionAPI) {
	pi.on("tool_call", event => {
		if (event.toolName !== "task") return;
		const reason = taskIsolationViolation(event.input as TaskInput);
		return reason ? { block: true, reason } : undefined;
	});
}
