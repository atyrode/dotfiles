package main

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const catalogListJSON = `{` +
	`"bottom":{"attribute":"bottom","reason":"Watch what this machine is doing.",` +
	`"systems":["x86_64-linux","aarch64-linux","aarch64-darwin"]},` +
	`"ripgrep":{"attribute":"ripgrep","reason":"Search a tree fast.",` +
	`"systems":["x86_64-linux","aarch64-linux","aarch64-darwin"]},` +
	`"vlc":{"attribute":"vlc","reason":"Play a video file nothing else will.",` +
	`"systems":["x86_64-linux","aarch64-linux"]}}`

func newCatalogModel(t *testing.T, payload, system string) model {
	t.Helper()
	m := newModel("atyrode")
	m.width, m.height = 120, 34
	m.catalogSystem = system
	m.runner = runnerFunc(func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name != "atyrode" || strings.Join(args, " ") != "run --json" {
			t.Fatalf("unexpected catalog command: %s %v", name, args)
		}
		return []byte(payload), nil
	})
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'8'}})
	m = next.(model)
	if m.nav.Active() != workspaceCatalog || cmd == nil || !m.catalogLoading {
		t.Fatalf("catalog entry = active %q, cmd %v, loading %t", m.nav.Active(), cmd, m.catalogLoading)
	}
	next, _ = m.Update(cmd())
	m = next.(model)
	if m.catalogLoading || m.catalogErr != nil {
		t.Fatalf("catalog load = loading %t, err %v", m.catalogLoading, m.catalogErr)
	}
	return m
}

func TestCatalogListsEveryReviewedEntryWithItsReason(t *testing.T) {
	m := newCatalogModel(t, catalogListJSON, "x86_64-linux")
	if len(m.catalog) != 3 || m.catalog[0].Name != "bottom" || m.catalog[2].Name != "vlc" {
		t.Fatalf("catalog order = %v", m.catalog)
	}
	view := stripTerminalControls(m.View())
	for _, want := range []string{
		"Ephemeral catalog",
		"Nothing is installed or declared",
		"atyrode clean",
		"bottom",
		"Watch what this machine is doing.",
		"ripgrep",
		"Search a tree fast.",
		"vlc",
		"Play a video file nothing else will.",
		"Enter run once",
	} {
		if !strings.Contains(view, want) {
			t.Errorf("catalog view missing %q\n%s", want, view)
		}
	}
}

// An entry belonging to another system stays listed — the operator asked what
// the fleet curates, not what this machine happens to support — but it can
// never be reached by the cursor, and the row says where it does run.
func TestCatalogEntryForAnotherSystemIsListedButNotSelectable(t *testing.T) {
	for _, tc := range []struct {
		name     string
		system   string
		unusable string
		wants    []string
	}{
		{
			name:     "linux-only entry on a mac",
			system:   "aarch64-darwin",
			unusable: "vlc",
			wants: []string{
				"runs on x86_64-linux, aarch64-linux",
				"macOS GUI software is declared as a Homebrew cask instead",
			},
		},
		{
			name:     "mac-only entry on linux",
			system:   "x86_64-linux",
			unusable: "raycast",
			wants:    []string{"runs on aarch64-darwin"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := catalogListJSON
			if tc.unusable == "raycast" {
				payload = strings.Replace(catalogListJSON, `"vlc":{"attribute":"vlc"`,
					`"raycast":{"attribute":"raycast"`, 1)
				payload = strings.Replace(payload, `"systems":["x86_64-linux","aarch64-linux"]}}`,
					`"systems":["aarch64-darwin"]}}`, 1)
			}
			m := newCatalogModel(t, payload, tc.system)
			view := stripTerminalControls(m.View())
			if !strings.Contains(view, tc.unusable) {
				t.Fatalf("catalog view hid %q\n%s", tc.unusable, view)
			}
			for _, want := range tc.wants {
				if !strings.Contains(view, want) {
					t.Errorf("catalog view missing %q\n%s", want, view)
				}
			}

			// Walking the list to its end must never rest on the unusable entry.
			for range m.catalog {
				m.catalogUpdate("down")
				entry, ok := m.selectedCatalogEntry()
				if !ok || entry.Name == tc.unusable {
					t.Fatalf("cursor reached the unusable entry: %q", entry.Name)
				}
			}

			// The refusal still has to be legible if the cursor is placed there.
			for index, entry := range m.catalog {
				if entry.Name == tc.unusable {
					m.catalogCursor = index
				}
			}
			if cmd := m.catalogUpdate("enter"); cmd != nil || m.catalogRunning {
				t.Fatalf("unusable entry launched: cmd %v, running %t", cmd, m.catalogRunning)
			}
			if !strings.Contains(m.catalogStatus, "does not run on "+tc.system) {
				t.Fatalf("refusal status = %q", m.catalogStatus)
			}
		})
	}
}

