package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// managerModel is a three-vault model with the manager open and a
// representative spread of per-vault usage states: mine has data, mum is
// offline (a fetch returned unavailable), victor has never been fetched.
func managerModel() model {
	m := layoutModel()
	m.vaults = []vault{
		{ID: "mine", Label: "mine", Profile: "default", Claude: "Alex", Codex: "Alex"},
		{ID: "mum", Label: "mum", Profile: "mum", Claude: "Mum", Codex: "Alex"},
		{ID: "victor", Label: "victor", Profile: "victor", Claude: "Victor", Codex: "Alex"},
	}
	m.selected = "mine"
	m.disabled = map[string]bool{}
	m.vaultUsage = map[string]availability{
		"mine": {ok: true, bucket: map[string]string{}, reset: map[string]int64{}, wins: []usageWin{
			{prov: "openai-codex", pct: 12}, {prov: "anthropic", pct: 55},
		}},
		"mum": {ok: false, bucket: map[string]string{}, reset: map[string]int64{}},
	}
	m.manager = true
	return m
}

func keyFor(k string) tea.KeyMsg {
	switch k {
	case "up":
		return tea.KeyMsg{Type: tea.KeyUp}
	case "down":
		return tea.KeyMsg{Type: tea.KeyDown}
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEsc}
	case "space":
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(" ")}
	default:
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
	}
}

func sendKey(t *testing.T, m model, k string) (model, tea.Cmd) {
	t.Helper()
	nm, cmd := m.Update(keyFor(k))
	return nm.(model), cmd
}

func TestManagerOpenAndClose(t *testing.T) {
	m := multiProfileModel()
	wide, _, _, _ := layoutSizes(t, m)
	m = resize(t, m, wide.w, wide.h)

	opened, cmd := sendKey(t, m, "v")
	if !opened.manager {
		t.Fatal("v must open the manager")
	}
	if cmd == nil {
		t.Fatal("opening the manager must kick off a whole-list refresh")
	}
	if opened.mgrCursor != opened.activeIndex() {
		t.Fatalf("manager must open on the active vault, cursor=%d active=%d", opened.mgrCursor, opened.activeIndex())
	}
	if closed, _ := sendKey(t, opened, "esc"); closed.manager {
		t.Fatal("esc must close the manager")
	}
	if closed, _ := sendKey(t, opened, "v"); closed.manager {
		t.Fatal("v must toggle the manager closed")
	}
}

func TestManagerCursorNavigation(t *testing.T) {
	m := managerModel()
	m.mgrCursor = 0
	m, _ = sendKey(t, m, "down")
	m, _ = sendKey(t, m, "down")
	if m.mgrCursor != 2 {
		t.Fatalf("down must advance the cursor, got %d", m.mgrCursor)
	}
	m, _ = sendKey(t, m, "down")
	if m.mgrCursor != 2 {
		t.Fatalf("down must clamp at the last vault, got %d", m.mgrCursor)
	}
	m, _ = sendKey(t, m, "up")
	if m.mgrCursor != 1 {
		t.Fatalf("up must retreat the cursor, got %d", m.mgrCursor)
	}
	for range 5 {
		m, _ = sendKey(t, m, "up")
	}
	if m.mgrCursor != 0 {
		t.Fatalf("up must clamp at the first vault, got %d", m.mgrCursor)
	}
}

func TestManagerActivateSelectsCursoredVault(t *testing.T) {
	m := managerModel()
	m.mgrCursor = 1 // mum
	m, cmd := sendKey(t, m, "enter")
	if m.selected != "mum" {
		t.Fatalf("enter must activate the cursored vault, selected=%q", m.selected)
	}
	if cmd == nil {
		t.Fatal("activating a different vault must refresh the detailed panel")
	}
}
func TestManagerActivateEnablesDisabledVault(t *testing.T) {
	m := managerModel()
	m.disabled = map[string]bool{"victor": true}
	m.mgrCursor = 2 // victor (disabled)
	m, _ = sendKey(t, m, "enter")
	if m.disabled["victor"] {
		t.Fatal("activating a disabled vault must enable it")
	}
	if m.selected != "victor" {
		t.Fatalf("enter must select victor, selected=%q", m.selected)
	}
}

