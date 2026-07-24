{ pkgs }:

let
  runtimeConfig = pkgs.writeText "omp-secret-obfuscation-runtime.yml" ''
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
  '';
  captureProvider = pkgs.writeText "omp-secret-obfuscation-provider.ts" ''
    import {
      AssistantMessageEventStream,
      type AssistantMessage,
      type Model,
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

    function finish(stream: AssistantMessageEventStream, model: Model): void {
      const text = "captured";
      const partial: AssistantMessage = {
        role: "assistant",
        content: [{ type: "text", text }],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: zeroUsage,
        stopReason: "stop",
        timestamp: Date.now(),
      };
      stream.push({ type: "start", partial });
      stream.push({ type: "text_start", contentIndex: 0, partial });
      stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial });
      stream.push({ type: "text_end", contentIndex: 0, content: text, partial });
      stream.push({ type: "done", reason: "stop", message: partial });
    }

    export default function secretCaptureProvider(pi: ExtensionAPI): void {
      pi.registerProvider("issue17-secret-fixture", {
        baseUrl: "fixture://secret-capture",
        apiKey: "fixture-api-key",
        api: "issue17-secret-capture",
        models: [
          {
            id: "capture",
            name: "Issue 17 secret capture",
            reasoning: false,
            input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: 32768,
            maxTokens: 1024,
          },
        ],
        streamSimple(model, context) {
          const stream = new AssistantMessageEventStream();
          queueMicrotask(async () => {
            try {
              const capturePath = process.env.ISSUE17_SECRET_CAPTURE;
              if (!capturePath) throw new Error("ISSUE17_SECRET_CAPTURE is required");
              await Bun.write(capturePath, JSON.stringify(context));
              finish(stream, model);
            } catch (error) {
              stream.fail(error);
            }
          });
          return stream;
        },
      });
    }
  '';
in
pkgs.runCommand "check-omp-secret-obfuscation"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    export HOME="$TMPDIR/home"
    project="$TMPDIR/project"
    mkdir -p "$HOME" "$project"

    export ISSUE17_SECRET_MARKER="issue17-planted-secret-4f0d9a26"
    export ISSUE17_SECRET_CAPTURE="$TMPDIR/provider-context.json"

    ${pkgs.omp-configured}/bin/omp-managed config managed --json \
      > "$TMPDIR/effective.json"
    jq -e '.effectiveManaged.secrets.enabled == true' \
      "$TMPDIR/effective.json" >/dev/null

    # The deterministic provider runs in-process, after OMP's provider-context
    # transform, so this exercises the pinned binary and the shipped managed
    # launcher without network access. It proves plaintext user content is
    # redacted before provider dispatch; HTTP serialization itself is outside
    # this sandboxed check's boundary.
    ${pkgs.omp-configured}/bin/omp-managed \
      --extension ${captureProvider} \
      --config ${runtimeConfig} \
      --model issue17-secret-fixture/capture \
      --cwd "$project" \
      --thinking off \
      --no-session \
      --no-tools \
      --no-lsp \
      --no-title \
      --print \
      "marker:$ISSUE17_SECRET_MARKER" \
      > "$TMPDIR/omp.out"

    jq -e --arg marker "$ISSUE17_SECRET_MARKER" '
      ([
        .messages[]
        | select(.role == "user")
        | .content[]
        | select(.type == "text")
        | .text
      ]) as $texts
      | (($texts | length) == 1)
        and ($texts[0] | test("^marker:#[A-Z0-9]{12}(:[ULCM])?#$"))
        and (all($texts[]; contains($marker) | not))
    ' "$ISSUE17_SECRET_CAPTURE" >/dev/null
    ! grep -Fq "$ISSUE17_SECRET_MARKER" "$ISSUE17_SECRET_CAPTURE"

    mkdir "$out"
  ''