func TestCatalogEnterRunsTheSelectedEntryThroughTheCLI(t *testing.T) {
	m := newCatalogModel(t, catalogListJSON, "x86_64-linux")
	for index, entry := range m.catalog {
		if entry.Name == "ripgrep" {
			m.catalogCursor = index
		}
	}
	cmd := m.catalogUpdate("enter")
	if cmd == nil || !m.catalogRunning {
		t.Fatalf("launch = cmd %v, running %t", cmd, m.catalogRunning)
	}
	if m.catalogLaunching != "ripgrep" {
		t.Fatalf("launched entry = %q, want ripgrep", m.catalogLaunching)
	}
	if !strings.Contains(stripTerminalControls(m.View()), "Running `atyrode run ripgrep`") {
		t.Error("the running command is not shown in the panel")
	}

	// A finished launch reports the return path, because that is the whole
	// contract the operator is trusting.
	next, _ := m.Update(catalogRunMsg{name: "ripgrep"})
	m = next.(model)
	if m.catalogRunning {
		t.Fatal("the panel stayed in the running state after the launch returned")
	}
	view := stripTerminalControls(m.View())
	for _, want := range []string{"Launched ripgrep", "nothing was installed", "atyrode clean"} {
		if !strings.Contains(view, want) {
			t.Errorf("completion view missing %q\n%s", want, view)
		}
	}
}

// A program is allowed to fail. tcpdump without privileges exits 1, and the
// screen that offered it must report that as the program's news while keeping
// the list on screen; only a launch that never became a program is a failure
// of this screen.
func TestCatalogSeparatesAProgramsExitFromABrokenCatalog(t *testing.T) {
	exited := exec.Command("false").Run()
	for name, testCase := range map[string]struct {
		err       error
		wantRows  bool
		wantTexts []string
	}{
		"the program exited nonzero": {
			err:       exited,
			wantRows:  true,
			wantTexts: []string{"tcpdump exited 1", "nothing was installed", "ripgrep"},
		},
		"the program never started": {
			err:       errors.New("no such file or directory"),
			wantTexts: []string{"could not launch tcpdump"},
		},
	} {
		t.Run(name, func(t *testing.T) {
			m := newCatalogModel(t, catalogListJSON, "x86_64-linux")
			next, _ := m.Update(catalogRunMsg{name: "tcpdump", err: testCase.err})
			view := stripTerminalControls(next.(model).View())
			for _, want := range testCase.wantTexts {
				if !strings.Contains(view, want) {
					t.Errorf("view missing %q\n%s", want, view)
				}
			}
			if testCase.wantRows && strings.Contains(view, "Catalog unavailable") {
				t.Errorf("a program's exit status hid the catalog\n%s", view)
			}
		})
	}
}

func TestCatalogContractFailsClosed(t *testing.T) {
	for name, payload := range map[string]string{
		"empty catalog": `{}`,
		"no attribute":  `{"a":{"reason":"Do a thing.","systems":["x86_64-linux"]}}`,
		"no reason":     `{"a":{"attribute":"a","systems":["x86_64-linux"]}}`,
		"no systems":    `{"a":{"attribute":"a","reason":"Do a thing.","systems":[]}}`,
		"not an object": `["ripgrep"]`,
	} {
		m := newModel("atyrode")
		body := payload
		m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
			return []byte(body), nil
		})
		msg := m.loadCatalog()().(catalogReportMsg)
		if msg.err == nil || !strings.Contains(msg.err.Error(), "decode the catalog") {
			t.Errorf("%s: catalog contract error = %v", name, msg.err)
		}
	}
}

func TestCurrentNixSystemUsesTheNixpkgsSpelling(t *testing.T) {
	system := currentNixSystem()
	for _, forbidden := range []string{"amd64", "arm64"} {
		if strings.Contains(system, forbidden) {
			t.Fatalf("current system %q uses the Go architecture spelling", system)
		}
	}
	if parts := strings.Split(system, "-"); len(parts) != 2 || parts[1] == "" {
		t.Fatalf("current system %q is not <arch>-<os>", system)
	}
}

func TestCatalogWorkspaceStaysWithinRepresentativeWindows(t *testing.T) {
	for _, size := range []struct{ width, height int }{{44, 18}, {80, 26}, {100, 30}, {150, 44}} {
		m := newCatalogModel(t, catalogListJSON, "aarch64-darwin")
		m.width, m.height = size.width, size.height
		for _, running := range []bool{false, true} {
			m.catalogRunning, m.catalogLaunching = running, "ripgrep"
			view := m.View()
			if rows := strings.Split(view, "\n"); len(rows) > m.height {
				t.Errorf("catalog at %dx%d rendered %d rows", m.width, m.height, len(rows))
			}
			for _, row := range strings.Split(view, "\n") {
				if got := lipgloss.Width(row); got >= m.width {
					t.Errorf("catalog at %dx%d rendered row width %d: %q",
						m.width, m.height, got, stripTerminalControls(row))
				}
			}
		}
	}
}
