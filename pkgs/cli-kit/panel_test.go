package clikit

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

func TestPanelClipsWithoutWrapping(t *testing.T) {
	for _, width := range []int{1, 12, 40} {
		out := Panel(width, strings.Repeat("x", 120)+"\nsecond")
		if got := lipgloss.Width(out); got > width {
			t.Fatalf("Panel width = %d, want <= %d\n%s", got, width, out)
		}
		wantHeight := 4
		if width == 1 {
			wantHeight = 2
		}
		if got := lipgloss.Height(out); got != wantHeight {
			t.Fatalf("Panel(%d) height = %d, want %d physical rows\n%s", width, got, wantHeight, out)
		}
	}
}

func TestPanelContentWidthIsAlwaysUsable(t *testing.T) {
	previous := 0
	for width := -2; width <= 40; width++ {
		got := PanelContentWidth(width)
		if got < 1 {
			t.Fatalf("PanelContentWidth(%d) = %d", width, got)
		}
		if width > 1 && got < previous {
			t.Fatalf("PanelContentWidth decreased at %d: %d < %d", width, got, previous)
		}
		previous = got
	}
}