func TestManagerSpaceTogglesEnabledAndProtectsMine(t *testing.T) {
	m := managerModel()
	m.mgrCursor = 1 // mum
	m, _ = sendKey(t, m, "space")
	if !m.disabled["mum"] {
		t.Fatal("space must disable an enabled vault")
	}
	m, _ = sendKey(t, m, "space")
	if m.disabled["mum"] {
		t.Fatal("space must re-enable a disabled vault")
	}

	m.mgrCursor = 0 // mine — the protected fallback
	m, _ = sendKey(t, m, "space")
	if m.disabled["mine"] || !m.isEnabled(0) {
		t.Fatal("the fallback vault must never be disabled from the manager")
	}
}

func TestManagerRefreshAllRefetches(t *testing.T) {
	m := managerModel()
	m, cmd := sendKey(t, m, "r")
	if cmd == nil {
		t.Fatal("r must refresh every vault")
	}
	if !m.fetching {
		t.Fatal("r must mark the active fetch in flight")
	}
}

func TestManagerLoginKeysReturnCommands(t *testing.T) {
	m := managerModel()
	m.mgrCursor = 1
	if _, cmd := sendKey(t, m, "c"); cmd == nil {
		t.Fatal("c must launch the Anthropic login handoff")
	}
	if _, cmd := sendKey(t, m, "o"); cmd == nil {
		t.Fatal("o must launch the openai-codex login handoff")
	}
}

func TestManagerStaleUsageScopedByVault(t *testing.T) {
	m := managerModel()
	m.selected = "mine"
	m.avail = availability{bucket: map[string]string{}, reset: map[string]int64{}}
	m.hadUsage = false

	ok := availability{ok: true, bucket: map[string]string{}, reset: map[string]int64{}, wins: []usageWin{{prov: "anthropic", pct: 70}}}

	// A reply for a non-active vault is stored under that vault and never
	// touches the detailed panel or produces a command.
	nm, cmd := m.Update(usageMsg{vault: "mum", avail: ok})
	m = nm.(model)
	if cmd != nil {
		t.Fatal("a non-active vault reply must not drive the detailed panel's fill")
	}
	if m.avail.ok {
		t.Fatal("a non-active vault reply must not populate the detailed panel")
	}
	if !m.vaultUsage["mum"].ok {
		t.Fatal("a reply must be stored under its own vault for the manager")
	}

	// A reply for the active vault does update the detailed panel.
	nm, _ = m.Update(usageMsg{vault: "mine", avail: ok})
	m = nm.(model)
	if !m.avail.ok {
		t.Fatal("the active vault's reply must populate the detailed panel")
	}
}

func TestManagerRenderingWithinBounds(t *testing.T) {
	base := managerModel()
	// A fourth, disabled vault so one row exercises every state at once:
	// mine has usage, mum is offline, victor is loading, guest is disabled.
	base.vaults = append(base.vaults, vault{ID: "guest", Label: "guest", Profile: "guest", Claude: "Guest", Codex: "Alex"})
	base.disabled = map[string]bool{"guest": true}
	wideW := base.genRowWidth() + routingMinW
	for _, s := range []termSize{{wideW + 20, 40}, {72, 30}, {50, 20}} {
		m := resize(t, base, s.w, s.h)
		view := m.View()
		for _, line := range strings.Split(view, "\n") {
			if w := lipgloss.Width(line); w > s.w {
				t.Errorf("width %d: manager line overflows (%d): %q", s.w, w, stripAnsi(line))
			}
		}
		plain := stripAnsi(view)
		for _, want := range []string{"vaults", "mine", "mum", "victor", "guest", "offline", "loading", "disabled"} {
			if !strings.Contains(plain, want) {
				t.Errorf("width %d: manager view missing %q:\n%s", s.w, want, plain)
			}
		}
		// The active vault's compact per-provider usage renders.
		if !strings.Contains(plain, "Codex 12%") || !strings.Contains(plain, "Claude 55%") {
			t.Errorf("width %d: manager missing active vault usage:\n%s", s.w, plain)
		}
		// A control cue row is always present.
		if !strings.Contains(plain, "v") {
			t.Errorf("width %d: manager missing control cues:\n%s", s.w, plain)
		}
	}
}

func TestManagerControlsCompactWhenNarrow(t *testing.T) {
	m := managerModel()
	wide := m.managerControls(200)
	if !strings.Contains(stripAnsi(wide), "activate") {
		t.Fatalf("wide controls must be labelled: %q", stripAnsi(wide))
	}
	narrow := m.managerControls(20)
	if strings.Contains(stripAnsi(narrow), "activate") {
		t.Fatalf("narrow controls must drop to keys only: %q", stripAnsi(narrow))
	}
	if lipgloss.Width(narrow) > 20 {
		t.Fatalf("narrow controls must fit the width, got %d", lipgloss.Width(narrow))
	}
}
