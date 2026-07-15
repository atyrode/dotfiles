package main

import (
	"regexp"
	"strings"
	"testing"

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

// TestPreviewColumn locks the right column's shape: a pinned "routing" pill on
// top, no settings-summary line (the dials are visible on the left), and the
// pinned f cue at the bottom worded as a DISPLAY toggle (show/hide).
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
	if !strings.Contains(plain, "routing") {
		t.Errorf("preview column must carry the routing pill, got:\n%s", plain)
	}
	if strings.Contains(plain, "fallback on") || strings.Contains(plain, "thinking medium ·") {
		t.Errorf("the baked settings-summary line must not reach the preview, got:\n%s", plain)
	}
	rows := strings.Split(strings.TrimRight(plain, "\n"), "\n")
	if last := strings.TrimSpace(rows[len(rows)-1]); last != "f · show fallback chains" {
		t.Errorf("bottom hint = %q, want %q", last, "f · show fallback chains")
	}
	m.depth = 1
	if plain := stripAnsi(m.previewColumn()); !strings.Contains(plain, "f · hide fallback chains") {
		t.Errorf("full-chain depth must flip the cue to hide, got:\n%s", plain)
	}
}
