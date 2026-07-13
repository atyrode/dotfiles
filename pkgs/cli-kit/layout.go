package clikit

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// PadLeft indents every line of s by n spaces. Safe on styled (ANSI) strings —
// the spaces sit before any escape codes.
func PadLeft(s string, n int) string {
	pad := strings.Repeat(" ", n)
	lines := strings.Split(s, "\n")
	for i := range lines {
		lines[i] = pad + lines[i]
	}
	return strings.Join(lines, "\n")
}

// Pad right-pads s with spaces to at least width n.
func Pad(s string, n int) string {
	for len(s) < n {
		s += " "
	}
	return s
}

// WindowList clips a list to h lines, scrolled to keep the cursor visible, fixes
// the width, and appends a 1-column scrollbar (blank when everything fits) — so
// the column is always exactly h lines tall and w wide, and shows its scroll pos.
func WindowList(lines []string, cursor, h, w int) string {
	if h < 1 {
		h = 1
	}
	total := len(lines)
	start := 0
	if total > h {
		if cursor >= h {
			start = cursor - h + 1
		}
		if start+h > total {
			start = total - h
		}
		if start < 0 {
			start = 0
		}
	}
	end := start + h
	if end > total {
		end = total
	}
	vis := append([]string(nil), lines[start:end]...)
	for len(vis) < h { // pad so the column is exactly h tall
		vis = append(vis, "")
	}
	lw := w - 1 // reserve a column for the scrollbar
	list := lipgloss.NewStyle().Width(lw).MaxWidth(lw).Render(strings.Join(vis, "\n"))
	return lipgloss.JoinHorizontal(lipgloss.Top, list, Scrollbar(total, h, start))
}

// Scrollbar renders a 1-column, h-line track with a proportional thumb; when the
// content fits (total ≤ h) it is a blank column, keeping the layout width stable.
func Scrollbar(total, h, start int) string {
	track := StDim.Render("│")
	thumbCh := lipgloss.NewStyle().Foreground(lipgloss.Color(CHead)).Render("┃")
	pos, thumb := -1, 0
	if total > h {
		thumb = h * h / total
		if thumb < 1 {
			thumb = 1
		}
		pos = start * h / total
		if pos+thumb > h {
			pos = h - thumb
		}
	}
	var b strings.Builder
	for i := 0; i < h; i++ {
		switch {
		case total <= h:
			b.WriteString(" ")
		case i >= pos && i < pos+thumb:
			b.WriteString(thumbCh)
		default:
			b.WriteString(track)
		}
		if i < h-1 {
			b.WriteString("\n")
		}
	}
	return b.String()
}
