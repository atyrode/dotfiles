package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// vault is one selectable auth-broker identity from the CODE_AUTH_VAULTS
// manifest. Every vault is backed by a profile-local broker store (Profile),
// but trusted `code` launches and usage calls all run on the shared `default`
// OMP client profile — the vault only swaps which broker (and token) serves the
// upstream credentials, never the client profile itself. Profile is used solely
// for the login handoff, which reaches the vault's own profile store directly.
type vault struct {
	ID            string `json:"id"`
	Label         string `json:"label"`
	Profile       string `json:"profile"`
	Claude        string `json:"claude"`
	Codex         string `json:"codex"`
	BrokerURL     string `json:"brokerUrl"`
	TokenFile     string `json:"tokenFile"`
	SnapshotCache string `json:"snapshotCache"`
}

var validVaultID = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

// parseVaults decodes the non-secret CODE_AUTH_VAULTS JSON manifest, dropping
// entries with an unsafe or duplicate id and filling the display defaults. An
// empty or unparsable manifest degrades to a single default vault so the UI is
// always usable.
func parseVaults(raw string) []vault {
	var vaults []vault
	if raw != "" {
		_ = json.Unmarshal([]byte(raw), &vaults)
	}
	valid := vaults[:0]
	seen := map[string]bool{}
	for _, v := range vaults {
		v.ID = strings.TrimSpace(v.ID)
		v.Label = strings.TrimSpace(v.Label)
		v.Profile = strings.TrimSpace(v.Profile)
		v.Claude = strings.TrimSpace(v.Claude)
		v.Codex = strings.TrimSpace(v.Codex)
		if !validVaultID.MatchString(v.ID) || strings.HasSuffix(v.ID, ".") || seen[v.ID] {
			continue
		}
		if v.Label == "" {
			v.Label = v.ID
		}
		if v.Profile == "" {
			v.Profile = v.ID
		}
		if v.Claude == "" {
			v.Claude = v.Label
		}
		if v.Codex == "" {
			v.Codex = v.Label
		}
		seen[v.ID] = true
		valid = append(valid, v)
	}
	if len(valid) == 0 {
		return []vault{{ID: "default", Label: "default", Profile: "default", Claude: "current", Codex: "current"}}
	}
	return valid
}

// vaultStateFile is the persisted CODE_AUTH_STATE payload: the selected vault id
// and the set of disabled vault ids. Written non-secret (the id is not the
// token) but 0600, as it is mutable per-user auth state.
type vaultStateFile struct {
	Selected string   `json:"selected"`
	Disabled []string `json:"disabled"`
}

// loadVaultState reads CODE_AUTH_STATE, migrating the pre-vault format (a plain
// selected-id line) to the {selected,disabled} model. The first vault is the
// non-disableable safe fallback: it can never be disabled, and an unknown or
// disabled selection collapses onto it, so at least one vault always stays
// enabled and selectable.
func loadVaultState(vaults []vault, path string) (string, map[string]bool) {
	disabled := map[string]bool{}
	ids := map[string]bool{}
	for _, v := range vaults {
		ids[v.ID] = true
	}
	selected := ""
	if path != "" {
		if b, err := os.ReadFile(path); err == nil {
			trimmed := strings.TrimSpace(string(b))
			if strings.HasPrefix(trimmed, "{") {
				var sf vaultStateFile
				if json.Unmarshal([]byte(trimmed), &sf) == nil {
					selected = strings.TrimSpace(sf.Selected)
					for _, id := range sf.Disabled {
						if ids[id] {
							disabled[id] = true
						}
					}
				}
			} else {
				selected = trimmed // migrate the old plain selected-id file
			}
		}
	}
	if len(vaults) > 0 {
		delete(disabled, vaults[0].ID) // the fallback vault is never disabled
	}
	if !ids[selected] || disabled[selected] {
		if len(vaults) > 0 {
			selected = vaults[0].ID
		} else {
			selected = ""
		}
	}
	return selected, disabled
}

