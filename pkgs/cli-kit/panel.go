package clikit

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

var panelStyle = lipgloss.NewStyle().
	Border(lipgloss.RoundedBorder()).
	BorderForeground(lipgloss.Color(CBord)).
	Padding(0, 1)

// Panel renders clipped content inside cli-kit's shared rounded chrome. The
// returned block never exceeds width, preventing terminal auto-wrap from moving
// footers below the viewport.
func Panel(width int, content string) string {
	if width < 1 {
		width = 1
	}
	frame := panelStyle.GetHorizontalFrameSize()
	if width <= frame {
		return ClipLines(content, width)
	}
	inner := PanelContentWidth(width)
	styleWidth := width - panelStyle.GetHorizontalBorderSize()
	return panelStyle.Width(styleWidth).Render(ClipLines(content, inner))
}

// PanelContentWidth reports the usable content width inside Panel.
func PanelContentWidth(width int) int {
	inner := width - panelStyle.GetHorizontalFrameSize()
	if inner < 1 {
		return 1
	}
	return inner
}

// ClipLines truncates every physical row to width without wrapping.
func ClipLines(content string, width int) string {
	if width < 1 {
		width = 1
	}
	lines := strings.Split(content, "\n")
	for i := range lines {
		lines[i] = ansi.Truncate(lines[i], width, "")
	}
	return strings.Join(lines, "\n")
}
