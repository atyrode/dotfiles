package clikit

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Meter renders a labelled 1..5 scale — n glyphs in the fill colour, the rest in
// the dim "empty" colour — always five glyphs, so the fill (and the headroom)
// read at a glance. Pair with MeterRamp to colour the fill by score.
func Meter(label, glyph, fill string, n int) string {
	on := lipgloss.NewStyle().Foreground(lipgloss.Color(fill)).Bold(true).Render(strings.Repeat(glyph, n))
	off := lipgloss.NewStyle().Foreground(lipgloss.Color(CEmpty)).Render(strings.Repeat(glyph, 5-n))
	return "  " + StDim.Render(Pad(label, 6)) + on + off
}
