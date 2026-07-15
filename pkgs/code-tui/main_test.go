package main

import (
	"fmt"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	clikit "cli-kit"
	"github.com/charmbracelet/bubbles/help"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ansiRe strips SGR sequences so tests assert on visible text regardless of the
// active color profile.
var ansiRe = regexp.MustCompile("\x1b\\[[0-9;]*m")

func stripAnsi(s string) string { return ansiRe.ReplaceAllString(s, "") }

// A realistic full-name routing row: renderRoute shortens the names for display.
const sampleRow = "  default    gpt-5.6-terra:medium → gpt-5.6-luna:medium → claude-sonnet-5:medium → claude-haiku-4-5:medium"

// labelWidth mirrors how renderRoute derives the role label (everything before
// the first model match) so tests assert against the real alignment column.
func labelWidth(row string) int {
	loc := modelRe.FindStringIndex(row)
	if loc == nil {
		return 0
	}
	return lipgloss.Width(row[:loc[0]])
}

// routeLines splits renderRoute output into physical lines, dropping the trailing
// newline the function appends.
func routeLines(out string) []string {
	return strings.Split(strings.TrimRight(out, "\n"), "\n")
}

// TestRenderRouteHangingIndent locks the bug fixed in #118: when a chain wraps,
// every continuation line must be indented to align under the first model (a
// hanging block), never flush-left.
func TestRenderRouteHangingIndent(t *testing.T) {
	lw := labelWidth(sampleRow)
	indent := strings.Repeat(" ", lw)
	// The sample chain is ~70 cols on one line; these widths force it to wrap.
	for _, width := range []int{40, 52, 64} {
		out := renderRoute([]string{sampleRow}, 1, availability{}, width)
		lines := routeLines(out)
		if len(lines) < 2 {
			t.Fatalf("width=%d: expected the chain to wrap onto multiple lines, got %d", width, len(lines))
		}
		for i, ln := range lines[1:] {
			// Continuation lines start with exactly the label-width of spaces,
			// then a (non-space) model — i.e. aligned under the first model.
			if !strings.HasPrefix(ln, indent) {
				t.Errorf("width=%d line %d not aligned under first model: %q", width, i+1, ln)
			}
			if lw < len(ln) && ln[lw] == ' ' {
				t.Errorf("width=%d line %d over-indented past the model column: %q", width, i+1, ln)
			}
		}
	}
}

// TestRenderRouteWidthInvariant: no rendered line exceeds the target width — the
// 2-col reserve for the trailing arrow must keep even break lines in bounds.
func TestRenderRouteWidthInvariant(t *testing.T) {
	for _, width := range []int{40, 56, 72, 100} {
		out := renderRoute([]string{sampleRow}, 1, availability{}, width)
		for i, ln := range routeLines(out) {
			if w := lipgloss.Width(ln); w > width {
				t.Errorf("width=%d: line %d overflows (%d cols): %q", width, i, w, ln)
			}
		}
	}
}

// TestRenderRouteLeadDepth: at depth 0 only the primary (first live) model shows.
func TestRenderRouteLeadDepth(t *testing.T) {
	out := renderRoute([]string{sampleRow}, 0, availability{}, 120)
	if lines := routeLines(out); len(lines) != 1 {
		t.Fatalf("lead depth should be a single line, got %d:\n%s", len(lines), out)
	}
	if !strings.Contains(out, "terra:medium") {
		t.Errorf("lead should show the primary model terra:medium: %q", out)
	}
	if strings.Contains(out, "luna:medium") {
		t.Errorf("lead depth must not show fallback models: %q", out)
	}
}

// TestRenderRoutePassThrough: a line with no models is emitted unchanged (modulo
// colourisation), not dropped.
func TestRenderRoutePassThrough(t *testing.T) {
	out := renderRoute([]string{"  advisor    (disabled)"}, 1, availability{}, 80)
	if !strings.Contains(out, "advisor") || !strings.Contains(out, "(disabled)") {
		t.Errorf("note line should pass through, got: %q", out)
	}
}

func TestShortModel(t *testing.T) {
	cases := map[string]string{
		"gpt-5.6-terra":       "terra",
		"gpt-5.6-luna":        "luna",
		"gpt-5.6-sol":         "sol",
		"gpt-5.3-codex-spark": "spark",
		"claude-opus-4-8":     "opus",
		"claude-sonnet-5":     "sonnet",
		"claude-haiku-4-5":    "haiku",
		"claude-fable-5":      "fable",
		"gpt-5.4":             "gpt-5.4", // special-cased whole name
	}
	for in, want := range cases {
		if got := shortModel(in); got != want {
			t.Errorf("shortModel(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLvl(t *testing.T) {
	cases := map[string]int{
		"minimal": 0, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5,
		"": 5, "bogus": 5,
	}
	for in, want := range cases {
		if got := lvl(in); got != want {
			t.Errorf("lvl(%q) = %d, want %d", in, got, want)
		}
	}
}

// TestComboID covers the lane-driven suppression: gpt-only forces fable off,
// claude-only forces spark off, regardless of the toggles — plus the fable-main
// segment: famain only when fable is on too, and lane suppression wins over both.
func TestComboID(t *testing.T) {
	cases := []struct {
		sel  map[string]string
		want string
	}{
		{map[string]string{"lane": "mixed", "model": "normal", "thinking": "medium", "spark": "on", "fable": "off"}, "mixed_normal_medium_sp_nofa"},
		{map[string]string{"lane": "mixed", "model": "normal", "thinking": "medium", "spark": "off", "fable": "on"}, "mixed_normal_medium_nosp_fa"},
		{map[string]string{"lane": "gpt-only", "model": "fast", "thinking": "high", "spark": "on", "fable": "on"}, "gpt-only_fast_high_sp_nofa"},
		{map[string]string{"lane": "claude-only", "model": "smart", "thinking": "low", "spark": "on", "fable": "on"}, "claude-only_smart_low_nosp_fa"},
		{map[string]string{"lane": "mixed", "model": "smart", "thinking": "high", "spark": "off", "fable": "on", "main": "on"}, "mixed_smart_high_nosp_famain"},
		{map[string]string{"lane": "mixed", "model": "smart", "thinking": "high", "spark": "off", "fable": "off", "main": "on"}, "mixed_smart_high_nosp_nofa"},
		{map[string]string{"lane": "gpt-only", "model": "smart", "thinking": "high", "spark": "on", "fable": "on", "main": "on"}, "gpt-only_smart_high_sp_nofa"},
	}
	for _, c := range cases {
		if got := comboID(c.sel); got != c.want {
			t.Errorf("comboID(%v) = %q, want %q", c.sel, got, c.want)
		}
	}
}

// TestDefaultSelValid guards the reset-to-defaults key (#119) against facet
// drift: every default must name a real facet and a value that facet offers,
// every facet must be seeded exactly once, and the model default is smart (#178).
func TestDefaultSelValid(t *testing.T) {
	facets := facetDefs(map[string]string{})
	byKey := map[string][]string{}
	for _, f := range facets {
		byKey[f.key] = f.values
	}
	def := defaultSel()
	if len(def) != len(facets) {
		t.Errorf("defaultSel has %d keys, facetDefs has %d — every facet must be seeded", len(def), len(facets))
	}
	for k, v := range def {
		values, ok := byKey[k]
		if !ok {
			t.Errorf("defaultSel key %q is not a known facet", k)
			continue
		}
		found := false
		for _, allowed := range values {
			if allowed == v {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("defaultSel[%q]=%q is not a valid value (allowed: %v)", k, v, values)
		}
	}
	if def["model"] != "smart" {
		t.Errorf(`defaultSel["model"] = %q, want "smart"`, def["model"])
	}
}

// TestMainFacetVisibility locks the sub-setting behavior: the main (fable-as-main)
// dial only exists while fable is on and the lane can host Fable at all.
func TestMainFacetVisibility(t *testing.T) {
	has := func(sel map[string]string) bool {
		m := model{facets: facetDefs(map[string]string{}), sel: sel}
		for _, f := range m.visibleFacets() {
			if f.key == "main" {
				return true
			}
		}
		return false
	}
	if !has(map[string]string{"lane": "mixed", "fable": "on"}) {
		t.Errorf("main must be visible when fable is on")
	}
	if has(map[string]string{"lane": "mixed", "fable": "off"}) {
		t.Errorf("main must be hidden while fable is off")
	}
	if has(map[string]string{"lane": "gpt-only", "fable": "on"}) {
		t.Errorf("main must be hidden on a gpt-only lane")
	}
}

// TestCycleFacetClearsMain: manually toggling fable off must clear fable-as-main
// too, so a later fable re-enable never silently resurrects the escalation.
func TestCycleFacetClearsMain(t *testing.T) {
	m := &model{facets: facetDefs(map[string]string{}), sel: defaultSel()}
	m.sel["fable"] = "on"
	m.sel["main"] = "on"
	for i, f := range m.visibleFacets() {
		if f.key == "fable" {
			m.fcur = i
		}
	}
	m.cycleFacet(1) // fable on → off
	if m.sel["fable"] != "off" {
		t.Fatalf("cycle should have turned fable off, got %q", m.sel["fable"])
	}
	if m.sel["main"] != "off" {
		t.Errorf("main must clear when fable is manually turned off, got %q", m.sel["main"])
	}
}

// TestLaunchKeys locks the launch decision: Enter always launches the generated
// profile for the current facets — even at defaults with no prompt — while m
// requests omp-managed on the managed defaults with no generated overlay.
func TestLaunchKeys(t *testing.T) {
	rows := []string{
		"    default    gpt-5.6-sol:high → gpt-5.6-terra:medium",
		"  ● task       gpt-5.6-terra:medium",
	}
	base := model{
		sel:       defaultSel(),
		generated: map[string][]string{comboID(defaultSel()): rows},
	}

	next, _ := base.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m := next.(model)
	if m.genConfig == "" || m.launchManaged {
		t.Errorf("Enter at defaults must launch a generated profile, got genConfig=%q launchManaged=%v", m.genConfig, m.launchManaged)
	}

	next, _ = base.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'m'}})
	m = next.(model)
	if !m.launchManaged || m.genConfig != "" {
		t.Errorf("m must request the managed defaults with no overlay, got genConfig=%q launchManaged=%v", m.genConfig, m.launchManaged)
	}
}

// TestGenConfigYAMLAgentOverrides locks the #173 fix: every ●-marked
// agent-backed role in the generated block is mirrored into
// task.agentModelOverrides (so spawned agents follow the generated profile),
// while unmarked roles and the advisor never are. Prompt-focused keystrokes
// never reach the launch keybinds — clikit's promptbox owns that routing and
// its tests live in cli-kit.
func TestGenConfigYAMLAgentOverrides(t *testing.T) {
	rows := []string{
		"    default    gpt-5.6-sol:high",
		"    plan       claude-fable-5:xhigh",
		"  ● designer   claude-fable-5:xhigh → claude-sonnet-5:high",
		"  ● librarian  gpt-5.6-sol:high",
		"  ● reviewer   claude-fable-5:xhigh",
		"  ● sonic      gpt-5.6-luna:minimal",
		"  ● task       gpt-5.6-terra:medium",
		"    smol       gpt-5.6-luna:low",
	}
	m := model{
		sel:       defaultSel(),
		generated: map[string][]string{comboID(defaultSel()): rows},
	}
	m.sel["advisor"] = "off"
	got := m.genConfigYAML()

	// The override block is emitted in row order with a fixed shape; assert it
	// verbatim so any drift in keys, values, or nesting fails loudly.
	want := "task:\n  agentModelOverrides:\n" +
		"    designer: anthropic/claude-fable-5:xhigh\n" +
		"    librarian: openai-codex/gpt-5.6-sol:high\n" +
		"    reviewer: anthropic/claude-fable-5:xhigh\n" +
		"    sonic: openai-codex/gpt-5.6-luna:minimal\n" +
		"    task: openai-codex/gpt-5.6-terra:medium\n" +
		"defaultThinkingLevel:"
	if !strings.Contains(got, want) {
		t.Errorf("generated config must mirror exactly the ● roles into agentModelOverrides, got:\n%s", got)
	}
	// Override entries are 4-space-indented; assert no non-agent role sneaks in.
	for _, role := range []string{"plan", "smol", "default", "advisor"} {
		if strings.Contains(got, "    "+role+": ") {
			t.Errorf("non-agent role %q must not be overridden, got:\n%s", role, got)
		}
	}
}

// TestDefaultGlyphs pins the built-in facet glyphs to their Nerd Font (FA PUA)
// codepoints. The literals are invisible in most editors — an edit once wiped
// them all to empty strings without anything failing; this locks each value.
func TestDefaultGlyphs(t *testing.T) {
	want := map[string]rune{
		"lane": 0xf127, "model": 0xf085, "thinking": 0xf0eb, "advisor": 0xf14e,
		"spark": 0xf135, "fable": 0xf02d, "main": 0xf140, "fast": 0xf0e7,
	}
	g := defaultGlyphs()
	if len(g) != len(want) {
		t.Errorf("defaultGlyphs has %d entries, want %d", len(g), len(want))
	}
	for _, f := range facetDefs(g) {
		r := []rune(g[f.key])
		if len(r) != 1 {
			t.Errorf("glyph for %q is %d runes, want exactly 1", f.key, len(r))
			continue
		}
		if r[0] != want[f.key] {
			t.Errorf("glyph for %q = U+%04X, want U+%04X", f.key, r[0], want[f.key])
		}
	}
}

// TestGenLinesMainRow: the fable-as-main dial renders as fable's tabulated child
// labelled "default" (self-explanatory next to the preview), with no flavor text
// — the old explainer wrapped on narrow panes and broke the layout.
func TestGenLinesMainRow(t *testing.T) {
	m := model{facets: facetDefs(defaultGlyphs()), sel: defaultSel()}
	m.sel["fable"] = "on"
	m.sel["main"] = "on"
	lines, _ := m.genLines()
	var mainRow string
	for _, ln := range lines {
		p := stripAnsi(ln)
		if strings.Contains(p, "default") {
			mainRow = p
		}
		if strings.Contains(p, "Fable leads") {
			t.Errorf("main row must carry no flavor text, got %q", p)
		}
	}
	if mainRow == "" {
		t.Fatalf("no row labelled 'default' while fable+main are on:\n%s", stripAnsi(strings.Join(lines, "\n")))
	}
	// tabulated child: unfocused prefix is the 2-space pointer slot + an
	// L-shaped tree connector before the glyph — the connector makes the
	// parent/child link to fable explicit, like the `tree` CLI.
	if !strings.HasPrefix(mainRow, "  └ ") {
		t.Errorf("main row must carry the └ child connector, got %q", mainRow)
	}
}

// TestAdvisorChainFlip locks the advisor's opposite-provider rule: the second
// opinion tracks whoever actually leads. Lane-led flips were already in place;
// fable-as-main (fable on + default on) puts Claude Fable in the default seat,
// so mixed/gpt-led lanes must flip the advisor to GPT too — same-provider lead
// and advisor would reintroduce the tunnel-vision risk the advisor exists to
// cut. Pure lanes keep their own provider; fable alone (main off) doesn't flip.
func TestAdvisorChainFlip(t *testing.T) {
	adv := map[string][]string{
		"glance/gpt":    {"gpt-5.6-terra:low"},
		"glance/claude": {"claude-quartz-5:low"},
	}
	cases := []struct {
		lane, fable, main string
		wantCtx           string
	}{
		{"mixed", "off", "off", "claude"},
		{"gpt-led", "off", "off", "claude"},
		{"claude-led", "off", "off", "gpt"},
		{"gpt-only", "off", "off", "gpt"},
		{"claude-only", "off", "off", "claude"},
		// fable on but not leading: no flip.
		{"mixed", "on", "off", "claude"},
		// fable-as-main: Claude leads, advisor flips to GPT.
		{"mixed", "on", "on", "gpt"},
		{"gpt-led", "on", "on", "gpt"},
		{"claude-led", "on", "on", "gpt"},
		// pure Claude pool: pure-lane rule wins, no GPT in the pool.
		{"claude-only", "on", "on", "claude"},
	}
	for _, c := range cases {
		m := model{advisors: adv, sel: defaultSel()}
		m.sel["lane"], m.sel["fable"], m.sel["main"] = c.lane, c.fable, c.main
		got := m.advisorChain("glance")
		want := adv["glance/"+c.wantCtx]
		if len(got) == 0 || got[0] != want[0] {
			t.Errorf("lane=%s fable=%s main=%s: advisor chain = %v, want %s (%v)",
				c.lane, c.fable, c.main, got, c.wantCtx, want)
		}
	}
}

// TestApplyAdvisorFableMain: the flipped chain must flow through applyAdvisor —
// the single seam feeding the preview, the cost/speed meters, and the launched
// config YAML — not just the raw table lookup.
func TestApplyAdvisorFableMain(t *testing.T) {
	m := model{
		advisors: map[string][]string{
			"glance/gpt":    {"gpt-5.6-terra:low"},
			"glance/claude": {"claude-quartz-5:low"},
		},
		sel: defaultSel(),
	}
	m.sel["fable"], m.sel["main"] = "on", "on" // mixed lane (default)
	rows := m.applyAdvisor([]string{"    default    claude-fable-5:high"}, "glance")
	joined := strings.Join(rows, "\n")
	if !strings.Contains(joined, "advisor    gpt-5.6-terra:low") {
		t.Errorf("fable-as-main must synthesise a GPT advisor row, got:\n%s", joined)
	}
}

// TestPreviewColumn locks the Routing section's shape (#198): the title row
// carries the section-local collapse cue (p · hide), the fallback-display cue
// sits directly beneath the title as Routing chrome (worded as a show/hide
// DISPLAY toggle) rather than on a detached bottom row, and no baked
// settings-summary line reaches the preview (the dials are visible on the
// left).
func TestPreviewColumn(t *testing.T) {
	id := comboID(defaultSel())
	m := model{
		generated: map[string][]string{id: {
			"  thinking medium · fallback on · advisor on",
			"    default    gpt-5.6-terra:medium → gpt-5.6-luna:medium",
			"  ● task       gpt-5.6-terra:medium → gpt-5.6-luna:medium",
		}},
		sel: defaultSel(),
		rdy: true,
	}
	m.vp = viewport.New(60, 6)
	m.syncPreview()
	plain := stripAnsi(m.previewColumn())
	if strings.Contains(plain, "fallback on") || strings.Contains(plain, "thinking medium ·") {
		t.Errorf("the baked settings-summary line must not reach the preview, got:\n%s", plain)
	}
	rows := strings.Split(plain, "\n")
	if !strings.Contains(rows[0], "routing") || !strings.Contains(rows[0], "p · hide") {
		t.Errorf("title row must carry the routing pill and its local collapse cue, got %q", rows[0])
	}
	if strings.TrimSpace(rows[1]) != "f · show fallback chains" {
		t.Errorf("fallback cue must sit under the title as chrome, got %q", rows[1])
	}
	if tail := strings.TrimSpace(rows[len(rows)-1]); strings.Contains(tail, "fallback") {
		t.Errorf("no detached bottom hint row may remain, got %q", tail)
	}
	m.depth = 1
	if plain := stripAnsi(m.previewColumn()); !strings.Contains(plain, "f · hide fallback chains") {
		t.Errorf("full-chain depth must flip the cue to hide, got:\n%s", plain)
	}
}

// ── responsive layout (#197) ─────────────────────────────────────────────────

// layoutModel builds a fully-populated model the way main() does — real facets,
// a generated routing block, and usage windows for both providers — so layout
// tests exercise the actual compositions rather than skeleton fixtures.
func layoutModel() model {
	glyphs := defaultGlyphs()
	id := comboID(defaultSel())
	rows := []string{
		"  thinking medium · fallback on · advisor on",
		"    default    gpt-5.6-terra:medium → gpt-5.6-luna:medium → claude-sonnet-5:medium",
		"  ● task       gpt-5.6-terra:medium → gpt-5.6-luna:medium → claude-sonnet-5:medium",
		"  ● scout      gpt-5.6-luna:low → claude-haiku-4-5:low",
		"    advisor    claude-opus-4-5:high",
		"    commit     gpt-5.6-luna:minimal",
	}
	return model{
		generated: map[string][]string{id: rows},
		avail: availability{
			ok:     true,
			bucket: map[string]string{},
			reset:  map[string]int64{},
			wins: []usageWin{
				{label: "5 hours", pct: 12, secs: 3 * 3600, dur: 5 * 3600, prov: "openai-codex"},
				{label: "7 days", pct: 33, secs: 6 * day, dur: 7 * day, prov: "openai-codex"},
				{label: "5 hours", pct: 55, secs: 2 * 3600, dur: 5 * 3600, prov: "anthropic"},
				{label: "7 days", pct: 61, secs: 5 * day, dur: 7 * day, prov: "anthropic"},
			},
		},
		usageCmd:     "omp usage --json",
		authProfiles: []authProfile{{ID: "default", Label: "mine", Claude: "Alex", Codex: "Alex"}},
		spin:         spinner.New(),
		help:         help.New(),
		glyphs:       glyphs,
		facets:       facetDefs(glyphs),
		sel:          defaultSel(),
		nextRefresh:  time.Now().Add(refreshEvery),
	}
}

// resize drives a live tea.WindowSizeMsg through Update and asserts the one
// hard rule of #197 resizing: it must never produce a command (no fetches).
func resize(t *testing.T, m model, w, h int) model {
	t.Helper()
	nm, cmd := m.Update(tea.WindowSizeMsg{Width: w, Height: h})
	if cmd != nil {
		t.Fatalf("resize to %dx%d produced a command — resizes must never trigger fetches", w, h)
	}
	return nm.(model)
}

type termSize struct{ w, h int }

// layoutSizes derives representative wide/medium/narrow/short terminal sizes
// from the model's own measured breakpoints (terminal cells, never pixels), so
// the tests keep tracking content needs if the rendered minima ever grow.
func layoutSizes(t *testing.T, m model) (wide, medium, narrow, short termSize) {
	t.Helper()
	wideW := m.genRowWidth() + routingMinW
	if m.mediumMinW()+6 >= wideW {
		t.Fatalf("fixture drift: medium width %d overlaps the wide threshold %d", m.mediumMinW()+6, wideW)
	}
	wide = termSize{wideW + 20, 40}
	medium = termSize{m.mediumMinW() + 6, 40}
	narrow = termSize{m.mediumMinW() - 10, 40}
	short = termSize{wideW + 20, 10}
	return
}

// assertLayoutInvariants checks the frame guarantees every composition must
// hold: no line wider than the terminal (it would auto-wrap), total height in
// bounds, full-width rules never broken mid-line, and the help footer pinned
// to the very last row.
func assertLayoutInvariants(t *testing.T, m model, label string) {
	t.Helper()
	view := stripAnsi(m.View())
	lines := strings.Split(view, "\n")
	if got := len(lines); got > m.h {
		t.Errorf("%s: view is %d rows for a %d-row terminal", label, got, m.h)
	}
	for i, l := range lines {
		if w := lipgloss.Width(l); w > m.w {
			t.Errorf("%s: line %d is %d cells wide (terminal %d) — would auto-wrap: %q", label, i, w, m.w, l)
		}
		if strings.HasPrefix(l, "─") { // horizontal rules span exactly the terminal
			if strings.TrimRight(l, " ") != strings.Repeat("─", m.w) {
				t.Errorf("%s: rule on line %d does not span the full width: %q", label, i, l)
			}
		}
	}
	if last := lines[len(lines)-1]; !strings.Contains(last, "move") {
		t.Errorf("%s: help footer not pinned to the last row: %q", label, last)
	}
}

// lineIndex returns the first view line containing every needle, or -1.
func lineIndex(lines []string, needles ...string) int {
	for i, l := range lines {
		ok := true
		for _, n := range needles {
			if !strings.Contains(l, n) {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return -1
}

// TestResponsiveCompositions locks the #197 hierarchy: wide keeps Generator and
// Routing side by side over a full-width Usage band (provider groups side by
// side); medium is generator-dominant — the list full width on top, Routing and
// Usage sharing a secondary row, Usage's provider groups stacked vertically;
// narrow and short show one usable panel at a time, Generator first, instead of
// compressing every section.
func TestResponsiveCompositions(t *testing.T) {
	m := layoutModel()
	wide, medium, narrow, short := layoutSizes(t, m)

	m = resize(t, m, wide.w, wide.h)
	if m.mode() != modeSplit {
		t.Fatalf("wide %dx%d: mode = %d, want split", wide.w, wide.h, m.mode())
	}
	lines := strings.Split(stripAnsi(m.View()), "\n")
	if lineIndex(lines, "generator", "routing") < 0 {
		t.Errorf("wide: generator and routing pills must share a row:\n%s", strings.Join(lines, "\n"))
	}
	sideBySide := false
	for _, l := range lines {
		if strings.Count(l, "% used") > 1 {
			sideBySide = true
		}
	}
	if !sideBySide {
		t.Errorf("wide: usage provider groups must sit side by side in the bottom band:\n%s", strings.Join(lines, "\n"))
	}
	assertLayoutInvariants(t, m, "wide")

	m = resize(t, m, medium.w, medium.h)
	if m.mode() != modeMedium {
		t.Fatalf("medium %dx%d: mode = %d, want medium", medium.w, medium.h, m.mode())
	}
	lines = strings.Split(stripAnsi(m.View()), "\n")
	gen := lineIndex(lines, "generator")
	sec := lineIndex(lines, "routing", "usage")
	launch := lineIndex(lines, "launch generated profile")
	if gen < 0 || sec < 0 || launch < 0 {
		t.Fatalf("medium: missing generator (%d), secondary row (%d), or launch footer (%d):\n%s", gen, sec, launch, strings.Join(lines, "\n"))
	}
	if lineIndex(lines, "generator", "routing") >= 0 {
		t.Errorf("medium: generator must own its full-width row, not share it with routing")
	}
	if !(gen < launch && launch < sec) {
		t.Errorf("medium: want generator (%d) over its launch footer (%d) over the routing+usage row (%d)", gen, launch, sec)
	}
	for i, l := range lines {
		if strings.Count(l, "% used") > 1 {
			t.Errorf("medium: usage provider groups must stack vertically, found side-by-side row %d: %q", i, l)
		}
	}
	if lineIndex(lines, "% used") < 0 {
		t.Errorf("medium: usage rows must be visible in the secondary column")
	}
	baseGenH, baseSecH := m.mediumSplit(m.contentH())
	if want := m.secondaryMinH(); baseSecH != want {
		t.Errorf("medium: secondary row height = %d, want measured minimum %d", baseSecH, want)
	}
	tall := resize(t, m, medium.w, medium.h+8)
	tallGenH, tallSecH := tall.mediumSplit(tall.contentH())
	if tallSecH != baseSecH {
		t.Errorf("tall medium: secondary row grew from %d to %d instead of staying content-sized", baseSecH, tallSecH)
	}
	if tallGenH != baseGenH+8 {
		t.Errorf("tall medium: generator grew from %d to %d, want %d", baseGenH, tallGenH, baseGenH+8)
	}
	assertLayoutInvariants(t, m, "medium")

	m = resize(t, m, narrow.w, narrow.h)
	if m.mode() != modeCollapsed {
		t.Fatalf("narrow %dx%d: mode = %d, want collapsed", narrow.w, narrow.h, m.mode())
	}
	lines = strings.Split(stripAnsi(m.View()), "\n")
	if lineIndex(lines, "generator") < 0 {
		t.Errorf("narrow: the generator must stay usable")
	}
	// The shed routing SECTION (its p · hide title chrome) must be gone; the
	// compact footer instead carries the recovery cue.
	if lineIndex(lines, "p · hide") >= 0 || lineIndex(lines, "% used") >= 0 {
		t.Errorf("narrow: secondary sections must be shed, not compressed:\n%s", strings.Join(lines, "\n"))
	}
	if lineIndex(lines, "show routing") < 0 {
		t.Errorf("narrow: the compact footer must offer the routing recovery cue:\n%s", strings.Join(lines, "\n"))
	}
	assertLayoutInvariants(t, m, "narrow")

	// ‹p› swaps to the routing panel — one full panel at a time.
	nm, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("p")})
	m = nm.(model)
	lines = strings.Split(stripAnsi(m.View()), "\n")
	if lineIndex(lines, "routing", "p · hide") < 0 || lineIndex(lines, "generator") >= 0 {
		t.Errorf("narrow+p: want the routing panel full width instead of the generator:\n%s", strings.Join(lines, "\n"))
	}
	nm, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("p")})
	m = nm.(model)

	m = resize(t, m, short.w, short.h)
	if m.mode() != modeCollapsed {
		t.Fatalf("short %dx%d: mode = %d, want collapsed", short.w, short.h, m.mode())
	}
	lines = strings.Split(stripAnsi(m.View()), "\n")
	if lineIndex(lines, "generator") < 0 {
		t.Errorf("short: the generator must stay usable")
	}
	if lineIndex(lines, "% used") >= 0 {
		t.Errorf("short: the usage band must be shed to preserve generator rows")
	}
	assertLayoutInvariants(t, m, "short")
}

// TestModeThresholdEdges locks the exact measured breakpoints: one cell or row
// under a threshold flips the composition immediately on the resize itself —
// no extra keypress, tick, or second message.
func TestModeThresholdEdges(t *testing.T) {
	m := layoutModel()
	wideW := m.genRowWidth() + routingMinW

	m = resize(t, m, wideW, 40)
	if m.mode() != modeSplit {
		t.Fatalf("at the wide width threshold: mode = %d, want split", m.mode())
	}
	m = resize(t, m, wideW-1, 40)
	if m.mode() != modeMedium {
		t.Fatalf("one cell under the wide threshold: mode = %d, want medium", m.mode())
	}
	m = resize(t, m, wideW, 40)
	if m.mode() != modeSplit {
		t.Fatalf("back across the wide threshold: mode = %d, want split", m.mode())
	}

	hEdge := m.wideMinH()
	m = resize(t, m, wideW, hEdge)
	if m.mode() != modeSplit {
		t.Fatalf("at the wide height threshold %d: mode = %d, want split", hEdge, m.mode())
	}
	m = resize(t, m, wideW, hEdge-1)
	if m.mode() == modeSplit {
		t.Fatalf("one row under the wide height threshold %d must leave the split", hEdge)
	}

	mediumW := m.mediumMinW() + 6
	m = resize(t, m, mediumW, 40)
	if m.mode() != modeMedium {
		t.Fatalf("medium width %d: mode = %d, want medium", mediumW, m.mode())
	}
	mEdge := m.mediumMinH()
	m = resize(t, m, mediumW, mEdge)
	if m.mode() != modeMedium {
		t.Fatalf("at the medium height threshold %d: mode = %d, want medium", mEdge, m.mode())
	}
	m = resize(t, m, mediumW, mEdge-1)
	if m.mode() != modeCollapsed {
		t.Fatalf("one row under the medium height threshold %d: mode = %d, want collapsed", mEdge, m.mode())
	}
	m = resize(t, m, m.mediumMinW()-1, 40)
	if m.mode() != modeCollapsed {
		t.Fatalf("one cell under the medium width threshold: mode = %d, want collapsed", m.mode())
	}
}

// TestRepeatedResizeCrossingsPreserveState resizes back and forth across every
// threshold repeatedly and asserts the whole interactive state — selection,
// cursor, depth, collapse, auth, usage fetch identity — rides along untouched,
// and that the routing viewport offset always stays clamped to valid content.
func TestRepeatedResizeCrossingsPreserveState(t *testing.T) {
	m := layoutModel()
	wide, medium, narrow, short := layoutSizes(t, m)
	m = resize(t, m, wide.w, wide.h)

	m.fcur = 2
	m.cycleFacet(1) // thinking: medium → high (facet semantics untouched)
	m.depth = 1
	m.syncPreview()
	wantSel := map[string]string{}
	for k, v := range m.sel {
		wantSel[k] = v
	}
	wantNext := m.nextRefresh

	steps := []struct {
		termSize
		mode int
	}{
		{medium, modeMedium},
		{narrow, modeCollapsed},
		{short, modeCollapsed},
		{medium, modeMedium},
		{wide, modeSplit},
		{narrow, modeCollapsed},
		{wide, modeSplit},
	}
	for round := range 3 {
		for _, s := range steps {
			m = resize(t, m, s.w, s.h)
			label := fmt.Sprintf("round %d, %dx%d", round, s.w, s.h)
			if m.mode() != s.mode {
				t.Fatalf("%s: mode = %d, want %d immediately after the resize", label, m.mode(), s.mode)
			}
			if m.fcur != 2 || m.depth != 1 || m.collapse || m.showResult {
				t.Fatalf("%s: cursor/depth/collapse state mutated: fcur=%d depth=%d collapse=%v showResult=%v", label, m.fcur, m.depth, m.collapse, m.showResult)
			}
			if !reflect.DeepEqual(m.sel, wantSel) {
				t.Fatalf("%s: facet selection mutated: %v", label, m.sel)
			}
			if m.fetching || !m.nextRefresh.Equal(wantNext) {
				t.Fatalf("%s: usage fetch state mutated: fetching=%v nextRefresh moved=%v", label, m.fetching, !m.nextRefresh.Equal(wantNext))
			}
			if m.authIdx != 0 {
				t.Fatalf("%s: auth profile mutated: %d", label, m.authIdx)
			}
			maxOff := m.vp.TotalLineCount() - m.vp.Height
			if maxOff < 0 {
				maxOff = 0
			}
			if m.vp.YOffset < 0 || m.vp.YOffset > maxOff {
				t.Fatalf("%s: viewport offset %d outside [0,%d]", label, m.vp.YOffset, maxOff)
			}
			assertLayoutInvariants(t, m, label)
		}
	}
}

// TestResizeScrollClamp: a scrolled routing viewport keeps its offset across a
// width-only resize, and clamps (never dangles past the content) when a resize
// shrinks the panel; a facet change still resets to the top.
func TestResizeScrollClamp(t *testing.T) {
	m := layoutModel()
	id := comboID(defaultSel())
	rows := []string{"  thinking medium · fallback on · advisor on"}
	for i := range 40 {
		rows = append(rows, fmt.Sprintf("    role%02d     gpt-5.6-terra:medium", i))
	}
	m.generated[id] = rows
	wide, medium, narrow, _ := layoutSizes(t, m)

	m = resize(t, m, wide.w, wide.h)
	if m.vp.TotalLineCount() <= m.vp.Height {
		t.Fatalf("fixture: routing content (%d lines) must overflow the viewport (%d rows)", m.vp.TotalLineCount(), m.vp.Height)
	}
	m.vp.SetYOffset(6)

	m = resize(t, m, wide.w+8, wide.h) // width-only: offset survives
	if m.vp.YOffset != 6 {
		t.Fatalf("width-only resize moved the scroll: YOffset = %d, want 6", m.vp.YOffset)
	}

	m.vp.GotoBottom()
	m = resize(t, m, medium.w, medium.h) // shrink: offset clamps into range
	maxOff := m.vp.TotalLineCount() - m.vp.Height
	if maxOff < 0 {
		maxOff = 0
	}
	if m.vp.YOffset < 0 || m.vp.YOffset > maxOff {
		t.Fatalf("shrink left a dangling offset %d outside [0,%d]", m.vp.YOffset, maxOff)
	}
	m = resize(t, m, narrow.w, narrow.h)
	m = resize(t, m, wide.w, wide.h)

	m.vp.SetYOffset(4)
	m.cycleFacet(1) // content change: back to the top
	if m.vp.YOffset != 0 {
		t.Fatalf("facet change must reset the preview scroll, YOffset = %d", m.vp.YOffset)
	}
}

// ── trackpad / wheel gating ──────────────────────────────────────────────────

// TestWheelGate locks the temporal detent: the first event of a gesture acts
// immediately (real wheel clicks feel instant), a rapid same-axis burst is
// absorbed after that one step, orthogonal jitter inside the locked gesture
// never leaks a step (and keeps the lock alive), a held scroll advances at the
// controlled wheelRepeat cadence, and a pause re-arms an immediate step.
func TestWheelGate(t *testing.T) {
	t0 := time.Unix(1000, 0)
	var g wheelGate

	if !g.admit(wheelAxisV, t0) {
		t.Fatal("first wheel event must act immediately")
	}
	for i := 1; i <= 30; i++ { // trackpad fling: 30 events over 150ms
		if g.admit(wheelAxisV, t0.Add(time.Duration(i)*5*time.Millisecond)) {
			t.Fatalf("burst event %d must be absorbed by the gate", i)
		}
	}
	if g.admit(wheelAxisH, t0.Add(160*time.Millisecond)) {
		t.Fatal("orthogonal jitter inside a vertical gesture must not act")
	}
	if g.admit(wheelAxisV, t0.Add(170*time.Millisecond)) {
		t.Fatal("jitter must keep the lock alive — same-axis event still rationed")
	}
	if !g.admit(wheelAxisV, t0.Add(310*time.Millisecond)) {
		t.Fatal("a held deliberate scroll must advance after wheelRepeat")
	}
	if g.admit(wheelAxisV, t0.Add(320*time.Millisecond)) {
		t.Fatal("the cadence must re-arm after each granted step")
	}
	if !g.admit(wheelAxisH, t0.Add(700*time.Millisecond)) {
		t.Fatal("after an idle pause a deliberate step on any axis must act immediately")
	}
	if g.axis != wheelAxisH {
		t.Fatalf("gate must re-lock to the new axis, got %d", g.axis)
	}
}

// TestWheelStepsFacets locks the wheel→facet mapping with a controlled clock:
// vertical steps move the selection, horizontal steps change the focused
// facet's value, bursts and diagonal jitter advance at most one step, and
// later deliberate steps land after a pause. Facet semantics are the arrow-key
// handlers verbatim.
func TestWheelStepsFacets(t *testing.T) {
	m := layoutModel()
	wide, _, _, _ := layoutSizes(t, m)
	m = resize(t, m, wide.w, wide.h)
	t0 := time.Unix(1000, 0)

	m.wheelStep(tea.MouseButtonWheelDown, t0)
	if m.fcur != 1 {
		t.Fatalf("wheel down must move the selection, fcur = %d", m.fcur)
	}
	for i := 1; i <= 20; i++ { // same-axis burst: at most that one step
		m.wheelStep(tea.MouseButtonWheelDown, t0.Add(time.Duration(i)*5*time.Millisecond))
	}
	if m.fcur != 1 {
		t.Fatalf("a wheel burst must advance one controlled step, fcur = %d", m.fcur)
	}
	sel := m.sel["model"]
	for i := range 5 { // diagonal jitter during the vertical gesture
		m.wheelStep(tea.MouseButtonWheelRight, t0.Add(120*time.Millisecond+time.Duration(i)*5*time.Millisecond))
	}
	if m.sel["model"] != sel {
		t.Fatalf("diagonal jitter must not change facet values: model %q → %q", sel, m.sel["model"])
	}

	t1 := t0.Add(time.Second) // deliberate later gesture on the other axis
	m.wheelStep(tea.MouseButtonWheelRight, t1)
	if m.sel["model"] == sel {
		t.Fatal("a deliberate horizontal step after a pause must change the value")
	}
	m.wheelStep(tea.MouseButtonWheelUp, t1.Add(time.Second))
	if m.fcur != 0 {
		t.Fatalf("wheel up must move the selection back, fcur = %d", m.fcur)
	}
}

// TestWheelThroughUpdate verifies the wiring: a live tea.MouseMsg wheel press
// reaches the gate (one immediate step, no command), and non-wheel mouse
// traffic is ignored.
func TestWheelThroughUpdate(t *testing.T) {
	m := layoutModel()
	wide, _, _, _ := layoutSizes(t, m)
	m = resize(t, m, wide.w, wide.h)

	nm, cmd := m.Update(tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonWheelDown})
	m = nm.(model)
	if cmd != nil {
		t.Fatal("wheel input must never produce a command")
	}
	if m.fcur != 1 {
		t.Fatalf("wheel press must step the selection, fcur = %d", m.fcur)
	}

	sel := map[string]string{}
	for k, v := range m.sel {
		sel[k] = v
	}
	nm, cmd = m.Update(tea.MouseMsg{Action: tea.MouseActionMotion, Button: tea.MouseButtonNone})
	m = nm.(model)
	if cmd != nil || m.fcur != 1 || !reflect.DeepEqual(m.sel, sel) {
		t.Fatal("non-wheel mouse traffic must be ignored")
	}
}

