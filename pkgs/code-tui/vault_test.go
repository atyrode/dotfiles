package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const day = int64(86400)

func TestParseVaults(t *testing.T) {
	got := parseVaults(`[
		{"id":"mine","label":"mine","profile":"default","claude":"Alex","codex":"Alex","brokerUrl":"u1","tokenFile":"t1","snapshotCache":"c1"},
		{"id":"mum","profile":"mum","claude":"Mum"},
		{"id":"../bad","label":"bad"},
		{"id":"mine","label":"duplicate"}
	]`)
	want := []vault{
		{ID: "mine", Label: "mine", Profile: "default", Claude: "Alex", Codex: "Alex", BrokerURL: "u1", TokenFile: "t1", SnapshotCache: "c1"},
		{ID: "mum", Label: "mum", Profile: "mum", Claude: "Mum", Codex: "mum"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("vaults = %#v, want %#v", got, want)
	}
}

func TestParseVaultsEmptyFallback(t *testing.T) {
	got := parseVaults("")
	if len(got) != 1 || got[0].ID != "default" || got[0].Profile != "default" {
		t.Fatalf("empty manifest must degrade to a single default vault, got %#v", got)
	}
}

func TestLoadVaultStateMigratesPlainFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state")
	if err := os.WriteFile(p, []byte("mum\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	vaults := []vault{{ID: "mine"}, {ID: "mum"}, {ID: "victor"}}
	sel, dis := loadVaultState(vaults, p)
	if sel != "mum" {
		t.Fatalf("plain selected-id file must migrate to selected=mum, got %q", sel)
	}
	if len(dis) != 0 {
		t.Fatalf("migration must leave no disabled vaults, got %#v", dis)
	}
}

func TestLoadVaultStateJSON(t *testing.T) {
	vaults := []vault{{ID: "mine"}, {ID: "mum"}, {ID: "victor"}}
	p := filepath.Join(t.TempDir(), "state")

	// mine can never be disabled; unknown ids are dropped.
	if err := os.WriteFile(p, []byte(`{"selected":"victor","disabled":["mum","mine","ghost"]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	sel, dis := loadVaultState(vaults, p)
	if sel != "victor" {
		t.Fatalf("selected = %q, want victor", sel)
	}
	if !dis["mum"] || dis["mine"] || dis["ghost"] {
		t.Fatalf("disabled must keep mum, strip mine, drop ghost, got %#v", dis)
	}

	// A selection that is itself disabled collapses onto the fallback vault.
	if err := os.WriteFile(p, []byte(`{"selected":"mum","disabled":["mum"]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	sel, _ = loadVaultState(vaults, p)
	if sel != "mine" {
		t.Fatalf("a disabled selection must fall back to the first vault, got %q", sel)
	}
}

func TestVaultStatePersistRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "nested", "state")
	if err := writeVaultState(p, "victor", map[string]bool{"mum": true}); err != nil {
		t.Fatal(err)
	}
	vaults := []vault{{ID: "mine"}, {ID: "mum"}, {ID: "victor"}}
	sel, dis := loadVaultState(vaults, p)
	if sel != "victor" || !dis["mum"] {
		t.Fatalf("round trip lost state: selected=%q disabled=%#v", sel, dis)
	}
	info, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("state mode = %o, want 600", info.Mode().Perm())
	}
}

func TestCycleVaultSkipsDisabled(t *testing.T) {
	m := model{
		vaults:   []vault{{ID: "mine"}, {ID: "mum"}, {ID: "victor"}},
		disabled: map[string]bool{"mum": true},
		avail:    availability{bucket: map[string]string{}, reset: map[string]int64{}},
	}
	changed, err := m.cycleVault()
	if err != nil || !changed {
		t.Fatalf("cycle from mine must advance: changed=%v err=%v", changed, err)
	}
	if got := m.activeVault().ID; got != "victor" {
		t.Fatalf("cycle skipped the disabled mum but landed on %q, want victor", got)
	}
	changed, _ = m.cycleVault()
	if !changed || m.activeVault().ID != "mine" {
		t.Fatalf("cycle from victor must wrap past disabled mum to mine, got %q", m.activeVault().ID)
	}
}

func TestCycleVaultSingleEnabledIsNoop(t *testing.T) {
	m := model{
		vaults:   []vault{{ID: "mine"}, {ID: "mum"}},
		disabled: map[string]bool{"mum": true},
		avail:    availability{bucket: map[string]string{}, reset: map[string]int64{}},
	}
	changed, err := m.cycleVault()
	if err != nil || changed {
		t.Fatalf("with only mine enabled, cycle must be a no-op: changed=%v err=%v", changed, err)
	}
	if m.activeVault().ID != "mine" {
		t.Fatalf("active vault moved off mine: %q", m.activeVault().ID)
	}
}

func TestMineProtection(t *testing.T) {
	m := model{
		vaults:   []vault{{ID: "mine"}, {ID: "mum"}},
		disabled: map[string]bool{},
		avail:    availability{bucket: map[string]string{}, reset: map[string]int64{}},
	}
	if changed, err := m.toggleVault(0); changed || err != nil {
		t.Fatalf("toggling the fallback vault must be a no-op: changed=%v err=%v", changed, err)
	}
	if m.disabled["mine"] || !m.isEnabled(0) {
		t.Fatal("the fallback vault must never become disabled")
	}

	// Disabling the active vault falls the selection back to the fallback.
	m.selected = "mum"
	changed, err := m.toggleVault(1)
	if err != nil {
		t.Fatal(err)
	}
	if !m.disabled["mum"] {
		t.Fatal("mum must be disabled after toggle")
	}
	if !changed || m.activeVault().ID != "mine" {
		t.Fatalf("disabling the active vault must fall back to mine (changed=%v active=%q)", changed, m.activeVault().ID)
	}
	if m.enabledCount() != 1 {
		t.Fatalf("at least one vault must stay enabled, enabledCount=%d", m.enabledCount())
	}
}

func TestBrokerEnv(t *testing.T) {
	tokenPath := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokenPath, []byte("s3cr3t\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	v := vault{BrokerURL: "http://127.0.0.1:9", TokenFile: tokenPath, SnapshotCache: "/cache/mum"}
	env, err := brokerEnv(v)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"OMP_AUTH_BROKER_URL=http://127.0.0.1:9",
		"OMP_AUTH_BROKER_SNAPSHOT_CACHE=/cache/mum",
		"OMP_AUTH_BROKER_TOKEN=s3cr3t",
	}
	if !reflect.DeepEqual(env, want) {
		t.Fatalf("broker env = %#v, want %#v", env, want)
	}
}

func TestBrokerEnvTokenFailure(t *testing.T) {
	v := vault{BrokerURL: "u", TokenFile: filepath.Join(t.TempDir(), "missing")}
	if _, err := brokerEnv(v); err == nil {
		t.Fatal("a missing token file must be a hard error")
	}
	// The failure must surface as an unavailable usage result, never a launch.
	if got := loadAvailability("true usage --json", v); got.ok {
		t.Fatal("a token failure must yield unavailable usage")
	}
}

func TestLoadAvailabilityForcesDefaultProfileAndBrokerEnv(t *testing.T) {
	dir := t.TempDir()
	argsPath := filepath.Join(dir, "args")
	envPath := filepath.Join(dir, "env")
	tokenPath := filepath.Join(dir, "token")
	if err := os.WriteFile(tokenPath, []byte("s3cr3t\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(dir, "usage")
	body := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" > \"$ARGS_PATH\"\n" +
		"printf '%s\\n' \"$OMP_AUTH_BROKER_URL\" \"$OMP_AUTH_BROKER_TOKEN\" \"$OMP_AUTH_BROKER_SNAPSHOT_CACHE\" > \"$ENV_PATH\"\n" +
		"printf '%s\\n' '{\"reports\":[]}'\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ARGS_PATH", argsPath)
	t.Setenv("ENV_PATH", envPath)
	v := vault{ID: "mum", Profile: "mum", BrokerURL: "http://127.0.0.1:9", TokenFile: tokenPath, SnapshotCache: "/cache/mum"}

	got := loadAvailability(script+" --profile mum usage --json", v)
	if !got.ok {
		t.Fatal("usage response was not accepted")
	}
	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	if want := "--profile\ndefault\nusage\n--json\n"; string(args) != want {
		t.Fatalf("usage must force the shared default profile: args = %q, want %q", args, want)
	}
	env, err := os.ReadFile(envPath)
	if err != nil {
		t.Fatal(err)
	}
	if want := "http://127.0.0.1:9\ns3cr3t\n/cache/mum\n"; string(env) != want {
		t.Fatalf("usage must apply the vault broker env: %q, want %q", env, want)
	}
}

func TestTrustedLaunchForcesDefaultProfile(t *testing.T) {
	// Both trusted launch paths force --profile default and strip any forwarded
	// profile, regardless of the selected vault's own profile.
	forwarded := []string{"--config", "/tmp/x.yml", "--profile", "mum", "--resume"}
	managed := managedLaunchArgv("/bin/omp", forwarded, "hello")
	wantManaged := []string{"/bin/omp", "--profile", "default", "--config", "/tmp/x.yml", "--resume", "hello"}
	if !reflect.DeepEqual(managed, wantManaged) {
		t.Fatalf("managed launch argv = %#v, want %#v", managed, wantManaged)
	}

	gen := generatedLaunchArgv("/bin/omp", "/tmp/gen.yml", []string{"--profile", "mum", "--resume"}, "")
	wantGen := []string{"/bin/omp", "--profile", "default", "--config", "/tmp/gen.yml", "--resume"}
	if !reflect.DeepEqual(gen, wantGen) {
		t.Fatalf("generated launch argv = %#v, want %#v", gen, wantGen)
	}
}

func TestSandboxLaunchStripsProfile(t *testing.T) {
	got := sandboxLaunchArgv("/bin/ompu", []string{"--profile", "mum", "--resume"}, "")
	want := []string{"/bin/ompu", "--resume"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sandbox launch argv = %#v, want %#v (profile must be stripped, none forced)", got, want)
	}
}

func TestLoginArgv(t *testing.T) {
	if got := loginArgv("victor", "anthropic"); !reflect.DeepEqual(got, []string{"--profile", "victor", "auth-broker", "login", "anthropic"}) {
		t.Fatalf("anthropic login argv = %#v", got)
	}
	if got := loginArgv("mum", "openai-codex"); !reflect.DeepEqual(got, []string{"--profile", "mum", "auth-broker", "login", "openai-codex"}) {
		t.Fatalf("openai-codex login argv = %#v", got)
	}
}

func TestWithBrokerEnvOverridesAmbient(t *testing.T) {
	base := []string{"PATH=/bin", "OMP_AUTH_BROKER_TOKEN=stale", "HOME=/root"}
	add := []string{"OMP_AUTH_BROKER_TOKEN=fresh", "OMP_AUTH_BROKER_URL=u"}
	got := withBrokerEnv(base, add)
	want := []string{"PATH=/bin", "HOME=/root", "OMP_AUTH_BROKER_TOKEN=fresh", "OMP_AUTH_BROKER_URL=u"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("withBrokerEnv = %#v, want %#v", got, want)
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
			profile: "default",
			args:    []string{"--config", "/tmp/generated.yml", "--resume"},
			want:    []string{"--profile", "default", "--config", "/tmp/generated.yml", "--resume"},
		},
		{
			name:    "separate override",
			profile: "default",
			args:    []string{"--config", "/tmp/generated.yml", "--profile", "mum", "--resume"},
			want:    []string{"--profile", "default", "--config", "/tmp/generated.yml", "--resume"},
		},
		{
			name:    "equals override",
			profile: "default",
			args:    []string{"--profile=mum", "--resume"},
			want:    []string{"--profile", "default", "--resume"},
		},
		{
			name:    "message after terminator",
			profile: "default",
			args:    []string{"--resume", "--", "--profile", "literal message"},
			want:    []string{"--profile", "default", "--resume", "--", "--profile", "literal message"},
		},
		{
			name:    "sandbox strips override",
			profile: "",
			args:    []string{"--profile", "mum", "--resume"},
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

// TestUsagePanelNamesWholeVaultCombination locks the identity move: the effective
// provider/account combination lives in the provider headings ("Codex
// (account)", "Claude (account)") and the switch cue names vaults.
func TestUsagePanelNamesWholeVaultCombination(t *testing.T) {
	m := model{
		vaults: []vault{
			{ID: "mine", Label: "mine", Profile: "default", Claude: "Alex", Codex: "Alex"},
			{ID: "mum", Label: "mum", Profile: "mum", Claude: "Mum", Codex: "Alex"},
		},
		selected: "mum",
		avail:    availability{bucket: map[string]string{}, reset: map[string]int64{}},
	}
	panel := stripAnsi(m.usagePanel())
	for _, text := range []string{"usage", "Claude (Mum)", "Codex (Alex)", "a switch vault"} {
		if !strings.Contains(panel, text) {
			t.Fatalf("usage panel missing %q: %q", text, panel)
		}
	}
	if strings.Contains(panel, "auth ·") || strings.Contains(panel, " + ") {
		t.Fatalf("usage panel must not repeat the auth equation: %q", panel)
	}
}

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
		vaults: []vault{{ID: "mine", Label: "mine", Profile: "default", Claude: "Alex", Codex: "Alex"}},
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
		vaults: []vault{{ID: "mine", Label: "mine", Profile: "default", Claude: "Alex", Codex: "Alex"}},
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
