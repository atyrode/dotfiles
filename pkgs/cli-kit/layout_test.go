package clikit

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
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

func TestSeparatedSectionsAlwaysBoundsContent(t *testing.T) {
	out := SeparatedSections(8, "", "usage", "", "controls")
	rows := strings.Split(out, "\n")
	if len(rows) != 4 {
		t.Fatalf("got %d rows, want two boundaries and two sections: %q", len(rows), out)
	}
	for _, i := range []int{0, 2} {
		if lipgloss.Width(rows[i]) != 8 || strings.Trim(ansi.Strip(rows[i]), "─") != "" {
			t.Errorf("row %d is not an 8-cell section boundary: %q", i, rows[i])
		}
	}
	if rows[1] != "usage" || rows[3] != "controls" {
		t.Fatalf("section order changed: %q", out)
	}
	if got := SeparatedSections(8, "", ""); got != "" {
		t.Fatalf("empty sections must produce no orphan boundary: %q", got)
	}
}

func TestWrapHelpUsesSharedStyleAndWrapsWholeCues(t *testing.T) {
	h := NewHelp()
	if h.Styles.ShortKey.GetForeground() != StHead.GetForeground() ||
		h.Styles.ShortDesc.GetForeground() != StDim.GetForeground() ||
		h.Styles.ShortSeparator.GetForeground() != StDim.GetForeground() {
		t.Fatal("shared Help styles diverged from the cli-kit palette")
	}
	items := []HelpItem{
		{Key: "a", Description: "alpha"},
		{Key: "b", Description: "beta"},
		{Key: "c", Description: "gamma"},
	}
	out := WrapHelp(h, 16, items)
	for _, row := range strings.Split(out, "\n") {
		if lipgloss.Width(row) > 16 {
			t.Errorf("wrapped Help row exceeds 16 cells: %q", row)
		}
	}
	for _, want := range []string{"a alpha", "b beta", "c gamma"} {
		if !strings.Contains(out, want) {
			t.Errorf("wrapped Help dropped %q: %q", want, out)
		}
	}
	if got := WrapHelp(h, 16, nil); got != "" {
		t.Fatalf("empty Help items rendered content: %q", got)
	}
}