// ── usage identity · collapsible sections · contextual help (#198) ──────────

// press drives one rune keypress through Update.
func press(t *testing.T, m model, k string) (model, tea.Cmd) {
	t.Helper()
	nm, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)})
	return nm.(model), cmd
}

// multiProfileModel is layoutModel with a second (mixed) auth profile, so the
// switch cue and profile-dependent help rules engage.
func multiProfileModel() model {
	m := layoutModel()
	m.authProfiles = []authProfile{
		{ID: "default", Label: "mine", Claude: "Alex", Codex: "Alex"},
		{ID: "mum", Label: "mum", Claude: "Mum", Codex: "Alex"},
	}
	return m
}

// shortDescs returns the compact help line's action descriptions — the
// state-derived contract, independent of footer width truncation.
func shortDescs(m model) []string {
	var out []string
	for _, b := range m.contextHelp().ShortHelp() {
		out = append(out, b.Help().Desc)
	}
	return out
}

func hasDesc(descs []string, want string) bool {
	for _, d := range descs {
		if d == want {
			return true
		}
	}
	return false
}

// TestUsageHeadingsNameEffectiveProfile locks the identity move: provider
// group headings carry the effective account ("Codex <account>",
// "Claude <account>") for every supported profile combination — including
// mixed profiles — and the standalone auth equation is gone.
func TestUsageHeadingsNameEffectiveProfile(t *testing.T) {
	cases := []struct {
		name          string
		claude, codex string
	}{
		{"alex/alex", "Alex", "Alex"},
		{"mum/alex mixed", "Mum", "Alex"},
		{"mum/mum", "Mum", "Mum"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := layoutModel()
			m.authProfiles = []authProfile{{ID: "p", Label: "p", Claude: tc.claude, Codex: tc.codex}}
			lines := strings.Split(stripAnsi(m.usagePanel()), "\n")
			codexHead := lineIndex(lines, "Codex "+tc.codex)
			claudeHead := lineIndex(lines, "Claude "+tc.claude)
			if codexHead < 0 || claudeHead < 0 {
				t.Fatalf("provider headings must name the effective accounts:\n%s", strings.Join(lines, "\n"))
			}
			if trimmed := strings.TrimSpace(lines[codexHead]); trimmed != "Codex "+tc.codex {
				t.Errorf("Codex heading must be a standalone group title, got %q", trimmed)
			}
			if lineIndex(lines, "auth ·") >= 0 || lineIndex(lines, "Claude "+tc.claude+" + ") >= 0 {
				t.Errorf("the standalone auth equation must be gone:\n%s", strings.Join(lines, "\n"))
			}
			if lines[0] == "" || !strings.Contains(lines[0], "usage") || !strings.Contains(lines[0], "s · hide") {
				t.Errorf("usage must open with its first-class title and local hide cue, got %q", lines[0])
			}
		})
	}
}