// writeVaultState commits {selected,disabled} atomically at 0600.
func writeVaultState(path, selected string, disabled map[string]bool) error {
	if path == "" {
		return nil
	}
	ids := make([]string, 0, len(disabled))
	for id := range disabled {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	b, err := json.Marshal(vaultStateFile{Selected: selected, Disabled: ids})
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".code-vault-state-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// brokerEnv builds the per-launch broker environment for a vault, reading the
// mutable 0600 token file fresh on every call so a rotated token takes effect
// without restarting the UI. A missing or unreadable token file is a hard error
// (the caller must not launch or fetch with stale/absent credentials).
func brokerEnv(v vault) ([]string, error) {
	var env []string
	if v.BrokerURL != "" {
		env = append(env, "OMP_AUTH_BROKER_URL="+v.BrokerURL)
	}
	if v.SnapshotCache != "" {
		env = append(env, "OMP_AUTH_BROKER_SNAPSHOT_CACHE="+v.SnapshotCache)
	}
	if v.TokenFile != "" {
		b, err := os.ReadFile(v.TokenFile)
		if err != nil {
			return nil, err
		}
		env = append(env, "OMP_AUTH_BROKER_TOKEN="+strings.TrimSpace(string(b)))
	}
	return env, nil
}

// withBrokerEnv overlays add over base, replacing any base entries whose keys
// add also sets, so a stale ambient OMP_AUTH_BROKER_* never shadows the vault's.
func withBrokerEnv(base, add []string) []string {
	if len(add) == 0 {
		return base
	}
	keys := map[string]bool{}
	for _, e := range add {
		if i := strings.IndexByte(e, '='); i >= 0 {
			keys[e[:i]] = true
		}
	}
	out := make([]string, 0, len(base)+len(add))
	for _, e := range base {
		if i := strings.IndexByte(e, '='); i >= 0 && keys[e[:i]] {
			continue
		}
		out = append(out, e)
	}
	return append(out, add...)
}

// loginArgv is the exact argument vector for the vault login handoff: the
// vault's own profile (never the shared default) plus the broker login verb for
// one provider. Pure so the contract is testable without spawning a process.
func loginArgv(profile, provider string) []string {
	return []string{"--profile", profile, "auth-broker", "login", provider}
}

// withOMPProfile makes the given profile authoritative for a forwarded command
// line. Any forwarded profile flag is stripped before the chosen flag is
// inserted, so the client profile OMP launches cannot diverge from the one the
// UI intends (always `default` for trusted launches; "" for the sandbox, which
// owns its own fixed profile). Arguments after `--` are messages, untouched.
func withOMPProfile(profile string, args ...string) []string {
	clean := make([]string, 0, len(args))
	skipValue := false
scan:
	for i, arg := range args {
		if skipValue {
			skipValue = false
			continue
		}
		switch {
		case arg == "--":
			clean = append(clean, args[i:]...)
			break scan
		case arg == "--profile":
			skipValue = true
		case strings.HasPrefix(arg, "--profile="):
			continue
		default:
			clean = append(clean, arg)
		}
	}
	if profile == "" {
		return clean
	}
	out := make([]string, 0, len(clean)+2)
	out = append(out, "--profile", profile)
	return append(out, clean...)
}

func (m model) activeIndex() int {
	for i, v := range m.vaults {
		if v.ID == m.selected {
			return i
		}
	}
	return 0
}

func (m model) activeVault() vault {
	if len(m.vaults) == 0 {
		return vault{ID: "default", Label: "default", Profile: "default", Claude: "current", Codex: "current"}
	}
	return m.vaults[m.activeIndex()]
}

// isEnabled reports whether the vault at index i may be selected. The first
// vault is the protected fallback and is always enabled.
func (m model) isEnabled(i int) bool {
	if i == 0 {
		return true
	}
	if i < 0 || i >= len(m.vaults) {
		return false
	}
	return !m.disabled[m.vaults[i].ID]
}

func (m model) enabledCount() int {
	c := 0
	for i := range m.vaults {
		if m.isEnabled(i) {
			c++
		}
	}
	return c
}

// selectVault points the active selection at index i and re-arms the detailed
// usage panel (a fresh first-load fill for the new vault's context). It reports
// whether the selection actually moved; re-selecting the active vault is a
// no-op that preserves its usage on screen.
func (m *model) selectVault(i int) bool {
	if i < 0 || i >= len(m.vaults) {
		return false
	}
	id := m.vaults[i].ID
	if m.selected == id {
		return false
	}
	m.selected = id
	m.hadUsage = false
	m.barAnim = 0
	m.avail = availability{bucket: map[string]string{}, reset: map[string]int64{}}
	m.nextRefresh = time.Time{}
	m.usageStale = false
	return true
}

func (m model) persistVaultState() error {
	return writeVaultState(m.vaultState, m.selected, m.disabled)
}

// cycleVault advances the selection to the next enabled vault, wrapping and
// skipping disabled ones. It reports whether the selection changed.
func (m *model) cycleVault() (bool, error) {
	n := len(m.vaults)
	if n < 2 {
		return false, nil
	}
	cur := m.activeIndex()
	for step := 1; step <= n; step++ {
		j := (cur + step) % n
		if j == cur || !m.isEnabled(j) {
			continue
		}
		if !m.selectVault(j) {
			return false, nil
		}
		return true, m.persistVaultState()
	}
	return false, nil
}

// activateVault selects the vault at index i, enabling it first if it was
// disabled so the active vault is always enabled. It reports whether the
// selection changed.
func (m *model) activateVault(i int) (bool, error) {
	if i < 0 || i >= len(m.vaults) {
		return false, nil
	}
	if i != 0 {
		delete(m.disabled, m.vaults[i].ID)
	}
	changed := m.selectVault(i)
	return changed, m.persistVaultState()
}

// toggleVault flips the enabled state of the vault at index i. The first vault
// (the safe fallback) can never be disabled. Disabling the active vault falls
// the selection back to the fallback so the shown usage stays coherent. It
// reports whether the selection changed.
func (m *model) toggleVault(i int) (bool, error) {
	if i <= 0 || i >= len(m.vaults) {
		return false, nil
	}
	if m.disabled == nil {
		m.disabled = map[string]bool{}
	}
	id := m.vaults[i].ID
	selChanged := false
	if m.disabled[id] {
		delete(m.disabled, id)
	} else {
		m.disabled[id] = true
		if m.selected == id {
			selChanged = m.selectVault(0)
		}
	}
	return selChanged, m.persistVaultState()
}
