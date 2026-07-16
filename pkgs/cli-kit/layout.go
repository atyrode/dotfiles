package clikit

import (
	"strings"

	"github.com/charmbracelet/bubbles/help"
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

// Rule renders a full-width section boundary using the shared visual palette.
func Rule(width int) string {
	if width < 0 {
		width = 0
	}
	return StDim.Render(strings.Repeat("─", width))
}

// SeparatedSections stacks every non-empty section behind a full-width Rule.
// The result always begins with a boundary, so callers can attach it below any
// independently laid-out body without allowing adjacent sections to run
// together. Empty sections are omitted along with their boundary.
func SeparatedSections(width int, sections ...string) string {
	parts := make([]string, 0, len(sections)*2)
	for _, section := range sections {
		if section == "" {
			continue
		}
		parts = append(parts, Rule(width), section)
	}
	return strings.Join(parts, "\n")
}

// HelpItem is one reusable key/description pair in a TUI control footer.
type HelpItem struct {
	Key         string
	Description string
}

// WrapHelp renders every control using the supplied shared help model and wraps
// whole cues across rows without dropping any. This complements Bubble Help's
// intentionally truncating single-line renderer for screens whose controls are
// all required, such as modal managers.
func WrapHelp(h help.Model, width int, items []HelpItem) string {
	cue := func(item HelpItem) string {
		return h.Styles.ShortKey.Inline(true).Render(item.Key) + " " +
			h.Styles.ShortDesc.Inline(true).Render(item.Description)
	}
	separator := h.Styles.ShortSeparator.Inline(true).Render(h.ShortSeparator)
	rows := make([]string, 0, len(items))
	row := ""
	for _, item := range items {
		rendered := cue(item)
		next := rendered
		if row != "" {
			next = row + separator + rendered
		}
		if row != "" && lipgloss.Width(next) > width {
			rows = append(rows, row)
			row = rendered
		} else {
			row = next
		}
	}
	if row != "" {
		rows = append(rows, row)
	}
	return strings.Join(rows, "\n")
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
	// Clip BEFORE fixing the width: Width() word-wraps over-wide lines onto
	// extra physical rows, silently making the column taller than h and pushing
	// everything below it off-screen. MaxWidth alone truncates per line without
	// wrapping; Width then only pads the (now fitting) lines to a stable lw.
	clipped := lipgloss.NewStyle().MaxWidth(lw).Render(strings.Join(vis, "\n"))
	list := lipgloss.NewStyle().Width(lw).Render(clipped)
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