// TestUsageSwitchCue: `a switch profile` sits after `r now` in the control
// row when an alternate profile exists, and disappears everywhere when only
// one auth profile is configured.
func TestUsageSwitchCue(t *testing.T) {
	m := multiProfileModel()
	wide, _, _, _ := layoutSizes(t, m)
	m = resize(t, m, wide.w, wide.h)
	lines := strings.Split(stripAnsi(m.usagePanel()), "\n")
	ctrl := lineIndex(lines, "next refresh", "r now", "a switch profile")
	if ctrl < 0 {
		t.Fatalf("refresh and switch must share the usage control row:\n%s", strings.Join(lines, "\n"))
	}
	row := lines[ctrl]
	if strings.Index(row, "r now") > strings.Index(row, "a switch profile") {
		t.Errorf("switch cue must come after the refresh cue: %q", row)
	}

	single := layoutModel()
	single = resize(t, single, wide.w, wide.h)
	if view := stripAnsi(single.View()); strings.Contains(view, "switch profile") {
		t.Errorf("single-profile: the switch cue must be omitted everywhere:\n%s", view)
	}
}

// TestUsageLoadingErrorStates: the loading, refreshing, unavailable, and
// switch-failure states each keep the effective identity visible and replace
// only the status — errors stay attached to the Usage section.
func TestUsageLoadingErrorStates(t *testing.T) {
	m := layoutModel()

	loading := m
	loading.avail = availability{bucket: map[string]string{}, reset: map[string]int64{}}
	loading.fetching = true
	panel := stripAnsi(loading.usagePanel())
	for _, want := range []string{"fetching usage…", "Codex Alex", "Claude Alex"} {
		if !strings.Contains(panel, want) {
			t.Errorf("loading: panel missing %q:\n%s", want, panel)
		}
	}
	if strings.Contains(panel, "usage unavailable") {
		t.Errorf("loading must not read as an error:\n%s", panel)
	}

	refreshing := m
	refreshing.fetching = true
	panel = stripAnsi(refreshing.usagePanel())
	for _, want := range []string{"refreshing…", "Codex Alex", "Claude Alex", "% used"} {
		if !strings.Contains(panel, want) {
			t.Errorf("refreshing: panel missing %q:\n%s", want, panel)
		}
	}
	if strings.Contains(panel, "next refresh") {
		t.Errorf("refreshing must replace the countdown, not stack on it:\n%s", panel)
	}

	failed := m
	failed.avail = availability{bucket: map[string]string{}, reset: map[string]int64{}}
	panel = stripAnsi(failed.usagePanel())
	for _, want := range []string{"usage unavailable · authenticate with omp --profile default", "Codex Alex", "Claude Alex"} {
		if !strings.Contains(panel, want) {
			t.Errorf("unavailable: panel missing %q:\n%s", want, panel)
		}
	}

	switchErr := multiProfileModel()
	switchErr.authErr = "state write denied"
	panel = stripAnsi(switchErr.usagePanel())
	if !strings.Contains(panel, "profile switch failed: state write denied") {
		t.Errorf("a switch failure must stay attached to the usage section:\n%s", panel)
	}
}

