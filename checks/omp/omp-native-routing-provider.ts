import { appendFileSync, writeFileSync } from "node:fs";
import {
  AssistantMessageEventStream,
  type AssistantMessage,
  type Context,
  type Model,
  type TextContent,
  type ToolCall,
  type ToolResultMessage,
  type Usage,
} from "@oh-my-pi/pi-ai";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const provider = "native-routing-fixture";
const zeroUsage: Usage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};
const gridAgents = ["task", "scout", "sonic", "reviewer", "security-reviewer", "seance"];
const retryAgents = ["task", "reviewer", "scout"];
type Block = TextContent | ToolCall;

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required by the native routing fixture`);
  return value;
}

function emit(model: Model, blocks: Block[], fail = false): AssistantMessageEventStream {
  const stream = new AssistantMessageEventStream();
  queueMicrotask(() => {
    const reason = fail ? "error" : blocks.some(block => block.type === "toolCall") ? "toolUse" : "stop";
    const message: AssistantMessage = {
      role: "assistant",
      content: blocks,
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: zeroUsage,
      stopReason: reason,
      timestamp: Date.now(),
      ...(fail ? { errorStatus: 503, errorMessage: "503 native routing fixture temporarily unavailable" } : {}),
    };
    stream.push({ type: "start", partial: message });
    blocks.forEach((block, contentIndex) => {
      if (block.type === "text") {
        stream.push({ type: "text_start", contentIndex, partial: message });
        stream.push({ type: "text_delta", contentIndex, delta: block.text, partial: message });
        stream.push({ type: "text_end", contentIndex, content: block.text, partial: message });
      } else {
        stream.push({ type: "toolcall_start", contentIndex, partial: message });
        stream.push({ type: "toolcall_delta", contentIndex, delta: JSON.stringify(block.arguments), partial: message });
        stream.push({ type: "toolcall_end", contentIndex, toolCall: block, partial: message });
      }
    });
    if (fail) stream.push({ type: "error", reason: "error", error: message });
    else stream.push({ type: "done", reason, message });
  });
  return stream;
}

function invocation(context: Context): { scenario: string; agent: string } {
  // A seance sees its saved conversation before its new assignment. The last
  // user marker, not a global call counter or the selected model, identifies it.
  const userText = context.messages
    .filter(message => message.role === "user")
    .map(message => typeof message.content === "string"
      ? message.content
      : message.content.filter(block => block.type === "text").map(block => block.text).join("\n"))
    .join("\n");
  const matches = [...userText.matchAll(/OMP_NATIVE_ROUTING:(source|grid|retry):([a-z-]+)/g)];
  const match = matches.at(-1);
  if (!match) throw new Error("Unexpected model request without a native routing assignment");
  return { scenario: match[1], agent: match[2] };
}

function yielded(id: string, data: unknown, type?: string[]): ToolCall {
  return { type: "toolCall", id, name: "yield", arguments: { data, ...(type ? { type } : {}) } };
}

function childResponse(model: Model, context: Context, scenario: string, agent: string): AssistantMessageEventStream {
  const yieldResults = context.messages.filter(message =>
    message.role === "toolResult" && message.toolName === "yield" &&
    message.toolCallId.startsWith(`native-routing-${scenario}-${agent}-`));
  if (yieldResults.some(message => message.isError)) {
    throw new Error(`Native ${agent} rejected its fixture yield: ${JSON.stringify(yieldResults)}`);
  }
  if (yieldResults.length > 0) {
    // Incremental reviewer sections are finalized by native idle finalization.
    if (agent !== "reviewer" || yieldResults.length !== 3) {
      throw new Error(`Unexpected continuation after ${agent}'s terminal yield`);
    }
    return emit(model, []);
  }
  const id = `native-routing-${scenario}-${agent}-yield`;
  switch (agent) {
    case "reviewer":
      return emit(model, [
        yielded(`${id}-correctness`, "correct", ["overall_correctness"]),
        yielded(`${id}-explanation`, "The disposable routing fixture completed without repository changes.", ["explanation"]),
        yielded(`${id}-confidence`, 1, ["confidence"]),
      ]);
    case "security-reviewer":
      return emit(model, [yielded(id, {
        coverage_summary: "Only the disposable routing fixture was assigned; no vulnerability claim is made.",
        findings: [],
        reviewed_paths: [],
      })]);
    case "scout":
      return emit(model, [yielded(id, {
        summary: "Native routing fixture completed.",
        files: [],
        architecture: "The pinned OMP task tool selected the bundled scout.",
      })]);
    default:
      return emit(model, [yielded(id, `native routing ${agent} completed`)]);
  }
}

export default function nativeRoutingProvider(pi: ExtensionAPI): void {
  const observation = requiredEnvironment("OMP_NATIVE_ROUTING_OBSERVATION");
  // This fixture never serves HTTP. Fail closed if any background subsystem
  // attempts fetch instead of using the deterministic provider callback.
  globalThis.fetch = (() => { throw new Error("Network access is forbidden in the native routing fixture"); }) as typeof fetch;
  pi.registerProvider(provider, {
    baseUrl: "fixture://native-routing",
    apiKey: "public-zero-cost-fixture-key",
    api: "native-routing-script",
    models: ["main", "default", "task", "smol", "slow", "archive", "lead", "default-fallback", "task-fallback", "slow-fallback"]
      .map(id => ({
        id,
        name: `Native routing fixture ${id}`,
        reasoning: true,
        thinking: { mode: "effort" as const, efforts: ["minimal", "low", "medium", "high", "xhigh", "max"] as const },
        input: ["text" as const],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 32768,
        maxTokens: 2048,
      })),
    streamSimple(model, context, options) {
      const { scenario, agent } = invocation(context);
      appendFileSync(observation, JSON.stringify({
        scenario,
        agent,
        provider: model.provider,
        model: model.id,
        thinking: options?.reasoning ?? null,
        tools: context.tools?.map(tool => tool.name).sort() ?? [],
      }) + "\n");
      if (scenario === "source") return emit(model, [{ type: "text", text: "Disposable source session for native seance inheritance." }]);
      if (agent !== "parent") {
        if (scenario === "retry" && model.id === "lead") return emit(model, [], true);
        return childResponse(model, context, scenario, agent);
      }
      const agents = scenario === "grid" ? gridAgents : retryAgents;
      const results = context.messages.filter((message): message is ToolResultMessage =>
        message.role === "toolResult" && message.toolName === "task" &&
        message.toolCallId.startsWith(`native-routing-${scenario}-`));
      if (results.length > agents.length) throw new Error("Native task returned too many fixture results");
      if (results.length === agents.length) {
        writeFileSync(`${observation}.${scenario}-results.json`, JSON.stringify(results));
        return emit(model, [{ type: "text", text: `native routing ${scenario} finished` }]);
      }
      const child = agents[results.length];
      return emit(model, [{
        type: "toolCall",
        id: `native-routing-${scenario}-${child}`,
        name: "task",
        arguments: {
          name: `NativeRoute${results.length + 1}`,
          agent: child,
          task: `OMP_NATIVE_ROUTING:${scenario}:${child}\nComplete this disposable routing observation without reading or changing repository files.`,
          schemaMode: "strict",
          ...(child === "seance" ? { sourceSession: requiredEnvironment("OMP_NATIVE_ROUTING_SOURCE_SESSION") } : {}),
        },
      }]);
    },
  });
}
