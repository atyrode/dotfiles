import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

// Anthropic rejects forced tool use on Claude Opus 5.5 with `400 tool_choice:
// type "tool" and "any" are not supported for this model`, but the pinned
// catalog only marks Fable and Mythos as lacking forced tool choice. Every
// forced turn (the eager todo on a new chat's first message, a forced subagent
// yield) therefore failed over to the next model. Apply the downgrade upstream
// gives Fable: the tool stays available and the prompt still steers to it.
// Delete this once the pinned catalog sets supportsForcedToolChoice=false here.
const rejectsForcedToolChoice = /^claude-opus-5-5(?:-\d{8})?$/;

interface AnthropicPayload {
	model?: unknown;
	tool_choice?: { type?: unknown };
}

export default function forcedToolChoiceCompat(pi: ExtensionAPI) {
	pi.on("before_provider_request", (event, ctx) => {
		if (ctx.model?.api !== "anthropic-messages") return;
		const payload = event.payload as AnthropicPayload | null;
		if (typeof payload?.model !== "string" || !rejectsForcedToolChoice.test(payload.model)) return;
		const choice = payload.tool_choice?.type;
		if (choice !== "tool" && choice !== "any") return;
		return { ...payload, tool_choice: { type: "auto" } };
	});
}
