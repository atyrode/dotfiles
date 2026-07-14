package clikit

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// TestWindowListNeverWraps locks the height contract: a row wider than the
// column must be CLIPPED, not wrapped — wrapping grew the column past h
// physical lines and pushed everything below it (footers) off-screen.
func TestWindowListNeverWraps(t *testing.T) {
	long := strings.Repeat("x", 120) + " " + strings.Repeat("y", 80) // the space invites word-wrap
	lines := []string{"short", long, "tail"}
	const w = 30
	for _, h := range []int{2, 3, 5} {
		out := WindowList(lines, 0, h, w)
		rows := strings.Split(out, "\n")
		if len(rows) != h {
			t.Errorf("h=%d: got %d physical rows, want exactly %d", h, len(rows), h)
		}
		for i, r := range rows {
			if rw := lipgloss.Width(r); rw > w {
				t.Errorf("h=%d row %d overflows the column: %d > %d", h, i, rw, w)
			}
		}
	}
}

// TestWindowListStableGeometry: short content keeps the exact h × w footprint
// (padded rows, blank scrollbar column) — the invariant layouts build on.
func TestWindowListStableGeometry(t *testing.T) {
	out := WindowList([]string{"a", "b"}, 0, 4, 20)
	rows := strings.Split(out, "\n")
	if len(rows) != 4 {
		t.Fatalf("got %d rows, want 4", len(rows))
	}
	for i, r := range rows {
		if rw := lipgloss.Width(r); rw != 20 {
			t.Errorf("row %d width = %d, want 20", i, rw)
		}
	}
}