// TestSectionToggleCombinations walks every routing × usage visibility combo
// on a wide terminal: local hide cues live in the section titles, hidden
// sections surface their recovery cue in the compact footer instead, no
// toggle ever triggers a fetch, and every combination keeps the frame
// invariants.
func TestSectionToggleCombinations(t *testing.T) {
	m := multiProfileModel()
	wide, _, _, _ := layoutSizes(t, m)
	m = resize(t, m, wide.w, wide.h)
	availBefore := m.avail

	assertCombo := func(label string, wantRouting, wantUsage bool) {
		t.Helper()
		view := stripAnsi(m.View())
		lines := strings.Split(view, "\n")
		if got := lineIndex(lines, "p · hide") >= 0; got != wantRouting {
			t.Errorf("%s: routing chrome visible = %v, want %v:\n%s", label, got, wantRouting, view)
		}
		if got := lineIndex(lines, "s · hide") >= 0; got != wantUsage {
			t.Errorf("%s: usage chrome visible = %v, want %v:\n%s", label, got, wantUsage, view)
		}
		if got := lineIndex(lines, "% used") >= 0; got != wantUsage {
			t.Errorf("%s: usage rows visible = %v, want %v", label, got, wantUsage)
		}
		descs := shortDescs(m)
		if got := hasDesc(descs, "show routing"); got == wantRouting {
			t.Errorf("%s: compact help offers show routing = %v with routing visible = %v", label, got, wantRouting)
		}
		if got := hasDesc(descs, "show usage"); got == wantUsage {
			t.Errorf("%s: compact help offers show usage = %v with usage visible = %v", label, got, wantUsage)
		}
		if got := hasDesc(descs, "switch profile"); got == wantUsage {
			t.Errorf("%s: compact help repeats/misses switch profile (got %v) with usage visible = %v", label, got, wantUsage)
		}
		if m.fetching || !reflect.DeepEqual(m.avail, availBefore) {
			t.Errorf("%s: a display toggle mutated fetch state", label)
		}
		assertLayoutInvariants(t, m, label)
	}

	assertCombo("both visible", true, true)

	var cmd tea.Cmd
	m, cmd = press(t, m, "s")
	if cmd != nil {
		t.Fatal("hiding usage must never produce a command")
	}
	assertCombo("usage hidden", true, false)

	m, cmd = press(t, m, "p")
	if cmd != nil {
		t.Fatal("hiding routing must never produce a command")
	}
	assertCombo("both hidden", false, false)

	m, _ = press(t, m, "s")
	assertCombo("routing hidden", false, true)

	m, _ = press(t, m, "p")
	assertCombo("both restored", true, true)
}

