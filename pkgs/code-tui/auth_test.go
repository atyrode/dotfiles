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
	got := loadAvailability(script+" --profile default usage --json", "mum")
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

const day = int64(86400)

func TestCreditLine(t *testing.T) {
	tests := []struct {
		name    string
		credits resetCredits
		want    string
	}{
		{"absent", resetCredits{}, ""},
		{"count only", resetCredits{avail: 2}, "2 resets"},
		{"singular", resetCredits{avail: 1, exp: []int64{3 * day}}, "1 reset · expiring in 3d"},
		{"sorted ascending", resetCredits{avail: 3, exp: []int64{28 * day, 11 * day, 16 * day}}, "3 resets · expiring in 11d, 16d, 28d"},
		{"capped at three soonest", resetCredits{avail: 5, exp: []int64{40 * day, 2 * day, 30 * day, 9 * day, 20 * day}}, "5 resets · expiring in 2d, 9d, 20d"},
		{"rounds up to whole days", resetCredits{avail: 3, exp: []int64{1, day, day + 1}}, "3 resets · expiring in 1d, 1d, 2d"},
		{"expired reads zero", resetCredits{avail: 0, exp: []int64{-5}}, "0 resets · expiring in 0d"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := model{avail: availability{credits: tt.credits}}
			got := m.creditLine()
			if tt.want == "" {
				if got != "" {
					t.Fatalf("creditLine() = %q, want empty", got)
				}
				return
			}
			if !strings.Contains(got, tt.want) {
				t.Fatalf("creditLine() = %q, want it to contain %q", got, tt.want)
			}
		})
	}
}

func TestUsagePanelShowsOpenAIResetCredits(t *testing.T) {
	m := model{
		authProfiles: []authProfile{{ID: "default", Label: "mine", Claude: "Alex", Codex: "Alex"}},
		avail: availability{
			ok:      true,
			bucket:  map[string]string{},
			reset:   map[string]int64{},
			wins:    []usageWin{{label: "7 days", pct: 33, secs: 6 * day, dur: 7 * day, prov: "openai-codex"}},
			credits: resetCredits{avail: 3, exp: []int64{28 * day, 11 * day, 16 * day}},
		},
	}
	panel := m.usagePanel()
	if !strings.Contains(panel, "3 resets · expiring in 11d, 16d, 28d") {
		t.Fatalf("usage panel missing reset credits: %q", panel)
	}
}

func TestUsagePanelWithoutResetCredits(t *testing.T) {
	m := model{
		authProfiles: []authProfile{{ID: "default", Label: "mine", Claude: "Alex", Codex: "Alex"}},
		avail: availability{
			ok:     true,
			bucket: map[string]string{},
			reset:  map[string]int64{},
			wins:   []usageWin{{label: "7 days", pct: 33, secs: 6 * day, dur: 7 * day, prov: "openai-codex"}},
		},
	}
	if panel := m.usagePanel(); strings.Contains(panel, "expiring") || strings.Contains(panel, "resets") {
		t.Fatalf("usage panel unexpectedly mentions reset credits: %q", panel)
	}
}

func TestWithOMPProfileOverridesForwardedProfile(t *testing.T) {
	tests := []struct {
		name    string
		profile string
		args    []string
		want    []string
	}{
		{
			name:    "no override",
			profile: "mum",
			args:    []string{"--config", "/tmp/generated.yml", "--resume"},
			want:    []string{"--profile", "mum", "--config", "/tmp/generated.yml", "--resume"},
		},
		{
			name:    "separate override",
			profile: "mum",
			args:    []string{"--config", "/tmp/generated.yml", "--profile", "default", "--resume"},
			want:    []string{"--profile", "mum", "--config", "/tmp/generated.yml", "--resume"},
		},
		{
			name:    "equals override",
			profile: "mum",
			args:    []string{"--profile=default", "--resume"},
			want:    []string{"--profile", "mum", "--resume"},
		},
		{
			name:    "message after terminator",
			profile: "mum",
			args:    []string{"--resume", "--", "--profile", "literal message"},
			want:    []string{"--profile", "mum", "--resume", "--", "--profile", "literal message"},
		},
		{
			name:    "sandbox strips override",
			profile: "",
			args:    []string{"--profile", "default", "--resume"},
			want:    []string{"--resume"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := withOMPProfile(tt.profile, tt.args...)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("args = %#v, want %#v", got, tt.want)
			}
		})
	}
}
