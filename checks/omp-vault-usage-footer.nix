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
  # assertion passed, so a silent load failure cannot fake a green check. A
  # session_start probe additionally pins the identity API's real shape so a
  # signature drift in the pinned OMP surfaces here, not as silently missing
  # emails.
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
    import { visibleWidth } from "@oh-my-pi/pi-tui";
    import {
      barFillColor,
      detailLines,
      displayProvider,
      formatCachedAge,
      formatCountdown,
      formatPercent,
      labelGroups,
      buildRedactionMap,
      paint,
      pickSummary,
      projectReports,
      renderBar,
      renderBarAnsi,
      renderRow,
      renderRule,
      resetEmphasis,
      shortWindowLabel,
      usedPercent,
      PALETTE,
      RESET_GLYPH,
      type FooterState,
      type WindowView,
    } from "./vault-usage-footer.ts";

    const now = 1_700_000_000_000;
    const HOUR = 3_600_000;
    const DAY = 86_400_000;
    const reports = [
      {
        provider: "openai-codex",
        fetchedAt: now - 120_000,
        limits: [
          {
            id: "codex-5h",
            label: "5 hours",
            scope: { provider: "openai-codex" },
            window: { id: "5h", label: "5 Hour", resetsAt: now + 30 * 60_000, durationMs: 5 * HOUR },
            amount: { used: 100, limit: 100, unit: "percent" },
            status: "exhausted",
          },
          {
            id: "codex-7d",
            label: "7 days",
            scope: { provider: "openai-codex" },
            window: { id: "7d", label: "7 Day", resetsAt: now + 5 * DAY + 14 * HOUR, durationMs: 7 * DAY },
            amount: { usedFraction: 0.45, unit: "percent" },
            status: "ok",
          },
          {
            id: "codex-7d-spark",
            label: "7 days (Spark)",
            scope: { provider: "openai-codex", tier: "spark" },
            window: { id: "7d", label: "7 Day", resetsAt: now + 5 * DAY + 14 * HOUR, durationMs: 7 * DAY },
            amount: { usedFraction: 0.03, unit: "percent" },
            status: "ok",
          },
        ],
      },
      {
        provider: "anthropic",
        fetchedAt: now - 60_000,
        limits: [
          {
            id: "anthropic-7d",
            label: "Claude 7 Day",
            scope: { provider: "anthropic" },
            window: { id: "7d", label: "7 Day", resetsAt: now + 3 * DAY + 4 * HOUR, durationMs: 7 * DAY },
            amount: { usedFraction: 0.31, unit: "percent" },
            status: "ok",
          },
          {
            id: "anthropic-7d-fable",
            label: "Claude 7 Day (Fable)",
            scope: { provider: "anthropic", shared: true },
            window: { id: "7d", label: "7 Day", resetsAt: now + 3 * DAY + 4 * HOUR, durationMs: 7 * DAY },
            amount: { usedFraction: 0.58, unit: "percent" },
            status: "ok",
          },
          {
            id: "anthropic-5h",
            label: "Claude 5 Hour",
            scope: { provider: "anthropic", tier: "max" },
            window: { id: "5h", label: "5 Hour", resetsAt: now + 90 * 60_000, durationMs: 5 * HOUR },
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
      ["anthropic", "openai-codex"],
    );
    assert.equal(projected.fetchedAt, now - 60_000);
    assert.equal(projected.providers[0].summary.limitId, "anthropic-5h");
    assert.equal(projected.providers[1].summary.exhausted, true);

    // Multi-account provider windows use the same rounded mean as code's Usage
    // panel, rather than showing the busiest account as the provider total.
    const aggregateReports = [
      {
        provider: "openai-codex",
        fetchedAt: now - 30_000,
        limits: [{
          id: "first-5h",
          label: "5 hours",
          scope: { provider: "openai-codex" },
          window: { id: "5h", label: "5 Hour", resetsAt: now + HOUR, durationMs: 5 * HOUR },
          amount: { usedFraction: 0.214, unit: "percent" },
          status: "ok",
        }],
      },
      {
        provider: "openai-codex",
        fetchedAt: now - 10_000,
        limits: [{
          id: "second-5h",
          label: "5 hours",
          scope: { provider: "openai-codex" },
          window: { id: "5h", label: "5 Hour", resetsAt: now + 3 * HOUR, durationMs: 5 * HOUR },
          amount: { usedFraction: 0.825, unit: "percent" },
          status: "ok",
        }],
      },
    ] as unknown as UsageReport[];
    const aggregate = projectReports(aggregateReports);
    assert.equal(aggregate.providers.length, 1);
    assert.equal(aggregate.providers[0].windows.length, 1);
    assert.equal(aggregate.providers[0].windows[0].usedFraction, 0.52);
    assert.equal(aggregate.providers[0].windows[0].resetsAt, now + 2 * HOUR);
    assert.equal(aggregate.providers[0].windows[0].exhausted, false);
    assert.equal(aggregate.fetchedAt, now - 10_000);

    // Label groups: every distinct short label, one winner each (the busier
    // Fable window represents "7d fable", not the whole 7d duration).
    const anthropicGroups = labelGroups(projected.providers[0].windows);
    assert.deepEqual(anthropicGroups.map(w => w.limitId), ["anthropic-5h", "anthropic-7d", "anthropic-7d-fable"]);
    const codexGroups = labelGroups(projected.providers[1].windows);
    assert.deepEqual(codexGroups.map(w => w.limitId), ["codex-5h", "codex-7d", "codex-7d-spark"]);

    const state: FooterState = {
      kind: "data",
      providers: projected.providers,
      fetchedAt: projected.fetchedAt,
      identities: { anthropic: "al*" },
    };
    // Tight-width regression: a quiet short-term quota is still a core
    // window. Variant buckets may shed first, but 5h and 7d must both remain.
    const quietFiveHourProviders = projected.providers.map(view => {
      const windows = view.windows.map(window =>
        window.limitId === "anthropic-5h" ? { ...window, usedFraction: 0.02 } : window,
      );
      return { ...view, windows, summary: pickSummary(windows) };
    });
    const quietFiveHourState: FooterState = {
      kind: "data",
      providers: quietFiveHourProviders,
      fetchedAt: projected.fetchedAt,
    };
    const base = { now, staleAfterMs: 15 * 60_000, color: false };
    const active = { provider: "anthropic", authenticated: true };

    // Provider display naming parity with code (providerHeading).
    assert.equal(displayProvider("anthropic"), "claude");
    assert.equal(displayProvider("openai-codex"), "codex");
    assert.equal(displayProvider("google"), "google");

    // Window shortname parity with code (shortWin).
    assert.equal(shortWindowLabel("Claude 5 Hour", "5h"), "5h");
    assert.equal(shortWindowLabel("7 days", "7d"), "7d");
    assert.equal(shortWindowLabel("7 days (Spark)", "7d"), "7d spark");
    assert.equal(shortWindowLabel("Claude 7 Day (Fable)", "7d"), "7d fable");
    assert.equal(shortWindowLabel("monthly quota", "30d"), "30d");

    // Layout probes: with elastic fill a wide row's length always equals
    // the render width minus the 4-column right inset, so ladder
    // boundaries are found by content.
    const bare = (w: number) => renderRow(state, { ...base, width: w, active })[0];
    const minWidth = (has: (row: string) => boolean, render: (w: number) => string): number => {
      for (let w = 120; w <= 320; w += 1) if (has(render(w))) return w;
      throw new Error("ladder boundary not found");
    };
    const cells = (row: string) => (row.match(/[█░]/g) ?? []).length;

    // Full row: identity plus every labeled window, provider delimiter.
    // Identities render only when nothing is sacrificed for them. The row
    // is inset 4 columns on both edges (mirroring the border's corner-to-π
    // indent) and its bars stretch so the inset width is filled exactly.
    const bareIdMin = minWidth(row => row.includes("al*"), bare);
    const fullWidth = bareIdMin + 20;
    const full = renderRow(state, { ...base, width: fullWidth, active });
    assert.equal(full.length, 1);
    assert.ok(full[0].startsWith("    *claude al* 5h "));
    assert.equal(visibleWidth(full[0]), fullWidth - 4);
    assert.ok(full[0].includes("62% " + RESET_GLYPH + "1h30m"));
    assert.ok(full[0].includes("31% " + RESET_GLYPH + "3d4h"));
    assert.ok(full[0].includes("7d fable"));
    assert.ok(full[0].includes(" │ codex 5h "));
    assert.ok(full[0].includes("100% " + RESET_GLYPH + "30m maxed"));
    assert.ok(full[0].includes("45%"));
    assert.ok(full[0].includes("7d spark"));

    // Elasticity: 20 more columns land entirely in the bars; the fill is
    // recomputed per paint, which is what makes resizes adapt.
    const wider = renderRow(state, { ...base, width: fullWidth + 20, active });
    assert.equal(visibleWidth(wider[0]), fullWidth + 20 - 4);
    assert.equal(cells(wider[0]) - cells(full[0]), 20);

    // One short of the identity boundary: window data always outranks
    // identity decoration.
    const noEmail = bare(bareIdMin - 1);
    assert.ok(!noEmail.includes("al*"));
    assert.ok(noEmail.includes("31%"));

    // At width 100 neither one nor two wide rows hold every labeled window
    // (the codex chunk alone overflows the inset budget), so bars yield
    // before any quota window. Named variants shed before core buckets.
    const wide = bare(100);
    assert.ok(!wide.includes("█"), "tight wide row must drop bars before windows");
    assert.ok(wide.startsWith("    *claude 5h "), "active Claude chunk must lead");
    assert.ok(!wide.includes("al*"), "identity must shed before windows");
    assert.ok(wide.includes("7d 31%"), "Claude core 7d window must remain");
    assert.ok(!wide.includes("7d fable"), "Claude variant must shed before core windows");
    assert.ok(wide.includes("codex 5h "), "Codex core 5h window must remain");
    assert.ok(wide.includes("100%!"), "exhausted Codex core window must remain");
    assert.ok(wide.includes("45%"), "Codex core 7d window must remain");
    assert.ok(!wide.includes("7d spark"), "Codex variant must shed before core windows");
    assert.ok(visibleWidth(wide) <= 96, "tight row must stay inside its inset budget");

    // Active-provider reordering follows the live selection.
    const wideCodex = renderRow(state, {
      ...base,
      width: 135,
      active: { provider: "openai-codex", authenticated: true },
    });
    assert.ok(wideCodex[0].startsWith("    *codex 5h "));

    // Two-line wide tier: when one row cannot hold every labeled window
    // with bars, the layout splits at a provider boundary across two rows
    // (bars intact, no │ delimiter). All bars stretch to one shared
    // uniform width — the largest both rows fit — and the rows
    // column-align into a table: heads and every window column's slots
    // pad to their widest counterpart, so bar runs start at the same
    // columns on both rows.
    const barRuns = (row: string) => [...row.matchAll(/[█░]+/g)].map(match => match.index);
    const twoLine = renderRow(state, { ...base, width: 110, active });
    assert.equal(twoLine.length, 2);
    assert.ok(twoLine[0].startsWith("    *claude 5h "));
    assert.ok(twoLine[0].includes("█"));
    assert.ok(twoLine[0].includes("7d fable"));
    assert.ok(!twoLine[0].includes("│"));
    assert.ok(twoLine[1].startsWith("    codex   5h "), "head pads to align with *claude");
    assert.ok(twoLine[1].includes("█"));
    assert.ok(twoLine[1].includes("7d spark"));
    assert.ok(twoLine[1].includes("maxed"));
    const runWidths = [...twoLine[0].matchAll(/[█░]+/g), ...twoLine[1].matchAll(/[█░]+/g)]
      .map(match => match[0].length);
    assert.equal(runWidths.length, 6, "three bars per row");
    assert.equal(new Set(runWidths).size, 1, "all bars share one width");
    assert.ok(runWidths[0] >= 10, "shared width never shrinks below base");
    assert.equal(cells(twoLine[0]), cells(twoLine[1]), "equal bar cells per row");
    assert.deepEqual(barRuns(twoLine[0]), barRuns(twoLine[1]), "bar columns align");
    assert.ok(visibleWidth(twoLine[0]) <= 110 - 4);
    assert.ok(visibleWidth(twoLine[1]) <= 110 - 4);

    // A suffix rides the bottom row of a two-line layout.
    const twoLineStale = renderRow(state, { ...base, width: 130, active, refreshFailed: true });
    assert.equal(twoLineStale.length, 2);
    assert.ok(!twoLineStale[0].includes("cached"));
    assert.ok(twoLineStale[1].includes("· cached 1m ago"));

    // Single-provider overflow splits between window cells instead: the
    // continuation row repeats the provider head so ownership stays
    // legible, and bars survive widths that previously fell to text.
    const claudeOnly: FooterState = {
      kind: "data",
      providers: [projected.providers[0]],
      fetchedAt: projected.fetchedAt,
    };
    const splitWithin = renderRow(claudeOnly, { ...base, width: 72, active });
    assert.equal(splitWithin.length, 2);
    assert.ok(splitWithin[0].startsWith("    *claude 5h "));
    assert.ok(splitWithin[0].includes("█"));
    assert.ok(splitWithin[1].startsWith("    *claude 7d fable "));
    assert.ok(splitWithin[1].includes("█"));
    assert.equal(cells(splitWithin[0]), 20, "top row is budget-packed, so bars stay at base");
    assert.equal(cells(splitWithin[1]), 10, "bottom shares the top row's bar width");
    assert.equal(barRuns(splitWithin[0])[0], barRuns(splitWithin[1])[0], "first bars align");
    assert.ok(visibleWidth(splitWithin[0]) <= 72 - 4);
    assert.ok(visibleWidth(splitWithin[1]) <= 72 - 4);

    // At the first wide breakpoint, bars must yield before core windows.
    // This reproduces the live failure where Claude 5h disappeared behind
    // the busier 7d Fable bucket even though the broker reported both.
    const tightCoreWindows = renderRow(quietFiveHourState, { ...base, width: 100, active })[0];
    assert.ok(!tightCoreWindows.includes("█"), "quiet-5h fixture must drop bars first");
    assert.ok(
      tightCoreWindows.includes("5h 2% " + RESET_GLYPH + "1h30m"),
      "quiet Claude 5h window must remain",
    );
    assert.ok(
      tightCoreWindows.includes("7d 31% " + RESET_GLYPH + "3d4h"),
      "Claude core 7d window must remain",
    );
    assert.ok(tightCoreWindows.includes("codex 5h 100%!"), "Codex core 5h window must remain");
    assert.ok(tightCoreWindows.includes("7d 45%"), "Codex core 7d window must remain");
    assert.ok(!tightCoreWindows.includes("7d fable"), "Claude variant must shed first");
    assert.ok(!tightCoreWindows.includes("7d spark"), "Codex variant must shed first");
    // Medium: bars and variants drop before the four core windows.
    const medium = renderRow(state, { ...base, width: 84, active });
    assert.equal(medium.length, 1);
    assert.ok(!medium[0].includes("█"));
    assert.ok(medium[0].includes("5h 62%"));
    assert.ok(medium[0].includes("7d 31%"));
    assert.ok(!medium[0].includes("7d fable"));
    assert.ok(medium[0].includes("100%!"));
    assert.ok(medium[0].includes("45%"));
    assert.ok(medium[0].includes(" │ codex"));
    assert.ok(!medium[0].includes("7d spark"));

    // Narrow: active provider's summary window only; hidden below minimum.
    const narrow = renderRow(state, { ...base, width: 54, active });
    assert.equal(narrow.length, 1);
    assert.ok(narrow[0].includes("*claude"));
    assert.ok(!narrow[0].includes("codex"));
    assert.ok(visibleWidth(narrow[0]) <= 50);
    const hidden = renderRow(state, { ...base, width: 39, active });
    assert.deepEqual(hidden, []);

    // Live next-fetch countdown suffix: healthy rows only, minute-granular;
    // staleness replaces it, and it competes in the same width budget.
    const withTimer = renderRow(state, {
      ...base,
      width: bareIdMin + 30,
      active,
      nextRefreshAt: now + 3 * 60_000,
    });
    assert.ok(withTimer[0].includes("· refresh in 3m"));
    assert.ok(withTimer[0].includes("al*"));
    const staleOverTimer = renderRow(state, {
      ...base,
      width: 150,
      active,
      refreshFailed: true,
      nextRefreshAt: now + 3 * 60_000,
    });
    assert.equal(staleOverTimer.length, 2);
    assert.ok(staleOverTimer[1].includes("· cached 1m ago"));
    assert.ok(!staleOverTimer.join("\n").includes("refresh in"));

    // Manual-refresh cue ladder — monotonic as width shrinks so nothing
    // blinks back in during a resize: identities+cue → cue → plain. No
    // decoration ever sheds a window.
    const timerOpts = { ...base, active, nextRefreshAt: now + 3 * 60_000 };
    const armed = (w: number) => renderRow(state, { ...timerOpts, width: w, refreshHint: "alt+u" })[0];
    const unarmed = (w: number) => renderRow(state, { ...timerOpts, width: w })[0];
    const cueFull = armed(500);
    assert.ok(cueFull.includes("al*"));
    assert.ok(cueFull.includes("· refresh in 3m (alt+u)"));
    assert.equal(visibleWidth(cueFull), 500 - 4);
    // With the hotkey armed the identity tier always carries the cue: below
    // the armed-identity boundary the ladder drops straight to the cue tier
    // rather than showing identity without its cue (monotonicity).
    const armedIdMin = minWidth(row => row.includes("al*"), armed);
    assert.ok(armed(armedIdMin).includes("(alt+u)"));
    const cueOnly = armed(armedIdMin - 1);
    assert.ok(!cueOnly.includes("al*"));
    assert.ok(cueOnly.includes("(alt+u)"));
    assert.ok(cueOnly.includes("7d spark"));
    // The cue costs columns, so unarmed identity appears earlier (and never
    // shows a cue it does not have).
    const unarmedIdMin = minWidth(row => row.includes("al*"), unarmed);
    assert.ok(unarmedIdMin < armedIdMin);
    assert.ok(!unarmed(armedIdMin).includes("alt+u"));
    // Plain tier: below the cue boundary the hint is dropped rather than
    // shedding a window.
    const cueMin = minWidth(row => row.includes("(alt+u)"), armed);
    const plainFull = armed(cueMin - 1);
    assert.ok(!plainFull.includes("(alt+u)"));
    assert.ok(plainFull.includes("7d spark"));
    // The cue also decorates the stale suffix (refresh matters most then).
    const staleCue = renderRow(state, {
      ...base,
      width: 500,
      active,
      refreshFailed: true,
      refreshHint: "alt+u",
    });
    assert.ok(staleCue[0].includes("· cached 1m ago (alt+u)"));
    // Narrow layouts never show the cue.
    const narrowCue = renderRow(state, { ...timerOpts, width: 50, refreshHint: "alt+u" });
    assert.ok(!narrowCue[0].includes("alt+u"));

    // Constant one-row height for every network state at supported widths;
    // status rows carry the same 4-column left inset as data rows.
    const loading = renderRow({ kind: "loading" }, { ...base, width: 60 });
    assert.equal(loading.length, 1);
    assert.ok(loading[0].startsWith("    usage: loading"));
    assert.equal(renderRow({ kind: "unavailable" }, { ...base, width: 60 }).length, 1);

    // Stale: immediately on failed refresh, with code's cached-age wording.
    const failed = renderRow(state, { ...base, width: 150, active, refreshFailed: true });
    assert.ok(failed[1].includes("· cached 1m ago"));
    const aged = renderRow(state, {
      width: 150,
      now: now + 20 * 60_000,
      staleAfterMs: 15 * 60_000,
      active,
      color: false,
    });
    assert.ok(aged[1].includes("· cached 21m ago"));

    // Unauthenticated is distinct from authenticated-but-unreported.
    const unauth = renderRow(state, {
      ...base,
      width: 150,
      active: { provider: "google", authenticated: false },
    });
    assert.ok(unauth[0].includes("*google unauthenticated"));
    const unreported = renderRow(state, {
      ...base,
      width: 150,
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
    assert.equal(renderBar(0.62, 14), "█████████░░░░░");
    assert.equal(renderBar(1, 13), "█████████████");

    // Width math counts terminal cells through the TUI's own visibleWidth:
    // the reset glyph is two UTF-16 units (↻ plus U+FE0E) but one column.
    assert.equal(RESET_GLYPH.length, 2);
    assert.equal(visibleWidth(RESET_GLYPH), 1);
    assert.equal(visibleWidth(RESET_GLYPH + "1h30m"), 6);

    // Cached-age fixtures against code v0.1.0 (formatCachedAge, main.go).
    assert.equal(formatCachedAge(0), "<1m ago");
    assert.equal(formatCachedAge(59_000), "<1m ago");
    assert.equal(formatCachedAge(60_000), "1m ago");
    assert.equal(formatCachedAge(3_599_000), "59m ago");
    assert.equal(formatCachedAge(2 * HOUR), "2h ago");
    assert.equal(formatCachedAge(3 * DAY), "3d ago");
    assert.equal(formatCachedAge(14 * DAY), "2w ago");
    assert.equal(formatCachedAge(400 * DAY), "1y ago");

    // Gradient parity with code v0.1.0 (barStr): green→red, blue fixed 0x46.
    assert.equal(barFillColor(0), "#5ac846");
    assert.equal(barFillColor(30), "#b4c846");
    assert.equal(barFillColor(50), "#ebc846");
    assert.equal(barFillColor(62), "#eba446");
    assert.equal(barFillColor(100), "#eb3c46");

    // SGR layer: exact truecolor sequences, identity when color is off.
    assert.equal(paint("x", "#ff9f52", true), "\u001b[38;2;255;159;82mx\u001b[0m");
    assert.equal(paint("x", "#ff9f52", true, true), "\u001b[1;38;2;255;159;82mx\u001b[0m");
    assert.equal(paint("x", "#ff9f52", false), "x");
    assert.equal(
      renderBarAnsi(0.62, 10, true),
      paint("██████", "#eba446", true) + paint("░░░░", PALETTE.dim, true),
    );
    // Width 250 keeps a single identity-tier row so the │ delimiter shows.
    const colored = renderRow(state, { ...base, width: 250, active, color: true });
    assert.ok(colored[0].includes("\u001b[1;38;2;255;159;82m*claude\u001b[0m"));
    assert.ok(colored[0].includes("38;2;98;167;255m"));
    assert.ok(colored[0].includes("38;2;105;114;126m│"));

    // Separator rule: spans the inset budget, dim-painted, resize-adaptive.
    assert.equal(renderRule(120, false), "    " + "─".repeat(112));
    assert.equal(renderRule(64, false), "    " + "─".repeat(56));
    assert.equal(visibleWidth(renderRule(120, false)), 116);
    assert.equal(renderRule(120, true), "    " + paint("─".repeat(112), PALETTE.dim, true));
    assert.equal(visibleWidth(renderRule(120, true)), 116);

    // Reset-urgency tiers (usageRow reset emphasis).
    assert.equal(resetEmphasis(1_000_000, 5 * HOUR), "imminent");
    assert.equal(resetEmphasis(1 * HOUR, 5 * HOUR), "soon");
    assert.equal(resetEmphasis(4 * HOUR, 5 * HOUR), "dim");
    assert.equal(resetEmphasis(1_000_000, undefined), "dim");

    // Identity masking parity with OMP usage --redact, including collisions.
    const uniqueMasks = buildRedactionMap(["alpha@example.test", "bravo@example.test"]);
    assert.equal(uniqueMasks.get("alpha@example.test"), "al*");
    assert.equal(uniqueMasks.get("bravo@example.test"), "br*");
    const collidingValues = ["dum.my@example.org", "dum.my9@example.net", "dummy@example.net"];
    const collidingMasks = collidingValues.map(value => buildRedactionMap(collidingValues).get(value)!);
    assert.equal(new Set(collidingMasks).size, collidingMasks.length);
    assert.ok(collidingMasks.every(mask => /^du\*(.{1,2}\*)?$/.test(mask)));
    assert.equal(buildRedactionMap(collidingValues).get("dum.my9@example.net"), "du*9*");
    assert.equal(buildRedactionMap(["user@example.test", "user@example.test"]).get("user@example.test"), "us*");

    // Detail view lists every original window/scope with masked identity.
    const details = detailLines(state, now);
    assert.equal(details.length, 6);
    assert.ok(details.some(line => line.startsWith("claude al* · Claude 5 Hour")));
    assert.ok(details.some(line => line.includes("max")));
    assert.ok(details.some(line => line.includes("100% used (exhausted)")));
    assert.ok(details.some(line => line.includes("spark")));
    assert.ok(details.every(line => line.includes("resets")));

    const observationPath = process.env.ISSUE220_FOOTER_OBSERVATION;
    if (!observationPath) throw new Error("ISSUE220_FOOTER_OBSERVATION is required");
    writeFileSync(
      observationPath,
      JSON.stringify({
        ok: true,
        samples: { full: full[0], wide, medium: medium[0], narrow: narrow[0], hidden },
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
      // Pin the identity API's live shape against the pinned OMP build: the
      // footer reads it defensively, so drift must fail here instead of
      // silently dropping every email.
      pi.on("session_start", (_event, ctx) => {
        const probePath = process.env.ISSUE220_FOOTER_IDENTITY_PROBE;
        if (!probePath) return;
        let unknownProviderOk = false;
        let unknownProviderSync = false;
        try {
          const result = ctx.modelRegistry.authStorage.getOAuthAccountIdentity(
            "issue220-no-such-provider",
            ctx.sessionManager.getSessionId(),
          );
          unknownProviderOk = result === undefined || result === null || typeof result === "object";
          unknownProviderSync = !(result instanceof Promise);
        } catch {
          unknownProviderOk = false;
        }
        writeFileSync(
          probePath,
          JSON.stringify({
            fnType: typeof ctx.modelRegistry.authStorage.getOAuthAccountIdentity,
            unknownProviderOk,
            unknownProviderSync,
          }),
        );
      });

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
    export ISSUE220_FOOTER_IDENTITY_PROBE="$TMPDIR/identity-probe.json"

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

    # Placement contract: print mode has no widget surface, so pin the
    # runtime wiring textually against the deployed extension copy - the
    # widget hangs below the editor with a dim rule line above the row.
    grep -Fq 'placement: "belowEditor"' "$ext/vault-usage-footer.ts"
    grep -Fq 'cachedRows = [renderRule(width), ...rows]' "$ext/vault-usage-footer.ts"

    jq -e '
      .ok == true
      and (.samples.full | startswith("    *claude al* 5h "))
      and (.samples.wide | startswith("    *claude 5h "))
      and (.samples.narrow | contains("codex") | not)
      and (.samples.hidden | length == 0)
    ' "$ISSUE220_FOOTER_OBSERVATION" >/dev/null

    jq -e '
      .fnType == "function"
      and .unknownProviderOk == true
      and .unknownProviderSync == true
    ' "$ISSUE220_FOOTER_IDENTITY_PROBE" >/dev/null

    mkdir "$out"
  ''