// TestCompactHelpDerivation locks the state-derived footer rules: chrome-
// visible actions never repeat in the compact line, hidden sections add their
// recovery cue, refresh hides while a fetch is in flight or unusable, the
// launch trio surfaces only when the generator's launch footer is off screen,
// and the usage recovery cue never advertises a restore the narrow layout
// would immediately shed.
func TestCompactHelpDerivation(t *testing.T) {
	m := multiProfileModel()
	wide, _, narrow, _ := layoutSizes(t, m)

	m = resize(t, m, wide.w, wide.h)
	descs := shortDescs(m)
	for _, d := range []string{"move", "change", "switch profile", "refresh usage", "managed omp", "sandbox", "launch", "show routing", "show usage"} {
		got := hasDesc(descs, d)
		want := d == "move" || d == "change"
		if got != want {
			t.Errorf("wide compact help: %q shown = %v, want %v (descs %v)", d, got, want, descs)
		}
	}
	if !hasDesc(descs, "more") || !hasDesc(descs, "quit") {
		t.Errorf("full-help discovery and quit must always be offered: %v", descs)
	}

	m = resize(t, m, narrow.w, narrow.h)
	descs = shortDescs(m)
	for _, d := range []string{"show routing", "switch profile", "refresh usage"} {
		if !hasDesc(descs, d) {
			t.Errorf("narrow compact help missing %q: %v", d, descs)
		}
	}
	if hasDesc(descs, "show usage") {
		t.Errorf("narrow sheds usage by size, not by state — no show-usage cue: %v", descs)
	}
	ordered := strings.Join(descs, "|")
	for _, optional := range []string{"switch profile", "refresh usage"} {
		if strings.Index(ordered, "more") > strings.Index(ordered, optional) ||
			strings.Index(ordered, "quit") > strings.Index(ordered, optional) {
			t.Errorf("narrow compact help must prioritize more/quit before %q: %v", optional, descs)
		}
	}

	fetching := m
	fetching.fetching = true
	if hasDesc(shortDescs(fetching), "refresh usage") {
		t.Error("refresh must hide from compact help while a fetch is in flight")
	}
	noCmd := m
	noCmd.usageCmd = ""
	if hasDesc(shortDescs(noCmd), "refresh usage") {
		t.Error("refresh must hide from compact help when no usage command exists")
	}

	// narrow + p: routing full-screen hides the generator launch footer.
	swapped, _ := press(t, m, "p")
	descs = shortDescs(swapped)
	for _, d := range []string{"launch", "managed omp", "sandbox"} {
		if !hasDesc(descs, d) {
			t.Errorf("routing-full-screen compact help missing %q: %v", d, descs)
		}
	}
	if hasDesc(descs, "show routing") {
		t.Errorf("routing is visible full-screen — no recovery cue: %v", descs)
	}

	// A terminal too narrow to ever seat usage must not advertise its restore.
	tiny := multiProfileModel()
	tiny.hideUsage = true
	tiny = resize(t, tiny, routingMinW-3, 40)
	if hasDesc(shortDescs(tiny), "show usage") {
		t.Error("show usage must not be offered when restoring could not render it")
	}
}

