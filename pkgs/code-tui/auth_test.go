package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseAuthProfiles(t *testing.T) {
	got := parseAuthProfiles(`[
		{"id":"default","label":"mine","claude":"Alex","codex":"Alex"},
		{"id":"mum","label":"mum","claude":"Mum","codex":"Alex"},
		{"id":"../bad","label":"bad"},
		{"id":"mum","label":"duplicate"}
	]`)
	want := []authProfile{
		{ID: "default", Label: "mine", Claude: "Alex", Codex: "Alex"},
		{ID: "mum", Label: "mum", Claude: "Mum", Codex: "Alex"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("profiles = %#v, want %#v", got, want)
	}
}

func TestAuthProfileSelectionPersists(t *testing.T) {
	state := filepath.Join(t.TempDir(), "nested", "selected")
	profiles := []authProfile{{ID: "default"}, {ID: "mum"}}
	m := model{
		authProfiles: profiles,
		authState:    state,
		avail:        availability{bucket: map[string]string{"claude-main": "ok"}},
	}
	if err := m.switchAuthProfile(); err != nil {
		t.Fatal(err)
	}
	if m.activeAuthProfile().ID != "mum" {
		t.Fatalf("active profile = %q, want mum", m.activeAuthProfile().ID)
	}
	if selectedAuthIndex(profiles, state) != 1 {
		t.Fatal("persisted selection was not restored")
	}
	if m.avail.ok || len(m.avail.bucket) != 0 {
		t.Fatalf("usage was not cleared after switch: %#v", m.avail)
	}
	info, err := os.Stat(state)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("state mode = %o, want 600", info.Mode().Perm())
	}
}

func TestLoadAvailabilityUsesSelectedProfile(t *testing.T) {
	dir := t.TempDir()
	argsPath := filepath.Join(dir, "args")
	script := filepath.Join(dir, "usage")
	body := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ARGS_PATH\"\nprintf '%s\\n' '{\"reports\":[]}'\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ARGS_PATH", argsPath)
	got := loadAvailability(script+" usage --json", "mum")
	if !got.ok {
		t.Fatal("usage response was not accepted")
	}
	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	if want := "--profile\nmum\nusage\n--json\n"; string(args) != want {
		t.Fatalf("usage args = %q, want %q", args, want)
	}
}

func TestUsagePanelNamesWholeAuthCombination(t *testing.T) {
	m := model{
		authProfiles: []authProfile{
			{ID: "default", Label: "mine", Claude: "Alex", Codex: "Alex"},
			{ID: "mum", Label: "mum", Claude: "Mum", Codex: "Alex"},
		},
		authIdx: 1,
		avail:   availability{bucket: map[string]string{}, reset: map[string]int64{}},
	}
	panel := m.usagePanel()
	for _, text := range []string{"auth", "mum", "Claude Mum", "Codex Alex", "switch"} {
		if !strings.Contains(panel, text) {
			t.Fatalf("usage panel missing %q: %q", text, panel)
		}
	}
}

func TestWithOMPProfilePrecedesForwardedArgs(t *testing.T) {
	got := withOMPProfile("mum", "--config", "/tmp/generated.yml", "--resume")
	want := []string{"--profile", "mum", "--config", "/tmp/generated.yml", "--resume"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args = %#v, want %#v", got, want)
	}
}
