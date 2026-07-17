{ pkgs }:

let
  runtimeConfig = pkgs.writeText "omp-vault-usage-footer-runtime.yml" ''
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
  footerExtension = ../omp/extensions/vault-usage-footer.ts;
  # Deterministic scripted provider plus load-time assertions over the footer
  # module's exported view-model and rendering functions. Assertions run when
  # OMP imports the extension; the observation file is only written when every
  # assertion passed, so a silent load failure cannot fake a green check.
  testExtension = pkgs.writeText "omp-vault-usage-footer-test.ts" ''
    import { strict as assert } from "node:assert";
    import { writeFileSync } from "node:fs";
    import {
      AssistantMessageEventStream,
      type AssistantMessage,
      type Model,
      type Usage,
      type UsageReport,
    } from "@oh-my-pi/pi-ai";
    import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
    import {
      detailLines,
      formatCountdown,
      formatPercent,
      pickSummary,
      projectReports,
      renderBar,
      renderRow,
      usedPercent,
      type FooterState,
      type WindowView,
    } from "./vault-usage-footer.ts";

    const now = 1_700_000_000_000;
    const reports = [
      {
        provider: "openai",
        fetchedAt: now - 120_000,
        limits: [
          {
            id: "codex-5h",
            label: "5 hours",
            scope: { provider: "openai" },
            window: { id: "5h", label: "5 Hour", resetsAt: now + 30 * 60_000 },
            amount: { used: 100, limit: 100, unit: "percent" },
            status: "exhausted",
          },
        ],
      },
      {
        provider: "anthropic",
        fetchedAt: now - 60_000,
        limits: [
          {
            id: "anthropic-7d",
            label: "7 days",
            scope: { provider: "anthropic" },
            window: { id: "7d", label: "7 Day", resetsAt: now + 3 * 86_400_000 + 4 * 3_600_000 },
            amount: { usedFraction: 0.31, unit: "percent" },
            status: "ok",
          },
          {
            id: "anthropic-5h",
            label: "5 hours",
            scope: { provider: "anthropic", tier: "max" },
            window: { id: "5h", label: "5 Hour", resetsAt: now + 90 * 60_000 },
            amount: { usedFraction: 0.62, unit: "percent" },
            status: "ok",
          },
        ],
      },
    ] as unknown as UsageReport[];

    // Projection: providers sorted, raw/identity dropped, summary priority.
    const projected = projectReports(reports);
    assert.deepEqual(
      projected.providers.map(entry => entry.provider),
      ["anthropic", "openai"],
    );
    assert.equal(projected.fetchedAt, now - 60_000);
    assert.equal(projected.providers[0].summary.limitId, "anthropic-5h");
    assert.equal(projected.providers[1].summary.exhausted, true);

    const state: FooterState = {
      kind: "data",
      providers: projected.providers,
      fetchedAt: projected.fetchedAt,
    };
    const base = { now, staleAfterMs: 15 * 60_000 };
    const active = { provider: "anthropic", authenticated: true };

    // Wide: every provider, active first, bar + window + percent + reset.
    const wide = renderRow(state, { ...base, width: 140, active });
    assert.equal(wide.length, 1);
    assert.ok(wide[0].startsWith("*anthropic 5h "));
    assert.ok(wide[0].includes("██████░░░░ 62% ~1h30m"));
    assert.ok(wide[0].includes("openai 5h ██████████ 100%! ~30m"));
    assert.ok(wide[0].length <= 140);

    // Active-provider reordering follows the live selection.
    const wideOpenai = renderRow(state, {
      ...base,
      width: 140,
      active: { provider: "openai", authenticated: true },
    });
    assert.ok(wideOpenai[0].startsWith("*openai 5h "));

    // Medium: bars dropped first, quota state retained.
    const medium = renderRow(state, { ...base, width: 80, active });
    assert.equal(medium.length, 1);
    assert.ok(!medium[0].includes("█"));
    assert.ok(medium[0].includes("62%"));
    assert.ok(medium[0].includes("openai"));

    // Narrow: active provider only; hidden below the minimum width.
    const narrow = renderRow(state, { ...base, width: 50, active });
    assert.equal(narrow.length, 1);
    assert.ok(narrow[0].includes("*anthropic"));
    assert.ok(!narrow[0].includes("openai"));
    assert.ok(narrow[0].length <= 50);
    const hidden = renderRow(state, { ...base, width: 39, active });
    assert.deepEqual(hidden, []);

    // Constant one-row height for every network state at supported widths.
    assert.equal(renderRow({ kind: "loading" }, { ...base, width: 60 }).length, 1);
    assert.equal(renderRow({ kind: "unavailable" }, { ...base, width: 60 }).length, 1);

    // Stale: immediately on failed refresh (code parity) and by age.
    const failed = renderRow(state, { ...base, width: 140, active, refreshFailed: true });
    assert.ok(failed[0].includes("·stale 1m"));
    const aged = renderRow(state, {
      width: 140,
      now: now + 20 * 60_000,
      staleAfterMs: 15 * 60_000,
      active,
    });
    assert.ok(aged[0].includes("·stale 21m"));

    // Unauthenticated is distinct from authenticated-but-unreported.
    const unauth = renderRow(state, {
      ...base,
      width: 140,
      active: { provider: "google", authenticated: false },
    });
    assert.ok(unauth[0].includes("*google unauthenticated"));
    const unreported = renderRow(state, {
      ...base,
      width: 140,
      active: { provider: "google", authenticated: true },
    });
    assert.ok(unreported[0].includes("*google usage n/a"));

    // Summary priority: exhausted, then used fraction, then nearest reset,
    // then stable limit id. Windows are never aggregated.
    const win = (over: Partial<WindowView>): WindowView => ({
      limitId: "base",
      windowLabel: "5h",
      fullLabel: "5 hours",
      exhausted: false,
      ...over,
    });
    assert.equal(
      pickSummary([win({ limitId: "hot", usedFraction: 0.9 }), win({ limitId: "max", exhausted: true, usedFraction: 0.1 })]).limitId,
      "max",
    );
    assert.equal(
      pickSummary([win({ limitId: "later", usedFraction: 0.5, resetsAt: now + 2000 }), win({ limitId: "sooner", usedFraction: 0.5, resetsAt: now + 1000 })]).limitId,
      "sooner",
    );
    assert.equal(pickSummary([win({ limitId: "b" }), win({ limitId: "a" })]).limitId, "a");

    // Parity fixtures against code v0.1.0 (main.go fmtReset/barStr/percent).
    assert.equal(formatCountdown(0), "0m");
    assert.equal(formatCountdown(59_000), "0m");
    assert.equal(formatCountdown(3_599_000), "59m");
    assert.equal(formatCountdown(3_600_000), "1h0m");
    assert.equal(formatCountdown(5_400_000), "1h30m");
    assert.equal(formatCountdown(86_399_000), "23h59m");
    assert.equal(formatCountdown(90_000_000), "1d1h");
    assert.equal(formatCountdown(-5_000), "0m");
    assert.equal(formatPercent(0.62), "62%");
    assert.equal(formatPercent(1), "100%");
    assert.equal(formatPercent(0.005), "1%");
    assert.equal(formatPercent(1.04), "104%");
    assert.equal(formatPercent(undefined), "?%");
    assert.equal(usedPercent(0.615), 62);
    assert.equal(renderBar(0, 10), "░░░░░░░░░░");
    assert.equal(renderBar(0.04, 10), "░░░░░░░░░░");
    assert.equal(renderBar(0.05, 10), "█░░░░░░░░░");
    assert.equal(renderBar(0.62, 10), "██████░░░░");
    assert.equal(renderBar(0.95, 10), "██████████");
    assert.equal(renderBar(1.2, 10), "██████████");

    // Detail view lists every original window/scope without identity fields.
    const details = detailLines(state, now);
    assert.equal(details.length, 3);
    assert.ok(details.some(line => line.includes("max")));
    assert.ok(details.some(line => line.includes("100% used (exhausted)")));
    assert.ok(details.every(line => line.includes("resets")));

    const observationPath = process.env.ISSUE220_FOOTER_OBSERVATION;
    if (!observationPath) throw new Error("ISSUE220_FOOTER_OBSERVATION is required");
    writeFileSync(
      observationPath,
      JSON.stringify({
        ok: true,
        samples: { wide: wide[0], medium: medium[0], narrow: narrow[0], hidden },
      }),
    );

    const zeroUsage: Usage = {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    };

    function finish(stream: AssistantMessageEventStream, model: Model): void {
      const text = "footer-ok";
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

    export default function footerFixtureProvider(pi: ExtensionAPI): void {
      pi.registerProvider("issue220-footer-fixture", {
        baseUrl: "fixture://footer",
        apiKey: "fixture-api-key",
        api: "issue220-footer-fixture",
        models: [
          {
            id: "scripted",
            name: "Issue 220 footer fixture",
            reasoning: false,
            input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: 32768,
            maxTokens: 1024,
          },
        ],
        streamSimple(model) {
          const stream = new AssistantMessageEventStream();
          queueMicrotask(() => finish(stream, model));
          return stream;
        },
      });
    }
  '';
in
pkgs.runCommand "check-omp-vault-usage-footer"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    export HOME="$TMPDIR/home"
    project="$TMPDIR/project"
    ext="$TMPDIR/ext"
    mkdir -p "$HOME" "$project" "$ext"
    cp ${footerExtension} "$ext/vault-usage-footer.ts"
    cp ${testExtension} "$ext/footer-test.ts"

    export ISSUE220_FOOTER_OBSERVATION="$TMPDIR/footer-observation.json"

    # Print mode has no widget surface: the managed platform copy of the
    # footer extension must load and stay inert, while the test extension's
    # load-time assertions exercise the exported view-model and rendering
    # logic deterministically (no network, no broker).
    ${pkgs.omp-configured}/bin/omp-managed \
      --extension "$ext/footer-test.ts" \
      --config ${runtimeConfig} \
      --model issue220-footer-fixture/scripted \
      --cwd "$project" \
      --thinking off \
      --no-session \
      --no-tools \
      --no-lsp \
      --no-title \
      --print \
      "Run the footer fixture." \
      > "$TMPDIR/omp.out"

    grep -Fq "footer-ok" "$TMPDIR/omp.out"

    jq -e '
      .ok == true
      and (.samples.wide | startswith("*anthropic 5h "))
      and (.samples.narrow | contains("openai") | not)
      and (.samples.hidden | length == 0)
    ' "$ISSUE220_FOOTER_OBSERVATION" >/dev/null

    mkdir "$out"
  ''