// TestFullHelpComplete: ? always exposes every binding — including both
// section toggles — regardless of what the compact footer dropped, and the
// full keymap stays conflict-free (u keeps the sandbox; s is the usage key).
func TestFullHelpComplete(t *testing.T) {
	m := multiProfileModel()
	wide, _, _, _ := layoutSizes(t, m)
	m = resize(t, m, wide.w, wide.h)
	m.hideUsage = true
	m.collapse = true
	m.help.ShowAll = true
	foot := stripAnsi(m.footer())
	for _, d := range []string{"move", "change", "defaults", "primary ⇄ full chains", "refresh usage", "switch profile", "show/hide routing", "show/hide usage", "launch", "managed omp", "sandbox", "quit"} {
		if !strings.Contains(foot, d) {
			t.Errorf("full help missing %q:\n%s", d, foot)
		}
	}

	seen := map[string]string{}
	for _, group := range keys.FullHelp() {
		for _, b := range group {
			for _, k := range b.Keys() {
				if prev, dup := seen[k]; dup {
					t.Errorf("key %q bound to both %q and %q", k, prev, b.Help().Desc)
				}
				seen[k] = b.Help().Desc
			}
		}
	}
	if got := keys.Usage.Keys(); len(got) != 1 || got[0] != "s" {
		t.Errorf("usage toggle key = %v, want [s]", got)
	}
	if got := keys.Untrusted.Keys(); len(got) != 1 || got[0] != "u" {
		t.Errorf("sandbox must keep u, got %v", got)
	}
	if got := keys.Collapse.Keys(); len(got) != 1 || got[0] != "p" {
		t.Errorf("routing toggle must keep p, got %v", got)
	}
}

