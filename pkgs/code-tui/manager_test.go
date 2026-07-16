package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// managerModel is a three-vault model with representative loaded, unavailable,
// and never-fetched states.
func managerModel() model {
	m := layoutModel()
	m.vaults = []vault{
		{ID: "primary", Label: "primary", Profile: "default", Claude: "Operator", Codex: "Operator"},
		{ID: "secondary", Label: "secondary", Profile: "secondary", Claude: "Collaborator", Codex: "Operator"},
		{ID: "tertiary", Label: "tertiary", Profile: "tertiary", Claude: "Reviewer", Codex: "Operator"},
	}
	m.selected = "primary"
	m.disabled = map[string]bool{}
	m.vaultUsage = map[string]availability{
		"primary": {
			ok: true, bucket: map[string]string{}, reset: map[string]int64{},
			accountsOK: true, accounts: map[string][]vaultAccount{
				"anthropic":    {{Provider: "anthropic", Email: "operator.claude@example.test"}},
				"openai-codex": {{Provider: "openai-codex", Email: "operator.codex@example.test"}},
			},
			wins: []usageWin{{prov: "openai-codex", pct: 12}, {prov: "anthropic", pct: 55}},
		},
		"secondary": {
			ok: false, bucket: map[string]string{}, reset: map[string]int64{},
			accountsOK: true, accounts: map[string][]vaultAccount{},
		},
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
	m.mgrCursor = 1 // secondary
	m, cmd := sendKey(t, m, "enter")
	if m.selected != "secondary" {
		t.Fatalf("enter must activate the cursored vault, selected=%q", m.selected)
	}
	if cmd == nil {
		t.Fatal("activating a different vault must refresh the detailed panel")
	}
}
func TestManagerActivateEnablesDisabledVault(t *testing.T) {
	m := managerModel()
	m.disabled = map[string]bool{"tertiary": true}
	m.mgrCursor = 2 // tertiary (disabled)
	m, _ = sendKey(t, m, "enter")
	if m.disabled["tertiary"] {
		t.Fatal("activating a disabled vault must enable it")
	}
	if m.selected != "tertiary" {
		t.Fatalf("enter must select tertiary, selected=%q", m.selected)
	}
}

func TestManagerSpaceTogglesEnabledAndProtectsFallback(t *testing.T) {
	m := managerModel()
	m.mgrCursor = 1 // secondary
	m, _ = sendKey(t, m, "space")
	if !m.disabled["secondary"] {
		t.Fatal("space must disable an enabled vault")
	}
	m, _ = sendKey(t, m, "space")
	if m.disabled["secondary"] {
		t.Fatal("space must re-enable a disabled vault")
	}

	m.mgrCursor = 0 // protected fallback
	m, _ = sendKey(t, m, "space")
	if m.disabled["primary"] || !m.isEnabled(0) {
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

func TestManagerDoesNotQueueLoginHandoffs(t *testing.T) {
	m := managerModel()
	m.mgrCursor = 1
	m, first := sendKey(t, m, "c")
	if first == nil || !m.loginRunning {
		t.Fatal("the first login must start and mark the handoff active")
	}
	m, second := sendKey(t, m, "o")
	if second != nil {
		t.Fatal("a second login key must be ignored while a handoff is active")
	}

	nm, _ := m.Update(loginDoneMsg{vault: "secondary", err: errLoginCancelled})
	m = nm.(model)
	if m.loginRunning {
		t.Fatal("login completion must release the handoff guard")
	}
	if m.vaultErr != "" {
		t.Fatalf("cancellation must not render as a failure: %q", m.vaultErr)
	}

	m.loginRunning = true
	nm, _ = m.Update(loginDoneMsg{vault: "secondary", err: errors.New("provider failed")})
	m = nm.(model)
	if m.vaultErr != "login failed: provider failed" {
		t.Fatalf("real login error was not preserved: %q", m.vaultErr)
	}
}

func TestLoginProcessSuppressesReadlineCancellation(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestLoginProcessHelper$")
	cmd.Env = append(os.Environ(), "CODE_LOGIN_HELPER=cancel")
	p := &loginProcess{cmd: cmd}
	p.SetStdin(strings.NewReader(""))
	p.SetStdout(io.Discard)
	var visible bytes.Buffer
	p.SetStderr(&visible)

	if err := p.Run(); !errors.Is(err, errLoginCancelled) {
		t.Fatalf("cancel error = %v, want errLoginCancelled", err)
	}
	if visible.Len() != 0 {
		t.Fatalf("readline cancellation leaked to terminal: %q", visible.String())
	}
}

func TestLoginProcessPreservesRealDiagnostics(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestLoginProcessHelper$")
	cmd.Env = append(os.Environ(), "CODE_LOGIN_HELPER=error")
	p := &loginProcess{cmd: cmd}
	p.SetStdin(strings.NewReader(""))
	p.SetStdout(io.Discard)
	var visible bytes.Buffer
	p.SetStderr(&visible)

	err := p.Run()
	if err == nil || errors.Is(err, errLoginCancelled) {
		t.Fatalf("real process error was misclassified: %v", err)
	}
	if visible.String() != "provider login failed\n" {
		t.Fatalf("real diagnostic = %q", visible.String())
	}
}

func TestLoginProcessHelper(t *testing.T) {
	switch os.Getenv("CODE_LOGIN_HELPER") {
	case "cancel":
		_, _ = os.Stderr.WriteString("error: readline was closed\n code: \"ERR_USE_AFTER_CLOSE\"\n")
		os.Exit(1)
	case "error":
		_, _ = os.Stderr.WriteString("provider login failed\n")
		os.Exit(1)
	}
}

func TestManagerStaleUsageScopedByVault(t *testing.T) {
	m := managerModel()
	m.selected = "primary"
	m.avail = availability{bucket: map[string]string{}, reset: map[string]int64{}}
	m.hadUsage = false

	ok := availability{ok: true, bucket: map[string]string{}, reset: map[string]int64{}, wins: []usageWin{{prov: "anthropic", pct: 70}}}

	// A reply for a non-active vault is stored under that vault and never
	// touches the detailed panel or produces a command.
	nm, cmd := m.Update(usageMsg{vault: "secondary", avail: ok})
	m = nm.(model)
	if cmd != nil {
		t.Fatal("a non-active vault reply must not drive the detailed panel's fill")
	}
	if m.avail.ok {
		t.Fatal("a non-active vault reply must not populate the detailed panel")
	}
	if !m.vaultUsage["secondary"].ok {
		t.Fatal("a reply must be stored under its own vault for the manager")
	}

	// A reply for the active vault does update the detailed panel.
	nm, _ = m.Update(usageMsg{vault: "primary", avail: ok})
	m = nm.(model)
	if !m.avail.ok {
		t.Fatal("the active vault's reply must populate the detailed panel")
	}
}

func TestManagerRetainsCachedFablePerVault(t *testing.T) {
	m := managerModel()
	m.selected = "primary"
	first := availability{
		ok: true, bucket: map[string]string{"claude-fable": "ok"}, reset: map[string]int64{},
		wins: []usageWin{
			{label: "Claude 5 Hour", prov: "anthropic", pct: 20},
			{label: "Claude 7 Day (Fable)", prov: "anthropic", tier: "fable", pct: 45, observed: 1_752_665_040},
		},
	}
	nm, _ := m.Update(usageMsg{vault: "secondary", avail: first})
	m = nm.(model)
	second := availability{
		ok: true, bucket: map[string]string{"claude-fable": "ok"}, reset: map[string]int64{},
		wins: []usageWin{{label: "Claude 5 Hour", prov: "anthropic", pct: 30}},
	}
	nm, _ = m.Update(usageMsg{vault: "secondary", avail: second})
	m = nm.(model)

	found := false
	for _, w := range m.vaultUsage["secondary"].wins {
		if w.tier == "fable" {
			found = true
			if !w.stale || w.pct != 45 || w.observed != 1_752_665_040 {
				t.Fatalf("per-vault Fable cache was not retained: %+v", w)
			}
		}
	}
	if !found {
		t.Fatal("per-vault Fable cache disappeared after an omitted refresh")
	}
}

func TestManagerRenderingWithinBounds(t *testing.T) {
	base := managerModel()
	// A fourth, disabled vault so one row exercises every state at once.
	base.vaults = append(base.vaults, vault{ID: "guest", Label: "guest", Profile: "guest", Claude: "Guest", Codex: "Operator"})
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
		for _, want := range []string{
			"vaults", "primary", "secondary", "tertiary", "guest",
			"not authenticated", "checking account", "disabled",
		} {
			if !strings.Contains(plain, want) {
				t.Errorf("width %d: manager view missing %q:\n%s", s.w, want, plain)
			}
		}
		// Wide layouts keep verified identity and usage on the same owner row;
		// narrow layouts deliberately clip detail without overflowing.
		if s.w >= 100 &&
			(!strings.Contains(plain, "Claude (Operator) · operator.claude@example.test · 55% used") ||
				!strings.Contains(plain, "Codex (Operator) · operator.codex@example.test · 12% used")) {
			t.Errorf("width %d: manager did not bind usage to an account owner:\n%s", s.w, plain)
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
	if !strings.Contains(stripAnsi(wide), "select") ||
		!strings.Contains(stripAnsi(wide), "login Claude for Operator in profile default") {
		t.Fatalf("wide controls must name the target account and profile: %q", stripAnsi(wide))
	}
	narrow := m.managerControls(20)
	if strings.Contains(stripAnsi(narrow), "login") {
		t.Fatalf("narrow controls must drop to keys only: %q", stripAnsi(narrow))
	}
	if lipgloss.Width(narrow) > 20 {
		t.Fatalf("narrow controls must fit the width, got %d", lipgloss.Width(narrow))
	}
}
