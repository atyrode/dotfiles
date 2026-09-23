{ pkgs }:

let
  # Force the eager todo on the first turn: the forced tool_choice Opus 5.5
  # rejects. Everything else that could add requests stays off.
  runtimeConfig = pkgs.writeText "omp-forced-tool-choice-runtime.yml" ''
    todo:
      eager: always
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
  # Loaded after the managed platform, so it records the payload the platform
  # hands to the wire. The sandbox has no network; the request itself fails.
  payloadCapture = pkgs.writeText "omp-forced-tool-choice-capture.ts" ''
    import { appendFileSync } from "node:fs";
    import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

    export default function payloadCapture(pi: ExtensionAPI): void {
      pi.on("before_provider_request", event => {
        const capture = process.env.FORCED_TOOL_CHOICE_CAPTURE;
        if (!capture) throw new Error("FORCED_TOOL_CHOICE_CAPTURE is required");
        const { model, tool_choice } = event.payload as { model?: unknown; tool_choice?: unknown };
        appendFileSync(capture, JSON.stringify({ model, tool_choice }) + "\n");
      });
    }
  '';
in
pkgs.runCommand "check-omp-forced-tool-choice"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    export HOME="$TMPDIR/home"
    project="$TMPDIR/project"
    mkdir -p "$HOME" "$project"
    export ANTHROPIC_API_KEY=sk-ant-fixture

    first_request() { # model
      export FORCED_TOOL_CHOICE_CAPTURE="$TMPDIR/$1.jsonl"
      ${pkgs.omp-configured}/bin/omp-managed \
        --extension ${payloadCapture} \
        --config ${runtimeConfig} \
        --model "anthropic/$1" \
        --cwd "$project" \
        --no-session \
        --no-lsp \
        --no-title \
        --print \
        "plan dinner" </dev/null >/dev/null 2>&1 || true
      jq -sc --arg model "$1" 'map(select(.model == $model)) | first' "$FORCED_TOOL_CHOICE_CAPTURE"
    }

    # Control: the eager todo still forces the tool where Anthropic allows it,
    # so the Opus assertion below is exercising a forced turn.
    first_request claude-sonnet-5 | jq -e '.tool_choice == {type: "tool", name: "todo"}' >/dev/null
    # Opus 5.5 400s on a forced choice; the platform downgrades it to auto.
    first_request claude-opus-5-5 | jq -e '.tool_choice == {type: "auto"}' >/dev/null

    mkdir "$out"
  ''