// TestLongAccountLabelsWidthInvariant: over-long account names widen the
// measured usage column (shifting the breakpoints) instead of overflowing or
// truncating the identity, at every representative terminal size.
func TestLongAccountLabelsWidthInvariant(t *testing.T) {
	const longName = "Alexander-Maximilian-Extremely-Long-Name"
	m := layoutModel()
	m.authProfiles = []authProfile{{ID: "long", Label: "long", Claude: longName, Codex: longName}}
	wideW := m.genRowWidth() + routingMinW
	sizes := []termSize{
		{wideW + 30, 40},
		{m.mediumMinW() + 2, 40},
		{m.mediumMinW() - 10, 40},
		{45, 40},
		{wideW + 30, 12},
	}
	for _, s := range sizes {
		m = resize(t, m, s.w, s.h)
		label := fmt.Sprintf("long labels %dx%d", s.w, s.h)
		assertLayoutInvariants(t, m, label)
		view := stripAnsi(m.View())
		if strings.Contains(view, "% used") && !strings.Contains(view, "Codex "+longName) {
			t.Errorf("%s: visible usage must keep the full account identity:\n%s", label, view)
		}
	}
}

// TestSectionStatePreservation: routing/usage visibility survives resizes,
// background refreshes, auth switches, and PromptBox proposal round-trips;
// restoring routing recovers its prior scroll; restoring usage refetches
// nothing.
func TestSectionStatePreservation(t *testing.T) {
	m := multiProfileModel()
	m.authState = filepath.Join(t.TempDir(), "nested", "selected")
	wide, medium, narrow, _ := layoutSizes(t, m)
	m = resize(t, m, wide.w, wide.h)
	m.hideUsage = true
	m.collapse = true

	for _, s := range []termSize{medium, narrow, wide} {
		m = resize(t, m, s.w, s.h)
		if !m.hideUsage || !m.collapse {
			t.Fatalf("resize to %dx%d mutated section visibility", s.w, s.h)
		}
		assertLayoutInvariants(t, m, fmt.Sprintf("hidden sections %dx%d", s.w, s.h))
	}

	nm, _ := m.Update(usageMsg{profile: "default", avail: m.avail})
	m = nm.(model)
	if !m.hideUsage || !m.collapse {
		t.Fatal("a background refresh mutated section visibility")
	}

	m, cmd := press(t, m, "a")
	if cmd == nil {
		t.Fatal("an auth switch must trigger a usage fetch")
	}
	if !m.hideUsage || !m.collapse {
		t.Fatal("an auth switch mutated section visibility")
	}
	if m.activeAuthProfile().ID != "mum" {
		t.Fatalf("auth switch did not advance the profile: %q", m.activeAuthProfile().ID)
	}
	m.fetching = false
	m.avail = multiProfileModel().avail
	if panel := stripAnsi(m.usagePanel()); !strings.Contains(panel, "Claude Mum") {
		t.Errorf("usage headings must follow the switched profile:\n%s", panel)
	}

	nm, _ = m.Update(clikit.ActionsProposedMsg{})
	m = nm.(model)
	nm, _ = m.Update(clikit.ActionsRevertedMsg{})
	m = nm.(model)
	if !m.hideUsage || !m.collapse {
		t.Fatal("a PromptBox proposal round-trip mutated section visibility")
	}

	// Restoring routing recovers the prior scroll position.
	sc := layoutModel()
	id := comboID(defaultSel())
	rows := []string{"  thinking medium · fallback on · advisor on"}
	for i := range 40 {
		rows = append(rows, fmt.Sprintf("    role%02d     gpt-5.6-terra:medium", i))
	}
	sc.generated[id] = rows
	sc = resize(t, sc, wide.w, wide.h)
	sc.vp.SetYOffset(6)
	sc, _ = press(t, sc, "p")
	sc, _ = press(t, sc, "p")
	if sc.vp.YOffset != 6 {
		t.Fatalf("routing restore lost the scroll position: YOffset = %d, want 6", sc.vp.YOffset)
	}

	// Restoring usage refetches nothing: same rows, no command, no fetch.
	u := layoutModel()
	u = resize(t, u, wide.w, wide.h)
	before := stripAnsi(u.View())
	u, cmd = press(t, u, "s")
	if cmd != nil {
		t.Fatal("hiding usage must not produce a command")
	}
	u, cmd = press(t, u, "s")
	if cmd != nil || u.fetching {
		t.Fatal("restoring usage must not refetch")
	}
	if after := stripAnsi(u.View()); after != before {
		t.Fatalf("usage restore must reproduce the exact prior band:\n--- before ---\n%s\n--- after ---\n%s", before, after)
	}
}

