{ pkgs }:

let
  # Force the eager todo on the first turn: the forced tool_choice Opus/Sonnet
  # 5.5 reject. Everything else that could add requests stays off.
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
        const { model, tool_choice, thinking, output_config } = event.payload;
        appendFileSync(capture, JSON.stringify({ model, tool_choice, thinking, output_config }) + "\n");
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

    first_request() { # model [thinking]
      export FORCED_TOOL_CHOICE_CAPTURE="$TMPDIR/$1-''${2:-high}.jsonl"
      ${pkgs.omp-configured}/bin/omp-managed \
        --extension ${payloadCapture} \
        --config ${runtimeConfig} \
        --model "anthropic/$1" \
        --thinking "''${2:-high}" \
        --cwd "$project" \
        --no-session \
        --no-lsp \
        --no-title \
        --print \
        "plan dinner" </dev/null >/dev/null 2>&1 || true
      jq -sc --arg model "$1" 'map(select(.model == $model)) | first' "$FORCED_TOOL_CHOICE_CAPTURE"
    }

    # Control: the eager todo still forces the tool where Anthropic allows it,
    # so the 5.5 assertions below are exercising a forced turn.
    first_request claude-sonnet-5 | jq -e '.tool_choice == {type: "tool", name: "todo"}' >/dev/null
    # Opus 5.5 400s on a forced choice; the platform downgrades it to auto.
    first_request claude-opus-5-5 | jq -e '.tool_choice == {type: "auto"}' >/dev/null
    # Sonnet 5.5 must preserve the reviewer's effort, not disable thinking to
    # accommodate the unsupported forced choice.
    first_request claude-sonnet-5-5 | jq -e \
      '.tool_choice == {type: "auto"} and .thinking.type == "adaptive" and .output_config.effort == "high"' >/dev/null
    # The slow-role fallback uses xhigh, which requires adaptive thinking.
    first_request claude-sonnet-5-5 xhigh | jq -e \
      '.tool_choice == {type: "auto"} and .thinking.type == "adaptive" and .output_config.effort == "xhigh"' >/dev/null

    mkdir "$out"
  ''
