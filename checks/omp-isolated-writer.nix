{ pkgs }:

let
  runtimeConfig = pkgs.writeText "omp-isolated-writer-runtime.yml" ''
    async:
      enabled: false
    advisor:
      enabled: false
    autolearn:
      enabled: false
    branchSummary:
      enabled: false
    checkpoint:
      enabled: false
    retry:
      enabled: false
    task:
      batch: false
      agentModelOverrides:
        task: issue17-isolation-fixture/writer
  '';
  scriptedProvider = pkgs.writeText "omp-isolated-writer-provider.ts" ''
    import { realpathSync, writeFileSync } from "node:fs";
    import { resolve } from "node:path";
    import {
      AssistantMessageEventStream,
      type AssistantMessage,
      type Model,
      type TextContent,
      type ToolCall,
      type Usage,
    } from "@oh-my-pi/pi-ai";
    import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

    const zeroUsage: Usage = {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    };

    type Block = TextContent | ToolCall;

    function emit(stream: AssistantMessageEventStream, model: Model, blocks: Block[]): void {
      const reason: "stop" | "toolUse" = blocks.some((block) => block.type === "toolCall")
        ? "toolUse"
        : "stop";
      const partial: AssistantMessage = {
        role: "assistant",
        content: blocks,
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: zeroUsage,
        stopReason: reason,
        timestamp: Date.now(),
      };
      stream.push({ type: "start", partial });
      blocks.forEach((block, contentIndex) => {
        if (block.type === "text") {
          stream.push({ type: "text_start", contentIndex, partial });
          stream.push({ type: "text_delta", contentIndex, delta: block.text, partial });
          stream.push({ type: "text_end", contentIndex, content: block.text, partial });
          return;
        }
        const serialized = JSON.stringify(block.arguments);
        stream.push({ type: "toolcall_start", contentIndex, partial });
        stream.push({ type: "toolcall_delta", contentIndex, delta: serialized, partial });
        stream.push({ type: "toolcall_end", contentIndex, toolCall: block, partial });
      });
      stream.push({ type: "done", reason, message: partial });
    }

    function response(model: Model, blocks: Block[]): AssistantMessageEventStream {
      const stream = new AssistantMessageEventStream();
      queueMicrotask(() => emit(stream, model, blocks));
      return stream;
    }

    export default function isolatedWriterProvider(pi: ExtensionAPI): void {
      const extensionRepo = realpathSync(resolve(import.meta.dir, "../.."));
      let callCount = 0;

      pi.registerProvider("issue17-isolation-fixture", {
        baseUrl: "fixture://isolated-writer",
        apiKey: "fixture-api-key",
        api: "issue17-isolation-script",
        models: [
          {
            id: "writer",
            name: "Issue 17 isolated writer",
            reasoning: false,
            input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: 32768,
            maxTokens: 2048,
          },
        ],
        streamSimple(model, context) {
          callCount += 1;
          const sourcePath = process.env.ISSUE17_SOURCE_REPO;
          const observationPath = process.env.ISSUE17_ISOLATION_OBSERVATION;
          if (!sourcePath || !observationPath) {
            throw new Error("isolated-writer fixture environment is incomplete");
          }
          const sourceRepo = realpathSync(sourcePath);
          const isSourceProvider = extensionRepo === sourceRepo;

          if (isSourceProvider && callCount === 1) {
            return response(model, [
              {
                type: "toolCall",
                id: "issue17-task-call",
                name: "task",
                arguments: {
                  name: "Issue17Writer",
                  agent: "task",
                  task: "Replace fixture.txt with exactly isolated-change followed by a newline, then finish.",
                  isolated: true,
                },
              },
            ]);
          }

          if (!isSourceProvider && callCount === 1) {
            return response(model, [
              {
                type: "toolCall",
                id: "issue17-write-call",
                name: "write",
                arguments: {
                  path: "fixture.txt",
                  content: "isolated-change\n",
                },
              },
            ]);
          }

          if (!isSourceProvider && callCount === 2) {
            const stream = new AssistantMessageEventStream();
            queueMicrotask(async () => {
              try {
                const isolatedText = await Bun.file(resolve(extensionRepo, "fixture.txt")).text();
                const sourceText = await Bun.file(resolve(sourceRepo, "fixture.txt")).text();
                await Bun.write(
                  observationPath,
                  JSON.stringify({ extensionRepo, sourceRepo, isolatedText, sourceText }),
                );
                emit(stream, model, [{ type: "text", text: "isolated writer finished" }]);
              } catch (error) {
                stream.fail(error);
              }
            });
            return stream;
          }

          writeFileSync(observationPath + ".parent", JSON.stringify(context));
          return response(model, [{ type: "text", text: "parent finished" }]);
        },
      });
    }
  '';
in
pkgs.runCommand "check-omp-isolated-writer"
  {
    nativeBuildInputs = [
      pkgs.gitMinimal
      pkgs.jq
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    repo="$TMPDIR/source"
    observation="$TMPDIR/isolation-observation.json"
    mkdir -p "$HOME" "$repo/.omp/extensions"
    cp ${runtimeConfig} "$repo/.omp/config.yml"
    cp ${scriptedProvider} "$repo/.omp/extensions/isolation-fixture.ts"
    printf 'source-baseline\n' > "$repo/fixture.txt"

    git init --quiet "$repo"
    git -C "$repo" config user.name "Isolation Fixture"
    git -C "$repo" config user.email "isolation-fixture@example.invalid"
    git -C "$repo" add .
    git -C "$repo" commit --quiet -m baseline

    (
      cd "$repo"
      ${pkgs.omp-configured}/bin/omp-managed config managed --json \
        > "$TMPDIR/effective.json"
    )
    jq -e '.effectiveManaged.task.isolation == {
      "mode": "auto",
      "merge": "patch",
      "commits": "generic"
    }' "$TMPDIR/effective.json" >/dev/null

    export ISSUE17_SOURCE_REPO="$repo"
    export ISSUE17_ISOLATION_OBSERVATION="$observation"

    # The deterministic provider replaces only remote model inference. The
    # pinned OMP task/write tools, copy-on-write backend, delta capture,
    # teardown, and patch application all run normally. This covers an explicit
    # `isolated: true` writing spawn; it does not claim process isolation or
    # prove that an arbitrary model will choose isolation without that request.
    ${pkgs.omp-configured}/bin/omp-managed \
      --model issue17-isolation-fixture/writer \
      --cwd "$repo" \
      --thinking off \
      --no-session \
      --no-lsp \
      --no-title \
      --print \
      "Run the isolated writer fixture." \
      > "$TMPDIR/omp.out"

    jq -e --arg source "$repo" '
      (.sourceRepo == $source)
      and (.extensionRepo != $source)
      and (.isolatedText == "isolated-change\n")
      and (.sourceText == "source-baseline\n")
    ' "$observation" >/dev/null

    test "$(cat "$repo/fixture.txt")" = "isolated-change"
    test "$(git -C "$repo" diff --name-only)" = "fixture.txt"
    test -z "$(git -C "$repo" diff --cached --name-only)"
    jq -e '
      [
        .messages[]
        | select(.role == "toolResult")
        | .content[]
        | select(.type == "text")
        | .text
      ]
      | any(contains("<merge-summary>\nApplied patches: yes\n</merge-summary>"))
    ' "$observation.parent" >/dev/null

    mkdir "$out"
  ''