// TestCollapseReallocation: hiding a section hands its rows to the active
// composition immediately — medium's secondary row shrinks to routing-only at
// full width and the generator absorbs the slack; wide returns the usage band
// rows to the body; a narrow terminal gains the medium secondary row once the
// usage column no longer needs seating.
func TestCollapseReallocation(t *testing.T) {
	m := layoutModel()
	wide, medium, narrow, _ := layoutSizes(t, m)

	m = resize(t, m, medium.w, medium.h+8)
	gen0, sec0 := m.mediumSplit(m.contentH())
	m, _ = press(t, m, "s")
	if m.mode() != modeMedium {
		t.Fatalf("hiding usage at medium width must stay medium, mode = %d", m.mode())
	}
	gen1, sec1 := m.mediumSplit(m.contentH())
	if sec1 >= sec0 || gen1 <= gen0 {
		t.Errorf("medium reallocation: secondary %d→%d, generator %d→%d — generator must absorb the freed rows", sec0, sec1, gen0, gen1)
	}
	if got := m.routingColW(); got != m.w {
		t.Errorf("routing must span the full secondary row when usage hides: %d, want %d", got, m.w)
	}
	assertLayoutInvariants(t, m, "medium usage hidden")
	m, _ = press(t, m, "s")
	if gen2, sec2 := m.mediumSplit(m.contentH()); gen2 != gen0 || sec2 != sec0 {
		t.Errorf("restore must return the original split: got %d/%d, want %d/%d", gen2, sec2, gen0, gen0)
	}

	w := layoutModel()
	w = resize(t, w, wide.w, wide.h)
	ch0 := w.contentH()
	w, _ = press(t, w, "s")
	if ch1 := w.contentH(); ch1 <= ch0 {
		t.Errorf("wide: hiding the usage band must return its rows to the body: %d → %d", ch0, ch1)
	}
	assertLayoutInvariants(t, w, "wide usage hidden")

	n := layoutModel()
	n = resize(t, n, narrow.w, narrow.h)
	if n.mode() != modeCollapsed {
		t.Fatalf("fixture: %dx%d must start collapsed", narrow.w, narrow.h)
	}
	n, _ = press(t, n, "s")
	if n.mode() != modeMedium {
		t.Fatalf("narrow: freeing the usage column must let routing return, mode = %d", n.mode())
	}
	lines := strings.Split(stripAnsi(n.View()), "\n")
	if lineIndex(lines, "routing", "p · hide") < 0 {
		t.Errorf("narrow with usage hidden: the routing section must reappear:\n%s", strings.Join(lines, "\n"))
	}
	assertLayoutInvariants(t, n, "narrow usage hidden")
}
